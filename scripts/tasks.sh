#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Tasks
# CLI wrapper for task management (replaces raw SQL in skills)
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

# ─── Parse arguments ──────────────────────────────────────

action="${1:-pending}"
shift 2>/dev/null || true

project=""
json_output=false

# Extract global options from remaining args
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --project|-p)   project="$2"; shift 2 ;;
        --json|-j)      json_output=true; shift ;;
        --help|-h)
            echo -e "  ${BOLD}eagle-mem tasks${RESET} — Manage tracked tasks"
            echo ""
            echo -e "  ${BOLD}Usage:${RESET}"
            echo -e "    eagle-mem tasks                           ${DIM}# list pending tasks${RESET}"
            echo -e "    eagle-mem tasks ${CYAN}list${RESET}                      ${DIM}# list all tasks${RESET}"
            echo -e "    eagle-mem tasks ${CYAN}add${RESET} <title> [instructions] ${DIM}# add a task${RESET}"
            echo -e "    eagle-mem tasks ${CYAN}done${RESET} <id>                 ${DIM}# mark task complete${RESET}"
            echo -e "    eagle-mem tasks ${CYAN}block${RESET} <id>                ${DIM}# mark task blocked${RESET}"
            echo -e "    eagle-mem tasks ${CYAN}context${RESET} <id> <snapshot>    ${DIM}# set task context${RESET}"
            echo -e "    eagle-mem tasks ${CYAN}clear${RESET}                     ${DIM}# remove all done tasks${RESET}"
            echo ""
            echo -e "  ${BOLD}Options:${RESET}"
            echo -e "    ${CYAN}-p, --project${RESET} <name>    Project name (default: current dir)"
            echo -e "    ${CYAN}-j, --json${RESET}              Output as JSON"
            echo ""
            exit 0
            ;;
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
        pending) where_status="AND status IN ('pending', 'active')" ;;
        done)    where_status="AND status = 'done'" ;;
        all)     where_status="" ;;
    esac

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT id, title, instructions, status, ordinal, context_snapshot, completed_at, created_at
                       FROM tasks
                       WHERE project = '$project_sql' $where_status
                       ORDER BY ordinal ASC, id ASC;"
        return
    fi

    local results
    results=$(eagle_db "SELECT id, title, status, ordinal, instructions
                        FROM tasks
                        WHERE project = '$project_sql' $where_status
                        ORDER BY ordinal ASC, id ASC;")

    if [ -z "$results" ]; then
        eagle_dim "No tasks for project '$project'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Tasks${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r tid title status ordinal instructions; do
        [ -z "$tid" ] && continue
        local icon marker
        case "$status" in
            active)  icon="${CYAN}▶${RESET}"; marker=" ${CYAN}[ACTIVE]${RESET}" ;;
            pending) icon="${DIM}○${RESET}"; marker="" ;;
            done)    icon="${GREEN}✓${RESET}"; marker=" ${DIM}[DONE]${RESET}" ;;
            blocked) icon="${RED}✗${RESET}"; marker=" ${RED}[BLOCKED]${RESET}" ;;
            *)       icon="$DOT"; marker="" ;;
        esac
        echo -e "  ${icon}  ${BOLD}#$tid${RESET} $title$marker"
        [ -n "$instructions" ] && echo -e "     ${DIM}$instructions${RESET}"
    done <<< "$results"
    echo ""
}

# ─── Add task ─────────────────────────────────────────────

tasks_add() {
    local title="${args[0]:-}"
    local instructions="${args[1]:-}"

    if [ -z "$title" ]; then
        eagle_err "Usage: eagle-mem tasks add <title> [instructions]"
        exit 1
    fi

    local title_sql; title_sql=$(eagle_sql_escape "$title")
    local instr_sql; instr_sql=$(eagle_sql_escape "$instructions")

    local max_ord
    max_ord=$(eagle_db "SELECT COALESCE(MAX(ordinal), 0) FROM tasks WHERE project = '$project_sql';")
    local next_ord=$((max_ord + 1))

    local new_id
    new_id=$(eagle_db "INSERT INTO tasks (project, title, instructions, ordinal)
              VALUES ('$project_sql', '$title_sql', '$instr_sql', $next_ord);
              SELECT last_insert_rowid();")

    if [ "$json_output" = true ]; then
        jq -nc --arg id "$new_id" --arg title "$title" --argjson ord "$next_ord" \
            '{id: ($id | tonumber), title: $title, ordinal: $ord}'
        return
    fi

    eagle_ok "Task #$new_id added: $title"
}

# ─── Done ─────────────────────────────────────────────────

tasks_done() {
    local task_id="${args[0]:-}"

    if [ -z "$task_id" ]; then
        eagle_err "Usage: eagle-mem tasks done <id>"
        exit 1
    fi

    if ! [[ "$task_id" =~ ^[0-9]+$ ]]; then
        eagle_err "Task ID must be a number, got: $task_id"
        exit 1
    fi

    local changed
    changed=$(eagle_db "UPDATE tasks SET status = 'done', completed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
              WHERE id = $task_id AND project = '$project_sql';
              SELECT changes();")

    if [ "${changed:-0}" -eq 0 ]; then
        eagle_err "Task #$task_id not found in project '$project'"
        exit 1
    fi

    local title
    title=$(eagle_db "SELECT title FROM tasks WHERE id = $task_id AND project = '$project_sql';")

    if [ "$json_output" = true ]; then
        jq -nc --arg id "$task_id" '{id: ($id | tonumber), status: "done"}'
        return
    fi

    eagle_ok "Task #$task_id done: $title"
}

# ─── Block ────────────────────────────────────────────────

tasks_block() {
    local task_id="${args[0]:-}"

    if [ -z "$task_id" ]; then
        eagle_err "Usage: eagle-mem tasks block <id>"
        exit 1
    fi

    if ! [[ "$task_id" =~ ^[0-9]+$ ]]; then
        eagle_err "Task ID must be a number, got: $task_id"
        exit 1
    fi

    local changed
    changed=$(eagle_db "UPDATE tasks SET status = 'blocked' WHERE id = $task_id AND project = '$project_sql';
              SELECT changes();")

    if [ "${changed:-0}" -eq 0 ]; then
        eagle_err "Task #$task_id not found in project '$project'"
        exit 1
    fi

    if [ "$json_output" = true ]; then
        jq -nc --arg id "$task_id" '{id: ($id | tonumber), status: "blocked"}'
        return
    fi

    eagle_ok "Task #$task_id blocked"
}

# ─── Context snapshot ─────────────────────────────────────

tasks_context() {
    local task_id="${args[0]:-}"
    local snapshot="${args[1]:-}"

    if [ -z "$task_id" ] || [ -z "$snapshot" ]; then
        eagle_err "Usage: eagle-mem tasks context <id> <snapshot>"
        exit 1
    fi

    if ! [[ "$task_id" =~ ^[0-9]+$ ]]; then
        eagle_err "Task ID must be a number, got: $task_id"
        exit 1
    fi

    local snap_sql; snap_sql=$(eagle_sql_escape "$snapshot")
    local changed
    changed=$(eagle_db "UPDATE tasks SET context_snapshot = '$snap_sql' WHERE id = $task_id AND project = '$project_sql';
              SELECT changes();")

    if [ "${changed:-0}" -eq 0 ]; then
        eagle_err "Task #$task_id not found in project '$project'"
        exit 1
    fi

    if [ "$json_output" = true ]; then
        jq -nc --arg id "$task_id" '{id: ($id | tonumber), context_snapshot: true}'
        return
    fi

    eagle_ok "Context saved for task #$task_id"
}

# ─── Clear done tasks ────────────────────────────────────

tasks_clear() {
    local count
    count=$(eagle_db "SELECT COUNT(*) FROM tasks WHERE project = '$project_sql' AND status = 'done';")

    eagle_db "DELETE FROM tasks WHERE project = '$project_sql' AND status = 'done';"

    if [ "$json_output" = true ]; then
        jq -nc --argjson cleared "${count:-0}" '{cleared: $cleared}'
        return
    fi

    eagle_ok "Cleared ${count:-0} completed tasks"
}

# ─── Dispatch ─────────────────────────────────────────────

case "$action" in
    list)       tasks_list "all" ;;
    pending)    tasks_list "pending" ;;
    add)        tasks_add ;;
    done)       tasks_done ;;
    block)      tasks_block ;;
    context)    tasks_context ;;
    clear)      tasks_clear ;;
    --help|-h)
        echo -e "  ${BOLD}eagle-mem tasks${RESET} — Manage tracked tasks"
        echo ""
        echo -e "  ${BOLD}Usage:${RESET}"
        echo -e "    eagle-mem tasks                           ${DIM}# list pending tasks${RESET}"
        echo -e "    eagle-mem tasks ${CYAN}list${RESET}                      ${DIM}# list all tasks${RESET}"
        echo -e "    eagle-mem tasks ${CYAN}add${RESET} <title> [instructions] ${DIM}# add a task${RESET}"
        echo -e "    eagle-mem tasks ${CYAN}done${RESET} <id>                 ${DIM}# mark task complete${RESET}"
        echo -e "    eagle-mem tasks ${CYAN}block${RESET} <id>                ${DIM}# mark task blocked${RESET}"
        echo -e "    eagle-mem tasks ${CYAN}context${RESET} <id> <snapshot>    ${DIM}# set task context${RESET}"
        echo -e "    eagle-mem tasks ${CYAN}clear${RESET}                     ${DIM}# remove all done tasks${RESET}"
        echo ""
        echo -e "  ${BOLD}Options:${RESET}"
        echo -e "    ${CYAN}-p, --project${RESET} <name>    Project name (default: current dir)"
        echo -e "    ${CYAN}-j, --json${RESET}              Output as JSON"
        echo ""
        exit 0
        ;;
    *)
        eagle_err "Unknown action: $action"
        eagle_dim "  Run 'eagle-mem tasks --help' for options"
        exit 1
        ;;
esac
