#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Stop hook
# Fires when Claude's turn ends
# Primary: extracts summary from transcript heuristically
# Bonus: eagle-summary block overrides where present
# LLM enrichment fills in decisions/gotchas/key_files
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

[ -z "$transcript_path" ] || [ ! -f "$transcript_path" ] && exit 0

# ─── Primary: heuristic extraction from transcript ───────────

request=$(jq -r 'select(.type == "user") | .message.content | if type == "string" then . elif type == "array" then [.[] | select(.type == "text") | .text] | join(" ") else "" end' "$transcript_path" 2>/dev/null \
    | grep -v '<local-command-caveat>' \
    | grep -v '<system-reminder>' \
    | grep -v '<command-name>' \
    | grep -v '<command-message>' \
    | grep -v '^\[{' \
    | head -1 | cut -c1-500)

heuristic_reads=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | select(.name == "Read") | .input.file_path // empty' "$transcript_path" 2>/dev/null | sort -u | head -20)
heuristic_writes=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | select(.name == "Write" or .name == "Edit") | .input.file_path // empty' "$transcript_path" 2>/dev/null | sort -u | head -20)

files_read="[]"
files_modified="[]"
if [ -n "$heuristic_reads" ]; then
    files_read=$(echo "$heuristic_reads" | jq -Rsc 'split("\n") | map(select(. != ""))')
fi
if [ -n "$heuristic_writes" ]; then
    files_modified=$(echo "$heuristic_writes" | jq -Rsc 'split("\n") | map(select(. != ""))')
fi

investigated=""
learned=""
completed=""
next_steps=""
notes=""
decisions=""
gotchas=""
key_files=""

eagle_log "INFO" "Stop: heuristic extraction complete"

# ─── Bonus: eagle-summary block overrides where present ──────

text_content=$(jq -rs '
    [.[] | select(.type == "assistant")] | last |
    if . then
        [.message.content[]? | select(.type == "text") | .text] | join("\n")
    else "" end
' "$transcript_path" 2>/dev/null)

# Strip <private>...</private> blocks
text_content=$(echo "$text_content" | sed -E '/<[Pp][Rr][Ii][Vv][Aa][Tt][Ee][^>]*>/,/<\/[Pp][Rr][Ii][Vv][Aa][Tt][Ee][[:space:]]*>/d')

summary_block=""
if [ -n "$text_content" ] && echo "$text_content" | grep -q '<eagle-summary>' 2>/dev/null; then
    summary_block=$(echo "$text_content" | sed -n '/<eagle-summary>/,/<\/eagle-summary>/p' | sed '1d;$d')
fi

if [ -n "$summary_block" ]; then
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

    # Override heuristic fields with eagle-summary where non-empty
    _val=$(parse_field "$summary_block" "request");       [ -n "$_val" ] && request="$_val"
    _val=$(parse_field "$summary_block" "investigated");  [ -n "$_val" ] && investigated="$_val"
    _val=$(parse_field "$summary_block" "learned");       [ -n "$_val" ] && learned="$_val"
    _val=$(parse_field "$summary_block" "completed");     [ -n "$_val" ] && completed="$_val"
    _val=$(parse_field "$summary_block" "next_steps");    [ -n "$_val" ] && next_steps="$_val"
    _val=$(parse_field "$summary_block" "decisions");     [ -n "$_val" ] && decisions="$_val"
    _val=$(parse_field "$summary_block" "gotchas");       [ -n "$_val" ] && gotchas="$_val"
    _val=$(parse_field "$summary_block" "key_files");     [ -n "$_val" ] && key_files="$_val"

    # Convert bracket-list to JSON array
    to_json_array() {
        local raw="$1"
        raw=$(echo "$raw" | sed 's/^\[//;s/\]$//')
        echo "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -Rsc 'split("\n") | map(select(. != ""))'
    }

    raw_fr=$(parse_field "$summary_block" "files_read")
    raw_fm=$(parse_field "$summary_block" "files_modified")
    [ -n "$raw_fr" ] && files_read=$(to_json_array "$raw_fr")
    [ -n "$raw_fm" ] && files_modified=$(to_json_array "$raw_fm")

    eagle_log "INFO" "Stop: eagle-summary block merged over heuristic data"
fi

# ─── LLM enrichment: extract structured data when eagle-summary absent ──
# Runs when: (a) no eagle-summary block, OR (b) heuristic data is thin
# Skips when: eagle-summary already provided rich data, OR no text to analyze

context_pressure=0
if [ -f "$EAGLE_MEM_DIR/.context-pressure" ]; then
    context_pressure=1
fi

has_rich_data=0
if [ -n "$decisions" ] || [ -n "$gotchas" ] || [ -n "$key_files" ]; then
    has_rich_data=1
fi

request_is_polluted=0
if echo "$request" | grep -qE '<(local-command-caveat|system-reminder|command-name)>' 2>/dev/null; then
    request_is_polluted=1
fi

needs_enrichment=0
if [ "$has_rich_data" -eq 0 ]; then
    needs_enrichment=1
elif [ "$context_pressure" -eq 1 ]; then
    needs_enrichment=1
elif [ -z "$completed" ] && [ -z "$learned" ]; then
    needs_enrichment=1
elif [ "$request_is_polluted" -eq 1 ]; then
    needs_enrichment=1
fi

if [ "$needs_enrichment" -eq 1 ]; then
    provider=$(eagle_config_get "provider" "type" "none" 2>/dev/null)
    if [ "$provider" != "none" ] && [ -n "$text_content" ]; then
        excerpt=$(echo "$text_content" | tail -c 3000)

        enrich_prompt="Extract facts from this Claude Code session. Only include items with clear evidence in the session text. Do NOT invent or repeat example content.

Respond with EXACTLY these sections (omit sections with no evidence):

REQUEST:
One-line summary of what the user asked for. No system tags or XML.

COMPLETED:
What was actually accomplished. Be specific about changes made.

LEARNED:
Non-obvious discoveries or insights from the session.

DECISIONS:
Each as: <what was decided> — why: <reason>

GOTCHAS:
Each as: <surprising finding or pitfall>

KEY_FILES:
Each as: <filepath>

SESSION TEXT:
$excerpt"

        enrich_system="You extract structured facts from development sessions. Output format for decisions: '- Did X — why: Y'. Output format for gotchas: '- Gotcha description'. Be concise. Only include items with clear evidence in the session text. Never fabricate content."
        enrich_result=$(eagle_llm_call "$enrich_prompt" "$enrich_system" 768 2>/dev/null)
        llm_rc=$?

        if [ $llm_rc -ne 0 ] || [ -z "$enrich_result" ]; then
            eagle_log "WARN" "Stop: LLM enrichment failed (rc=$llm_rc) for session=$session_id provider=$provider"
        else
            extract_section() {
                local result="$1" header="$2"
                echo "$result" | awk -v h="$header:" '
                    $0 == h || $0 ~ "^"h { found=1; next }
                    found && /^[A-Z_]+:/ { exit }
                    found && /^[[:space:]]*$/ { next }
                    found && /^- / { sub(/^- /, ""); lines[++n] = $0; next }
                    found { lines[++n] = $0 }
                    END { for (i=1; i<=n; i++) { printf "%s", lines[i]; if (i<n) printf "; " } }
                '
            }
            _req=$(extract_section "$enrich_result" "REQUEST")
            _comp=$(extract_section "$enrich_result" "COMPLETED")
            _learn=$(extract_section "$enrich_result" "LEARNED")
            _dec=$(extract_section "$enrich_result" "DECISIONS")
            _got=$(extract_section "$enrich_result" "GOTCHAS")
            _kf=$(extract_section "$enrich_result" "KEY_FILES")

            [ -z "$request" ] || [ "$request_is_polluted" -eq 1 ] && [ -n "$_req" ] && request="$_req"
            [ -z "$completed" ] && [ -n "$_comp" ] && completed="$_comp"
            [ -z "$learned" ] && [ -n "$_learn" ] && learned="$_learn"
            [ -z "$decisions" ] && [ -n "$_dec" ] && decisions="$_dec"
            [ -z "$gotchas" ] && [ -n "$_got" ] && gotchas="$_got"
            [ -z "$key_files" ] && [ -n "$_kf" ] && key_files="$_kf"

            eagle_log "INFO" "Stop: LLM enrichment extracted for session=$session_id (req=${#_req} comp=${#_comp} dec=${#_dec})"
        fi
    else
        eagle_log "INFO" "Stop: LLM enrichment skipped — provider=$provider text_len=${#text_content}"
    fi
else
    eagle_log "INFO" "Stop: LLM enrichment skipped — rich data already present"
fi

# ─── Test reminder for guardrailed files ─────────────────

if [ -n "$files_modified" ] && [ "$files_modified" != "[]" ]; then
    # Short-circuit: skip per-file loop if project has no guardrails at all
    has_gr=$(eagle_has_any_guardrails "$project" 2>/dev/null)
    if [ -n "$has_gr" ]; then
        guardrailed_files=""
        while IFS= read -r mod_file; do
            [ -z "$mod_file" ] && continue
            mod_basename=$(basename "$mod_file")
            gr_check=$(eagle_get_guardrails_for_file "$project" "$mod_basename" 2>/dev/null)
            if [ -n "$gr_check" ]; then
                guardrailed_files+="${mod_basename}, "
            fi
        done < <(echo "$files_modified" | jq -r '.[]?' 2>/dev/null)

        if [ -n "$guardrailed_files" ]; then
            guardrailed_files=${guardrailed_files%, }
            test_reminder="Run affected tests for guardrailed files: ${guardrailed_files}"
            if [ -n "$next_steps" ]; then
                next_steps="${next_steps}; ${test_reminder}"
            else
                next_steps="$test_reminder"
            fi
            eagle_log "INFO" "Stop: added test reminder for guardrailed files: $guardrailed_files"
        fi
    fi
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
