#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Tasks (read-only viewer of Claude Code tasks)
# Claude Code manages task state via TaskCreate/TaskUpdate;
# Eagle Mem mirrors it and displays it here.
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

# ─── Parse arguments ──────────────────────────────────────

action="pending"
case "${1:-}" in
    -*)  ;; # flags parsed below
    "")  ;;
    *)   action="$1"; shift ;;
esac

project=""
json_output=false

show_help() {
    echo -e "  ${BOLD}eagle-mem tasks${RESET} — View mirrored Claude Code tasks"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem tasks                  ${DIM}# list pending/in-progress tasks${RESET}"
    echo -e "    eagle-mem tasks ${CYAN}list${RESET}             ${DIM}# list all tasks${RESET}"
    echo -e "    eagle-mem tasks ${CYAN}completed${RESET}        ${DIM}# list completed tasks${RESET}"
    echo -e "    eagle-mem tasks ${CYAN}search${RESET} <query>   ${DIM}# search tasks by keyword${RESET}"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    ${CYAN}-p, --project${RESET} <name>    Project name (default: current dir)"
    echo -e "    ${CYAN}-j, --json${RESET}              Output as JSON"
    echo ""
    echo -e "  ${DIM}Tasks are managed by Claude Code (TaskCreate/TaskUpdate).${RESET}"
    echo -e "  ${DIM}Eagle Mem automatically mirrors them for cross-session recall.${RESET}"
    echo ""
    exit 0
}

args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --project|-p)   project="$2"; shift 2 ;;
        --json|-j)      json_output=true; shift ;;
        --help|-h)      show_help ;;
        *)  args+=("$1"); shift ;;
    esac
done

[ -z "$project" ] && project=$(eagle_project_from_cwd "$(pwd)")
project_sql=$(eagle_sql_escape "$project")

# ─── List tasks ───────────────────────────────────────────

tasks_list() {
    local filter="${1:-all}"

    local where_status=""
    case "$filter" in
        pending) where_status="AND status IN ('pending', 'in_progress')" ;;
        completed) where_status="AND status = 'completed'" ;;
        all) where_status="" ;;
    esac

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT source_task_id, subject, description, status, blocks, blocked_by, updated_at
                       FROM claude_tasks
                       WHERE project = '$project_sql' $where_status
                       ORDER BY updated_at DESC
                       LIMIT 20;"
        return
    fi

    local results
    results=$(eagle_db "SELECT source_task_id, subject, status, blocked_by, description
                        FROM claude_tasks
                        WHERE project = '$project_sql' $where_status
                        ORDER BY
                            CASE status WHEN 'in_progress' THEN 0 WHEN 'pending' THEN 1 ELSE 2 END,
                            updated_at DESC
                        LIMIT 20;")

    if [ -z "$results" ]; then
        eagle_dim "No tasks for project '$project'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Tasks${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r tid subject status blocked_by desc; do
        [ -z "$tid" ] && continue
        local icon marker
        case "$status" in
            in_progress) icon="${CYAN}>${RESET}"; marker=" ${CYAN}[in_progress]${RESET}" ;;
            pending)     icon="${DIM}o${RESET}"; marker="" ;;
            completed)   icon="${GREEN}+${RESET}"; marker=" ${DIM}[completed]${RESET}" ;;
            deleted)     icon="${RED}x${RESET}"; marker=" ${RED}[deleted]${RESET}" ;;
            *)           icon="$DOT"; marker="" ;;
        esac
        if [ "$blocked_by" != "[]" ] && [ -n "$blocked_by" ]; then
            marker+=" ${DIM}(blocked)${RESET}"
        fi
        echo -e "  ${icon}  ${BOLD}$tid${RESET} $subject$marker"
        [ -n "$desc" ] && echo -e "     ${DIM}$(echo "$desc" | cut -c1-80)${RESET}"
    done <<< "$results"
    echo ""
}

# ─── Search tasks ─────────────────────────────────────────

tasks_search() {
    local query="${args[0]:-}"
    if [ -z "$query" ]; then
        eagle_err "Usage: eagle-mem tasks search <query>"
        exit 1
    fi

    if [ "$json_output" = true ]; then
        local query_sql; query_sql=$(eagle_fts_sanitize "$query")
        query_sql=$(eagle_sql_escape "$query_sql")
        eagle_db_json "SELECT t.source_task_id, t.subject, t.status, t.description, t.updated_at
                       FROM claude_tasks t
                       JOIN claude_tasks_fts f ON f.rowid = t.id
                       WHERE claude_tasks_fts MATCH '$query_sql'
                       AND t.project = '$project_sql'
                       ORDER BY rank
                       LIMIT 10;"
        return
    fi

    local results
    local query_sql; query_sql=$(eagle_fts_sanitize "$query")
    query_sql=$(eagle_sql_escape "$query_sql")
    results=$(eagle_db "SELECT t.source_task_id, t.subject, t.status, t.description
                        FROM claude_tasks t
                        JOIN claude_tasks_fts f ON f.rowid = t.id
                        WHERE claude_tasks_fts MATCH '$query_sql'
                        AND t.project = '$project_sql'
                        ORDER BY rank
                        LIMIT 10;")

    if [ -z "$results" ]; then
        eagle_dim "No tasks matching '$query'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Task search:${RESET} $query"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r tid subject status desc; do
        [ -z "$tid" ] && continue
        echo -e "  ${BOLD}$tid${RESET} [$status] $subject"
        [ -n "$desc" ] && echo -e "     ${DIM}$(echo "$desc" | cut -c1-80)${RESET}"
    done <<< "$results"
    echo ""
}

# ─── Dispatch ─────────────────────────────────────────────

case "$action" in
    list)       tasks_list "all" ;;
    pending)    tasks_list "pending" ;;
    completed)  tasks_list "completed" ;;
    search)     tasks_search ;;
    --help|-h)  show_help ;;
    *)
        eagle_err "Unknown action: $action"
        eagle_dim "  Run 'eagle-mem tasks --help' for options"
        exit 1
        ;;
esac
