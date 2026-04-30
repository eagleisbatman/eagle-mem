#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Claude Code memory/plan/task mirror helpers
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_MIRRORS_LOADED:-}" ] && return 0
_EAGLE_DB_MIRRORS_LOADED=1

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
    if [ -z "$query" ]; then
        echo "Search query is empty after sanitization. Try a different search term." >&2
        return 1
    fi
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
    if [ -z "$query" ]; then
        echo "Search query is empty after sanitization. Try a different search term." >&2
        return 1
    fi
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
    if [ -z "$query" ]; then
        echo "Search query is empty after sanitization. Try a different search term." >&2
        return 1
    fi
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
