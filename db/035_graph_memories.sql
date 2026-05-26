-- ═══════════════════════════════════════════════════════════
-- Migration 035: Graph-based memories (nodes and edges relational tables)
-- ═══════════════════════════════════════════════════════════

-- ─── Graph Nodes ───────────────────────────────────────────
-- Represents semantic entities in the codebase (files, features, memories, tasks, sessions, tags, etc.)
CREATE TABLE IF NOT EXISTS graph_nodes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    project         TEXT NOT NULL,
    node_type       TEXT NOT NULL, -- 'file', 'feature', 'memory', 'task', 'session', 'tag', etc.
    node_name       TEXT NOT NULL, -- e.g., 'lib/db-graph.sh', 'auth-middleware', 'agy-session-123'
    node_value      TEXT,          -- Optional content, JSON payload, description, etc.
    source_path     TEXT,          -- Optional filepath or link
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(project, node_type, node_name)
);

CREATE INDEX IF NOT EXISTS idx_graph_nodes_project ON graph_nodes(project);
CREATE INDEX IF NOT EXISTS idx_graph_nodes_type_name ON graph_nodes(node_type, node_name);

-- ─── Graph Edges ───────────────────────────────────────────
-- Represents relationships between nodes with optional weights
CREATE TABLE IF NOT EXISTS graph_edges (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    project         TEXT NOT NULL,
    source_node_id  INTEGER NOT NULL REFERENCES graph_nodes(id) ON DELETE CASCADE,
    target_node_id  INTEGER NOT NULL REFERENCES graph_nodes(id) ON DELETE CASCADE,
    edge_type       TEXT NOT NULL, -- 'imports', 'declares', 'references', 'verifies', 'contains', 'supersedes', 'co_edited', 'modified'
    weight          REAL NOT NULL DEFAULT 1.0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(project, source_node_id, target_node_id, edge_type)
);

CREATE INDEX IF NOT EXISTS idx_graph_edges_project ON graph_edges(project);
CREATE INDEX IF NOT EXISTS idx_graph_edges_source ON graph_edges(source_node_id);
CREATE INDEX IF NOT EXISTS idx_graph_edges_target ON graph_edges(target_node_id);

-- ─── FTS5: Full-text search on graph nodes ──────────────────
CREATE VIRTUAL TABLE IF NOT EXISTS graph_nodes_fts USING fts5(
    node_name,
    node_value,
    content='graph_nodes',
    content_rowid='id'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS graph_nodes_ai AFTER INSERT ON graph_nodes BEGIN
    INSERT INTO graph_nodes_fts(rowid, node_name, node_value)
    VALUES (new.id, new.node_name, new.node_value);
END;

CREATE TRIGGER IF NOT EXISTS graph_nodes_ad AFTER DELETE ON graph_nodes BEGIN
    INSERT INTO graph_nodes_fts(graph_nodes_fts, rowid, node_name, node_value)
    VALUES ('delete', old.id, old.node_name, old.node_value);
END;

CREATE TRIGGER IF NOT EXISTS graph_nodes_au
AFTER UPDATE OF node_name, node_value ON graph_nodes
BEGIN
    INSERT INTO graph_nodes_fts(graph_nodes_fts, rowid, node_name, node_value)
    VALUES ('delete', old.id, old.node_name, old.node_value);
    INSERT INTO graph_nodes_fts(rowid, node_name, node_value)
    VALUES (new.id, new.node_name, new.node_value);
END;
