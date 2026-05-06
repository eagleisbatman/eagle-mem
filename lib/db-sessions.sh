#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Session helpers
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_SESSIONS_LOADED:-}" ] && return 0
_EAGLE_DB_SESSIONS_LOADED=1

eagle_upsert_session() {
    local session_id_raw="${1:-}"
    local project_raw="${2:-}"
    local session_id; session_id=$(eagle_sql_escape "$session_id_raw")
    local project; project=$(eagle_sql_escape "$project_raw")
    local cwd; cwd=$(eagle_sql_escape "${3:-}")
    local model; model=$(eagle_sql_escape "${4:-}")
    local source; source=$(eagle_sql_escape "${5:-}")
    local agent; agent=$(eagle_sql_escape "${6:-$(eagle_agent_source)}")
    local prior_project
    prior_project=$(eagle_db "SELECT project FROM sessions WHERE id = '$session_id' LIMIT 1;" 2>/dev/null || true)

    eagle_db "INSERT INTO sessions (id, project, cwd, model, source, agent, last_activity_at)
              VALUES ('$session_id', '$project', '$cwd', '$model', '$source', '$agent', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
              ON CONFLICT(id) DO UPDATE SET
                  cwd = COALESCE(NULLIF(excluded.cwd, ''), sessions.cwd),
                  model = COALESCE(NULLIF(excluded.model, ''), sessions.model),
                  source = COALESCE(NULLIF(excluded.source, ''), sessions.source),
                  agent = COALESCE(NULLIF(excluded.agent, ''), sessions.agent),
                  status = 'active',
                  last_activity_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"

    local needs_project_repair=0
    if [ -n "$project_raw" ]; then
        if [ "$prior_project" != "$project_raw" ]; then
            needs_project_repair=1
        else
            local stale_child
            stale_child=$(eagle_db "SELECT 1 WHERE
                EXISTS (SELECT 1 FROM summaries WHERE session_id = '$session_id' AND project != '$project')
                OR EXISTS (SELECT 1 FROM observations WHERE session_id = '$session_id' AND project != '$project')
                OR EXISTS (SELECT 1 FROM agent_tasks WHERE source_session_id = '$session_id' AND project != '$project')
                OR EXISTS (SELECT 1 FROM agent_memories WHERE origin_session_id = '$session_id' AND project != '$project')
                OR EXISTS (SELECT 1 FROM agent_plans WHERE origin_session_id = '$session_id' AND project != '$project')
                OR EXISTS (SELECT 1 FROM pending_feature_verifications WHERE source_session_id = '$session_id' AND project != '$project')
                OR EXISTS (
                    SELECT 1
                    FROM pending_feature_verifications p
                    JOIN features f ON f.id = p.feature_id
                    WHERE p.source_session_id = '$session_id'
                      AND f.project != '$project'
                )
                LIMIT 1;" 2>/dev/null || true)
            [ "$stale_child" = "1" ] && needs_project_repair=1
        fi
    fi

    if [ "$needs_project_repair" = "1" ]; then
        eagle_db_pipe <<SQL >/dev/null 2>&1
BEGIN;
UPDATE summaries SET project = '$project' WHERE session_id = '$session_id' AND project != '$project';
UPDATE observations SET project = '$project' WHERE session_id = '$session_id' AND project != '$project';
UPDATE agent_tasks SET project = '$project' WHERE source_session_id = '$session_id' AND project != '$project';
UPDATE agent_memories SET project = '$project' WHERE origin_session_id = '$session_id' AND project != '$project';
UPDATE agent_plans SET project = '$project' WHERE origin_session_id = '$session_id' AND project != '$project';
CREATE TEMP TABLE IF NOT EXISTS eagle_feature_repair_map (
    old_feature_id INTEGER PRIMARY KEY,
    new_feature_id INTEGER NOT NULL
);
DELETE FROM eagle_feature_repair_map;
INSERT OR IGNORE INTO features (project, name, description, status, last_verified_at, last_verified_notes)
SELECT '$project', f_old.name, f_old.description, f_old.status, f_old.last_verified_at, f_old.last_verified_notes
FROM pending_feature_verifications p
JOIN features f_old ON f_old.id = p.feature_id
WHERE p.source_session_id = '$session_id'
  AND (p.project != '$project' OR f_old.project != '$project')
GROUP BY f_old.name;
INSERT OR REPLACE INTO eagle_feature_repair_map (old_feature_id, new_feature_id)
SELECT DISTINCT f_old.id, f_new.id
FROM pending_feature_verifications p
JOIN features f_old ON f_old.id = p.feature_id
JOIN features f_new ON f_new.project = '$project' AND f_new.name = f_old.name
WHERE p.source_session_id = '$session_id'
  AND (p.project != '$project' OR f_old.project != '$project');
INSERT OR IGNORE INTO feature_files (feature_id, file_path, role)
SELECT f_new.id, ff.file_path, ff.role
FROM pending_feature_verifications p
JOIN features f_old ON f_old.id = p.feature_id
JOIN eagle_feature_repair_map m ON m.old_feature_id = f_old.id
JOIN features f_new ON f_new.id = m.new_feature_id
JOIN feature_files ff ON ff.feature_id = f_old.id
WHERE p.source_session_id = '$session_id'
  AND (p.project != '$project' OR f_old.project != '$project');
INSERT OR IGNORE INTO feature_dependencies (feature_id, kind, target, name, notes)
SELECT f_new.id, fd.kind, fd.target, fd.name, fd.notes
FROM pending_feature_verifications p
JOIN features f_old ON f_old.id = p.feature_id
JOIN eagle_feature_repair_map m ON m.old_feature_id = f_old.id
JOIN features f_new ON f_new.id = m.new_feature_id
JOIN feature_dependencies fd ON fd.feature_id = f_old.id
WHERE p.source_session_id = '$session_id'
  AND (p.project != '$project' OR f_old.project != '$project');
INSERT OR IGNORE INTO feature_smoke_tests (feature_id, command, description)
SELECT f_new.id, fst.command, fst.description
FROM pending_feature_verifications p
JOIN features f_old ON f_old.id = p.feature_id
JOIN eagle_feature_repair_map m ON m.old_feature_id = f_old.id
JOIN features f_new ON f_new.id = m.new_feature_id
JOIN feature_smoke_tests fst ON fst.feature_id = f_old.id
WHERE p.source_session_id = '$session_id'
  AND (p.project != '$project' OR f_old.project != '$project');
DELETE FROM pending_feature_verifications
WHERE source_session_id = '$session_id'
  AND status = 'pending'
  AND id NOT IN (
      SELECT MIN(p.id)
      FROM pending_feature_verifications p
      LEFT JOIN eagle_feature_repair_map m ON m.old_feature_id = p.feature_id
      WHERE p.source_session_id = '$session_id'
        AND p.status = 'pending'
      GROUP BY
          CASE WHEN m.new_feature_id IS NOT NULL THEN '$project' ELSE p.project END,
          COALESCE(m.new_feature_id, p.feature_id),
          p.file_path
  )
  AND EXISTS (
      SELECT 1
      FROM eagle_feature_repair_map m
      WHERE m.old_feature_id = pending_feature_verifications.feature_id
  );
UPDATE pending_feature_verifications
SET feature_id = COALESCE((SELECT new_feature_id FROM eagle_feature_repair_map WHERE old_feature_id = feature_id), feature_id)
WHERE source_session_id = '$session_id'
  AND EXISTS (SELECT 1 FROM eagle_feature_repair_map WHERE old_feature_id = pending_feature_verifications.feature_id);
DELETE FROM pending_feature_verifications
WHERE source_session_id = '$session_id'
  AND project != '$project'
  AND status = 'pending'
  AND EXISTS (
      SELECT 1
      FROM pending_feature_verifications p2
      WHERE p2.project = '$project'
        AND p2.feature_id = pending_feature_verifications.feature_id
        AND p2.file_path = pending_feature_verifications.file_path
        AND p2.status = 'pending'
        AND p2.id != pending_feature_verifications.id
  );
UPDATE pending_feature_verifications SET project = '$project' WHERE source_session_id = '$session_id' AND project != '$project';
UPDATE sessions SET project = '$project' WHERE id = '$session_id' AND project != '$project';
COMMIT;
SQL
    fi
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
    local project_scope="${1:-}"
    local session_filter memory_filter plan_filter task_filter chunk_filter observation_filter
    session_filter=$(eagle_sql_project_scope_condition "project" "$project_scope")
    memory_filter=$(eagle_sql_project_scope_condition "project" "$project_scope")
    plan_filter=$(eagle_sql_project_scope_condition "project" "$project_scope")
    task_filter=$(eagle_sql_project_scope_condition "project" "$project_scope")
    chunk_filter=$(eagle_sql_project_scope_condition "project" "$project_scope")
    observation_filter=$(eagle_sql_project_scope_condition "project" "$project_scope")
    eagle_db_pipe <<SQL
SELECT 'sessions|' || COUNT(*) FROM sessions WHERE $session_filter;
SELECT 'sessions_claude|' || COUNT(*) FROM sessions WHERE $session_filter AND agent = 'claude-code';
SELECT 'sessions_codex|' || COUNT(*) FROM sessions WHERE $session_filter AND agent = 'codex';
SELECT 'summaries|' || COUNT(*) FROM summaries WHERE $session_filter;
SELECT 'with_summaries|' || COUNT(*) FROM summaries WHERE $session_filter AND request IS NOT NULL AND request != '';
SELECT 'memories|' || COUNT(*) FROM agent_memories WHERE $memory_filter;
SELECT 'plans|' || COUNT(*) FROM agent_plans WHERE $plan_filter;
SELECT 'tasks_pending|' || COUNT(*) FROM agent_tasks WHERE $task_filter AND status = 'pending';
SELECT 'tasks_progress|' || COUNT(*) FROM agent_tasks WHERE $task_filter AND status = 'in_progress';
SELECT 'tasks_done|' || COUNT(*) FROM agent_tasks WHERE $task_filter AND status = 'completed';
SELECT 'chunks|' || COUNT(*) FROM code_chunks WHERE $chunk_filter;
SELECT 'observations|' || COUNT(*) FROM observations WHERE $observation_filter;
SELECT 'last_active|' || COALESCE(MAX(date(COALESCE(last_activity_at, started_at))), 'never') FROM sessions WHERE $session_filter;
SELECT 'last_summary|' || COALESCE((SELECT substr(request, 1, 60)
    FROM summaries
    WHERE $session_filter
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
