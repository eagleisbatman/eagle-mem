#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Database helpers
# Source after common.sh: . "$(dirname "$0")/../lib/db.sh"
# ═══════════════════════════════════════════════════════════

EAGLE_DB_SETUP=".headers off
.output /dev/null
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;
PRAGMA trusted_schema=ON;
.output stdout"

eagle_db() {
    { echo "$EAGLE_DB_SETUP"; echo "$*"; } | sqlite3 "$EAGLE_MEM_DB" 2>/dev/null
}

eagle_db_pipe() {
    { echo "$EAGLE_DB_SETUP"; cat; } | sqlite3 "$EAGLE_MEM_DB" 2>/dev/null
}

eagle_db_json() {
    { echo "$EAGLE_DB_SETUP"; echo ".mode json"; echo "$*"; } | sqlite3 "$EAGLE_MEM_DB" 2>/dev/null
}

eagle_ensure_db() {
    if [ ! -f "$EAGLE_MEM_DB" ]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../db" && pwd)"
        "$script_dir/migrate.sh"
    fi
}

eagle_upsert_session() {
    local session_id; session_id=$(eagle_sql_escape "$1")
    local project; project=$(eagle_sql_escape "$2")
    local cwd; cwd=$(eagle_sql_escape "${3:-}")
    local model; model=$(eagle_sql_escape "${4:-}")
    local source; source=$(eagle_sql_escape "${5:-}")

    eagle_db "INSERT INTO sessions (id, project, cwd, model, source)
              VALUES ('$session_id', '$project', '$cwd', '$model', '$source')
              ON CONFLICT(id) DO UPDATE SET
                  cwd = COALESCE(excluded.cwd, sessions.cwd),
                  model = COALESCE(excluded.model, sessions.model),
                  source = COALESCE(excluded.source, sessions.source);"
}

eagle_end_session() {
    local session_id; session_id=$(eagle_sql_escape "$1")
    eagle_db "UPDATE sessions SET status = 'completed', ended_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = '$session_id';"
}

eagle_insert_observation() {
    local session_id; session_id=$(eagle_sql_escape "$1")
    local project; project=$(eagle_sql_escape "$2")
    local tool_name; tool_name=$(eagle_sql_escape "$3")
    local tool_input_summary; tool_input_summary=$(eagle_sql_escape "$4")
    local files_read; files_read=$(eagle_sql_escape "$5")
    local files_modified; files_modified=$(eagle_sql_escape "$6")

    eagle_db "INSERT INTO observations (session_id, project, tool_name, tool_input_summary, files_read, files_modified)
              VALUES ('$session_id', '$project', '$tool_name', '$tool_input_summary', '$files_read', '$files_modified');"
}

eagle_insert_summary() {
    local session_id; session_id=$(eagle_sql_escape "$1")
    local project; project=$(eagle_sql_escape "$2")
    local request; request=$(eagle_sql_escape "$3")
    local investigated; investigated=$(eagle_sql_escape "$4")
    local learned; learned=$(eagle_sql_escape "$5")
    local completed; completed=$(eagle_sql_escape "$6")
    local next_steps; next_steps=$(eagle_sql_escape "$7")
    local files_read; files_read=$(eagle_sql_escape "$8")
    local files_modified; files_modified=$(eagle_sql_escape "$9")
    local notes; notes=$(eagle_sql_escape "${10:-}")

    eagle_db_pipe <<SQL
INSERT INTO summaries (session_id, project, request, investigated, learned, completed, next_steps, files_read, files_modified, notes)
VALUES (
    '$session_id',
    '$project',
    '$request',
    '$investigated',
    '$learned',
    '$completed',
    '$next_steps',
    '$files_read',
    '$files_modified',
    '$notes'
);
SQL
}

eagle_get_recent_summaries() {
    local project; project=$(eagle_sql_escape "$1")
    local limit; limit=$(eagle_sql_int "${2:-5}")

    eagle_db "SELECT s.request, s.completed, s.learned, s.next_steps, s.created_at
              FROM summaries s
              WHERE s.project = '$project'
              ORDER BY s.created_at DESC
              LIMIT $limit;"
}

eagle_search_summaries() {
    local query; query=$(eagle_sql_escape "$1")
    local project="${2:-}"
    local limit; limit=$(eagle_sql_int "${3:-10}")

    local where_clause=""
    if [ -n "$project" ]; then
        project=$(eagle_sql_escape "$project")
        where_clause="AND s.project = '$project'"
    fi

    eagle_db "SELECT s.request, s.completed, s.learned, s.next_steps, s.created_at, s.project
              FROM summaries s
              JOIN summaries_fts f ON f.rowid = s.id
              WHERE summaries_fts MATCH '$query'
              $where_clause
              ORDER BY rank
              LIMIT $limit;"
}

eagle_get_pending_tasks() {
    local project; project=$(eagle_sql_escape "$1")

    eagle_db "SELECT id, title, instructions, status, ordinal
              FROM tasks
              WHERE project = '$project' AND status IN ('pending', 'active')
              ORDER BY ordinal ASC, id ASC;"
}

eagle_get_next_task() {
    local project; project=$(eagle_sql_escape "$1")

    eagle_db "SELECT id, title, instructions, context_snapshot
              FROM tasks
              WHERE project = '$project' AND status = 'pending'
              ORDER BY ordinal ASC, id ASC
              LIMIT 1;"
}

eagle_get_active_files() {
    local project; project=$(eagle_sql_escape "$1")
    local limit; limit=$(eagle_sql_int "${2:-20}")

    eagle_db "SELECT json_each.value
              FROM observations, json_each(observations.files_modified)
              WHERE observations.project = '$project'
              AND observations.created_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')
              GROUP BY json_each.value
              ORDER BY MAX(observations.created_at) DESC
              LIMIT $limit;"
}

eagle_observation_exists() {
    local session_id; session_id=$(eagle_sql_escape "$1")
    local tool_name; tool_name=$(eagle_sql_escape "$2")
    local tool_summary; tool_summary=$(eagle_sql_escape "$3")

    eagle_db "SELECT COUNT(*) FROM observations
              WHERE session_id = '$session_id'
              AND tool_name = '$tool_name'
              AND tool_input_summary = '$tool_summary'
              AND created_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-5 seconds');"
}

eagle_upsert_overview() {
    local project; project=$(eagle_sql_escape "$1")
    local content; content=$(eagle_sql_escape "$2")

    eagle_db "INSERT INTO overviews (project, content, updated_at)
              VALUES ('$project', '$content', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
              ON CONFLICT(project) DO UPDATE SET
                  content = excluded.content,
                  updated_at = excluded.updated_at;"
}

eagle_get_overview() {
    local project; project=$(eagle_sql_escape "$1")

    eagle_db "SELECT content FROM overviews WHERE project = '$project';"
}

eagle_activate_task() {
    local task_id; task_id=$(eagle_sql_int "$1")
    eagle_db "UPDATE tasks SET status = 'active', started_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = $task_id;"
}

eagle_complete_active_task() {
    local project; project=$(eagle_sql_escape "$1")
    local active_id
    active_id=$(eagle_db "SELECT id FROM tasks WHERE project = '$project' AND status = 'active' LIMIT 1;")
    if [ -n "$active_id" ]; then
        local safe_id; safe_id=$(eagle_sql_int "$active_id")
        eagle_db "UPDATE tasks SET status = 'done', completed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = $safe_id;"
        echo "$active_id"
    fi
}

eagle_get_active_task() {
    local project; project=$(eagle_sql_escape "$1")
    eagle_db "SELECT id, title, instructions, context_snapshot
              FROM tasks
              WHERE project = '$project' AND status = 'active'
              ORDER BY ordinal ASC, id ASC
              LIMIT 1;"
}

eagle_search_code_chunks() {
    local query; query=$(eagle_sql_escape "$1")
    local project; project=$(eagle_sql_escape "$2")
    local limit; limit=$(eagle_sql_int "${3:-5}")

    eagle_db "SELECT c.file_path, c.start_line, c.end_line, c.language
              FROM code_chunks c
              JOIN code_chunks_fts f ON f.rowid = c.id
              WHERE code_chunks_fts MATCH '$query'
              AND c.project = '$project'
              ORDER BY rank
              LIMIT $limit;"
}

eagle_count_code_chunks() {
    local project; project=$(eagle_sql_escape "$1")
    eagle_db "SELECT COUNT(*) FROM code_chunks WHERE project = '$project' LIMIT 1;"
}

eagle_prune_observations() {
    local days; days=$(eagle_sql_int "${1:-90}")
    local project_filter=""
    if [ -n "${2:-}" ]; then
        local proj; proj=$(eagle_sql_escape "$2")
        project_filter="AND session_id IN (SELECT id FROM sessions WHERE project = '$proj')"
    fi
    eagle_db "DELETE FROM observations WHERE created_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-$days days') $project_filter;"
}

eagle_capture_claude_memory() {
    local file_path="$1"
    local session_id="${2:-}"
    local project="${3:-}"

    [ ! -f "$file_path" ] && return 0

    local chash
    chash=$(shasum -a 256 "$file_path" | awk '{print $1}')

    local fm body
    fm=$(awk '/^---$/{c++; next} c==1' "$file_path")
    body=$(awk '/^---$/{c++; next} c>=2' "$file_path")

    _fm_field() { printf '%s\n' "$fm" | awk -F': *' -v k="$1" '$1==k{sub(/^[^:]+: */,""); gsub(/^"|"$/,""); print; exit}'; }

    local mname mdesc mtype morigin
    mname=$(_fm_field "name")
    mdesc=$(_fm_field "description")
    mtype=$(_fm_field "type")
    morigin=$(_fm_field "originSessionId")
    [ -z "$morigin" ] && morigin="$session_id"

    local fp_sql proj_sql name_sql desc_sql type_sql content_sql hash_sql origin_sql
    fp_sql=$(eagle_sql_escape "$file_path")
    proj_sql=$(eagle_sql_escape "$project")
    name_sql=$(eagle_sql_escape "$mname")
    desc_sql=$(eagle_sql_escape "$mdesc")
    type_sql=$(eagle_sql_escape "$mtype")
    content_sql=$(eagle_sql_escape "$body")
    hash_sql=$(eagle_sql_escape "$chash")
    origin_sql=$(eagle_sql_escape "$morigin")

    eagle_db_pipe <<SQL
INSERT INTO claude_memories (project, file_path, memory_name, description, memory_type, content, content_hash, origin_session_id)
VALUES ('$proj_sql', '$fp_sql', '$name_sql', '$desc_sql', '$type_sql', '$content_sql', '$hash_sql', '$origin_sql')
ON CONFLICT(file_path) DO UPDATE SET
    memory_name     = excluded.memory_name,
    description     = excluded.description,
    memory_type     = excluded.memory_type,
    content         = excluded.content,
    content_hash    = excluded.content_hash,
    origin_session_id = excluded.origin_session_id,
    updated_at      = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE claude_memories.content_hash != excluded.content_hash;
SQL
}

eagle_search_claude_memories() {
    local query; query=$(eagle_fts_sanitize "$1")
    query=$(eagle_sql_escape "$query")
    local project="${2:-}"
    local limit; limit=$(eagle_sql_int "${3:-10}")

    local where_clause=""
    if [ -n "$project" ]; then
        project=$(eagle_sql_escape "$project")
        where_clause="AND m.project = '$project'"
    fi

    eagle_db "SELECT m.memory_name, m.memory_type, m.description,
                     replace(substr(m.content, 1, 200), char(10), ' '),
                     m.file_path, m.updated_at
              FROM claude_memories m
              JOIN claude_memories_fts f ON f.rowid = m.id
              WHERE claude_memories_fts MATCH '$query'
              $where_clause
              ORDER BY rank
              LIMIT $limit;"
}

eagle_list_claude_memories() {
    local project="${1:-}"
    local limit; limit=$(eagle_sql_int "${2:-20}")

    local where_clause=""
    if [ -n "$project" ]; then
        project=$(eagle_sql_escape "$project")
        where_clause="WHERE project = '$project'"
    fi

    eagle_db "SELECT memory_name, memory_type, description, file_path, updated_at
              FROM claude_memories
              $where_clause
              ORDER BY updated_at DESC
              LIMIT $limit;"
}

eagle_get_claude_memory() {
    local file_path; file_path=$(eagle_sql_escape "$1")
    eagle_db "SELECT memory_name, memory_type, description, content, file_path, updated_at, origin_session_id
              FROM claude_memories
              WHERE file_path = '$file_path';"
}

eagle_capture_claude_plan() {
    local file_path="$1"
    local session_id="${2:-}"
    local project="${3:-}"

    [ ! -f "$file_path" ] && return 0

    local chash
    chash=$(shasum -a 256 "$file_path" | awk '{print $1}')

    local title content
    title=$(awk '/^# /{print; exit}' "$file_path" | sed 's/^# //')
    content=$(cat "$file_path")

    local fp_sql proj_sql title_sql content_sql hash_sql origin_sql
    fp_sql=$(eagle_sql_escape "$file_path")
    proj_sql=$(eagle_sql_escape "$project")
    title_sql=$(eagle_sql_escape "$title")
    content_sql=$(eagle_sql_escape "$content")
    hash_sql=$(eagle_sql_escape "$chash")
    origin_sql=$(eagle_sql_escape "$session_id")

    eagle_db_pipe <<SQL
INSERT INTO claude_plans (project, file_path, title, content, content_hash, origin_session_id)
VALUES ('$proj_sql', '$fp_sql', '$title_sql', '$content_sql', '$hash_sql', '$origin_sql')
ON CONFLICT(file_path) DO UPDATE SET
    title           = excluded.title,
    content         = excluded.content,
    content_hash    = excluded.content_hash,
    origin_session_id = COALESCE(NULLIF(excluded.origin_session_id, ''), claude_plans.origin_session_id),
    project         = CASE WHEN excluded.project != '' THEN excluded.project ELSE claude_plans.project END,
    updated_at      = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE claude_plans.content_hash != excluded.content_hash;
SQL
}

eagle_search_claude_plans() {
    local query; query=$(eagle_fts_sanitize "$1")
    query=$(eagle_sql_escape "$query")
    local project="${2:-}"
    local limit; limit=$(eagle_sql_int "${3:-10}")

    local where_clause=""
    if [ -n "$project" ]; then
        project=$(eagle_sql_escape "$project")
        where_clause="AND p.project = '$project'"
    fi

    eagle_db "SELECT p.title, p.project,
                     replace(substr(p.content, 1, 200), char(10), ' '),
                     p.file_path, p.updated_at
              FROM claude_plans p
              JOIN claude_plans_fts f ON f.rowid = p.id
              WHERE claude_plans_fts MATCH '$query'
              $where_clause
              ORDER BY rank
              LIMIT $limit;"
}

eagle_list_claude_plans() {
    local project="${1:-}"
    local limit; limit=$(eagle_sql_int "${2:-20}")

    local where_clause=""
    if [ -n "$project" ]; then
        project=$(eagle_sql_escape "$project")
        where_clause="WHERE project = '$project'"
    fi

    eagle_db "SELECT title, project, file_path, updated_at
              FROM claude_plans
              $where_clause
              ORDER BY updated_at DESC
              LIMIT $limit;"
}

eagle_capture_claude_task() {
    local file_path="$1"
    local session_id="${2:-}"
    local project="${3:-}"

    [ ! -f "$file_path" ] && return 0

    local chash
    chash=$(shasum -a 256 "$file_path" | awk '{print $1}')

    local task_json
    task_json=$(cat "$file_path")

    local task_id subject desc active_form status blocks blocked_by
    task_id=$(printf '%s' "$task_json" | jq -r '.id // empty')
    subject=$(printf '%s' "$task_json" | jq -r '.subject // empty')
    desc=$(printf '%s' "$task_json" | jq -r '.description // empty')
    active_form=$(printf '%s' "$task_json" | jq -r '.activeForm // empty')
    status=$(printf '%s' "$task_json" | jq -r '.status // "pending"')
    blocks=$(printf '%s' "$task_json" | jq -c '.blocks // []')
    blocked_by=$(printf '%s' "$task_json" | jq -c '.blockedBy // []')

    [ -z "$task_id" ] && return 0

    local fp_sql proj_sql sid_sql tid_sql subj_sql desc_sql af_sql status_sql blocks_sql bb_sql hash_sql
    fp_sql=$(eagle_sql_escape "$file_path")
    proj_sql=$(eagle_sql_escape "$project")
    sid_sql=$(eagle_sql_escape "$session_id")
    tid_sql=$(eagle_sql_escape "$task_id")
    subj_sql=$(eagle_sql_escape "$subject")
    desc_sql=$(eagle_sql_escape "$desc")
    af_sql=$(eagle_sql_escape "$active_form")
    status_sql=$(eagle_sql_escape "$status")
    blocks_sql=$(eagle_sql_escape "$blocks")
    bb_sql=$(eagle_sql_escape "$blocked_by")
    hash_sql=$(eagle_sql_escape "$chash")

    eagle_db_pipe <<SQL
INSERT INTO claude_tasks (project, source_session_id, source_task_id, file_path, subject, description, active_form, status, blocks, blocked_by, content_hash)
VALUES ('$proj_sql', '$sid_sql', '$tid_sql', '$fp_sql', '$subj_sql', '$desc_sql', '$af_sql', '$status_sql', '$blocks_sql', '$bb_sql', '$hash_sql')
ON CONFLICT(file_path) DO UPDATE SET
    subject         = excluded.subject,
    description     = excluded.description,
    active_form     = excluded.active_form,
    status          = excluded.status,
    blocks          = excluded.blocks,
    blocked_by      = excluded.blocked_by,
    content_hash    = excluded.content_hash,
    project         = CASE WHEN excluded.project != '' THEN excluded.project ELSE claude_tasks.project END,
    updated_at      = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE claude_tasks.content_hash != excluded.content_hash;
SQL
}

eagle_list_claude_tasks() {
    local project="${1:-}"
    local limit; limit=$(eagle_sql_int "${2:-20}")

    local where_clause=""
    if [ -n "$project" ]; then
        project=$(eagle_sql_escape "$project")
        where_clause="WHERE project = '$project'"
    fi

    eagle_db "SELECT subject, status, source_session_id, source_task_id, updated_at
              FROM claude_tasks
              $where_clause
              ORDER BY updated_at DESC
              LIMIT $limit;"
}

eagle_search_claude_tasks() {
    local query; query=$(eagle_fts_sanitize "$1")
    query=$(eagle_sql_escape "$query")
    local project="${2:-}"
    local limit; limit=$(eagle_sql_int "${3:-10}")

    local where_clause=""
    if [ -n "$project" ]; then
        project=$(eagle_sql_escape "$project")
        where_clause="AND t.project = '$project'"
    fi

    eagle_db "SELECT t.subject, t.status,
                     replace(substr(t.description, 1, 200), char(10), ' '),
                     t.source_session_id, t.source_task_id, t.updated_at
              FROM claude_tasks t
              JOIN claude_tasks_fts f ON f.rowid = t.id
              WHERE claude_tasks_fts MATCH '$query'
              $where_clause
              ORDER BY rank
              LIMIT $limit;"
}

eagle_prune_orphan_chunks() {
    local project; project=$(eagle_sql_escape "$1")
    local target_dir="$2"

    # Get all indexed file paths for this project
    local paths
    paths=$(eagle_db "SELECT DISTINCT file_path FROM code_chunks WHERE project = '$project';")

    local removed=0
    while IFS= read -r fpath; do
        [ -z "$fpath" ] && continue
        if [ ! -f "$target_dir/$fpath" ]; then
            local fpath_sql; fpath_sql=$(eagle_sql_escape "$fpath")
            eagle_db "DELETE FROM code_chunks WHERE project = '$project' AND file_path = '$fpath_sql';"
            removed=$((removed + 1))
        fi
    done <<< "$paths"
    echo "$removed"
}
