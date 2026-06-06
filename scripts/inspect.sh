#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Inspect
# Human-facing inspection surfaces for hook and recall observability.
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

action="${1:-recall}"
case "$action" in
    recall|events) shift 2>/dev/null || true ;;
    --help|-h|"") ;;
    *)
        eagle_err "Unknown inspect action: $action"
        eagle_dim "Run: eagle-mem inspect --help"
        exit 1
        ;;
esac

project=""
project_was_explicit=false
cross_project=false
session_id=""
limit=10
json_output=false

show_help() {
    echo -e "  ${BOLD}eagle-mem inspect${RESET} — Inspect Eagle Mem observability events"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem inspect recall              ${DIM}# recent recall events${RESET}"
    echo -e "    eagle-mem inspect events              ${DIM}# recent hook/action events${RESET}"
    echo -e "    eagle-mem inspect recall ${CYAN}--last${RESET}       ${DIM}# latest recall event${RESET}"
    echo -e "    eagle-mem inspect recall ${CYAN}--json${RESET}       ${DIM}# structured output${RESET}"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    ${CYAN}-p, --project${RESET} <name>    Project name (default: current dir scope)"
    echo -e "    ${CYAN}-s, --session${RESET} <id>      Filter by agent session id"
    echo -e "    ${CYAN}-n, --limit${RESET} <N>         Max events (default: 10)"
    echo -e "    ${CYAN}--all${RESET}                   Inspect all projects"
    echo -e "    ${CYAN}--last${RESET}                  Same as --limit 1"
    echo -e "    ${CYAN}-j, --json${RESET}              Output structured JSON"
    echo ""
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project|-p) project="$2"; project_was_explicit=true; shift 2 ;;
        --session|-s) session_id="$2"; shift 2 ;;
        --limit|-n) limit="$2"; shift 2 ;;
        --last) limit=1; shift ;;
        --all|-a) cross_project=true; shift ;;
        --json|-j) json_output=true; shift ;;
        --help|-h) show_help ;;
        *)
            eagle_err "Unknown option: $1"
            exit 1
            ;;
    esac
done

inspect_fail() {
    local error_code="$1"
    local message="$2"
    local db_status="${3:-unknown}"
    local db_detail="${4:-}"

    if [ "$json_output" = true ]; then
        jq -nc \
            --arg status "error" \
            --arg command "inspect" \
            --arg action "$action" \
            --arg error "$error_code" \
            --arg message "$message" \
            --arg project "${project:-}" \
            --arg db_status "$db_status" \
            --arg db_detail "$db_detail" \
            '{status:$status, command:$command, action:$action, error:$error, message:$message,
              project:$project, database:{integrity:{status:$db_status, detail:$db_detail}}}'
    else
        eagle_err "$message"
        [ -n "$db_detail" ] && eagle_dim "  $db_detail"
    fi
    exit 1
}

if [ "$action" = "--help" ] || [ "$action" = "-h" ] || [ -z "$action" ]; then
    show_help
fi

if ! eagle_ensure_db; then
    inspect_fail "database_unavailable" "Database is unavailable; SQLite/FTS5 setup failed." "unavailable" "eagle_ensure_db failed"
fi

db_integrity_check=$(eagle_db_integrity_status "$EAGLE_MEM_DB" 2>/dev/null || true)
db_integrity_status="${db_integrity_check%%|*}"
db_integrity_detail="${db_integrity_check#*|}"
[ -n "$db_integrity_status" ] || db_integrity_status="unknown"
[ -n "$db_integrity_detail" ] || db_integrity_detail="not checked"
if [ "$db_integrity_status" != "ok" ]; then
    inspect_fail "database_integrity" "Database integrity check failed; inspection is unavailable." "$db_integrity_status" "$db_integrity_detail"
fi

if [ "$action" = "recall" ] && [ -z "$(eagle_db "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'recall_events' LIMIT 1;" 2>/dev/null || true)" ]; then
    inspect_fail "migration_missing" "Recall inspection is unavailable until migrations create recall_events." "ok" "run: eagle-mem update"
fi

if [ "$action" = "events" ] && [ -z "$(eagle_db "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'eagle_events' LIMIT 1;" 2>/dev/null || true)" ]; then
    inspect_fail "migration_missing" "Event inspection is unavailable until migrations create eagle_events." "ok" "run: eagle-mem update"
fi

limit=$(eagle_sql_int "$limit")
[ "$limit" -le 0 ] 2>/dev/null && limit=10

if [ -z "$project" ] && [ "$cross_project" = false ]; then
    project=$(eagle_project_from_cwd "$(pwd)")
fi
if [ "$cross_project" = false ] && [ "$project_was_explicit" = false ]; then
    project=$(eagle_recall_project_scope_from_cwd "$(pwd)" "$project")
fi

recall_inspect() {
    local where_clause="1 = 1"
    local project_label="$project"

    if [ "$cross_project" = false ]; then
        where_clause="$where_clause AND $(eagle_sql_project_scope_condition "project" "$project")"
        project_label=$(eagle_project_scope_label "$project")
    else
        project_label="all projects"
    fi

    if [ -n "$session_id" ]; then
        local sid_sql
        sid_sql=$(eagle_sql_escape "$session_id")
        where_clause="$where_clause AND session_id = '$sid_sql'"
    fi

    local events_json
    events_json=$(eagle_db_json "SELECT id, session_id, project, agent, hook_name, prompt_snippet, fts_query,
                                        summary_matches, memory_matches, code_matches, injected_chars,
                                        injected_token_estimate, status, error, created_at
                                 FROM recall_events
                                 WHERE $where_clause
                                 ORDER BY created_at DESC, id DESC
                                 LIMIT $limit;")
    [ -n "$events_json" ] || events_json="[]"

    if [ "$json_output" = true ]; then
        jq -nc \
            --arg status "ok" \
            --arg command "inspect" \
            --arg action "recall" \
            --arg project "$project_label" \
            --arg db_integrity_status "$db_integrity_status" \
            --arg db_integrity_detail "$db_integrity_detail" \
            --argjson events "$events_json" \
            '{status:$status, command:$command, action:$action, project:$project,
              database:{integrity:{status:$db_integrity_status, detail:$db_integrity_detail}},
              events:$events}'
        return
    fi

    eagle_header "Recall Inspector"
    eagle_info "Project: $project_label"
    [ -n "$session_id" ] && eagle_info "Session: $session_id"
    echo ""

    if [ "$(printf '%s' "$events_json" | jq 'length')" -eq 0 ]; then
        eagle_dim "No recall events recorded yet."
        eagle_dim "UserPromptSubmit records events after migrations include recall_events."
        echo ""
        return
    fi

    printf '%s' "$events_json" | jq -c '.[]' | while IFS= read -r event; do
        local created agent prompt query summaries memories code tokens status event_project sid
        created=$(printf '%s' "$event" | jq -r '.created_at // ""')
        agent=$(printf '%s' "$event" | jq -r '.agent // ""')
        event_project=$(printf '%s' "$event" | jq -r '.project // ""')
        sid=$(printf '%s' "$event" | jq -r '.session_id // ""')
        prompt=$(printf '%s' "$event" | jq -r '.prompt_snippet // ""')
        query=$(printf '%s' "$event" | jq -r '.fts_query // ""')
        summaries=$(printf '%s' "$event" | jq -r '.summary_matches // 0')
        memories=$(printf '%s' "$event" | jq -r '.memory_matches // 0')
        code=$(printf '%s' "$event" | jq -r '.code_matches // 0')
        tokens=$(printf '%s' "$event" | jq -r '.injected_token_estimate // 0')
        status=$(printf '%s' "$event" | jq -r '.status // "unknown"')

        echo -e "  ${BOLD}${created}${RESET}  ${DIM}$(eagle_agent_label "$agent")${RESET}  ${CYAN}${status}${RESET}"
        [ "$cross_project" = true ] && echo -e "  ${DIM}Project:${RESET} $event_project"
        [ -n "$sid" ] && echo -e "  ${DIM}Session:${RESET} $sid"
        [ -n "$prompt" ] && echo -e "  ${DIM}Prompt:${RESET} $prompt"
        [ -n "$query" ] && echo -e "  ${DIM}Query:${RESET} $query"
        echo -e "  ${DIM}Retrieved:${RESET} summaries=$summaries memories=$memories code=$code  ${DIM}Injected:${RESET} ~${tokens} tokens"
        echo ""
    done
}

events_inspect() {
    local where_clause="1 = 1"
    local project_label="$project"

    if [ "$cross_project" = false ]; then
        where_clause="$where_clause AND $(eagle_sql_project_scope_condition "project" "$project")"
        project_label=$(eagle_project_scope_label "$project")
    else
        project_label="all projects"
    fi

    if [ -n "$session_id" ]; then
        local sid_sql
        sid_sql=$(eagle_sql_escape "$session_id")
        where_clause="$where_clause AND session_id = '$sid_sql'"
    fi

    local events_json
    events_json=$(eagle_db_json "SELECT id, session_id, project, agent, event_type, command,
                                        hook_event_name, status, detail_json, created_at
                                 FROM eagle_events
                                 WHERE $where_clause
                                 ORDER BY created_at DESC, id DESC
                                 LIMIT $limit;")
    [ -n "$events_json" ] || events_json="[]"

    if [ "$json_output" = true ]; then
        jq -nc \
            --arg status "ok" \
            --arg command "inspect" \
            --arg action "events" \
            --arg project "$project_label" \
            --arg db_integrity_status "$db_integrity_status" \
            --arg db_integrity_detail "$db_integrity_detail" \
            --argjson events "$events_json" \
            '{status:$status, command:$command, action:$action, project:$project,
              database:{integrity:{status:$db_integrity_status, detail:$db_integrity_detail}},
              events:($events | map(.detail = ((.detail_json // "{}") | fromjson? // {}) | del(.detail_json)))}'
        return
    fi

    eagle_header "Event Inspector"
    eagle_info "Project: $project_label"
    [ -n "$session_id" ] && eagle_info "Session: $session_id"
    echo ""

    if [ "$(printf '%s' "$events_json" | jq 'length')" -eq 0 ]; then
        eagle_dim "No Eagle events recorded yet."
        eagle_dim "Hooks record events after migrations include eagle_events."
        echo ""
        return
    fi

    printf '%s' "$events_json" | jq -c '.[]' | while IFS= read -r event; do
        local created agent event_type hook status event_project sid detail
        created=$(printf '%s' "$event" | jq -r '.created_at // ""')
        agent=$(printf '%s' "$event" | jq -r '.agent // ""')
        event_project=$(printf '%s' "$event" | jq -r '.project // ""')
        sid=$(printf '%s' "$event" | jq -r '.session_id // ""')
        event_type=$(printf '%s' "$event" | jq -r '.event_type // ""')
        hook=$(printf '%s' "$event" | jq -r '.hook_event_name // ""')
        status=$(printf '%s' "$event" | jq -r '.status // "unknown"')
        detail=$(printf '%s' "$event" | jq -r '(.detail_json // "{}") | fromjson? | to_entries | map("\(.key)=\(.value|tostring)") | join(", ")' 2>/dev/null)

        echo -e "  ${BOLD}${created}${RESET}  ${CYAN}${event_type}${RESET}  ${DIM}${status}${RESET}"
        [ "$cross_project" = true ] && echo -e "  ${DIM}Project:${RESET} $event_project"
        [ -n "$agent" ] && echo -e "  ${DIM}Agent:${RESET} $(eagle_agent_label "$agent")"
        [ -n "$sid" ] && echo -e "  ${DIM}Session:${RESET} $sid"
        [ -n "$hook" ] && echo -e "  ${DIM}Hook:${RESET} $hook"
        [ -n "$detail" ] && echo -e "  ${DIM}Detail:${RESET} $detail"
        echo ""
    done
}

case "$action" in
    recall) recall_inspect ;;
    events) events_inspect ;;
    *) show_help ;;
esac
