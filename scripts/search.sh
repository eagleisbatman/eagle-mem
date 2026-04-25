#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Search
# CLI wrapper for memory search (replaces raw SQL in skills)
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

# ─── Parse arguments ──────────────────────────────────────

mode="keyword"
project=""
limit=10
session_id=""
json_output=false
query=""
cross_project=false

while [ $# -gt 0 ]; do
    case "$1" in
        --timeline|-t)      mode="timeline"; shift ;;
        --session|-s)        mode="session"; session_id="$2"; shift 2 ;;
        --files|-f)          mode="files"; shift ;;
        --stats)             mode="stats"; shift ;;
        --project|-p)        project="$2"; shift 2 ;;
        --limit|-n)          limit="$2"; shift 2 ;;
        --all|-a)            cross_project=true; shift ;;
        --json|-j)           json_output=true; shift ;;
        --help|-h)
            echo -e "  ${BOLD}eagle-mem search${RESET} — Search persistent memory"
            echo ""
            echo -e "  ${BOLD}Usage:${RESET}"
            echo -e "    eagle-mem search ${CYAN}<query>${RESET}                   ${DIM}# keyword search${RESET}"
            echo -e "    eagle-mem search ${CYAN}--timeline${RESET}               ${DIM}# recent sessions${RESET}"
            echo -e "    eagle-mem search ${CYAN}--session <id>${RESET}            ${DIM}# session details${RESET}"
            echo -e "    eagle-mem search ${CYAN}--files${RESET}                  ${DIM}# frequently modified files${RESET}"
            echo -e "    eagle-mem search ${CYAN}--stats${RESET}                  ${DIM}# project statistics${RESET}"
            echo ""
            echo -e "  ${BOLD}Options:${RESET}"
            echo -e "    ${CYAN}-p, --project${RESET} <name>    Project name (default: current dir)"
            echo -e "    ${CYAN}-n, --limit${RESET} <N>         Max results (default: 10)"
            echo -e "    ${CYAN}-a, --all${RESET}               Search across all projects"
            echo -e "    ${CYAN}-j, --json${RESET}              Output as JSON"
            echo ""
            exit 0
            ;;
        -*)
            eagle_err "Unknown option: $1"
            exit 1
            ;;
        *)
            query="$1"; shift ;;
    esac
done

[ -z "$project" ] && project=$(eagle_project_from_cwd "$(pwd)")

# ─── Keyword search ──────────────────────────────────────

search_keyword() {
    local q; q=$(eagle_sql_escape "$query")
    local p; p=$(eagle_sql_escape "$project")

    local where_project=""
    if [ "$cross_project" = false ]; then
        where_project="AND s.project = '$p'"
    fi

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT s.id, s.project, s.request, s.completed, s.learned, s.created_at
                       FROM summaries s
                       JOIN summaries_fts f ON f.rowid = s.id
                       WHERE summaries_fts MATCH '$q'
                       $where_project
                       ORDER BY rank
                       LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT s.id, s.project, s.request, s.completed, s.learned, s.created_at
                        FROM summaries s
                        JOIN summaries_fts f ON f.rowid = s.id
                        WHERE summaries_fts MATCH '$q'
                        $where_project
                        ORDER BY rank
                        LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No results for '$query'"
        return
    fi

    echo ""
    while IFS='|' read -r sid sproj req completed learned created_at; do
        [ -z "$sid" ] && continue
        echo -e "  ${BOLD}#$sid${RESET}  ${DIM}$created_at${RESET}"
        if [ "$cross_project" = true ]; then
            echo -e "  ${DIM}project:${RESET} $sproj"
        fi
        [ -n "$req" ] && echo -e "  ${CYAN}Request:${RESET} $req"
        [ -n "$completed" ] && echo -e "  ${GREEN}Done:${RESET} $completed"
        [ -n "$learned" ] && echo -e "  ${YELLOW}Learned:${RESET} $learned"
        echo ""
    done <<< "$results"
}

# ─── Timeline ────────────────────────────────────────────

search_timeline() {
    local p; p=$(eagle_sql_escape "$project")

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT s.id, s.request, s.completed, s.learned, s.next_steps, s.created_at
                       FROM summaries s
                       WHERE s.project = '$p'
                       ORDER BY s.created_at DESC
                       LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT s.id, s.request, s.completed, s.learned, s.next_steps, s.created_at
                        FROM summaries s
                        WHERE s.project = '$p'
                        ORDER BY s.created_at DESC
                        LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No sessions found for project '$project'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Recent sessions${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r sid req completed learned next_steps created_at; do
        [ -z "$sid" ] && continue
        echo -e "  ${BOLD}#$sid${RESET}  ${DIM}$created_at${RESET}"
        [ -n "$req" ] && echo -e "  ${CYAN}Request:${RESET} $req"
        [ -n "$completed" ] && echo -e "  ${GREEN}Done:${RESET} $completed"
        [ -n "$learned" ] && echo -e "  ${YELLOW}Learned:${RESET} $learned"
        [ -n "$next_steps" ] && echo -e "  ${DIM}Next:${RESET} $next_steps"
        echo ""
    done <<< "$results"
}

# ─── Session details ──────────────────────────────────────

search_session() {
    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT o.tool_name, o.tool_input_summary, o.files_read, o.files_modified, o.created_at
                       FROM observations o
                       WHERE o.session_id = '$session_id'
                       ORDER BY o.created_at ASC;"
        return
    fi

    local results
    results=$(eagle_db "SELECT o.tool_name, o.tool_input_summary, o.files_read, o.files_modified, o.created_at
                        FROM observations o
                        WHERE o.session_id = '$session_id'
                        ORDER BY o.created_at ASC;")

    if [ -z "$results" ]; then
        eagle_dim "No observations found for session '$session_id'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Session${RESET} ${DIM}$session_id${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r tool_name summary files_r files_m created_at; do
        [ -z "$tool_name" ] && continue
        local icon="$DOT"
        case "$tool_name" in
            Read) icon="${CYAN}R${RESET}" ;;
            Write) icon="${GREEN}W${RESET}" ;;
            Edit) icon="${YELLOW}E${RESET}" ;;
            Bash) icon="${BLUE}\$${RESET}" ;;
        esac
        echo -e "  ${icon}  ${DIM}$created_at${RESET}  $summary"
    done <<< "$results"
    echo ""
}

# ─── Frequently modified files ────────────────────────────

search_files() {
    local p; p=$(eagle_sql_escape "$project")

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT json_each.value as file, COUNT(*) as times
                       FROM observations, json_each(observations.files_modified)
                       WHERE observations.project = '$p'
                       GROUP BY json_each.value
                       ORDER BY times DESC
                       LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT json_each.value as file, COUNT(*) as times
                        FROM observations, json_each(observations.files_modified)
                        WHERE observations.project = '$p'
                        GROUP BY json_each.value
                        ORDER BY times DESC
                        LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No file history for project '$project'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Frequently modified files${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r filepath count; do
        [ -z "$filepath" ] && continue
        printf "  ${GREEN}%3s×${RESET}  %s\n" "$count" "$filepath"
    done <<< "$results"
    echo ""
}

# ─── Stats ────────────────────────────────────────────────

search_stats() {
    local p; p=$(eagle_sql_escape "$project")

    local sessions summaries observations tasks
    sessions=$(eagle_db "SELECT COUNT(*) FROM sessions WHERE project = '$p';")
    summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project = '$p';")
    observations=$(eagle_db "SELECT COUNT(*) FROM observations o JOIN sessions s ON s.id = o.session_id WHERE s.project = '$p';")
    tasks=$(eagle_db "SELECT COUNT(*) FROM tasks WHERE project = '$p';")
    local chunks
    chunks=$(eagle_db "SELECT COUNT(*) FROM code_chunks WHERE project = '$p';")

    if [ "$json_output" = true ]; then
        printf '{"project":"%s","sessions":%s,"summaries":%s,"observations":%s,"tasks":%s,"code_chunks":%s}\n' \
            "$project" "${sessions:-0}" "${summaries:-0}" "${observations:-0}" "${tasks:-0}" "${chunks:-0}"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Stats${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""
    eagle_kv "Sessions:" "${sessions:-0}"
    eagle_kv "Summaries:" "${summaries:-0}"
    eagle_kv "Observations:" "${observations:-0}"
    eagle_kv "Tasks:" "${tasks:-0}"
    eagle_kv "Code chunks:" "${chunks:-0}"
    echo ""
}

# ─── Dispatch ─────────────────────────────────────────────

case "$mode" in
    keyword)
        if [ -z "$query" ]; then
            eagle_err "Usage: eagle-mem search <query>"
            eagle_dim "  Run 'eagle-mem search --help' for options"
            exit 1
        fi
        search_keyword
        ;;
    timeline)    search_timeline ;;
    session)     search_session ;;
    files)       search_files ;;
    stats)       search_stats ;;
esac
