#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Guardrails helpers
# Persistent per-project rules surfaced at Edit/Write time
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_GUARDRAILS_LOADED:-}" ] && return 0
_EAGLE_DB_GUARDRAILS_LOADED=1

eagle_add_guardrail() {
    local raw_rule="$2"
    # Cap rule length to 2048 chars to prevent unbounded storage
    if [ ${#raw_rule} -gt 2048 ]; then
        raw_rule="${raw_rule:0:2048}"
    fi

    local project; project=$(eagle_sql_escape "$1")
    local rule; rule=$(eagle_sql_escape "$raw_rule")
    local file_pattern="${3:-}"
    local source; source=$(eagle_sql_escape "${4:-manual}")

    file_pattern=$(eagle_sql_escape "$file_pattern")
    eagle_db "INSERT INTO guardrails (project, file_pattern, rule, source)
        VALUES ('$project', '$file_pattern', '$rule', '$source')
        ON CONFLICT(project, source, file_pattern, rule) DO UPDATE SET
            updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"
}

eagle_get_guardrails_for_file() {
    local project; project=$(eagle_sql_escape "$1")
    local filename; filename=$(eagle_sql_escape "$2")

    eagle_db "SELECT rule FROM guardrails
        WHERE project = '$project'
        AND active = 1
        AND (
            file_pattern = ''
            OR '$filename' GLOB file_pattern
            OR file_pattern = '$filename'
        )
        ORDER BY file_pattern = '', created_at DESC
        LIMIT 3;"
}

eagle_get_edit_context() {
    local project; project=$(eagle_sql_escape "$1")
    local filename; filename=$(eagle_sql_escape "$2")
    local fts_query; fts_query=$(eagle_sql_escape "$3")

    # Batched query: guardrails + decisions + gotchas in one sqlite3 call.
    # Results tagged with TYPE: prefix for caller to parse.
    eagle_db_pipe <<SQL
SELECT 'GR:' || rule FROM guardrails
    WHERE project = '$project'
    AND active = 1
    AND (
        file_pattern = ''
        OR '$filename' GLOB file_pattern
        OR file_pattern = '$filename'
    )
    ORDER BY file_pattern = '', created_at DESC
    LIMIT 3;
SELECT 'DEC:' || s.decisions
    FROM summaries s
    JOIN summaries_fts f ON f.rowid = s.id
    WHERE summaries_fts MATCH '$fts_query'
    AND s.project = '$project'
    AND s.decisions IS NOT NULL AND s.decisions != ''
    ORDER BY s.created_at DESC LIMIT 1;
SELECT 'GOT:' || s.gotchas
    FROM summaries s
    JOIN summaries_fts f ON f.rowid = s.id
    WHERE summaries_fts MATCH '$fts_query'
    AND s.project = '$project'
    AND s.gotchas IS NOT NULL AND s.gotchas != ''
    ORDER BY s.created_at DESC LIMIT 2;
SQL
}

eagle_list_guardrails() {
    local project; project=$(eagle_sql_escape "$1")

    eagle_db "SELECT id, file_pattern, rule, source, active, created_at
        FROM guardrails
        WHERE project = '$project'
        ORDER BY active DESC, created_at DESC;"
}

eagle_remove_guardrail() {
    local id; id=$(eagle_sql_int "$1")

    eagle_db "DELETE FROM guardrails WHERE id = $id;"
}

eagle_has_any_guardrails() {
    local project; project=$(eagle_sql_escape "$1")
    eagle_db "SELECT 1 FROM guardrails
        WHERE project = '$project' AND active = 1
        LIMIT 1;"
}

eagle_deactivate_guardrail() {
    local id; id=$(eagle_sql_int "$1")

    eagle_db "UPDATE guardrails SET active = 0,
        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
        WHERE id = $id;"
}
