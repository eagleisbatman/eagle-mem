#!/usr/bin/env bash
# Eagle Mem statusline section — outputs a single formatted section
# Called by the user's statusline command to append Eagle Mem stats.
# Usage: source this script OR call eagle_mem_statusline "$project_dir"

eagle_mem_statusline() {
    local project_dir="${1:-}"
    local session_id="${2:-}"
    local em_db="$HOME/.eagle-mem/memory.db"
    [ -f "$em_db" ] || return

    local SCRIPT_DIR; SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    . "$SCRIPT_DIR/../lib/common.sh"

    local proj
    [ -z "$project_dir" ] && project_dir="$(pwd)"
    proj=$(eagle_project_from_cwd "$project_dir")
    [ -z "$proj" ] && return

    proj=$(eagle_sql_escape "$proj")

    local version cnt mem turns
    version=$(tr -d '[:space:]' < "$HOME/.eagle-mem/.version" 2>/dev/null)
    [ -z "$version" ] && version="?"
    cnt=$(echo ".headers off
SELECT COUNT(*) FROM sessions WHERE project = '${proj}';" | sqlite3 "$em_db" 2>/dev/null | tr -d '[:space:]')
    mem=$(echo ".headers off
SELECT COUNT(*) FROM agent_memories WHERE project = '${proj}';" | sqlite3 "$em_db" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$session_id" ] && [ -f "$HOME/.eagle-mem/.turn-counter.${session_id}" ]; then
        turns=$(tr -d '[:space:]' < "$HOME/.eagle-mem/.turn-counter.${session_id}" 2>/dev/null)
    else
        turns=$(find "$HOME/.eagle-mem" -name '.turn-counter.*' -type f -mtime -1 -print 2>/dev/null \
            | while IFS= read -r f; do
                tr -d '[:space:]' < "$f" 2>/dev/null
                echo ""
            done \
            | awk '($1+0)>max{max=$1+0} END{print max+0}')
    fi
    cnt=${cnt:-0}; mem=${mem:-0}
    turns=${turns:-0}

    local R='\033[0m' CYAN='\033[96m' WHT='\033[97m' DIM='\033[2m'
    printf "%bEM%b %bv%s%b ses %b%s%b mem %b%s%b turns %b%s%b" \
        "$CYAN" "$R" \
        "$WHT" "$version" "$DIM" \
        "$WHT" "$cnt" "$DIM" \
        "$WHT" "$mem" "$DIM" \
        "$WHT" "$turns" "$R"
}

# When run directly, read project_dir from stdin JSON (statusline format)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ -t 0 ]; then
        input=""
    else
        input=$(cat)
    fi
    project_dir=$(echo "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // empty' 2>/dev/null)
    session_id=$(echo "$input" | jq -r '.session_id // .session.id // empty' 2>/dev/null)
    eagle_mem_statusline "${project_dir:-$(pwd)}" "$session_id"
fi
