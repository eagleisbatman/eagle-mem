#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Graph memories helpers
# Primitives for self-wiring codebase graph and relations
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_GRAPH_LOADED:-}" ] && return 0
_EAGLE_DB_GRAPH_LOADED=1

eagle_graph_decl_types_sql() {
    printf "'class','struct','function','func','fn','def'"
}

eagle_graph_project_root() {
    local project="${1:-}"
    local candidate=""

    case "$project" in
        /*) candidate="$project" ;;
        "")
            candidate="$(pwd)"
            ;;
        *)
            if [ -d "$HOME/$project" ]; then
                candidate="$HOME/$project"
            elif [ -d "/$project" ]; then
                candidate="/$project"
            else
                candidate="$(pwd)"
            fi
            ;;
    esac

    (cd "$candidate" 2>/dev/null && pwd) || printf '%s\n' "$candidate"
}

eagle_graph_normalize_file_path() {
    local project="${1:-}"
    local raw="${2:-}"
    local root="${3:-}"

    raw=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    raw="${raw#file://}"
    raw="${raw#./}"
    [ -z "$raw" ] && return 0

    case "$raw" in
        "~/"*) raw="$HOME/${raw#~/}" ;;
    esac

    [ -z "$root" ] && root=$(eagle_graph_project_root "$project")
    root="${root%/}"

    case "$raw" in
        "$root"/*) raw="${raw#"$root"/}" ;;
        "$project"/*) raw="${raw#"$project"/}" ;;
    esac

    raw="${raw#./}"
    printf '%s\n' "$raw"
}

eagle_graph_declaration_node_name() {
    local file="${1:-}"
    local declaration="${2:-}"
    [ -z "$file" ] && { printf '%s\n' "$declaration"; return; }
    printf '%s::%s\n' "$file" "$declaration"
}

eagle_graph_add_node() {
    local project; project=$(eagle_sql_escape "$1")
    local node_type; node_type=$(eagle_sql_escape "$2")
    local node_name; node_name=$(eagle_sql_escape "$3")
    local node_value; node_value=$(eagle_sql_escape "${4:-}")
    local source_path; source_path=$(eagle_sql_escape "${5:-}")

    eagle_db "INSERT INTO graph_nodes (project, node_type, node_name, node_value, source_path)
        VALUES ('$project', '$node_type', '$node_name', '$node_value', '$source_path')
        ON CONFLICT(project, node_type, node_name) DO UPDATE SET
            node_value = CASE WHEN excluded.node_value != '' THEN excluded.node_value ELSE node_value END,
            source_path = CASE WHEN excluded.source_path != '' THEN excluded.source_path ELSE source_path END,
            updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"
}

eagle_graph_get_node_id() {
    local project; project=$(eagle_sql_escape "$1")
    local node_type; node_type=$(eagle_sql_escape "$2")
    local node_name; node_name=$(eagle_sql_escape "$3")

    eagle_db "SELECT id FROM graph_nodes
        WHERE project = '$project'
        AND node_type = '$node_type'
        AND node_name = '$node_name'
        LIMIT 1;"
}

eagle_graph_add_edge() {
    local project; project=$(eagle_sql_escape "$1")
    local source_id; source_id=$(eagle_sql_int "$2")
    local target_id; target_id=$(eagle_sql_int "$3")
    local edge_type; edge_type=$(eagle_sql_escape "$4")
    local weight="${5:-1.0}"
    if ! [[ "$weight" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        weight="1.0"
    fi

    [ -z "$source_id" ] || [ -z "$target_id" ] && return 1
    [ "$source_id" = "$target_id" ] && return 0 # avoid self-loops

    eagle_db "INSERT INTO graph_edges (project, source_node_id, target_node_id, edge_type, weight)
        VALUES ('$project', $source_id, $target_id, '$edge_type', $weight)
        ON CONFLICT(project, source_node_id, target_node_id, edge_type) DO UPDATE SET
            weight = weight + excluded.weight;"
}

eagle_graph_sync_project_overview() {
    local project_raw="${1:-}"
    local overview_raw="${2:-}"
    [ -n "$project_raw" ] || return 0

    local exists
    exists=$(eagle_db "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'graph_nodes' LIMIT 1;" 2>/dev/null || true)
    [ "$exists" = "graph_nodes" ] || return 0

    eagle_graph_add_node "$project_raw" "project" "$project_raw" "$overview_raw" ""
}

eagle_graph_reset_file_static_edges() {
    local project_raw="${1:-}"
    local file_raw="${2:-}"
    local file_node_id="${3:-}"
    [ -n "$project_raw" ] && [ -n "$file_raw" ] || return 0

    local project file type_sql
    project=$(eagle_sql_escape "$project_raw")
    file=$(eagle_sql_escape "$file_raw")
    type_sql=$(eagle_graph_decl_types_sql)

    if [ -z "$file_node_id" ]; then
        file_node_id=$(eagle_graph_get_node_id "$project_raw" "file" "$file_raw")
    fi
    if [ -n "$file_node_id" ]; then
        file_node_id=$(eagle_sql_int "$file_node_id")
        eagle_db "DELETE FROM graph_edges
                  WHERE project = '$project'
                    AND source_node_id = $file_node_id
                    AND edge_type IN ('declares', 'imports');" >/dev/null
    fi

    eagle_db "DELETE FROM graph_nodes
              WHERE project = '$project'
                AND node_type IN ($type_sql)
                AND source_path = '$file';" >/dev/null
}

eagle_graph_clear_index_state() {
    local project_raw="${1:-}"
    [ -n "$project_raw" ] || return 0

    local project type_sql
    project=$(eagle_sql_escape "$project_raw")
    type_sql=$(eagle_graph_decl_types_sql)

    eagle_db_pipe <<SQL >/dev/null
BEGIN;
DELETE FROM code_chunks WHERE project = '$project';
DELETE FROM graph_edges
WHERE project = '$project'
  AND edge_type IN ('declares', 'imports');
DELETE FROM graph_nodes
WHERE project = '$project'
  AND node_type IN ($type_sql);
COMMIT;
SQL
}

eagle_graph_clear_code_state() {
    local project_raw="${1:-}"
    [ -n "$project_raw" ] || return 0

    local project type_sql
    project=$(eagle_sql_escape "$project_raw")
    type_sql=$(eagle_graph_decl_types_sql)

    eagle_db_pipe <<SQL >/dev/null
BEGIN;
DELETE FROM code_chunks WHERE project = '$project';
DELETE FROM graph_nodes
WHERE project = '$project'
  AND node_type IN ('project', 'file', $type_sql);
COMMIT;
SQL
}

eagle_graph_rebuild_codebase() {
    local project_raw="${1:-}"
    local target_dir="${2:-.}"
    [ -n "$project_raw" ] || return 1

    target_dir="$(cd "$target_dir" && pwd)"
    local tmp_files overview project_node_id file file_node_id file_count
    tmp_files=$(mktemp)
    eagle_collect_files "$target_dir" "$tmp_files"

    eagle_graph_clear_code_state "$project_raw"

    overview=""
    if declare -F eagle_get_overview >/dev/null 2>&1; then
        overview=$(eagle_get_overview "$project_raw" 2>/dev/null || true)
    fi
    eagle_graph_add_node "$project_raw" "project" "$project_raw" "$overview" ""
    project_node_id=$(eagle_graph_get_node_id "$project_raw" "project" "$project_raw")

    file_count=0
    if [ -n "$project_node_id" ]; then
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            [ -f "$target_dir/$file" ] || continue
            eagle_graph_add_node "$project_raw" "file" "$file" "" "$target_dir/$file"
            file_node_id=$(eagle_graph_get_node_id "$project_raw" "file" "$file")
            if [ -n "$file_node_id" ]; then
                eagle_graph_add_edge "$project_raw" "$project_node_id" "$file_node_id" "contains" 1.0 >/dev/null || true
            fi
            file_count=$((file_count + 1))
        done < "$tmp_files"
    fi

    rm -f "$tmp_files"
    printf '%s\n' "$file_count"
}

eagle_graph_wire_recent_session_edges() {
    local project_raw="${1:-}"
    local limit="${2:-15}"
    [ -n "$project_raw" ] || { printf '0\n'; return 0; }
    if ! [[ "$limit" =~ ^[0-9]+$ ]] || [ "$limit" -lt 1 ]; then
        limit=15
    fi

    local project rows session_count root sql_file
    project=$(eagle_sql_escape "$project_raw")
    rows=$(eagle_db_json "WITH recent_sessions AS (
              SELECT id, started_at, model
              FROM sessions
              WHERE project = '$project'
              ORDER BY started_at DESC
              LIMIT $limit
          )
          SELECT r.id AS session_id,
                 r.started_at AS started_at,
                 r.model AS model,
                 COALESCE(o.files_read, '[]') AS files_read,
                 COALESCE(o.files_modified, '[]') AS files_modified
          FROM recent_sessions r
          LEFT JOIN observations o ON o.session_id = r.id
          ORDER BY r.started_at DESC;" 2>/dev/null || true)

    if [ -z "$rows" ] || [ "$rows" = "[]" ]; then
        printf '0\n'
        return 0
    fi

    session_count=$(printf '%s' "$rows" | jq -r '.[].session_id // empty' 2>/dev/null | sort -u | wc -l | tr -d ' ')
    root=$(eagle_graph_project_root "$project_raw")
    sql_file=$(mktemp)

    {
        echo "BEGIN;"
        printf '%s' "$rows" | jq -c '.[]' 2>/dev/null | while IFS= read -r row; do
            local sid started model sid_sql value_sql
            sid=$(printf '%s' "$row" | jq -r '.session_id // empty')
            [ -n "$sid" ] || continue
            started=$(printf '%s' "$row" | jq -r '.started_at // "unknown"')
            model=$(printf '%s' "$row" | jq -r '.model // "unknown"')
            sid_sql=$(eagle_sql_escape "$sid")
            value_sql=$(eagle_sql_escape "Session run on $started using $model")

            cat <<SQL
INSERT INTO graph_nodes (project, node_type, node_name, node_value, source_path)
VALUES ('$project', 'session', '$sid_sql', '$value_sql', '')
ON CONFLICT(project, node_type, node_name) DO UPDATE SET
    node_value = excluded.node_value,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');
SQL

            printf '%s' "$row" | jq -r '.files_read | if type == "string" then (try fromjson catch []) else (. // []) end | .[]?' 2>/dev/null \
                | while IFS= read -r file_path; do
                    [ -n "$file_path" ] || continue
                    eagle_graph_emit_session_file_edge_sql "$project_raw" "$sid" "$file_path" "$root" "read" "1.0"
                done
            printf '%s' "$row" | jq -r '.files_modified | if type == "string" then (try fromjson catch []) else (. // []) end | .[]?' 2>/dev/null \
                | while IFS= read -r file_path; do
                    [ -n "$file_path" ] || continue
                    eagle_graph_emit_session_file_edge_sql "$project_raw" "$sid" "$file_path" "$root" "modified" "2.0"
                done
        done
        echo "COMMIT;"
    } > "$sql_file"

    eagle_db_pipe < "$sql_file" >/dev/null
    rm -f "$sql_file"
    printf '%s\n' "${session_count:-0}"
}

eagle_graph_wire_project_context_edges() {
    local project_raw="${1:-}"
    [ -n "$project_raw" ] || { printf '0\n'; return 0; }

    local project
    project=$(eagle_sql_escape "$project_raw")

    eagle_db_pipe <<SQL >/dev/null
BEGIN;

INSERT OR IGNORE INTO graph_nodes (project, node_type, node_name, node_value, source_path)
SELECT project, 'session', id,
       'Session run on ' || COALESCE(started_at, 'unknown') || ' using ' || COALESCE(model, 'unknown'),
       ''
FROM sessions
WHERE project = '$project';

INSERT OR IGNORE INTO graph_nodes (project, node_type, node_name, node_value, source_path)
SELECT project, 'decision', session_id || ':decision', decisions, ''
FROM summaries
WHERE project = '$project'
  AND COALESCE(decisions, '') != '';

INSERT OR IGNORE INTO graph_nodes (project, node_type, node_name, node_value, source_path)
SELECT project, 'feature', name, COALESCE(description, ''), ''
FROM features
WHERE project = '$project'
  AND status = 'active';

INSERT OR IGNORE INTO graph_nodes (project, node_type, node_name, node_value, source_path)
SELECT project, 'memory', memory_name, COALESCE(description, ''), COALESCE(file_path, '')
FROM agent_memories
WHERE project = '$project'
  AND COALESCE(memory_name, '') != '';

INSERT OR IGNORE INTO graph_nodes (project, node_type, node_name, node_value, source_path)
SELECT project, 'task', COALESCE(NULLIF(source_task_id, ''), subject), COALESCE(description, ''), COALESCE(file_path, '')
FROM agent_tasks
WHERE project = '$project'
  AND COALESCE(COALESCE(NULLIF(source_task_id, ''), subject), '') != '';

INSERT OR IGNORE INTO graph_nodes (project, node_type, node_name, node_value, source_path)
SELECT f.project, 'file', ff.file_path, '', ff.file_path
FROM feature_files ff
JOIN features f ON f.id = ff.feature_id
WHERE f.project = '$project';

INSERT OR IGNORE INTO graph_nodes (project, node_type, node_name, node_value, source_path)
SELECT DISTINCT sf.project, 'file', sf.file_path, '', sf.file_path
FROM (
    SELECT project, json_each.value AS file_path
    FROM summaries, json_each(CASE WHEN json_valid(files_read) THEN files_read ELSE '[]' END)
    WHERE project = '$project'
    UNION
    SELECT project, json_each.value AS file_path
    FROM summaries, json_each(CASE WHEN json_valid(files_modified) THEN files_modified ELSE '[]' END)
    WHERE project = '$project'
) sf
WHERE COALESCE(sf.file_path, '') != '';

INSERT OR IGNORE INTO graph_edges (project, source_node_id, target_node_id, edge_type, weight)
SELECT '$project', d.id, s.id, 'recorded_in', 1.0
FROM summaries sm
JOIN graph_nodes d ON d.project = sm.project AND d.node_type = 'decision' AND d.node_name = sm.session_id || ':decision'
JOIN graph_nodes s ON s.project = sm.project AND s.node_type = 'session' AND s.node_name = sm.session_id
WHERE sm.project = '$project'
  AND COALESCE(sm.decisions, '') != ''
  AND d.id != s.id;

INSERT OR IGNORE INTO graph_edges (project, source_node_id, target_node_id, edge_type, weight)
SELECT '$project', d.id, fnode.id, 'touches', 1.0
FROM summaries sm
JOIN graph_nodes d ON d.project = sm.project AND d.node_type = 'decision' AND d.node_name = sm.session_id || ':decision'
JOIN (
    SELECT session_id, project, json_each.value AS file_path
    FROM summaries, json_each(CASE WHEN json_valid(files_read) THEN files_read ELSE '[]' END)
    WHERE project = '$project'
    UNION
    SELECT session_id, project, json_each.value AS file_path
    FROM summaries, json_each(CASE WHEN json_valid(files_modified) THEN files_modified ELSE '[]' END)
    WHERE project = '$project'
) sf ON sf.session_id = sm.session_id AND sf.project = sm.project
JOIN graph_nodes fnode ON fnode.project = sf.project AND fnode.node_type = 'file' AND fnode.node_name = sf.file_path
WHERE sm.project = '$project'
  AND COALESCE(sm.decisions, '') != ''
  AND COALESCE(sf.file_path, '') != ''
  AND d.id != fnode.id;

INSERT OR IGNORE INTO graph_edges (project, source_node_id, target_node_id, edge_type, weight)
SELECT '$project', feat.id, file.id, 'covers', 1.0
FROM features f
JOIN feature_files ff ON ff.feature_id = f.id
JOIN graph_nodes feat ON feat.project = f.project AND feat.node_type = 'feature' AND feat.node_name = f.name
JOIN graph_nodes file ON file.project = f.project AND file.node_type = 'file' AND file.node_name = ff.file_path
WHERE f.project = '$project'
  AND feat.id != file.id;

INSERT OR IGNORE INTO graph_edges (project, source_node_id, target_node_id, edge_type, weight)
SELECT '$project', memory.id, session.id, 'originated_in', 1.0
FROM agent_memories m
JOIN graph_nodes memory ON memory.project = m.project AND memory.node_type = 'memory' AND memory.node_name = m.memory_name
JOIN graph_nodes session ON session.project = m.project AND session.node_type = 'session' AND session.node_name = m.origin_session_id
WHERE m.project = '$project'
  AND COALESCE(m.origin_session_id, '') != ''
  AND memory.id != session.id;

INSERT OR IGNORE INTO graph_edges (project, source_node_id, target_node_id, edge_type, weight)
SELECT '$project', memory.id, feat.id, 'mentions', 1.0
FROM agent_memories m
JOIN features f ON f.project = m.project AND f.status = 'active'
JOIN graph_nodes memory ON memory.project = m.project AND memory.node_type = 'memory' AND memory.node_name = m.memory_name
JOIN graph_nodes feat ON feat.project = f.project AND feat.node_type = 'feature' AND feat.node_name = f.name
WHERE m.project = '$project'
  AND LOWER(COALESCE(m.memory_name, '') || ' ' || COALESCE(m.description, '') || ' ' || COALESCE(m.content, '')) LIKE '%' || LOWER(f.name) || '%'
  AND memory.id != feat.id;

INSERT OR IGNORE INTO graph_edges (project, source_node_id, target_node_id, edge_type, weight)
SELECT '$project', task.id, session.id, 'planned_in', 1.0
FROM agent_tasks t
JOIN graph_nodes task ON task.project = t.project AND task.node_type = 'task' AND task.node_name = COALESCE(NULLIF(t.source_task_id, ''), t.subject)
JOIN graph_nodes session ON session.project = t.project AND session.node_type = 'session' AND session.node_name = t.source_session_id
WHERE t.project = '$project'
  AND COALESCE(t.source_session_id, '') != ''
  AND task.id != session.id;

INSERT OR IGNORE INTO graph_edges (project, source_node_id, target_node_id, edge_type, weight)
SELECT '$project', task.id, feat.id, 'mentions', 1.0
FROM agent_tasks t
JOIN features f ON f.project = t.project AND f.status = 'active'
JOIN graph_nodes task ON task.project = t.project AND task.node_type = 'task' AND task.node_name = COALESCE(NULLIF(t.source_task_id, ''), t.subject)
JOIN graph_nodes feat ON feat.project = f.project AND feat.node_type = 'feature' AND feat.node_name = f.name
WHERE t.project = '$project'
  AND LOWER(COALESCE(t.subject, '') || ' ' || COALESCE(t.description, '')) LIKE '%' || LOWER(f.name) || '%'
  AND task.id != feat.id;

INSERT OR IGNORE INTO graph_edges (project, source_node_id, target_node_id, edge_type, weight)
SELECT '$project', decision.id, feat.id, 'mentions', 1.0
FROM summaries sm
JOIN features f ON f.project = sm.project AND f.status = 'active'
JOIN graph_nodes decision ON decision.project = sm.project AND decision.node_type = 'decision' AND decision.node_name = sm.session_id || ':decision'
JOIN graph_nodes feat ON feat.project = f.project AND feat.node_type = 'feature' AND feat.node_name = f.name
WHERE sm.project = '$project'
  AND LOWER(COALESCE(sm.decisions, '')) LIKE '%' || LOWER(f.name) || '%'
  AND decision.id != feat.id;

COMMIT;
SQL

    eagle_db "SELECT COUNT(*)
              FROM graph_nodes
              WHERE project = '$project'
                AND node_type IN ('feature', 'memory', 'task', 'session', 'decision');"
}

eagle_graph_emit_session_file_edge_sql() {
    local project_raw="${1:-}"
    local session_id="${2:-}"
    local file_path="${3:-}"
    local root="${4:-}"
    local edge_type="${5:-read}"
    local weight="${6:-1.0}"
    local normalized project sid file edge

    normalized=$(eagle_graph_normalize_file_path "$project_raw" "$file_path" "$root")
    [ -n "$normalized" ] || return 0

    project=$(eagle_sql_escape "$project_raw")
    sid=$(eagle_sql_escape "$session_id")
    file=$(eagle_sql_escape "$normalized")
    edge=$(eagle_sql_escape "$edge_type")
    if ! [[ "$weight" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        weight="1.0"
    fi

    cat <<SQL
INSERT OR IGNORE INTO graph_edges (project, source_node_id, target_node_id, edge_type, weight)
SELECT '$project', s.id, f.id, '$edge', 0.0
FROM graph_nodes s, graph_nodes f
WHERE s.project = '$project'
  AND s.node_type = 'session'
  AND s.node_name = '$sid'
  AND f.project = '$project'
  AND f.node_type = 'file'
  AND f.node_name = '$file'
  AND s.id != f.id;
UPDATE graph_edges
SET weight = weight + $weight
WHERE project = '$project'
  AND edge_type = '$edge'
  AND source_node_id = (
      SELECT id FROM graph_nodes
      WHERE project = '$project' AND node_type = 'session' AND node_name = '$sid'
      LIMIT 1
  )
  AND target_node_id = (
      SELECT id FROM graph_nodes
      WHERE project = '$project' AND node_type = 'file' AND node_name = '$file'
      LIMIT 1
  );
SQL
}

eagle_graph_query_neighbors() {
    local node_id; node_id=$(eagle_sql_int "$1")
    local direction="${2:-out}" # 'out', 'in', or 'both'

    if [ "$direction" = "out" ]; then
        eagle_db "SELECT e.edge_type, e.weight, n.id, n.node_type, n.node_name, n.node_value
            FROM graph_edges e
            JOIN graph_nodes n ON e.target_node_id = n.id
            WHERE e.source_node_id = $node_id
            ORDER BY e.weight DESC, n.node_name;"
    elif [ "$direction" = "in" ]; then
        eagle_db "SELECT e.edge_type, e.weight, n.id, n.node_type, n.node_name, n.node_value
            FROM graph_edges e
            JOIN graph_nodes n ON e.source_node_id = n.id
            WHERE e.target_node_id = $node_id
            ORDER BY e.weight DESC, n.node_name;"
    else
        eagle_db "SELECT 'out' as dir, e.edge_type, e.weight, n.id, n.node_type, n.node_name, n.node_value
            FROM graph_edges e
            JOIN graph_nodes n ON e.target_node_id = n.id
            WHERE e.source_node_id = $node_id
            UNION ALL
            SELECT 'in' as dir, e.edge_type, e.weight, n.id, n.node_type, n.node_name, n.node_value
            FROM graph_edges e
            JOIN graph_nodes n ON e.source_node_id = n.id
            WHERE e.target_node_id = $node_id
            ORDER BY weight DESC;"
    fi
}

eagle_graph_search() {
    local project; project=$(eagle_sql_escape "$1")
    local query; query=$(eagle_fts_sanitize "$2")
    local type_filter="${3:-}"

    local sql
    if [ -n "$type_filter" ]; then
        local t_esc; t_esc=$(eagle_sql_escape "$type_filter")
        sql="SELECT n.id, n.node_type, n.node_name, n.node_value, n.source_path
            FROM graph_nodes n
            JOIN graph_nodes_fts f ON f.rowid = n.id
            WHERE n.project = '$project'
            AND n.node_type = '$t_esc'
            AND graph_nodes_fts MATCH '$query'
            ORDER BY rank;"
    else
        sql="SELECT n.id, n.node_type, n.node_name, n.node_value, n.source_path
            FROM graph_nodes n
            JOIN graph_nodes_fts f ON f.rowid = n.id
            WHERE n.project = '$project'
            AND graph_nodes_fts MATCH '$query'
            ORDER BY rank;"
    fi

    eagle_db "$sql"
}

eagle_graph_get_node_by_id() {
    local node_id; node_id=$(eagle_sql_int "$1")
    eagle_db "SELECT id, node_type, node_name, node_value, source_path, created_at, updated_at
        FROM graph_nodes
        WHERE id = $node_id
        LIMIT 1;"
}

eagle_graph_delete_node() {
    local node_id; node_id=$(eagle_sql_int "$1")
    eagle_db "DELETE FROM graph_nodes WHERE id = $node_id;"
}

eagle_graph_prune_orphans() {
    local project; project=$(eagle_sql_escape "$1")
    local target_dir="${2:-}"
    [ -n "$target_dir" ] && target_dir="${target_dir%/}"
    # Delete file nodes that no longer exist on disk
    local result
    result=$(eagle_db "SELECT id, node_name, COALESCE(source_path, '') FROM graph_nodes WHERE project = '$project' AND node_type = 'file';")
    [ -z "$result" ] && return 0

    while IFS='|' read -r nid nname nsource; do
        [ -z "$nid" ] && continue
        local candidate="$nsource"
        if [ -z "$candidate" ]; then
            if [ -n "$target_dir" ]; then
                candidate="$target_dir/$nname"
            else
                candidate="$nname"
            fi
        fi
        if [ ! -f "$candidate" ]; then
            eagle_graph_delete_node "$nid"
        fi
    done <<< "$result"
}
