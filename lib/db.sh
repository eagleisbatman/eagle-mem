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
    { echo "$EAGLE_DB_SETUP"; echo "$*"; } | sqlite3 "$EAGLE_MEM_DB" 2>>"$EAGLE_MEM_LOG"
}

eagle_db_pipe() {
    { echo "$EAGLE_DB_SETUP"; echo ".bail on"; cat; } | sqlite3 "$EAGLE_MEM_DB" 2>>"$EAGLE_MEM_LOG"
}

eagle_db_json() {
    { echo "$EAGLE_DB_SETUP"; echo ".mode json"; echo "$*"; } | sqlite3 "$EAGLE_MEM_DB" 2>>"$EAGLE_MEM_LOG"
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

    eagle_db "INSERT INTO sessions (id, project, cwd, model, source, last_activity_at)
              VALUES ('$session_id', '$project', '$cwd', '$model', '$source', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
              ON CONFLICT(id) DO UPDATE SET
                  cwd = COALESCE(excluded.cwd, sessions.cwd),
                  model = COALESCE(excluded.model, sessions.model),
                  source = COALESCE(excluded.source, sessions.source),
                  status = 'active',
                  last_activity_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"
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
              SELECT '$session_id', '$project', '$tool_name', '$tool_input_summary', '$files_read', '$files_modified'
              WHERE NOT EXISTS (
                  SELECT 1 FROM observations
                  WHERE session_id = '$session_id'
                  AND tool_name = '$tool_name'
                  AND tool_input_summary = '$tool_input_summary'
                  AND created_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-5 seconds')
              );"
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
    local decisions; decisions=$(eagle_sql_escape "${11:-}")
    local gotchas; gotchas=$(eagle_sql_escape "${12:-}")
    local key_files; key_files=$(eagle_sql_escape "${13:-}")

    eagle_db_pipe <<SQL
INSERT INTO summaries (session_id, project, request, investigated, learned, completed, next_steps, files_read, files_modified, notes, decisions, gotchas, key_files)
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
    '$notes',
    '$decisions',
    '$gotchas',
    '$key_files'
)
ON CONFLICT(session_id) DO UPDATE SET
    project        = excluded.project,
    request        = COALESCE(NULLIF(excluded.request, ''), summaries.request),
    investigated   = COALESCE(NULLIF(excluded.investigated, ''), summaries.investigated),
    learned        = COALESCE(NULLIF(excluded.learned, ''), summaries.learned),
    completed      = COALESCE(NULLIF(excluded.completed, ''), summaries.completed),
    next_steps     = COALESCE(NULLIF(excluded.next_steps, ''), summaries.next_steps),
    files_read     = COALESCE(NULLIF(excluded.files_read, '[]'), summaries.files_read),
    files_modified = COALESCE(NULLIF(excluded.files_modified, '[]'), summaries.files_modified),
    notes          = COALESCE(NULLIF(excluded.notes, ''), summaries.notes),
    decisions      = COALESCE(NULLIF(excluded.decisions, ''), summaries.decisions),
    gotchas        = COALESCE(NULLIF(excluded.gotchas, ''), summaries.gotchas),
    key_files      = COALESCE(NULLIF(excluded.key_files, ''), summaries.key_files);
SQL
}

eagle_get_recent_summaries() {
    local project; project=$(eagle_sql_escape "$1")
    local limit; limit=$(eagle_sql_int "${2:-5}")

    eagle_db "SELECT s.request, s.completed, s.learned, s.next_steps, s.created_at, s.decisions, s.gotchas, s.key_files
              FROM summaries s
              WHERE s.project = '$project'
              AND s.request NOT LIKE '%<local-command-caveat>%'
              ORDER BY s.created_at DESC
              LIMIT $limit;"
}

eagle_search_summaries() {
    local query; query=$(eagle_fts_sanitize "$1")
    query=$(eagle_sql_escape "$query")
    local project="${2:-}"
    local limit; limit=$(eagle_sql_int "${3:-10}")

    local where_clause=""
    if [ -n "$project" ]; then
        project=$(eagle_sql_escape "$project")
        where_clause="AND s.project = '$project'"
    fi

    eagle_db "SELECT s.request, s.completed, s.learned, s.next_steps, s.created_at, s.project, s.decisions, s.gotchas, s.key_files
              FROM summaries s
              JOIN summaries_fts f ON f.rowid = s.id
              WHERE summaries_fts MATCH '$query'
              $where_clause
              ORDER BY rank
              LIMIT $limit;"
}

eagle_upsert_overview() {
    local project; project=$(eagle_sql_escape "$1")
    local raw_content="$2"
    local ov_source; ov_source=$(eagle_sql_escape "${3:-manual}")

    if [ ${#raw_content} -gt 16384 ]; then
        raw_content="${raw_content:0:16384}"
        eagle_log "WARN" "Overview for '$1' truncated to 16 KB (was ${#2} bytes)"
    fi

    local content; content=$(eagle_sql_escape "$raw_content")

    eagle_db "INSERT INTO overviews (project, content, source, updated_at)
              VALUES ('$project', '$content', '$ov_source', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
              ON CONFLICT(project) DO UPDATE SET
                  content = excluded.content,
                  source = excluded.source,
                  updated_at = excluded.updated_at;"
}

eagle_get_overview_source() {
    local project; project=$(eagle_sql_escape "$1")
    eagle_db "SELECT source FROM overviews WHERE project = '$project';"
}

eagle_get_overview() {
    local project; project=$(eagle_sql_escape "$1")

    eagle_db "SELECT content FROM overviews WHERE project = '$project';"
}

eagle_search_code_chunks() {
    local query; query=$(eagle_fts_sanitize "$1")
    query=$(eagle_sql_escape "$query")
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

eagle_build_session_project_map() {
    local claude_projects_dir="$HOME/.claude/projects"
    [ ! -d "$claude_projects_dir" ] && return 0

    for proj_dir in "$claude_projects_dir"/*/; do
        [ ! -d "$proj_dir" ] && continue

        local project=""
        local sample_jsonl
        sample_jsonl=$(ls "$proj_dir"*.jsonl 2>/dev/null | head -1)
        if [ -n "$sample_jsonl" ] && [ -f "$sample_jsonl" ]; then
            local cwd
            cwd=$(head -10 "$sample_jsonl" | jq -r 'select(.cwd != null) | .cwd' 2>/dev/null | head -1)
            if [ -n "$cwd" ]; then
                project=$(eagle_project_from_cwd "$cwd")
            fi
        fi
        [ -z "$project" ] && continue

        for jsonl in "$proj_dir"*.jsonl; do
            [ ! -f "$jsonl" ] && continue
            local sid
            sid=$(basename "$jsonl" .jsonl)
            echo "$sid|$project"
        done
    done
}

eagle_backfill_projects() {
    local updated=0
    local map
    map=$(eagle_build_session_project_map)
    [ -z "$map" ] && echo "0" && return 0

    while IFS='|' read -r sid project; do
        [ -z "$sid" ] || [ -z "$project" ] && continue
        local sid_sql proj_sql
        sid_sql=$(eagle_sql_escape "$sid")
        proj_sql=$(eagle_sql_escape "$project")

        # All six tables updated atomically per session to prevent
        # partial backfill if the process is interrupted.
        # Note: total_changes() includes FTS trigger changes, so the
        # reported count may be higher than actual rows updated.
        # This is cosmetic — the count is only used for status messages.
        local ch
        ch=$(eagle_db_pipe <<SQL
BEGIN;
UPDATE sessions SET project = '$proj_sql' WHERE id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
UPDATE claude_tasks SET project = '$proj_sql' WHERE source_session_id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
UPDATE claude_memories SET project = '$proj_sql' WHERE origin_session_id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
UPDATE claude_plans SET project = '$proj_sql' WHERE origin_session_id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
UPDATE summaries SET project = '$proj_sql' WHERE session_id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
UPDATE observations SET project = '$proj_sql' WHERE session_id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
SELECT total_changes();
COMMIT;
SQL
)
        [ "${ch:-0}" -gt 0 ] && updated=$((updated + ch))
    done <<< "$map"

    echo "$updated"
}

eagle_prune_orphan_chunks() {
    local project; project=$(eagle_sql_escape "$1")
    local target_dir="$2"

    # Get all indexed file paths for this project
    local paths
    paths=$(eagle_db "SELECT DISTINCT file_path FROM code_chunks WHERE project = '$project';")

    local removed=0
    local txn_sql="BEGIN;"
    while IFS= read -r fpath; do
        [ -z "$fpath" ] && continue
        if [ ! -f "$target_dir/$fpath" ]; then
            local fpath_sql; fpath_sql=$(eagle_sql_escape "$fpath")
            txn_sql+="
DELETE FROM code_chunks WHERE project = '$project' AND file_path = '$fpath_sql';"
            removed=$((removed + 1))
        fi
    done <<< "$paths"
    txn_sql+="
COMMIT;"

    if [ "$removed" -gt 0 ]; then
        eagle_db_pipe <<< "$txn_sql"
    fi
    echo "$removed"
}

# ─── Feature graph helpers ─────��───────────────────────────

eagle_upsert_feature() {
    local project; project=$(eagle_sql_escape "$1")
    local name; name=$(eagle_sql_escape "$2")
    local description; description=$(eagle_sql_escape "${3:-}")

    eagle_db "INSERT INTO features (project, name, description)
        VALUES ('$project', '$name', '$description')
        ON CONFLICT(project, name) DO UPDATE SET
            description = COALESCE(NULLIF('$description', ''), features.description),
            updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"
}

eagle_add_feature_dependency() {
    local feature_id; feature_id=$(eagle_sql_int "$1")
    local kind; kind=$(eagle_sql_escape "$2")
    local target; target=$(eagle_sql_escape "$3")
    local name; name=$(eagle_sql_escape "$4")
    local notes; notes=$(eagle_sql_escape "${5:-}")

    eagle_db "INSERT OR IGNORE INTO feature_dependencies (feature_id, kind, target, name, notes)
        VALUES ($feature_id, '$kind', '$target', '$name', '$notes');"
}

eagle_add_feature_file() {
    local feature_id; feature_id=$(eagle_sql_int "$1")
    local file_path; file_path=$(eagle_sql_escape "$2")
    local role; role=$(eagle_sql_escape "${3:-}")

    eagle_db "INSERT OR IGNORE INTO feature_files (feature_id, file_path, role)
        VALUES ($feature_id, '$file_path', '$role');"
}

eagle_add_feature_smoke_test() {
    local feature_id; feature_id=$(eagle_sql_int "$1")
    local command; command=$(eagle_sql_escape "$2")
    local description; description=$(eagle_sql_escape "${3:-}")

    eagle_db "INSERT INTO feature_smoke_tests (feature_id, command, description)
        VALUES ($feature_id, '$command', '$description');"
}

eagle_verify_feature() {
    local project; project=$(eagle_sql_escape "$1")
    local name; name=$(eagle_sql_escape "$2")
    local notes; notes=$(eagle_sql_escape "${3:-}")

    eagle_db "UPDATE features SET
        last_verified_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
        last_verified_notes = '$notes',
        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
        WHERE project = '$project' AND name = '$name';"
}

eagle_get_feature_id() {
    local project; project=$(eagle_sql_escape "$1")
    local name; name=$(eagle_sql_escape "$2")
    eagle_db "SELECT id FROM features WHERE project = '$project' AND name = '$name';"
}

eagle_list_features() {
    local project; project=$(eagle_sql_escape "$1")
    local limit; limit=$(eagle_sql_int "${2:-20}")

    eagle_db "SELECT f.name, f.description, f.status, f.last_verified_at,
        (SELECT COUNT(*) FROM feature_dependencies WHERE feature_id = f.id) as dep_count,
        (SELECT COUNT(*) FROM feature_files WHERE feature_id = f.id) as file_count,
        (SELECT COUNT(*) FROM feature_smoke_tests WHERE feature_id = f.id) as test_count
        FROM features f
        WHERE f.project = '$project' AND f.status = 'active'
        ORDER BY f.updated_at DESC
        LIMIT $limit;"
}

eagle_show_feature() {
    local project; project=$(eagle_sql_escape "$1")
    local name; name=$(eagle_sql_escape "$2")

    local feature_id
    feature_id=$(eagle_get_feature_id "$1" "$2")
    [ -z "$feature_id" ] && return 1

    echo "=== Feature: $2 ==="
    eagle_db "SELECT name, description, status, last_verified_at, last_verified_notes
        FROM features WHERE id = $feature_id;"

    local deps
    deps=$(eagle_db "SELECT kind, target, name, notes FROM feature_dependencies WHERE feature_id = $feature_id;")
    if [ -n "$deps" ]; then
        echo "--- Dependencies ---"
        echo "$deps"
    fi

    local files
    files=$(eagle_db "SELECT file_path, role FROM feature_files WHERE feature_id = $feature_id;")
    if [ -n "$files" ]; then
        echo "--- Files ---"
        echo "$files"
    fi

    local tests
    tests=$(eagle_db "SELECT command, description FROM feature_smoke_tests WHERE feature_id = $feature_id;")
    if [ -n "$tests" ]; then
        echo "--- Smoke Tests ---"
        echo "$tests"
    fi
}

eagle_find_features_for_file() {
    local project; project=$(eagle_sql_escape "$1")
    local file_path="$2"
    local fname; fname=$(basename "$file_path")
    local fname_esc; fname_esc=$(eagle_sql_escape "$fname")

    eagle_db "SELECT f.name, f.description, f.last_verified_at,
        ff.role,
        (SELECT GROUP_CONCAT(fd.target || ':' || fd.name, ', ')
         FROM feature_dependencies fd WHERE fd.feature_id = f.id) as deps,
        (SELECT GROUP_CONCAT(ff2.file_path, ', ')
         FROM feature_files ff2 WHERE ff2.feature_id = f.id AND ff2.file_path != ff.file_path) as other_files,
        (SELECT GROUP_CONCAT(fst.command, ', ')
         FROM feature_smoke_tests fst WHERE fst.feature_id = f.id) as smoke_tests
        FROM features f
        JOIN feature_files ff ON ff.feature_id = f.id
        WHERE f.project = '$project'
        AND f.status = 'active'
        AND (ff.file_path LIKE '%$fname_esc' OR ff.file_path LIKE '%$fname_esc%')
        ORDER BY f.updated_at DESC
        LIMIT 3;"
}
