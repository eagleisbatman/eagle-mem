#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Orchestration DB helpers
# Lightweight helpers safe for hooks; full worker management lives in scripts/orchestrate.sh.
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_ORCHESTRATION_LOADED:-}" ] && return 0
_EAGLE_DB_ORCHESTRATION_LOADED=1

eagle_auto_orchestration_agent() {
    local agent="${1:-}"
    case "$agent" in
        codex|claude-code) printf '%s\n' "$agent" ;;
        *) printf 'codex\n' ;;
    esac
}

eagle_auto_orchestration_lane_sql() {
    local oid="$1" project="$2" name="$3" lane_key="$4" title="$5" description="$6" agent="$7" validation="$8"
    local source_task_id file_path content_hash
    local oid_sql project_sql name_sql key_sql title_sql desc_sql agent_sql validation_sql task_sql fp_sql hash_sql

    oid_sql=$(eagle_sql_int "$oid")
    project_sql=$(eagle_sql_escape "$project")
    name_sql=$(eagle_sql_escape "$name")
    key_sql=$(eagle_sql_escape "$lane_key")
    title_sql=$(eagle_sql_escape "$title")
    desc_sql=$(eagle_sql_escape "$description")
    agent_sql=$(eagle_sql_escape "$(eagle_auto_orchestration_agent "$agent")")
    validation_sql=$(eagle_sql_escape "$validation")
    source_task_id="lane-${name}-${lane_key}"
    file_path="orchestration-lane://${project}/${name}/${lane_key}"
    task_sql=$(eagle_sql_escape "$source_task_id")
    fp_sql=$(eagle_sql_escape "$file_path")
    content_hash=$(printf '%s|%s|%s|%s|%s' "$lane_key" "$title" "$description" "$agent" "$validation" | eagle_sha256_stream)
    hash_sql=$(eagle_sql_escape "$content_hash")

    cat <<SQL
INSERT INTO orchestration_lanes (orchestration_id, project, lane_key, title, description, agent, worktree_path, validation, status, source_task_id)
VALUES ($oid_sql, '$project_sql', '$key_sql', '$title_sql', '$desc_sql', '$agent_sql', '', '$validation_sql', 'pending', '$task_sql')
ON CONFLICT(orchestration_id, lane_key) DO UPDATE SET
    title = excluded.title,
    description = excluded.description,
    agent = excluded.agent,
    validation = excluded.validation,
    source_task_id = excluded.source_task_id,
    status = CASE
        WHEN orchestration_lanes.status IN ('completed', 'cancelled') THEN orchestration_lanes.status
        ELSE orchestration_lanes.status
    END,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');

INSERT INTO agent_tasks (project, source_session_id, source_task_id, file_path, subject, description, active_form, status, blocks, blocked_by, content_hash, origin_agent)
VALUES ('$project_sql', 'orchestration', '$task_sql', '$fp_sql', '$title_sql', '$desc_sql', '$validation_sql', 'pending', '[]', '[]', '$hash_sql', '$agent_sql')
ON CONFLICT(file_path) DO UPDATE SET
    source_task_id = excluded.source_task_id,
    file_path = excluded.file_path,
    subject = excluded.subject,
    description = excluded.description,
    active_form = excluded.active_form,
    status = CASE
        WHEN agent_tasks.status IN ('completed', 'cancelled') THEN agent_tasks.status
        ELSE agent_tasks.status
    END,
    content_hash = excluded.content_hash,
    origin_agent = excluded.origin_agent,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');
SQL
}

eagle_auto_orchestrate_from_prompt() {
    local project_raw="${1:-}"
    local session_id_raw="${2:-}"
    local agent_raw="${3:-$(eagle_agent_source)}"
    local prompt_raw="${4:-}"
    local cwd_raw="${5:-}"
    local trigger_raw="${6:-broad_prompt}"
    [ -n "$project_raw" ] && [ -n "$prompt_raw" ] || return 0

    local has_tables
    has_tables=$(eagle_db "SELECT COUNT(*)
                           FROM sqlite_master
                           WHERE type = 'table'
                             AND name IN ('orchestrations', 'orchestration_lanes', 'agent_tasks');" 2>/dev/null || printf '0')
    [ "${has_tables:-0}" -ge 3 ] 2>/dev/null || return 0

    local name="auto"
    local project_sql name_sql goal_sql baseline_sql run_key_sql session_sql cwd_sql agent_sql trigger_sql prompt_sql
    local oid lanes_json lanes_sql lane_count
    project_sql=$(eagle_sql_escape "$project_raw")
    name_sql=$(eagle_sql_escape "$name")
    goal_sql=$(eagle_sql_escape "$(eagle_trim_text "$prompt_raw" 700)")
    baseline_sql=$(eagle_sql_escape "$(git -C "${cwd_raw:-$(pwd)}" rev-parse --short HEAD 2>/dev/null || true)")
    run_key_sql=$(eagle_sql_escape "auto-$(printf '%s' "$project_raw|$prompt_raw" | eagle_sha256_stream | cut -c1-12)")
    session_sql=$(eagle_sql_escape "$session_id_raw")
    cwd_sql=$(eagle_sql_escape "$cwd_raw")
    agent_sql=$(eagle_sql_escape "$(eagle_auto_orchestration_agent "$agent_raw")")
    trigger_sql=$(eagle_sql_escape "$trigger_raw")
    prompt_sql=$(eagle_sql_escape "$(eagle_trim_text "$prompt_raw" 300)")

    eagle_db_pipe <<SQL >/dev/null
INSERT INTO orchestrations (project, name, goal, status, baseline_ref, run_key)
VALUES ('$project_sql', '$name_sql', '$goal_sql', 'active', '$baseline_sql', '$run_key_sql')
ON CONFLICT(project, name) DO UPDATE SET
    goal = excluded.goal,
    status = 'active',
    baseline_ref = COALESCE(NULLIF(excluded.baseline_ref, ''), orchestrations.baseline_ref),
    run_key = CASE
        WHEN orchestrations.status IN ('completed', 'cancelled')
          OR orchestrations.run_key IS NULL
          OR orchestrations.run_key = ''
        THEN excluded.run_key
        ELSE orchestrations.run_key
    END,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');
SQL

    oid=$(eagle_db "SELECT id FROM orchestrations WHERE project = '$project_sql' AND name = '$name_sql' LIMIT 1;" 2>/dev/null || true)
    [ -n "$oid" ] || return 0

    eagle_db_pipe <<SQL >/dev/null
BEGIN;
$(eagle_auto_orchestration_lane_sql "$oid" "$project_raw" "$name" "scope" "Scope broad request" "Map requirements, affected files, risks, and existing docs before implementation." "$agent_raw" "Document scope and affected surfaces")
$(eagle_auto_orchestration_lane_sql "$oid" "$project_raw" "$name" "implementation" "Implement scoped changes" "Make the smallest safe changes needed for the broad request, preserving existing behavior." "$agent_raw" "Run targeted implementation checks")
$(eagle_auto_orchestration_lane_sql "$oid" "$project_raw" "$name" "verification" "Verify and report" "Run targeted tests, smoke checks, and update backlog or handoff notes after implementation." "$agent_raw" "Run relevant tests and smoke checks")
UPDATE orchestrations SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = $oid;
COMMIT;
SQL

    lanes_json=$(eagle_db_json "SELECT lane_key, title, agent, status
                                FROM orchestration_lanes
                                WHERE orchestration_id = $oid
                                ORDER BY CASE lane_key WHEN 'scope' THEN 0 WHEN 'implementation' THEN 1 WHEN 'verification' THEN 2 ELSE 3 END, lane_key;" 2>/dev/null || printf '[]')
    [ -n "$lanes_json" ] || lanes_json="[]"
    lanes_sql=$(eagle_sql_escape "$lanes_json")
    lane_count=$(printf '%s' "$lanes_json" | jq 'length' 2>/dev/null || printf '0')

    if [ -n "$(eagle_db "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'orchestration_auto_events' LIMIT 1;" 2>/dev/null || true)" ]; then
        eagle_db "INSERT INTO orchestration_auto_events (
                      session_id, project, cwd, agent, prompt_snippet, trigger,
                      orchestration_id, orchestration_name, lanes, status
                  )
                  VALUES (
                      '$session_sql', '$project_sql', '$cwd_sql', '$agent_sql', '$prompt_sql', '$trigger_sql',
                      $oid, '$name_sql', '$lanes_sql', 'created'
                  );" >/dev/null 2>&1 || true
    fi

    printf '%s|%s|%s|%s\n' "$name" "$oid" "${lane_count:-0}" "$lanes_json"
}
