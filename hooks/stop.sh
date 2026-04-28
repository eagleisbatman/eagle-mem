#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Stop hook
# Fires when Claude's turn ends
# Parses <eagle-summary> from transcript, saves to DB
# Falls back to heuristic extraction if no summary block
# ═══════════════════════════════════════════════════════════
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/provider.sh"

eagle_ensure_db

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

[ -z "$session_id" ] && exit 0

# Skip subagent contexts
agent_type=$(echo "$input" | jq -r '.agent_type // empty')
[ -n "$agent_type" ] && [ "$agent_type" != "main" ] && exit 0

project=$(eagle_project_from_cwd "$cwd")
[ -z "$project" ] && exit 0

eagle_log "INFO" "Stop: session=$session_id project=$project transcript=$transcript_path"

# Ensure session exists (may not if SessionStart didn't fire)
eagle_upsert_session "$session_id" "$project" "$cwd" "" ""

# ─── Try to parse <eagle-summary> from transcript ──────────

summary_block=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    # Extract all text from the last assistant message using jq on JSONL
    # Real transcript format: top-level .type == "assistant", content in .message.content[]
    text_content=$(jq -rs '
        [.[] | select(.type == "assistant")] | last |
        if . then
            [.message.content[]? | select(.type == "text") | .text] | join("\n")
        else "" end
    ' "$transcript_path" 2>/dev/null)

    # Strip <private>...</private> blocks before processing (case-insensitive, tolerates attributes/whitespace)
    text_content=$(echo "$text_content" | sed -E '/<[Pp][Rr][Ii][Vv][Aa][Tt][Ee][^>]*>/,/<\/[Pp][Rr][Ii][Vv][Aa][Tt][Ee][[:space:]]*>/d')

    # Parse <eagle-summary> block
    if [ -n "$text_content" ] && echo "$text_content" | grep -q '<eagle-summary>' 2>/dev/null; then
        summary_block=$(echo "$text_content" | sed -n '/<eagle-summary>/,/<\/eagle-summary>/p' | sed '1d;$d')
    fi
fi

# ─── Extract fields from summary block ─────────────────────

parse_field() {
    local block="$1"
    local field="$2"
    echo "$block" | awk -v f="$field" '
        BEGIN { IGNORECASE=1; found=0 }
        $0 ~ "^"f":" {
            sub("^"f":[[:space:]]*", ""); found=1; val=$0; next
        }
        found && /^(request|investigated|learned|completed|next_steps|files_read|files_modified|notes|decisions|gotchas|key_files):/ { exit }
        found { val = val " " $0 }
        END { if (found) print val }
    '
}

request=""
investigated=""
learned=""
completed=""
next_steps=""
files_read="[]"
files_modified="[]"
notes=""
decisions=""
gotchas=""
key_files=""

if [ -n "$summary_block" ]; then
    request=$(parse_field "$summary_block" "request")
    investigated=$(parse_field "$summary_block" "investigated")
    learned=$(parse_field "$summary_block" "learned")
    completed=$(parse_field "$summary_block" "completed")
    next_steps=$(parse_field "$summary_block" "next_steps")
    decisions=$(parse_field "$summary_block" "decisions")
    gotchas=$(parse_field "$summary_block" "gotchas")
    key_files=$(parse_field "$summary_block" "key_files")

    raw_fr=$(parse_field "$summary_block" "files_read")
    raw_fm=$(parse_field "$summary_block" "files_modified")

    # Convert bracket-list to JSON array (handles special chars safely)
    to_json_array() {
        local raw="$1"
        raw=$(echo "$raw" | sed 's/^\[//;s/\]$//')
        echo "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -Rsc 'split("\n") | map(select(. != ""))'
    }

    [ -n "$raw_fr" ] && files_read=$(to_json_array "$raw_fr")
    [ -n "$raw_fm" ] && files_modified=$(to_json_array "$raw_fm")

    eagle_log "INFO" "Stop: parsed eagle-summary block"
fi

# ─── Guard: skip fallback work if summary already exists ──
# Stop fires every assistant turn. Without this, the heuristic and LLM
# enrichment blocks fire on turn 2+ — wasting tokens and producing
# empty inserts that get rejected.

existing_count=0
if [ -z "$summary_block" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    existing_count=$(eagle_count_session_summaries "$session_id")
fi

if [ -z "$summary_block" ] && [ "${existing_count:-0}" -eq 0 ]; then

    # ─── Heuristic fallback: extract from tool calls ───────────

    if [ -z "$request" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        eagle_log "INFO" "Stop: no eagle-summary found, using heuristic fallback"

        request=$(jq -r 'select(.type == "user") | .message.content | if type == "string" then . elif type == "array" then [.[] | select(.type == "text") | .text] | join(" ") else "" end' "$transcript_path" 2>/dev/null | head -1 | cut -c1-500)

        heuristic_reads=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | select(.name == "Read") | .input.file_path // empty' "$transcript_path" 2>/dev/null | sort -u | head -20)
        heuristic_writes=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | select(.name == "Write" or .name == "Edit") | .input.file_path // empty' "$transcript_path" 2>/dev/null | sort -u | head -20)

        if [ -n "$heuristic_reads" ]; then
            files_read=$(echo "$heuristic_reads" | jq -Rsc 'split("\n") | map(select(. != ""))')
        fi
        if [ -n "$heuristic_writes" ]; then
            files_modified=$(echo "$heuristic_writes" | jq -Rsc 'split("\n") | map(select(. != ""))')
        fi

        completed="(auto-captured from tool usage)"
    fi

    # ─── LLM enrichment: extract decisions/gotchas/key_files ──

    if [ -z "$decisions" ] && [ -z "$gotchas" ] && [ -z "$key_files" ]; then
        provider=$(eagle_config_get "provider" "type" "none" 2>/dev/null)
        if [ "$provider" != "none" ] && [ -n "$text_content" ]; then
            excerpt=$(echo "$text_content" | tail -c 2000)

            enrich_prompt="Extract from this Claude Code session excerpt:
1. DECISIONS: architectural or design choices made (with WHY). One per line.
2. GOTCHAS: non-obvious pitfalls, bugs found, things that surprised. One per line.
3. KEY_FILES: important files that were central to the work. One per line.

SESSION EXCERPT:
$excerpt

Output EXACTLY this format (omit sections with nothing to report):
DECISIONS:
- <decision> — why: <reason>
GOTCHAS:
- <gotcha>
KEY_FILES:
- <filepath>"

            enrich_result=$(eagle_llm_call "$enrich_prompt" "Extract structured facts from development sessions. Be concise. Only include items with clear evidence." 512 2>/dev/null) || true

            if [ -n "$enrich_result" ]; then
                extract_section() {
                    local result="$1" header="$2"
                    echo "$result" | awk -v h="$header:" '
                        $0 == h || $0 ~ "^"h { found=1; next }
                        found && /^[A-Z_]+:/ { exit }
                        found && /^- / { sub(/^- /, ""); lines[++n] = $0 }
                        END { for (i=1; i<=n; i++) { printf "%s", lines[i]; if (i<n) printf "; " } }
                    '
                }
                decisions=$(extract_section "$enrich_result" "DECISIONS")
                gotchas=$(extract_section "$enrich_result" "GOTCHAS")
                key_files=$(extract_section "$enrich_result" "KEY_FILES")
                [ -n "$decisions" ] || [ -n "$gotchas" ] || [ -n "$key_files" ] && eagle_log "INFO" "Stop: LLM enrichment extracted for session=$session_id"
            fi
        fi
    fi

elif [ -z "$summary_block" ] && [ "${existing_count:-0}" -gt 0 ]; then
    eagle_log "INFO" "Stop: skipping fallback — summary already exists for session=$session_id (count=$existing_count)"
fi

# ─── Redact secrets from all text fields before storage ────

request=$(echo "$request" | eagle_redact)
investigated=$(echo "$investigated" | eagle_redact)
learned=$(echo "$learned" | eagle_redact)
completed=$(echo "$completed" | eagle_redact)
next_steps=$(echo "$next_steps" | eagle_redact)
decisions=$(echo "$decisions" | eagle_redact)
gotchas=$(echo "$gotchas" | eagle_redact)
key_files=$(echo "$key_files" | eagle_redact)

# ─── Write to database ─────────────────────────────────────

if [ -n "$request" ] || [ -n "$completed" ] || [ -n "$learned" ]; then
    if eagle_insert_summary "$session_id" "$project" "$request" "$investigated" "$learned" "$completed" "$next_steps" "$files_read" "$files_modified" "$notes" "$decisions" "$gotchas" "$key_files"; then
        eagle_log "INFO" "Stop: summary saved for session=$session_id"
    else
        eagle_log "ERROR" "Stop: summary insert FAILED for session=$session_id — check DB constraints"
    fi
fi

exit 0
