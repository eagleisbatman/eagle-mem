#!/usr/bin/env bash
# Eagle Mem event log helpers.

eagle_insert_event() {
    local project="$1"
    local session_id="$2"
    local agent="$3"
    local event_type="$4"
    local command="${5:-}"
    local hook_event_name="${6:-}"
    local status="${7:-ok}"
    local detail_json="${8:-}"
    [ -n "$detail_json" ] || detail_json="{}"

    [ -n "$event_type" ] || return 0
    [ -f "$EAGLE_MEM_DB" ] || return 0

    if [ -z "$(eagle_db "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'eagle_events' LIMIT 1;" 2>/dev/null || true)" ]; then
        return 0
    fi

    detail_json=$(printf '%s' "$detail_json" | jq -c . 2>/dev/null || printf '{}')

    local p_sql sid_sql agent_sql type_sql command_sql hook_sql status_sql detail_sql
    p_sql=$(eagle_sql_escape "$project")
    sid_sql=$(eagle_sql_escape "$session_id")
    agent_sql=$(eagle_sql_escape "$agent")
    type_sql=$(eagle_sql_escape "$event_type")
    command_sql=$(eagle_sql_escape "$command")
    hook_sql=$(eagle_sql_escape "$hook_event_name")
    status_sql=$(eagle_sql_escape "$status")
    detail_sql=$(eagle_sql_escape "$detail_json")

    eagle_db "INSERT INTO eagle_events (
                  project, session_id, agent, event_type, command,
                  hook_event_name, status, detail_json
              )
              VALUES (
                  '$p_sql', '$sid_sql', '$agent_sql', '$type_sql', '$command_sql',
                  '$hook_sql', '$status_sql', '$detail_sql'
              );" >/dev/null 2>&1 || true
}

eagle_hook_observability_begin() {
    local input="$1"
    local default_hook="$2"

    EAGLE_EVENT_HOOK_NAME=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)
    [ -n "$EAGLE_EVENT_HOOK_NAME" ] || EAGLE_EVENT_HOOK_NAME="$default_hook"
    EAGLE_EVENT_SESSION_ID=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
    EAGLE_EVENT_CWD=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
    EAGLE_EVENT_TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
    EAGLE_EVENT_AGENT=$(eagle_agent_source_from_json "$input")
    EAGLE_EVENT_PROJECT=$(eagle_project_from_hook_input "$input")
    EAGLE_EVENT_COMPLETION_DETAIL="{}"

    [ -n "$EAGLE_EVENT_PROJECT" ] || return 0

    local detail
    detail=$(jq -nc \
        --arg cwd "$EAGLE_EVENT_CWD" \
        --arg tool "$EAGLE_EVENT_TOOL_NAME" \
        '{cwd:$cwd, tool_name:$tool}')
    eagle_insert_event "$EAGLE_EVENT_PROJECT" "$EAGLE_EVENT_SESSION_ID" "$EAGLE_EVENT_AGENT" "hook_started" "" "$EAGLE_EVENT_HOOK_NAME" "ok" "$detail"
}

eagle_hook_observability_set_detail() {
    local detail_json="${1:-}"
    [ -n "$detail_json" ] || detail_json="{}"
    EAGLE_EVENT_COMPLETION_DETAIL=$(printf '%s' "$detail_json" | jq -c . 2>/dev/null || printf '{}')
}

eagle_hook_observability_complete() {
    local rc="${1:-0}"
    [ -n "${EAGLE_EVENT_PROJECT:-}" ] || return 0

    local status="ok"
    [ "$rc" -ne 0 ] 2>/dev/null && status="error"

    eagle_insert_event \
        "$EAGLE_EVENT_PROJECT" \
        "${EAGLE_EVENT_SESSION_ID:-}" \
        "${EAGLE_EVENT_AGENT:-}" \
        "hook_completed" \
        "" \
        "${EAGLE_EVENT_HOOK_NAME:-}" \
        "$status" \
        "${EAGLE_EVENT_COMPLETION_DETAIL:-}"
}
