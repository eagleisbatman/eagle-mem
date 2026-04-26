#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — UserPromptSubmit hook
# Fires when the user submits a prompt
# Searches memory for relevant context and injects it
# ═══════════════════════════════════════════════════════════
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

[ ! -f "$EAGLE_MEM_DB" ] && exit 0

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
user_prompt=$(echo "$input" | jq -r '.prompt // empty')

[ -z "$user_prompt" ] && exit 0

project=$(eagle_project_from_cwd "$cwd")

# Skip short prompts — not enough signal for meaningful search
word_count=$(echo "$user_prompt" | wc -w | tr -d ' ')
[ "$word_count" -lt 3 ] && exit 0

# Build FTS5 query from significant words (drop stop words, take first 6)
fts_query=$(echo "$user_prompt" | tr -cs '[:alnum:]' ' ' | tr '[:upper:]' '[:lower:]' | \
    awk '{
        split("the a an is are was were be been being have has had do does did will would shall should may might can could of in to for on with at by from", sw, " ")
        for (i in sw) stop[sw[i]]=1
        n=0
        for (i=1; i<=NF && n<6; i++) {
            if (length($i) > 2 && !($i in stop)) {
                printf "%s%s", (n>0?" OR ":""), $i; n++
            }
        }
    }')

[ -z "$fts_query" ] && exit 0

# Search for relevant past summaries (cross-session)
results=$(eagle_search_summaries "$fts_query" "$project" 3)

context=""

if [ -n "$results" ]; then
    context+="=== EAGLE MEM — Relevant Memory ===
"
    while IFS='|' read -r req completed learned _next_steps created_at _proj; do
        [ -z "$req" ] && [ -z "$completed" ] && continue
        context+="[$created_at] "
        [ -n "$req" ] && context+="$req"
        [ -n "$completed" ] && context+=" → $completed"
        [ -n "$learned" ] && context+=" (Learned: $learned)"
        context+="
"
    done <<< "$results"
fi

# Search indexed code chunks (if any exist for this project)
has_chunks=$(eagle_count_code_chunks "$project")
if [ "${has_chunks:-0}" -gt 0 ]; then
    code_results=$(eagle_search_code_chunks "$fts_query" "$project" 5)

    if [ -n "$code_results" ]; then
        context+="=== EAGLE MEM — Relevant Code ===
"
        while IFS='|' read -r fpath sline eline lang; do
            [ -z "$fpath" ] && continue
            context+="$fpath:${sline}-${eline}"
            [ -n "$lang" ] && context+=" ($lang)"
            context+="
"
        done <<< "$code_results"
    fi
fi

[ -z "$context" ] && exit 0

context+="
IMPORTANT: When Eagle Mem finds relevant memories or code for the user's prompt, briefly mention it at the start of your response: \"Eagle Mem recalled N relevant sessions\" or \"Eagle Mem found related code in [files]\". One line max — then proceed with the answer.

— Eagle Mem (persistent memory across sessions)
"

echo "$context"
exit 0
