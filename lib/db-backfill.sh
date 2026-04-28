#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Backfill + orphan cleanup helpers
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_BACKFILL_LOADED:-}" ] && return 0
_EAGLE_DB_BACKFILL_LOADED=1

eagle_build_session_project_map() {
    local claude_projects_dir="$EAGLE_CLAUDE_PROJECTS_DIR"
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
