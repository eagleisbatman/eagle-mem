#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Tasks
# Mirrors native task state and lets agents without native task files persist
# task handoff records directly.
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
agent=""

show_help() {
    echo -e "  ${BOLD}eagle-mem tasks${RESET} — View mirrored agent tasks"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem tasks                  ${DIM}# list pending/in-progress tasks${RESET}"
    echo -e "    eagle-mem tasks ${CYAN}list${RESET}             ${DIM}# list all tasks${RESET}"
    echo -e "    eagle-mem tasks ${CYAN}completed${RESET}        ${DIM}# list completed tasks${RESET}"
    echo -e "    eagle-mem tasks ${CYAN}search${RESET} <query>   ${DIM}# search tasks by keyword${RESET}"
    echo -e "    eagle-mem tasks ${CYAN}add${RESET} <subject>    ${DIM}# create a persistent task record${RESET}"
    echo -e "    eagle-mem tasks ${CYAN}update${RESET} <id>      ${DIM}# update subject/description/status${RESET}"
    echo -e "    eagle-mem tasks ${CYAN}start${RESET} <id>       ${DIM}# mark task in_progress${RESET}"
    echo -e "    eagle-mem tasks ${CYAN}complete${RESET} <id>    ${DIM}# mark task completed${RESET}"
    echo -e "    eagle-mem tasks ${CYAN}cancel${RESET} <id>      ${DIM}# mark task cancelled${RESET}"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    ${CYAN}-p, --project${RESET} <name>    Project name (default: current dir)"
    echo -e "    ${CYAN}--agent${RESET} <name>          Source agent (codex or claude-code)"
    echo -e "    ${CYAN}-j, --json${RESET}              Output as JSON"
    echo ""
    echo -e "  ${DIM}Claude Code task files are mirrored automatically.${RESET}"
    echo -e "  ${DIM}Codex can persist tasks with this CLI when using the eagle-mem-tasks skill.${RESET}"
    echo ""
    exit 0
}

args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --project|-p)   project="$2"; shift 2 ;;
        --agent)        agent="$2"; shift 2 ;;
        --json|-j)      json_output=true; shift ;;
        --help|-h)      show_help ;;
        *)  args+=("$1"); shift ;;
    esac
done

[ -z "$project" ] && project=$(eagle_project_from_cwd "$(pwd)")
project_sql=$(eagle_sql_escape "$project")
[ -z "$agent" ] && agent=$(eagle_agent_source)
agent_sql=$(eagle_sql_escape "$agent")

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
                       FROM agent_tasks
                       WHERE project = '$project_sql' $where_status
                       ORDER BY updated_at DESC
                       LIMIT 20;"
        return
    fi

    local results
    results=$(eagle_db "SELECT source_task_id, subject, status, blocked_by, description
                        FROM agent_tasks
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
            cancelled)   icon="${RED}x${RESET}"; marker=" ${RED}[cancelled]${RESET}" ;;
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

    local sanitized_query
    sanitized_query=$(eagle_fts_sanitize "$query")
    if [ -z "$sanitized_query" ]; then
        eagle_err "Search query contains no valid search terms"
        exit 1
    fi

    if [ "$json_output" = true ]; then
        local query_sql; query_sql=$(eagle_sql_escape "$sanitized_query")
        eagle_db_json "SELECT t.source_task_id, t.subject, t.status, t.description, t.updated_at
                       FROM agent_tasks t
                       JOIN agent_tasks_fts f ON f.rowid = t.id
                       WHERE agent_tasks_fts MATCH '$query_sql'
                       AND t.project = '$project_sql'
                       ORDER BY rank
                       LIMIT 10;"
        return
    fi

    local results
    local query_sql; query_sql=$(eagle_sql_escape "$sanitized_query")
    results=$(eagle_db "SELECT t.source_task_id, t.subject, t.status, t.description
                        FROM agent_tasks t
                        JOIN agent_tasks_fts f ON f.rowid = t.id
                        WHERE agent_tasks_fts MATCH '$query_sql'
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

# ─── Mutate task records ──────────────────────────────────

tasks_add() {
    local subject="${args[0]:-}"
    if [ -z "$subject" ]; then
        eagle_err "Usage: eagle-mem tasks add <subject> [--desc <text>] [--status pending|in_progress]"
        exit 1
    fi

    local desc=""
    local status="pending"
    local i=1
    while [ "$i" -lt "${#args[@]}" ]; do
        case "${args[$i]}" in
            --desc|-d)
                i=$((i + 1))
                desc="${args[$i]:-}"
                ;;
            --status)
                i=$((i + 1))
                status="${args[$i]:-pending}"
                ;;
        esac
        i=$((i + 1))
    done

    case "$status" in
        pending|in_progress|completed|cancelled) ;;
        *)
            eagle_err "Invalid status: $status"
            exit 1
            ;;
    esac

    local task_id file_path content_hash
    task_id="agent-$(date -u +%Y%m%d%H%M%S)-$$"
    file_path="agent-task://$project/$task_id"
    content_hash=$(printf '%s|%s|%s|%s' "$subject" "$desc" "$status" "$agent" | shasum -a 256 | awk '{print $1}')

    local tid_sql fp_sql subj_sql desc_sql status_sql hash_sql
    tid_sql=$(eagle_sql_escape "$task_id")
    fp_sql=$(eagle_sql_escape "$file_path")
    subj_sql=$(eagle_sql_escape "$subject")
    desc_sql=$(eagle_sql_escape "$desc")
    status_sql=$(eagle_sql_escape "$status")
    hash_sql=$(eagle_sql_escape "$content_hash")

    eagle_db_pipe <<SQL
INSERT INTO agent_tasks (project, source_session_id, source_task_id, file_path, subject, description, active_form, status, blocks, blocked_by, content_hash, origin_agent)
VALUES ('$project_sql', 'manual', '$tid_sql', '$fp_sql', '$subj_sql', '$desc_sql', '', '$status_sql', '[]', '[]', '$hash_sql', '$agent_sql');
SQL

    if [ "$json_output" = true ]; then
        jq -nc --arg id "$task_id" --arg subject "$subject" --arg status "$status" --arg agent "$agent" \
            '{source_task_id:$id, subject:$subject, status:$status, origin_agent:$agent}'
    else
        eagle_ok "Task '$task_id' created"
    fi
}

tasks_set_status() {
    local task_id="${args[0]:-}"
    local status="$1"
    if [ -z "$task_id" ]; then
        eagle_err "Usage: eagle-mem tasks $action <id>"
        exit 1
    fi

    local tid_sql status_sql
    tid_sql=$(eagle_sql_escape "$task_id")
    status_sql=$(eagle_sql_escape "$status")

    changed=$(eagle_db_pipe <<SQL
UPDATE agent_tasks
SET status = '$status_sql',
    origin_agent = COALESCE(NULLIF('$agent_sql', ''), origin_agent),
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE project = '$project_sql' AND source_task_id = '$tid_sql';
SELECT changes();
SQL
)

    if [ "${changed:-0}" -gt 0 ] 2>/dev/null; then
        eagle_ok "Task '$task_id' marked $status"
    else
        eagle_err "Task not found: $task_id"
        exit 1
    fi
}

tasks_update() {
    local task_id="${args[0]:-}"
    if [ -z "$task_id" ]; then
        eagle_err "Usage: eagle-mem tasks update <id> [--subject <text>] [--desc <text>] [--status <status>]"
        exit 1
    fi

    local subject="" desc="" status=""
    local i=1
    while [ "$i" -lt "${#args[@]}" ]; do
        case "${args[$i]}" in
            --subject)
                i=$((i + 1))
                subject="${args[$i]:-}"
                ;;
            --desc|-d)
                i=$((i + 1))
                desc="${args[$i]:-}"
                ;;
            --status)
                i=$((i + 1))
                status="${args[$i]:-}"
                ;;
        esac
        i=$((i + 1))
    done

    if [ -n "$status" ]; then
        case "$status" in
            pending|in_progress|completed|cancelled) ;;
            *)
                eagle_err "Invalid status: $status"
                exit 1
                ;;
        esac
    fi

    local tid_sql subj_sql desc_sql status_sql hash_sql
    tid_sql=$(eagle_sql_escape "$task_id")
    subj_sql=$(eagle_sql_escape "$subject")
    desc_sql=$(eagle_sql_escape "$desc")
    status_sql=$(eagle_sql_escape "$status")
    hash_sql=$(printf '%s|%s|%s|%s|%s' "$task_id" "$subject" "$desc" "$status" "$agent" | shasum -a 256 | awk '{print $1}')
    hash_sql=$(eagle_sql_escape "$hash_sql")

    changed=$(eagle_db_pipe <<SQL
UPDATE agent_tasks
SET subject = CASE WHEN '$subj_sql' != '' THEN '$subj_sql' ELSE subject END,
    description = CASE WHEN '$desc_sql' != '' THEN '$desc_sql' ELSE description END,
    status = CASE WHEN '$status_sql' != '' THEN '$status_sql' ELSE status END,
    origin_agent = COALESCE(NULLIF('$agent_sql', ''), origin_agent),
    content_hash = '$hash_sql',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE project = '$project_sql' AND source_task_id = '$tid_sql';
SELECT changes();
SQL
)

    if [ "${changed:-0}" -gt 0 ] 2>/dev/null; then
        eagle_ok "Task '$task_id' updated"
    else
        eagle_err "Task not found: $task_id"
        exit 1
    fi
}

# ─── Dispatch ─────────────────────────────────────────────

case "$action" in
    list)       tasks_list "all" ;;
    pending)    tasks_list "pending" ;;
    completed)  tasks_list "completed" ;;
    search)     tasks_search ;;
    add)        tasks_add ;;
    update)     tasks_update ;;
    start)      tasks_set_status "in_progress" ;;
    complete)   tasks_set_status "completed" ;;
    cancel)     tasks_set_status "cancelled" ;;
    --help|-h)  show_help ;;
    *)
        eagle_err "Unknown action: $action"
        eagle_dim "  Run 'eagle-mem tasks --help' for options"
        exit 1
        ;;
esac
