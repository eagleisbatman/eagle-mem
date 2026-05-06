#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Summary + overview helpers
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_SUMMARIES_LOADED:-}" ] && return 0
_EAGLE_DB_SUMMARIES_LOADED=1

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
    local agent; agent=$(eagle_sql_escape "${14:-$(eagle_agent_source)}")

    eagle_db_pipe <<SQL
INSERT INTO summaries (session_id, project, agent, request, investigated, learned, completed, next_steps, files_read, files_modified, notes, decisions, gotchas, key_files)
VALUES (
    '$session_id',
    '$project',
    '$agent',
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
    agent          = COALESCE(NULLIF(excluded.agent, ''), summaries.agent),
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
    local project_scope="${1:-}"
    local limit; limit=$(eagle_sql_int "${2:-5}")
    local project_filter="1 = 1"
    if [ -n "$project_scope" ]; then
        project_filter=$(eagle_sql_project_scope_condition "s.project" "$project_scope")
    fi

    eagle_db "SELECT s.request, s.completed, s.learned, s.next_steps, s.created_at, s.decisions, s.gotchas, s.key_files, s.agent
              FROM summaries s
              WHERE $project_filter
              AND COALESCE(s.request, '') NOT LIKE '%<local-command-caveat>%'
              AND COALESCE(s.request, '') NOT LIKE '# AGENTS.md instructions%'
              AND COALESCE(s.request, '') NOT LIKE '<environment_context>%'
              ORDER BY s.created_at DESC
              LIMIT $limit;"
}

eagle_search_summaries() {
    local query; query=$(eagle_fts_sanitize "$1")
    query=$(eagle_sql_escape "$query")
    local project_scope="${2:-}"
    local limit; limit=$(eagle_sql_int "${3:-10}")

    local where_clause=""
    if [ -n "$project_scope" ]; then
        where_clause="AND $(eagle_sql_project_scope_condition "s.project" "$project_scope")"
    fi

    eagle_db "SELECT s.request, s.completed, s.learned, s.next_steps, s.created_at, s.project, s.decisions, s.gotchas, s.key_files, s.agent
              FROM summaries s
              JOIN summaries_fts f ON f.rowid = s.id
              WHERE summaries_fts MATCH '$query'
              AND COALESCE(s.request, '') NOT LIKE '%<local-command-caveat>%'
              AND COALESCE(s.request, '') NOT LIKE '# AGENTS.md instructions%'
              AND COALESCE(s.request, '') NOT LIKE '<environment_context>%'
              AND COALESCE(s.request, '') NOT LIKE '<subagent_notification>%'
              AND COALESCE(s.request, '') NOT LIKE '</subagent_notification>%'
              $where_clause
              ORDER BY
                CASE
                  WHEN julianday('now') - julianday(s.created_at) <= 14 THEN 0
                  WHEN julianday('now') - julianday(s.created_at) <= 45 THEN 1
                  ELSE 2
                END,
                s.created_at DESC,
                rank
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

eagle_search_decisions_for_file() {
    local project; project=$(eagle_sql_escape "$1")
    local fts_query; fts_query=$(eagle_sql_escape "$2")
    eagle_db "SELECT s.decisions
        FROM summaries s
        JOIN summaries_fts f ON f.rowid = s.id
        WHERE summaries_fts MATCH '$fts_query'
        AND s.project = '$project'
        AND s.decisions IS NOT NULL
        AND s.decisions != ''
        ORDER BY s.created_at DESC
        LIMIT 1;"
}

eagle_last_session_enriched() {
    local project; project=$(eagle_sql_escape "$1")
    eagle_db "SELECT CASE
        WHEN (decisions IS NOT NULL AND decisions != '')
          OR (gotchas IS NOT NULL AND gotchas != '')
          OR (key_files IS NOT NULL AND key_files != '')
        THEN 1 ELSE 0 END
        FROM summaries WHERE project = '$project'
        ORDER BY created_at DESC LIMIT 1;"
}

eagle_search_gotchas_for_file() {
    local project; project=$(eagle_sql_escape "$1")
    local fts_query; fts_query=$(eagle_sql_escape "$2")
    eagle_db "SELECT s.gotchas
        FROM summaries s
        JOIN summaries_fts f ON f.rowid = s.id
        WHERE summaries_fts MATCH '$fts_query'
        AND s.project = '$project'
        AND s.gotchas IS NOT NULL
        AND s.gotchas != ''
        ORDER BY s.created_at DESC
        LIMIT 2;"
}

eagle_search_stale_memories() {
    local project; project=$(eagle_sql_escape "$1")
    local fts_query; fts_query=$(eagle_sql_escape "$2")
    eagle_db "SELECT m.memory_name
        FROM agent_memories m
        JOIN agent_memories_fts f ON f.rowid = m.id
        WHERE agent_memories_fts MATCH '$fts_query'
        AND m.project = '$project'
        LIMIT 1;"
}
