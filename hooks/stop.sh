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

    # Strip <private>...</private> blocks before processing
    text_content=$(echo "$text_content" | sed '/<private>/,/<\/private>/d')

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
        found && /^(request|investigated|learned|completed|next_steps|files_read|files_modified|notes):/ { exit }
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

if [ -n "$summary_block" ]; then
    request=$(parse_field "$summary_block" "request")
    investigated=$(parse_field "$summary_block" "investigated")
    learned=$(parse_field "$summary_block" "learned")
    completed=$(parse_field "$summary_block" "completed")
    next_steps=$(parse_field "$summary_block" "next_steps")

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

# ─── Heuristic fallback: extract from tool calls ───────────

if [ -z "$request" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    eagle_log "INFO" "Stop: no eagle-summary found, using heuristic fallback"

    # Extract first user prompt as "request"
    request=$(jq -r 'select(.type == "user") | .message.content | if type == "string" then . elif type == "array" then [.[] | select(.type == "text") | .text] | join(" ") else "" end' "$transcript_path" 2>/dev/null | head -1 | cut -c1-500)

    # Extract files from Read/Write/Edit tool calls
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

# ─── Write to database ─────────────────────────────────────

if [ -n "$request" ] || [ -n "$completed" ] || [ -n "$learned" ]; then
    eagle_insert_summary "$session_id" "$project" "$request" "$investigated" "$learned" "$completed" "$next_steps" "$files_read" "$files_modified" "$notes"
    eagle_log "INFO" "Stop: summary saved for session=$session_id"
fi

# Mark active task as done if eagle-summary mentions completion
if [ -n "$completed" ]; then
    completed_task_id=$(eagle_complete_active_task "$project")
    if [ -n "$completed_task_id" ]; then
        eagle_log "INFO" "Stop: marked task #$completed_task_id as done"
    fi
fi

exit 0
