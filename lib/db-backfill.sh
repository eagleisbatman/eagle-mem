#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Backfill + orphan cleanup helpers
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_BACKFILL_LOADED:-}" ] && return 0
_EAGLE_DB_BACKFILL_LOADED=1

eagle_build_session_project_map() {
    local session_filter_file="${1:-}"
    local claude_projects_dir="$EAGLE_CLAUDE_PROJECTS_DIR"
    [ ! -d "$claude_projects_dir" ] && return 0

    if [ -n "$session_filter_file" ] && [ -s "$session_filter_file" ]; then
        local transcript_index project_cache
        transcript_index=$(mktemp)
        project_cache=$(mktemp)
        find "$claude_projects_dir" -mindepth 2 -maxdepth 2 -name "*.jsonl" -print > "$transcript_index" 2>/dev/null || true

        local sid jsonl proj_dir project cached
        while IFS= read -r sid; do
            [ -z "$sid" ] && continue
            jsonl=$(grep -m 1 "/$sid.jsonl\$" "$transcript_index" 2>/dev/null || true)
            [ -f "$jsonl" ] || continue

            proj_dir=$(dirname "$jsonl")
            cached=$(grep -m 1 "^$proj_dir|" "$project_cache" 2>/dev/null || true)
            if [ -n "$cached" ]; then
                project="${cached#*|}"
            else
                project=$(eagle_project_from_claude_project_dir "$proj_dir" 2>/dev/null || true)
                printf '%s|%s\n' "$proj_dir" "$project" >> "$project_cache"
            fi
            [ -n "$project" ] && echo "$sid|$project"
        done < "$session_filter_file"
        rm -f "$transcript_index" "$project_cache"
        return 0
    fi

    for proj_dir in "$claude_projects_dir"/*/; do
        [ ! -d "$proj_dir" ] && continue

        local project=""
        project=$(eagle_project_from_claude_project_dir "$proj_dir" 2>/dev/null || true)
        [ -z "$project" ] && continue

        for jsonl in "$proj_dir"*.jsonl; do
            [ ! -f "$jsonl" ] && continue
            local sid
            sid=$(basename "$jsonl" .jsonl)
            echo "$sid|$project"
        done
    done
}

eagle_build_claude_project_dir_map() {
    local claude_projects_dir="$EAGLE_CLAUDE_PROJECTS_DIR"
    [ ! -d "$claude_projects_dir" ] && return 0

    for proj_dir in "$claude_projects_dir"/*/; do
        [ ! -d "$proj_dir" ] && continue

        local project
        project=$(eagle_project_from_claude_project_dir "$proj_dir" 2>/dev/null || true)
        [ -z "$project" ] && continue

        printf '%s|%s\n' "${proj_dir%/}" "$project"
    done
}

eagle_backfill_projects() {
    local updated=0
    local session_filter_file map
    session_filter_file=$(mktemp)
    eagle_db "SELECT id FROM sessions;" > "$session_filter_file" 2>/dev/null || true
    map=$(eagle_build_session_project_map "$session_filter_file")

    # Phase 1: Build old→new project mapping BEFORE mutating any rows.
    # Collect from sessions table so non-session tables can be migrated.
    local rename_map_file
    rename_map_file=$(mktemp)
    if [ -n "$map" ]; then
        while IFS='|' read -r sid project; do
            [ -z "$sid" ] || [ -z "$project" ] && continue
            local sid_sql
            sid_sql=$(eagle_sql_escape "$sid")
            local old_project
            old_project=$(eagle_db "SELECT project FROM sessions WHERE id = '$sid_sql';")
            if [ -n "$old_project" ] && [ "$old_project" != "$project" ]; then
                echo "$old_project|$project" >> "$rename_map_file"
            fi
        done <<< "$map"
    fi

    # Phase 2: Update session-linked tables
    if [ -n "$map" ]; then
        while IFS='|' read -r sid project; do
            [ -z "$sid" ] || [ -z "$project" ] && continue
            local sid_sql proj_sql
            sid_sql=$(eagle_sql_escape "$sid")
            proj_sql=$(eagle_sql_escape "$project")

            local ch
            ch=$(eagle_db_pipe <<SQL
BEGIN;
UPDATE sessions SET project = '$proj_sql' WHERE id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
UPDATE agent_tasks SET project = '$proj_sql' WHERE source_session_id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
UPDATE agent_memories SET project = '$proj_sql' WHERE origin_session_id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
UPDATE agent_plans SET project = '$proj_sql' WHERE origin_session_id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
UPDATE summaries SET project = '$proj_sql' WHERE session_id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
UPDATE observations SET project = '$proj_sql' WHERE session_id = '$sid_sql' AND (project = '' OR project != '$proj_sql');
SELECT total_changes();
COMMIT;
SQL
)
            [ "${ch:-0}" -gt 0 ] && updated=$((updated + ch))
        done <<< "$map"
    fi

    # Phase 3: Repair Claude memory rows that have no session id but live under
    # a Claude project directory. These rows used to keep stale project keys
    # when their file content did not change.
    local dir_map
    dir_map=$(eagle_build_claude_project_dir_map)
    while IFS='|' read -r proj_dir project; do
        [ -z "$proj_dir" ] || [ -z "$project" ] && continue
        local proj_sql prefix_sql
        proj_sql=$(eagle_sql_escape "$project")
        prefix_sql=$(eagle_sql_escape "$proj_dir/memory/")

        local ch
        ch=$(eagle_db_pipe <<SQL
BEGIN;
UPDATE agent_memories
SET project = '$proj_sql'
WHERE file_path >= '$prefix_sql'
  AND file_path < ('$prefix_sql' || char(0x10ffff))
  AND (project = '' OR project != '$proj_sql');
SELECT total_changes();
COMMIT;
SQL
)
        [ "${ch:-0}" -gt 0 ] && updated=$((updated + ch))
    done <<< "$dir_map"

    # Phase 4: Update non-session tables using the old→new mapping.
    # Skip ambiguous mappings (one old name → multiple new names).
    if [ -s "$rename_map_file" ]; then
        local uniq_map
        uniq_map=$(sort -u "$rename_map_file")
        local prev_old=""
        local ambiguous=""
        while IFS='|' read -r old_proj new_proj; do
            [ -z "$old_proj" ] && continue
            if [ "$old_proj" = "$prev_old" ]; then
                ambiguous+="$old_proj|"
            fi
            prev_old="$old_proj"
        done <<< "$(echo "$uniq_map" | sort -t'|' -k1,1)"

        while IFS='|' read -r old_proj new_proj; do
            [ -z "$old_proj" ] || [ -z "$new_proj" ] && continue
            case "$ambiguous" in *"$old_proj|"*) continue ;; esac

            local old_sql new_sql
            old_sql=$(eagle_sql_escape "$old_proj")
            new_sql=$(eagle_sql_escape "$new_proj")

            eagle_db_pipe <<SQL 2>/dev/null
BEGIN;
UPDATE OR IGNORE overviews SET project = '$new_sql' WHERE project = '$old_sql';
DELETE FROM overviews WHERE project = '$old_sql';
DELETE FROM code_chunks WHERE project = '$old_sql'
  AND EXISTS (SELECT 1 FROM code_chunks WHERE project = '$new_sql' LIMIT 1);
UPDATE code_chunks SET project = '$new_sql' WHERE project = '$old_sql';
UPDATE OR IGNORE features SET project = '$new_sql' WHERE project = '$old_sql';
DELETE FROM features WHERE project = '$old_sql';
UPDATE OR IGNORE command_rules SET project = '$new_sql' WHERE project = '$old_sql';
DELETE FROM command_rules WHERE project = '$old_sql';
UPDATE OR IGNORE eagle_meta SET project = '$new_sql' WHERE project = '$old_sql';
DELETE FROM eagle_meta WHERE project = '$old_sql';
UPDATE OR IGNORE file_hints SET project = '$new_sql' WHERE project = '$old_sql';
DELETE FROM file_hints WHERE project = '$old_sql';
UPDATE OR IGNORE guardrails SET project = '$new_sql' WHERE project = '$old_sql';
DELETE FROM guardrails WHERE project = '$old_sql';
COMMIT;
SQL
        done <<< "$uniq_map"
    fi
    rm -f "$rename_map_file" "$session_filter_file"

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
