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
