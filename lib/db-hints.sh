#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — File hint helpers (learned patterns from curator)
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_HINTS_LOADED:-}" ] && return 0
_EAGLE_DB_HINTS_LOADED=1

eagle_upsert_file_hint() {
    local project; project=$(eagle_sql_escape "$1")
    local hint_type; hint_type=$(eagle_sql_escape "$2")
    local file_path; file_path=$(eagle_sql_escape "$3")
    local hint_value; hint_value=$(eagle_sql_escape "$4")

    eagle_db "INSERT INTO file_hints (project, hint_type, file_path, hint_value)
        VALUES ('$project', '$hint_type', '$file_path', '$hint_value')
        ON CONFLICT(project, hint_type, file_path) DO UPDATE SET
            hint_value = excluded.hint_value,
            updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"
}

eagle_get_co_edits() {
    local project; project=$(eagle_sql_escape "$1")
    local file_path; file_path=$(eagle_sql_escape "$2")

    eagle_db "SELECT hint_value FROM file_hints
        WHERE project = '$project'
        AND hint_type = 'co_edit'
        AND file_path = '$file_path'
        LIMIT 1;"
}

eagle_get_hot_files() {
    local project; project=$(eagle_sql_escape "$1")

    eagle_db "SELECT hint_value FROM file_hints
        WHERE project = '$project'
        AND hint_type = 'hot_file'
        AND file_path = ''
        LIMIT 1;"
}

eagle_get_working_set() {
    local session_id; session_id=$(eagle_sql_escape "$1")

    eagle_db "SELECT
        CASE tool_name
            WHEN 'Edit' THEN SUBSTR(tool_input_summary, 6)
            WHEN 'Write' THEN SUBSTR(tool_input_summary, 7)
        END as file_path,
        COUNT(*) as edits
    FROM observations
    WHERE session_id = '$session_id'
    AND tool_name IN ('Edit', 'Write')
    AND tool_input_summary IS NOT NULL
    GROUP BY file_path
    ORDER BY MAX(created_at) DESC
    LIMIT 10;"
}

eagle_delete_file_hints() {
    local project; project=$(eagle_sql_escape "$1")
    local hint_type; hint_type=$(eagle_sql_escape "$2")

    eagle_db "DELETE FROM file_hints
        WHERE project = '$project'
        AND hint_type = '$hint_type';"
}
