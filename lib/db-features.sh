#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Feature graph helpers
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_FEATURES_LOADED:-}" ] && return 0
_EAGLE_DB_FEATURES_LOADED=1

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

    eagle_db "INSERT OR IGNORE INTO feature_smoke_tests (feature_id, command, description)
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

eagle_find_feature_impacts_for_file() {
    local project; project=$(eagle_sql_escape "$1")
    local file_path="$2"
    local fname; fname=$(basename "$file_path")
    local file_esc; file_esc=$(eagle_sql_escape "$file_path")
    local fname_esc; fname_esc=$(eagle_sql_escape "$fname")
    local file_like; file_like=$(eagle_like_escape "$file_esc")
    local fname_like; fname_like=$(eagle_like_escape "$fname_esc")

    eagle_db "SELECT DISTINCT f.id, f.name, f.description, f.last_verified_at,
        ff.file_path,
        (SELECT GROUP_CONCAT(fst.command, '; ')
         FROM feature_smoke_tests fst WHERE fst.feature_id = f.id) as smoke_tests
        FROM features f
        JOIN feature_files ff ON ff.feature_id = f.id
        WHERE f.project = '$project'
        AND f.status = 'active'
        AND (
            ff.file_path = '$file_esc'
            OR ff.file_path LIKE '%/$file_like' ESCAPE '\\'
            OR '$file_esc' LIKE '%' || ff.file_path ESCAPE '\\'
            OR ff.file_path LIKE '%$fname_like' ESCAPE '\\'
            OR ff.file_path LIKE '%$fname_like%' ESCAPE '\\'
        )
        ORDER BY f.updated_at DESC
        LIMIT 10;"
}

eagle_record_pending_feature_verifications() {
    local project="$1"
    local file_path="$2"
    local session_id="${3:-}"
    local trigger_tool="${4:-}"
    local reason="${5:-File changed}"
    local change_fingerprint="${6:-}"

    local impacts
    impacts=$(eagle_find_feature_impacts_for_file "$project" "$file_path")
    [ -z "$impacts" ] && return 0

    local p_esc; p_esc=$(eagle_sql_escape "$project")
    local fp_esc; fp_esc=$(eagle_sql_escape "$file_path")
    local sid_esc; sid_esc=$(eagle_sql_escape "$session_id")
    local tool_esc; tool_esc=$(eagle_sql_escape "$trigger_tool")
    local reason_esc; reason_esc=$(eagle_sql_escape "$reason")
    local fp_hash_esc; fp_hash_esc=$(eagle_sql_escape "$change_fingerprint")

    while IFS='|' read -r feature_id feature_name _desc _verified _matched_file _smoke; do
        [ -z "$feature_id" ] && continue
        local fid; fid=$(eagle_sql_int "$feature_id")
        local name_esc; name_esc=$(eagle_sql_escape "$feature_name")

        already_resolved=$(eagle_db "SELECT 1 FROM pending_feature_verifications
            WHERE project = '$p_esc'
              AND feature_id = $fid
              AND file_path = '$fp_esc'
              AND (
                  (change_fingerprint = '$fp_hash_esc' AND status = 'verified')
                  OR status = 'waived'
              )
            LIMIT 1;")
        [ -n "$already_resolved" ] && continue

        eagle_db "INSERT INTO pending_feature_verifications
            (project, feature_id, feature_name, file_path, reason, source_session_id, trigger_tool, change_fingerprint)
            VALUES ('$p_esc', $fid, '$name_esc', '$fp_esc', '$reason_esc', '$sid_esc', '$tool_esc', '$fp_hash_esc')
            ON CONFLICT(project, feature_id, file_path) WHERE status = 'pending' DO UPDATE SET
                feature_name = excluded.feature_name,
                reason = excluded.reason,
                source_session_id = excluded.source_session_id,
                trigger_tool = excluded.trigger_tool,
                change_fingerprint = excluded.change_fingerprint,
                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');" >/dev/null
    done <<< "$impacts"

    printf '%s\n' "$impacts"
}

eagle_record_current_feature_verifications_for_file() {
    local project="$1"
    local cwd="$2"
    local file_path="$3"
    local session_id="${4:-}"
    local trigger_tool="${5:-}"
    local reason="${6:-File changed}"

    local norm_file
    norm_file=$(eagle_project_file_path "$cwd" "$file_path")
    [ -z "$norm_file" ] && return 0

    local fingerprint
    fingerprint=$(eagle_change_fingerprint_for_file "$cwd" "$norm_file")
    eagle_record_pending_feature_verifications "$project" "$norm_file" "$session_id" "$trigger_tool" "$reason" "$fingerprint"
}

eagle_reconcile_current_feature_verifications() {
    local project="$1"
    local cwd="$2"
    local session_id="${3:-}"
    local trigger_tool="${4:-}"
    local reason="${5:-Repository change detected}"
    local changed_files="${6:-}"

    [ -z "$changed_files" ] && return 0
    while IFS= read -r changed_file; do
        [ -z "$changed_file" ] && continue
        eagle_record_current_feature_verifications_for_file "$project" "$cwd" "$changed_file" "$session_id" "$trigger_tool" "$reason" >/dev/null
    done <<< "$changed_files"
}

eagle_list_current_pending_feature_verifications() {
    local project="$1"
    local cwd="$2"
    local changed_files="${3:-}"
    local limit; limit=$(eagle_sql_int "${4:-20}")
    [ "$limit" -eq 0 ] && limit=20

    [ -z "$changed_files" ] && return 0

    local p_esc; p_esc=$(eagle_sql_escape "$project")
    local emitted=0
    local seen="|"

    while IFS= read -r changed_file; do
        [ -z "$changed_file" ] && continue
        [ "$emitted" -ge "$limit" ] && break

        local norm_file fingerprint impacts fp_esc fp_hash_esc
        norm_file=$(eagle_project_file_path "$cwd" "$changed_file")
        [ -z "$norm_file" ] && continue
        fingerprint=$(eagle_change_fingerprint_for_file "$cwd" "$norm_file")
        impacts=$(eagle_find_feature_impacts_for_file "$project" "$norm_file")
        [ -z "$impacts" ] && continue

        fp_esc=$(eagle_sql_escape "$norm_file")
        fp_hash_esc=$(eagle_sql_escape "$fingerprint")

        while IFS='|' read -r feature_id _feature_name _desc _verified _matched_file _smoke; do
            [ -z "$feature_id" ] && continue
            [ "$emitted" -ge "$limit" ] && break

            local fid row row_id
            fid=$(eagle_sql_int "$feature_id")
            row=$(eagle_db "SELECT p.id, p.feature_name, p.file_path, p.reason, p.trigger_tool, p.created_at,
                COALESCE((SELECT GROUP_CONCAT(fst.command, '; ')
                 FROM feature_smoke_tests fst WHERE fst.feature_id = p.feature_id), '') as smoke_tests,
                substr(p.change_fingerprint, 1, 12) as fingerprint
                FROM pending_feature_verifications p
                WHERE p.project = '$p_esc'
                  AND p.feature_id = $fid
                  AND p.file_path = '$fp_esc'
                  AND p.change_fingerprint = '$fp_hash_esc'
                  AND p.status = 'pending'
                ORDER BY p.updated_at DESC, p.id DESC
                LIMIT 1;")
            [ -z "$row" ] && continue
            row_id=${row%%|*}
            case "$seen" in *"|$row_id|"*) continue ;; esac
            seen+="$row_id|"
            printf '%s\n' "$row"
            emitted=$((emitted + 1))
        done <<< "$impacts"
    done <<< "$changed_files"
}

eagle_count_pending_feature_verifications() {
    local project; project=$(eagle_sql_escape "$1")
    eagle_db "SELECT COUNT(*) FROM pending_feature_verifications
        WHERE project = '$project' AND status = 'pending';"
}

eagle_list_pending_feature_verifications() {
    local project; project=$(eagle_sql_escape "$1")
    local limit; limit=$(eagle_sql_int "${2:-20}")

    eagle_db "SELECT p.id, p.feature_name, p.file_path, p.reason, p.trigger_tool, p.created_at,
        COALESCE((SELECT GROUP_CONCAT(fst.command, '; ')
         FROM feature_smoke_tests fst WHERE fst.feature_id = p.feature_id), '') as smoke_tests,
        substr(p.change_fingerprint, 1, 12) as fingerprint
        FROM pending_feature_verifications p
        WHERE p.project = '$project' AND p.status = 'pending'
        ORDER BY p.updated_at DESC, p.id DESC
        LIMIT $limit;"
}

eagle_resolve_pending_feature_verifications() {
    local project; project=$(eagle_sql_escape "$1")
    local name; name=$(eagle_sql_escape "$2")
    local status; status=$(eagle_sql_escape "${3:-verified}")
    local notes; notes=$(eagle_sql_escape "${4:-}")

    eagle_db_pipe <<SQL
UPDATE pending_feature_verifications
SET status = '$status',
    notes = '$notes',
    resolved_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE project = '$project'
  AND feature_name = '$name'
  AND status = 'pending';
SELECT changes();
SQL
}

eagle_waive_pending_feature_verification() {
    local project; project=$(eagle_sql_escape "$1")
    local id; id=$(eagle_sql_int "$2")
    local notes; notes=$(eagle_sql_escape "${3:-}")

    eagle_db_pipe <<SQL
UPDATE pending_feature_verifications
SET status = 'waived',
    notes = '$notes',
    resolved_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE project = '$project'
  AND id = $id
  AND status = 'pending';
SELECT changes();
SQL
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

eagle_count_active_features() {
    local project; project=$(eagle_sql_escape "$1")
    eagle_db "SELECT COUNT(*) FROM features WHERE project = '$project' AND status = 'active';"
}

eagle_find_feature_for_push() {
    local project; project=$(eagle_sql_escape "$1")
    local fname; fname=$(eagle_sql_escape "$2")
    local fname_like; fname_like=$(eagle_like_escape "$fname")

    eagle_db "SELECT DISTINCT f.name,
        (SELECT GROUP_CONCAT(fst.command, '; ')
         FROM feature_smoke_tests fst WHERE fst.feature_id = f.id) as smoke,
        (SELECT GROUP_CONCAT(fd.target || ':' || fd.name, ', ')
         FROM feature_dependencies fd WHERE fd.feature_id = f.id) as deps,
        f.last_verified_at
        FROM features f
        JOIN feature_files ff ON ff.feature_id = f.id
        WHERE f.project = '$project'
        AND f.status = 'active'
        AND (ff.file_path LIKE '%$fname_like' ESCAPE '\\' OR ff.file_path LIKE '%$fname_like%' ESCAPE '\\');"
}

eagle_find_features_for_file() {
    local project; project=$(eagle_sql_escape "$1")
    local file_path="$2"
    local fname; fname=$(basename "$file_path")
    local fname_esc; fname_esc=$(eagle_sql_escape "$fname")
    local fname_like; fname_like=$(eagle_like_escape "$fname_esc")

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
        AND (ff.file_path LIKE '%$fname_like' ESCAPE '\\' OR ff.file_path LIKE '%$fname_like%' ESCAPE '\\')
        ORDER BY f.updated_at DESC
        LIMIT 3;"
}
