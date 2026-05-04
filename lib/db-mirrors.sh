#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Agent memory/plan/task mirror helpers
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_MIRRORS_LOADED:-}" ] && return 0
_EAGLE_DB_MIRRORS_LOADED=1

eagle_capture_agent_memory() {
    local file_path="$1"
    local session_id="${2:-}"
    local project="${3:-}"
    local agent="${4:-$(eagle_agent_source)}"

    [ ! -f "$file_path" ] && return 0

    local chash
    chash=$(shasum -a 256 "$file_path" | awk '{print $1}')

    local fm body
    fm=$(awk '/^---$/{c++; next} c==1' "$file_path")
    body=$(awk '/^---$/{c++; next} c>=2' "$file_path")
    if [ -z "$body" ] && [ -z "$fm" ]; then
        body=$(cat "$file_path")
    fi

    _fm_field() { awk -F': *' -v k="$1" '$1==k{sub(/^[^:]+: */,""); gsub(/^"|"$/,""); print; exit}' <<< "$fm"; }

    local mname mdesc mtype morigin
    mname=$(_fm_field "name")
    mdesc=$(_fm_field "description")
    mtype=$(_fm_field "type")
    morigin=$(_fm_field "originSessionId")
    [ -z "$morigin" ] && morigin="$session_id"

    if [ -z "$mname" ]; then
        case "$(basename "$file_path")" in
            MEMORY.md) mname="Codex Memory Registry" ;;
            memory_summary.md) mname="Codex Memory Summary" ;;
            *) mname=$(basename "$file_path" .md) ;;
        esac
    fi
    [ -z "$mtype" ] && mtype="$agent"
    if [ -z "$mdesc" ]; then
        mdesc=$(awk '
            /^[[:space:]]*$/ { next }
            {
                line = substr($0, 1, 200)
                print line
                exit
            }
        ' <<< "$body")
    fi

    local fp_sql proj_sql name_sql desc_sql type_sql content_sql hash_sql origin_sql agent_sql
    fp_sql=$(eagle_sql_escape "$file_path")
    proj_sql=$(eagle_sql_escape "$project")
    name_sql=$(eagle_sql_escape "$mname")
    desc_sql=$(eagle_sql_escape "$mdesc")
    type_sql=$(eagle_sql_escape "$mtype")
    content_sql=$(eagle_sql_escape "$body")
    hash_sql=$(eagle_sql_escape "$chash")
    origin_sql=$(eagle_sql_escape "$morigin")
    agent_sql=$(eagle_sql_escape "$agent")

    eagle_db_pipe <<SQL
INSERT OR IGNORE INTO agent_memories (project, file_path, memory_name, description, memory_type, content, content_hash, origin_session_id, origin_agent)
VALUES ('$proj_sql', '$fp_sql', '$name_sql', '$desc_sql', '$type_sql', '$content_sql', '$hash_sql', '$origin_sql', '$agent_sql');

UPDATE agent_memories
SET memory_name       = '$name_sql',
    description       = '$desc_sql',
    memory_type       = '$type_sql',
    content           = '$content_sql',
    content_hash      = '$hash_sql',
    origin_session_id = COALESCE(NULLIF('$origin_sql', ''), origin_session_id),
    origin_agent      = COALESCE(NULLIF('$agent_sql', ''), origin_agent),
    project           = CASE WHEN '$proj_sql' != '' THEN '$proj_sql' ELSE project END,
    updated_at        = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE file_path = '$fp_sql'
  AND content_hash != '$hash_sql';

UPDATE agent_memories
SET origin_session_id = COALESCE(NULLIF('$origin_sql', ''), origin_session_id),
    origin_agent      = COALESCE(NULLIF('$agent_sql', ''), origin_agent),
    project           = CASE WHEN '$proj_sql' != '' THEN '$proj_sql' ELSE project END,
    updated_at        = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE file_path = '$fp_sql'
  AND content_hash = '$hash_sql'
  AND (('$proj_sql' != '' AND project != '$proj_sql')
       OR ('$origin_sql' != '' AND origin_session_id != '$origin_sql')
       OR ('$agent_sql' != '' AND origin_agent != '$agent_sql'));
SQL
}

eagle_search_agent_memories() {
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
                     m.file_path, m.updated_at, m.origin_agent
              FROM agent_memories m
              JOIN agent_memories_fts f ON f.rowid = m.id
              WHERE agent_memories_fts MATCH '$query'
              $where_clause
              ORDER BY rank
              LIMIT $limit;"
}

eagle_list_agent_memories() {
    local project="${1:-}"
    local limit; limit=$(eagle_sql_int "${2:-20}")

    local where_clause=""
    if [ -n "$project" ]; then
        project=$(eagle_sql_escape "$project")
        where_clause="WHERE project = '$project'"
    fi

    eagle_db "SELECT memory_name, memory_type, description, file_path, updated_at, origin_agent
              FROM agent_memories
              $where_clause
              ORDER BY updated_at DESC
              LIMIT $limit;"
}

eagle_capture_agent_plan() {
    local file_path="$1"
    local session_id="${2:-}"
    local project="${3:-}"
    local agent="${4:-$(eagle_agent_source)}"

    [ ! -f "$file_path" ] && return 0

    local chash
    chash=$(shasum -a 256 "$file_path" | awk '{print $1}')

    local title content
    title=$(awk '/^# /{print; exit}' "$file_path" | sed 's/^# //')
    content=$(cat "$file_path")

    local fp_sql proj_sql title_sql content_sql hash_sql origin_sql agent_sql
    fp_sql=$(eagle_sql_escape "$file_path")
    proj_sql=$(eagle_sql_escape "$project")
    title_sql=$(eagle_sql_escape "$title")
    content_sql=$(eagle_sql_escape "$content")
    hash_sql=$(eagle_sql_escape "$chash")
    origin_sql=$(eagle_sql_escape "$session_id")
    agent_sql=$(eagle_sql_escape "$agent")

    eagle_db_pipe <<SQL
INSERT OR IGNORE INTO agent_plans (project, file_path, title, content, content_hash, origin_session_id, origin_agent)
VALUES ('$proj_sql', '$fp_sql', '$title_sql', '$content_sql', '$hash_sql', '$origin_sql', '$agent_sql');

UPDATE agent_plans
SET title             = '$title_sql',
    content           = '$content_sql',
    content_hash      = '$hash_sql',
    origin_session_id = COALESCE(NULLIF('$origin_sql', ''), origin_session_id),
    origin_agent      = COALESCE(NULLIF('$agent_sql', ''), origin_agent),
    project           = CASE WHEN '$proj_sql' != '' THEN '$proj_sql' ELSE project END,
    updated_at        = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE file_path = '$fp_sql'
  AND content_hash != '$hash_sql';

UPDATE agent_plans
SET origin_session_id = COALESCE(NULLIF('$origin_sql', ''), origin_session_id),
    origin_agent      = COALESCE(NULLIF('$agent_sql', ''), origin_agent),
    project           = CASE WHEN '$proj_sql' != '' THEN '$proj_sql' ELSE project END,
    updated_at        = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE file_path = '$fp_sql'
  AND content_hash = '$hash_sql'
  AND (('$proj_sql' != '' AND project != '$proj_sql')
       OR ('$origin_sql' != '' AND origin_session_id != '$origin_sql')
       OR ('$agent_sql' != '' AND origin_agent != '$agent_sql'));
SQL
}

eagle_search_agent_plans() {
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
                     p.file_path, p.updated_at, p.origin_agent
              FROM agent_plans p
              JOIN agent_plans_fts f ON f.rowid = p.id
              WHERE agent_plans_fts MATCH '$query'
              $where_clause
              ORDER BY rank
              LIMIT $limit;"
}

eagle_list_agent_plans() {
    local project="${1:-}"
    local limit; limit=$(eagle_sql_int "${2:-20}")

    local where_clause=""
    if [ -n "$project" ]; then
        project=$(eagle_sql_escape "$project")
        where_clause="WHERE project = '$project'"
    fi

    eagle_db "SELECT title, project, file_path, updated_at, origin_agent
              FROM agent_plans
              $where_clause
              ORDER BY updated_at DESC
              LIMIT $limit;"
}

eagle_capture_agent_task() {
    local file_path="$1"
    local session_id="${2:-}"
    local project="${3:-}"
    local agent="${4:-$(eagle_agent_source)}"

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

    local fp_sql proj_sql sid_sql tid_sql subj_sql desc_sql af_sql status_sql blocks_sql bb_sql hash_sql agent_sql
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
    agent_sql=$(eagle_sql_escape "$agent")

    eagle_db_pipe <<SQL
INSERT OR IGNORE INTO agent_tasks (project, source_session_id, source_task_id, file_path, subject, description, active_form, status, blocks, blocked_by, content_hash, origin_agent)
VALUES ('$proj_sql', '$sid_sql', '$tid_sql', '$fp_sql', '$subj_sql', '$desc_sql', '$af_sql', '$status_sql', '$blocks_sql', '$bb_sql', '$hash_sql', '$agent_sql');

UPDATE agent_tasks
SET subject       = '$subj_sql',
    description   = '$desc_sql',
    active_form   = '$af_sql',
    status        = '$status_sql',
    blocks        = '$blocks_sql',
    blocked_by    = '$bb_sql',
    content_hash  = '$hash_sql',
    origin_agent  = COALESCE(NULLIF('$agent_sql', ''), origin_agent),
    project       = CASE WHEN '$proj_sql' != '' THEN '$proj_sql' ELSE project END,
    updated_at    = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE file_path = '$fp_sql'
  AND content_hash != '$hash_sql';

UPDATE agent_tasks
SET origin_agent  = COALESCE(NULLIF('$agent_sql', ''), origin_agent),
    project       = CASE WHEN '$proj_sql' != '' THEN '$proj_sql' ELSE project END,
    updated_at    = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE file_path = '$fp_sql'
  AND content_hash = '$hash_sql'
  AND (('$proj_sql' != '' AND project != '$proj_sql')
       OR ('$agent_sql' != '' AND origin_agent != '$agent_sql'));
SQL
}

eagle_list_agent_tasks() {
    local project="${1:-}"
    local limit; limit=$(eagle_sql_int "${2:-20}")

    local where_clause=""
    if [ -n "$project" ]; then
        project=$(eagle_sql_escape "$project")
        where_clause="WHERE project = '$project'"
    fi

    eagle_db "SELECT subject, status, source_session_id, source_task_id, updated_at, origin_agent
              FROM agent_tasks
              $where_clause
              ORDER BY updated_at DESC
              LIMIT $limit;"
}

eagle_search_agent_tasks() {
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
                     t.source_session_id, t.source_task_id, t.updated_at, t.origin_agent
              FROM agent_tasks t
              JOIN agent_tasks_fts f ON f.rowid = t.id
              WHERE agent_tasks_fts MATCH '$query'
              $where_clause
              ORDER BY rank
              LIMIT $limit;"
}

# Backward-compatible helper names for older installed hooks/scripts that source
# this library during an update window. Runtime code should use agent_* helpers.
eagle_capture_claude_memory() { eagle_capture_agent_memory "$@"; }
eagle_search_claude_memories() { eagle_search_agent_memories "$@"; }
eagle_list_claude_memories() { eagle_list_agent_memories "$@"; }
eagle_capture_claude_plan() { eagle_capture_agent_plan "$@"; }
eagle_search_claude_plans() { eagle_search_agent_plans "$@"; }
eagle_list_claude_plans() { eagle_list_agent_plans "$@"; }
eagle_capture_claude_task() { eagle_capture_agent_task "$@"; }
eagle_list_claude_tasks() { eagle_list_agent_tasks "$@"; }
eagle_search_claude_tasks() { eagle_search_agent_tasks "$@"; }
