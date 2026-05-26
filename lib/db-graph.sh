#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Graph memories helpers
# Primitives for self-wiring codebase graph and relations
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_GRAPH_LOADED:-}" ] && return 0
_EAGLE_DB_GRAPH_LOADED=1

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
    # Delete file nodes that no longer exist on disk
    local result
    result=$(eagle_db "SELECT id, node_name FROM graph_nodes WHERE project = '$project' AND node_type = 'file';")
    [ -z "$result" ] && return 0

    while IFS='|' read -r nid nname; do
        [ -z "$nid" ] && continue
        if [ ! -f "$nname" ]; then
            eagle_graph_delete_node "$nid"
        fi
    done <<< "$result"
}
