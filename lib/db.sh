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
