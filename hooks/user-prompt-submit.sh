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
project_sql=$(eagle_sql_escape "$project")

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

fts_query_escaped=$(eagle_sql_escape "$fts_query")

# Search for relevant past summaries (cross-session)
results=$(eagle_db "SELECT s.request, s.learned, s.completed, s.created_at
                    FROM summaries s
                    JOIN summaries_fts f ON f.rowid = s.id
                    WHERE summaries_fts MATCH '$fts_query_escaped'
                    AND s.project = '$project_sql'
                    ORDER BY rank
                    LIMIT 3;")

context=""

if [ -n "$results" ]; then
    context+="=== EAGLE MEM — Relevant Memory ===
"
    while IFS='|' read -r req learned completed created_at; do
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
has_chunks=$(eagle_db "SELECT COUNT(*) FROM code_chunks WHERE project = '$project_sql' LIMIT 1;")
if [ "${has_chunks:-0}" -gt 0 ]; then
    code_results=$(eagle_db "SELECT c.file_path, c.start_line, c.end_line, c.language
                             FROM code_chunks c
                             JOIN code_chunks_fts f ON f.rowid = c.id
                             WHERE code_chunks_fts MATCH '$fts_query_escaped'
                             AND c.project = '$project_sql'
                             ORDER BY rank
                             LIMIT 5;")

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

echo "$context"
exit 0
