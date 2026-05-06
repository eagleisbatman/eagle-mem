#!/usr/bin/env bash
# Eagle Mem statusline renderers.
# Usage:
#   source this file and call eagle_mem_statusline "$project_dir" "$session_id" "$input"
#   printf '%s' "$input" | bash ~/.eagle-mem/scripts/statusline-em.sh --hud

_eagle_statusline_load_common() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    . "$script_dir/../lib/common.sh"
}

_eagle_statusline_relative_time() {
    local raw="${1:-}"
    [ -n "$raw" ] && [ "$raw" != "never" ] || { printf 'never\n'; return; }

    local last_epoch now_epoch diff_sec
    last_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${raw%%.*}" "+%s" 2>/dev/null \
        || date -u -d "$raw" "+%s" 2>/dev/null \
        || true)
    now_epoch=$(date "+%s" 2>/dev/null || true)
    if [ -z "$last_epoch" ] || [ -z "$now_epoch" ]; then
        printf '%s\n' "$raw"
        return
    fi

    diff_sec=$((now_epoch - last_epoch))
    if [ "$diff_sec" -lt 60 ]; then
        printf 'just now\n'
    elif [ "$diff_sec" -lt 3600 ]; then
        printf '%sm ago\n' "$((diff_sec / 60))"
    elif [ "$diff_sec" -lt 86400 ]; then
        printf '%sh ago\n' "$((diff_sec / 3600))"
    else
        printf '%sd ago\n' "$((diff_sec / 86400))"
    fi
}

eagle_mem_statusline_stats() {
    local project_dir="${1:-}"
    local session_id="${2:-}"
    local statusline_input="${3:-}"
    local current_dir="${4:-}"
    local em_db="$HOME/.eagle-mem/memory.db"
    [ -f "$em_db" ] || return

    _eagle_statusline_load_common

    local sqlite_bin
    sqlite_bin=$(eagle_sqlite_path)
    [ -n "$sqlite_bin" ] || return

    if [ -n "$statusline_input" ]; then
        [ -z "$session_id" ] && session_id=$(printf '%s' "$statusline_input" | jq -r '.session_id // .session.id // empty' 2>/dev/null)
        [ -z "$project_dir" ] && project_dir=$(printf '%s' "$statusline_input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // empty' 2>/dev/null)
        [ -z "$current_dir" ] && current_dir=$(printf '%s' "$statusline_input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
    fi
    [ -z "$project_dir" ] && project_dir="$(pwd)"
    [ -z "$current_dir" ] && current_dir="$project_dir"

    local project_key project_scope project_condition stats sessions memories last_raw turns version latest
    project_key=$(eagle_project_from_statusline_input "$statusline_input" "$project_dir" "$current_dir" "$session_id")
    [ -n "$project_key" ] || return
    project_scope=$(eagle_recall_project_scope_from_cwd "${current_dir:-$project_dir}" "$project_key")
    project_condition=$(eagle_sql_project_scope_condition "project" "$project_scope")

    stats=$("$sqlite_bin" "$em_db" "SELECT
        COUNT(*) || '|' ||
        (SELECT COUNT(*) FROM agent_memories WHERE $project_condition) || '|' ||
        COALESCE(MAX(COALESCE(last_activity_at, started_at)), 'never')
        FROM sessions
        WHERE $project_condition;" 2>/dev/null)
    IFS='|' read -r sessions memories last_raw <<< "${stats:-0|0|never}"
    sessions=${sessions:-0}
    memories=${memories:-0}
    last_raw=${last_raw:-never}

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
    turns=${turns:-0}

    version=$(tr -d '[:space:]' < "$HOME/.eagle-mem/.version" 2>/dev/null)
    latest=$(tr -d '[:space:]' < "$HOME/.eagle-mem/.latest-version" 2>/dev/null)
    [ -z "$version" ] && version="?"
    [ -z "$latest" ] && latest="$version"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$project_key" "$version" "$latest" "$sessions" "$memories" "$turns" "$last_raw"
}

eagle_mem_statusline() {
    local stats project_key version latest sessions memories turns last_raw
    stats=$(eagle_mem_statusline_stats "${1:-}" "${2:-}" "${3:-}" "${4:-}") || return
    IFS=$'\t' read -r project_key version latest sessions memories turns last_raw <<< "$stats"

    local R='\033[0m' CYAN='\033[96m' WHT='\033[97m' DIM='\033[2m'
    printf "%bEagle%b %bv%s%b | %b%s%b sessions | %b%s%b memories | turn %b%s%b" \
        "$CYAN" "$R" \
        "$WHT" "$version" "$DIM" \
        "$WHT" "${sessions:-0}" "$DIM" \
        "$WHT" "${memories:-0}" "$DIM" \
        "$WHT" "${turns:-0}" "$R"
}

eagle_mem_statusline_hud() {
    local stats project_key version latest sessions memories turns last_raw last_label
    stats=$(eagle_mem_statusline_stats "${1:-}" "${2:-}" "${3:-}" "${4:-}") || return
    IFS=$'\t' read -r project_key version latest sessions memories turns last_raw <<< "$stats"
    last_label=$(_eagle_statusline_relative_time "$last_raw")

    local R='\033[0m' CYAN='\033[96m' WHT='\033[97m' DIM='\033[2m'
    local GRN='\033[92m' ORG='\033[38;5;214m' RED='\033[91m'
    local turn_color pressure_label em_ver newest

    turns=${turns:-0}
    if [ "$turns" -ge 30 ] 2>/dev/null; then
        turn_color="$RED"; pressure_label="CRITICAL"
    elif [ "$turns" -ge 20 ] 2>/dev/null; then
        turn_color="$ORG"; pressure_label="HIGH"
    else
        turn_color="$GRN"; pressure_label="OK"
    fi

    em_ver="v${version:-?}"
    newest=$(printf '%s\n' "${version:-}" "${latest:-}" | sort -V 2>/dev/null | tail -1 || true)
    if [ -n "$latest" ] && [ -n "$newest" ] && [ "$newest" != "$version" ]; then
        em_ver="${em_ver} ${ORG}↑${latest}${R}"
    elif [ -n "$latest" ] && [ "$latest" = "$version" ]; then
        em_ver="${em_ver} ${GRN}✓${R}"
    fi

    printf "%bEagle Mem%b %b %b│%b %bSessions:%b %b%s%b %b│%b %bMemories:%b %b%s%b %b│%b %bTurns:%b %b%s/30%b %b(%s)%b %b│%b %bUpdated:%b %b%s%b" \
        "$CYAN" "$R" "$em_ver" \
        "$DIM" "$R" "$DIM" "$R" "$WHT" "${sessions:-0}" "$R" "$DIM" "$R" \
        "$DIM" "$R" "$WHT" "${memories:-0}" "$R" "$DIM" "$R" \
        "$DIM" "$R" "$turn_color" "$turns" "$R" "$turn_color" "$pressure_label" "$R" "$DIM" "$R" \
        "$DIM" "$R" "$WHT" "$last_label" "$R"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    mode="${1:-compact}"
    if [ -t 0 ]; then
        input=""
    else
        input=$(cat)
    fi
    project_dir=$(printf '%s' "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // empty' 2>/dev/null)
    current_dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
    session_id=$(printf '%s' "$input" | jq -r '.session_id // .session.id // empty' 2>/dev/null)

    case "$mode" in
        --hud|hud)
            eagle_mem_statusline_hud "${project_dir:-$(pwd)}" "$session_id" "$input" "$current_dir"
            ;;
        --stats|stats)
            eagle_mem_statusline_stats "${project_dir:-$(pwd)}" "$session_id" "$input" "$current_dir"
            ;;
        *)
            eagle_mem_statusline "${project_dir:-$(pwd)}" "$session_id" "$input" "$current_dir"
            ;;
    esac
fi
