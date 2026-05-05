#!/usr/bin/env bash
# Eagle Mem — background summary enrichment
# Runs outside lifecycle hook timeouts. Input is a JSON job file created by Stop.
set +e
[ "${EAGLE_MEM_DISABLE_BACKGROUND_ENRICH:-}" = "1" ] && exit 0

job_file="${1:-}"
[ -n "$job_file" ] && [ -f "$job_file" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/provider.sh"

eagle_ensure_db || exit 0

session_id=$(jq -r '.session_id // empty' "$job_file" 2>/dev/null)
project=$(jq -r '.project // empty' "$job_file" 2>/dev/null)
agent=$(jq -r '.agent // empty' "$job_file" 2>/dev/null)
text_content=$(jq -r '.text // empty' "$job_file" 2>/dev/null)

if [ -z "$session_id" ] || [ -z "$project" ] || [ -z "$text_content" ]; then
    rm -f "$job_file" 2>/dev/null || true
    exit 0
fi

provider=$(eagle_config_get "provider" "type" "none" 2>/dev/null)
if [ "$provider" = "none" ]; then
    eagle_log "INFO" "Summary enrichment skipped: no provider for session=$session_id"
    rm -f "$job_file" 2>/dev/null || true
    exit 0
fi

excerpt=$(printf '%s' "$text_content" | tail -c 3000)

enrich_prompt="Extract facts from this AI coding session. Only include items with clear evidence in the session text. Do NOT invent or repeat example content.

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

enrich_system="You extract structured facts from Claude Code and Codex development sessions. Output format for decisions: '- Did X — why: Y'. Output format for gotchas: '- Gotcha description'. Be concise. Only include items with clear evidence in the session text. Never fabricate content."
enrich_result=$(eagle_llm_call "$enrich_prompt" "$enrich_system" 768 2>/dev/null)
llm_rc=$?

if [ $llm_rc -ne 0 ] || [ -z "$enrich_result" ]; then
    eagle_log "WARN" "Summary enrichment failed (rc=$llm_rc) for session=$session_id provider=$provider"
    rm -f "$job_file" 2>/dev/null || true
    exit 0
fi

extract_section() {
    local result="$1" header="$2"
    printf '%s\n' "$result" | awk -v h="$header:" '
        $0 == h || $0 ~ "^"h { found=1; next }
        found && /^[A-Z_]+:/ { exit }
        found && /^[[:space:]]*$/ { next }
        found && /^- / { sub(/^- /, ""); lines[++n] = $0; next }
        found { lines[++n] = $0 }
        END { for (i=1; i<=n; i++) { printf "%s", lines[i]; if (i<n) printf "; " } }
    '
}

request=$(extract_section "$enrich_result" "REQUEST" | eagle_redact)
completed=$(extract_section "$enrich_result" "COMPLETED" | eagle_redact)
learned=$(extract_section "$enrich_result" "LEARNED" | eagle_redact)
decisions=$(extract_section "$enrich_result" "DECISIONS" | eagle_redact)
gotchas=$(extract_section "$enrich_result" "GOTCHAS" | eagle_redact)
key_files=$(extract_section "$enrich_result" "KEY_FILES" | eagle_redact)

if [ -n "$request" ] || [ -n "$completed" ] || [ -n "$learned" ] || [ -n "$decisions" ] || [ -n "$gotchas" ] || [ -n "$key_files" ]; then
    eagle_insert_summary "$session_id" "$project" "$request" "" "$learned" "$completed" "" "[]" "[]" "" "$decisions" "$gotchas" "$key_files" "$agent"
    eagle_log "INFO" "Summary enrichment saved for session=$session_id provider=$provider"
fi

rm -f "$job_file" 2>/dev/null || true
exit 0
