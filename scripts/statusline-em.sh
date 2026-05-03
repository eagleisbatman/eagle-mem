#!/usr/bin/env bash
# Eagle Mem statusline section — outputs a single formatted section
# Called by the user's statusline command to append Eagle Mem stats.
# Usage: source this script OR call eagle_mem_statusline "$project_dir"

eagle_mem_statusline() {
    local project_dir="${1:-}"
    local em_db="$HOME/.eagle-mem/memory.db"
    [ -f "$em_db" ] || return

    local SCRIPT_DIR; SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    . "$SCRIPT_DIR/../lib/common.sh"

    local proj
    proj=$(eagle_project_from_cwd "$project_dir")
    [ -z "$proj" ] && return

    proj=$(eagle_sql_escape "$proj")

    local cnt mem
    cnt=$(echo ".headers off
SELECT COUNT(*) FROM sessions WHERE project = '${proj}';" | sqlite3 "$em_db" 2>/dev/null | tr -d '[:space:]')
    mem=$(echo ".headers off
SELECT COUNT(*) FROM agent_memories WHERE project = '${proj}';" | sqlite3 "$em_db" 2>/dev/null | tr -d '[:space:]')
    cnt=${cnt:-0}; mem=${mem:-0}

    local R='\033[0m' CYAN='\033[96m' WHT='\033[97m' DIM='\033[2m'
    printf "%bEagle Mem%b %b%s%b ses %b%s%b mem" "$CYAN" "$R" "$WHT" "$cnt" "$DIM" "$WHT" "$mem" "$R"
}

# When run directly, read project_dir from stdin JSON (statusline format)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    input=$(cat)
    project_dir=$(echo "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // ""' 2>/dev/null)
    eagle_mem_statusline "$project_dir"
fi
