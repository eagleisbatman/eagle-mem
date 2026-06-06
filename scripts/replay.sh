#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Replay
# Shows prompt → recall → injected context summary → observed work for a session.
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

session_id=""
project=""
project_was_explicit=false
cross_project=false
json_output=false
last=false

show_help() {
    echo -e "  ${BOLD}eagle-mem replay${RESET} — Replay what Eagle Mem did in a session"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem replay ${CYAN}<session-id>${RESET}"
    echo -e "    eagle-mem replay ${CYAN}--last${RESET}"
    echo -e "    eagle-mem replay ${CYAN}<session-id> --json${RESET}"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    ${CYAN}-p, --project${RESET} <name>  Project name (default: current dir scope)"
    echo -e "    ${CYAN}--all${RESET}                 Search all projects when resolving --last"
    echo -e "    ${CYAN}--last${RESET}                Replay latest recall event session"
    echo -e "    ${CYAN}-j, --json${RESET}            Output structured JSON"
    echo ""
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project|-p) project="$2"; project_was_explicit=true; shift 2 ;;
        --all|-a) cross_project=true; shift ;;
        --last) last=true; shift ;;
        --json|-j) json_output=true; shift ;;
        --help|-h) show_help ;;
        -*)
            eagle_err "Unknown option: $1"
            exit 1
            ;;
        *)
            session_id="$1"
            shift
            ;;
    esac
done

replay_fail() {
    local error_code="$1"
    local message="$2"
    local db_status="${3:-unknown}"
    local db_detail="${4:-}"

    if [ "$json_output" = true ]; then
        jq -nc \
            --arg status "error" \
            --arg command "replay" \
            --arg error "$error_code" \
            --arg message "$message" \
            --arg session_id "${session_id:-}" \
            --arg project "${project:-}" \
            --arg db_status "$db_status" \
            --arg db_detail "$db_detail" \
            '{status:$status, command:$command, error:$error, message:$message,
              session_id:$session_id, project:$project,
              database:{integrity:{status:$db_status, detail:$db_detail}}}'
    else
        eagle_err "$message"
        [ -n "$db_detail" ] && eagle_dim "  $db_detail"
    fi
    exit 1
}

json_array_or_empty() {
    local value="${1:-}"
    if [ -z "$value" ] || ! printf '%s' "$value" | jq -e 'type == "array"' >/dev/null 2>&1; then
        printf '[]\n'
        return 0
    fi
    printf '%s\n' "$value"
}

if ! eagle_ensure_db; then
    replay_fail "database_unavailable" "Database is unavailable; SQLite/FTS5 setup failed." "unavailable" "eagle_ensure_db failed"
fi

db_integrity_check=$(eagle_db_integrity_status "$EAGLE_MEM_DB" 2>/dev/null || true)
db_integrity_status="${db_integrity_check%%|*}"
db_integrity_detail="${db_integrity_check#*|}"
[ -n "$db_integrity_status" ] || db_integrity_status="unknown"
[ -n "$db_integrity_detail" ] || db_integrity_detail="not checked"
if [ "$db_integrity_status" != "ok" ]; then
    replay_fail "database_integrity" "Database integrity check failed; replay is unavailable." "$db_integrity_status" "$db_integrity_detail"
fi

if [ -z "$(eagle_db "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'recall_events' LIMIT 1;" 2>/dev/null || true)" ]; then
    replay_fail "migration_missing" "Replay is unavailable until migrations create recall_events." "ok" "run: eagle-mem update"
fi

if [ -z "$project" ] && [ "$cross_project" = false ]; then
    project=$(eagle_project_from_cwd "$(pwd)")
fi
if [ "$cross_project" = false ] && [ "$project_was_explicit" = false ]; then
    project=$(eagle_recall_project_scope_from_cwd "$(pwd)" "$project")
fi

where_project="1 = 1"
if [ "$cross_project" = false ]; then
    where_project=$(eagle_sql_project_scope_condition "project" "$project")
fi

if [ -z "$session_id" ] || [ "$last" = true ]; then
    session_id=$(eagle_db "SELECT session_id
                           FROM recall_events
                           WHERE $where_project
                             AND session_id IS NOT NULL
                             AND session_id != ''
                           ORDER BY created_at DESC, id DESC
                           LIMIT 1;" 2>/dev/null | awk 'NF { print; exit }')
fi

[ -n "$session_id" ] || replay_fail "session_missing" "No session id provided and no replayable recall event was found." "ok" "run: eagle-mem replay <session-id>"

sid_sql=$(eagle_sql_escape "$session_id")

session_json=$(eagle_db_json "SELECT id, project, agent, cwd, model, source, started_at, ended_at, status
                              FROM sessions
                              WHERE id = '$sid_sql'
                              LIMIT 1;" 2>/dev/null || printf '[]')
summary_json=$(eagle_db_json "SELECT request, completed, learned, decisions, gotchas, key_files, agent, created_at
                              FROM summaries
                              WHERE session_id = '$sid_sql'
                              ORDER BY created_at DESC;" 2>/dev/null || printf '[]')
recall_json=$(eagle_db_json "SELECT prompt_snippet, fts_query, summary_matches, memory_matches, code_matches,
                                    summary_refs, memory_refs, code_refs, injected_token_estimate,
                                    status, error, agent, created_at
                             FROM recall_events
                             WHERE session_id = '$sid_sql'
                             ORDER BY created_at ASC, id ASC;" 2>/dev/null || printf '[]')
observation_json=$(eagle_db_json "SELECT tool_name, tool_input_summary, files_read, files_modified, created_at
                                  FROM observations
                                  WHERE session_id = '$sid_sql'
                                  ORDER BY created_at ASC
                                  LIMIT 100;" 2>/dev/null || printf '[]')

session_json=$(json_array_or_empty "$session_json")
summary_json=$(json_array_or_empty "$summary_json")
recall_json=$(json_array_or_empty "$recall_json")
observation_json=$(json_array_or_empty "$observation_json")

replay_json=$(jq -nc \
    --arg status "ok" \
    --arg command "replay" \
    --arg session_id "$session_id" \
    --arg db_integrity_status "$db_integrity_status" \
    --arg db_integrity_detail "$db_integrity_detail" \
    --argjson session "$session_json" \
    --argjson summaries "$summary_json" \
    --argjson recalls "$recall_json" \
    --argjson observations "$observation_json" \
    '{status:$status, command:$command, session_id:$session_id,
      database:{integrity:{status:$db_integrity_status, detail:$db_integrity_detail}},
      session:($session[0] // null),
      summaries:$summaries,
      recall_events:($recalls | map(
        .summary_refs = ((.summary_refs // "[]") | fromjson? // []) |
        .memory_refs = ((.memory_refs // "[]") | fromjson? // []) |
        .code_refs = ((.code_refs // "[]") | fromjson? // [])
      )),
      observations:$observations}')

if [ "$json_output" = true ]; then
    printf '%s\n' "$replay_json"
    exit 0
fi

eagle_header "Replay"
eagle_info "Session: $session_id"
project_label=$(printf '%s' "$replay_json" | jq -r '.session.project // empty')
[ -n "$project_label" ] && eagle_info "Project: $project_label"
echo ""

recall_count=$(printf '%s' "$replay_json" | jq '.recall_events | length')
summary_count=$(printf '%s' "$replay_json" | jq '.summaries | length')
observation_count=$(printf '%s' "$replay_json" | jq '.observations | length')
eagle_kv "Recall events:" "$recall_count"
eagle_kv "Summaries:" "$summary_count"
eagle_kv "Observations:" "$observation_count"
echo ""

printf '%s' "$replay_json" | jq -c '.recall_events[]' | while IFS= read -r event; do
    created=$(printf '%s' "$event" | jq -r '.created_at // ""')
    agent=$(printf '%s' "$event" | jq -r '.agent // ""')
    prompt=$(printf '%s' "$event" | jq -r '.prompt_snippet // ""')
    query=$(printf '%s' "$event" | jq -r '.fts_query // ""')
    tokens=$(printf '%s' "$event" | jq -r '.injected_token_estimate // 0')
    summaries=$(printf '%s' "$event" | jq -r '.summary_matches // 0')
    memories=$(printf '%s' "$event" | jq -r '.memory_matches // 0')
    code=$(printf '%s' "$event" | jq -r '.code_matches // 0')

    echo -e "  ${BOLD}${created}${RESET}  ${DIM}$(eagle_agent_label "$agent")${RESET}"
    [ -n "$prompt" ] && echo -e "  ${DIM}Prompt:${RESET} $prompt"
    [ -n "$query" ] && echo -e "  ${DIM}Query:${RESET} $query"
    echo -e "  ${DIM}Retrieved:${RESET} summaries=$summaries memories=$memories code=$code  ${DIM}Injected:${RESET} ~${tokens} tokens"

    summary_refs=$(printf '%s' "$event" | jq -r '.summary_refs[]? | "- summary: " + ((.completed // .request // "summary") | tostring)' 2>/dev/null)
    memory_refs=$(printf '%s' "$event" | jq -r '.memory_refs[]? | "- memory: " + ((.name // "memory") | tostring)' 2>/dev/null)
    code_refs=$(printf '%s' "$event" | jq -r '.code_refs[]? | "- code: " + ((.file // "file") | tostring) + ":" + ((.start_line // "?") | tostring) + "-" + ((.end_line // "?") | tostring)' 2>/dev/null)

    if [ -n "$summary_refs$memory_refs$code_refs" ]; then
        echo -e "  ${DIM}Retrieved refs:${RESET}"
        [ -n "$summary_refs" ] && printf '%s\n' "$summary_refs" | sed 's/^/    /'
        [ -n "$memory_refs" ] && printf '%s\n' "$memory_refs" | sed 's/^/    /'
        [ -n "$code_refs" ] && printf '%s\n' "$code_refs" | sed 's/^/    /'
    fi
    echo ""
done

if [ "$summary_count" -gt 0 ]; then
    echo -e "  ${BOLD}Session summaries${RESET}"
    printf '%s' "$replay_json" | jq -c '.summaries[]' | while IFS= read -r row; do
        completed=$(printf '%s' "$row" | jq -r '.completed // ""')
        learned=$(printf '%s' "$row" | jq -r '.learned // ""')
        [ -n "$completed" ] && echo -e "  ${GREEN}Done:${RESET} $completed"
        [ -n "$learned" ] && echo -e "  ${YELLOW}Learned:${RESET} $learned"
    done
    echo ""
fi

if [ "$observation_count" -gt 0 ]; then
    echo -e "  ${BOLD}Observed tools${RESET}"
    printf '%s' "$replay_json" | jq -c '.observations[-12:][]' | while IFS= read -r row; do
        tool=$(printf '%s' "$row" | jq -r '.tool_name // ""')
        detail=$(printf '%s' "$row" | jq -r '.tool_input_summary // ""')
        created=$(printf '%s' "$row" | jq -r '.created_at // ""')
        echo -e "  ${DIM}${created}${RESET} ${BOLD}${tool}:${RESET} $detail"
    done
    echo ""
fi
