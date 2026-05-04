#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Session helpers
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_SESSIONS_LOADED:-}" ] && return 0
_EAGLE_DB_SESSIONS_LOADED=1

eagle_upsert_session() {
    local session_id; session_id=$(eagle_sql_escape "$1")
    local project; project=$(eagle_sql_escape "$2")
    local cwd; cwd=$(eagle_sql_escape "${3:-}")
    local model; model=$(eagle_sql_escape "${4:-}")
    local source; source=$(eagle_sql_escape "${5:-}")
    local agent; agent=$(eagle_sql_escape "${6:-$(eagle_agent_source)}")

    eagle_db "INSERT INTO sessions (id, project, cwd, model, source, agent, last_activity_at)
              VALUES ('$session_id', '$project', '$cwd', '$model', '$source', '$agent', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
              ON CONFLICT(id) DO UPDATE SET
                  cwd = COALESCE(NULLIF(excluded.cwd, ''), sessions.cwd),
                  model = COALESCE(NULLIF(excluded.model, ''), sessions.model),
                  source = COALESCE(NULLIF(excluded.source, ''), sessions.source),
                  agent = COALESCE(NULLIF(excluded.agent, ''), sessions.agent),
                  status = 'active',
                  last_activity_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"
}

eagle_end_session() {
    local session_id; session_id=$(eagle_sql_escape "$1")
    eagle_db "UPDATE sessions SET status = 'completed', ended_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = '$session_id';"
}

eagle_abandon_stale_sessions() {
    local exclude_sid="${1:-}"
    local exclude_clause=""
    if [ -n "$exclude_sid" ]; then
        exclude_clause="AND id != '$(eagle_sql_escape "$exclude_sid")'"
    fi
    eagle_db "UPDATE sessions SET status = 'abandoned'
        WHERE status = 'active'
        $exclude_clause
        AND COALESCE(last_activity_at, started_at) < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-7 days');"
}

eagle_get_project_stats() {
    local project; project=$(eagle_sql_escape "$1")
    eagle_db_pipe <<SQL
SELECT 'sessions|' || COUNT(*) FROM sessions WHERE project = '$project';
SELECT 'sessions_claude|' || COUNT(*) FROM sessions WHERE project = '$project' AND agent = 'claude-code';
SELECT 'sessions_codex|' || COUNT(*) FROM sessions WHERE project = '$project' AND agent = 'codex';
SELECT 'summaries|' || COUNT(*) FROM summaries WHERE project = '$project';
SELECT 'with_summaries|' || COUNT(*) FROM summaries WHERE project = '$project' AND request IS NOT NULL AND request != '';
SELECT 'memories|' || COUNT(*) FROM agent_memories WHERE project = '$project';
SELECT 'plans|' || COUNT(*) FROM agent_plans WHERE project = '$project';
SELECT 'tasks_pending|' || COUNT(*) FROM agent_tasks WHERE project = '$project' AND status = 'pending';
SELECT 'tasks_progress|' || COUNT(*) FROM agent_tasks WHERE project = '$project' AND status = 'in_progress';
SELECT 'tasks_done|' || COUNT(*) FROM agent_tasks WHERE project = '$project' AND status = 'completed';
SELECT 'chunks|' || COUNT(*) FROM code_chunks WHERE project = '$project';
SELECT 'observations|' || COUNT(*) FROM observations WHERE session_id IN (SELECT id FROM sessions WHERE project = '$project');
SELECT 'last_active|' || COALESCE(MAX(date(COALESCE(last_activity_at, started_at))), 'never') FROM sessions WHERE project = '$project';
SELECT 'last_summary|' || COALESCE((SELECT substr(request, 1, 60)
    FROM summaries
    WHERE project = '$project'
    AND COALESCE(request, '') NOT LIKE '# AGENTS.md instructions%'
    AND COALESCE(request, '') NOT LIKE '<environment_context>%'
    ORDER BY created_at DESC
    LIMIT 1), '');
SQL
}

eagle_get_session_project() {
    local sid; sid=$(eagle_sql_escape "$1")
    eagle_db "SELECT project FROM sessions WHERE id = '$sid' LIMIT 1;"
}

eagle_count_session_summaries() {
    local sid; sid=$(eagle_sql_escape "$1")
    eagle_db "SELECT COUNT(*) FROM summaries WHERE session_id = '$sid';"
}

eagle_meta_get() {
    local key; key=$(eagle_sql_escape "$1")
    local p_esc; p_esc=$(eagle_sql_escape "${2:-}")
    eagle_db "SELECT value FROM eagle_meta WHERE key = '$key' AND project = '$p_esc' LIMIT 1;"
}

eagle_meta_set() {
    local key; key=$(eagle_sql_escape "$1")
    local value; value=$(eagle_sql_escape "$2")
    local p_esc; p_esc=$(eagle_sql_escape "${3:-}")
    eagle_db "INSERT INTO eagle_meta (key, project, value) VALUES ('$key', '$p_esc', '$value')
              ON CONFLICT(key, project) DO UPDATE SET value = excluded.value, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"
}

eagle_count_sessions_since() {
    local project; project=$(eagle_sql_escape "$1")
    local since; since=$(eagle_sql_escape "$2")
    eagle_db "SELECT COUNT(*) FROM sessions WHERE project = '$project' AND started_at > '$since';"
}
