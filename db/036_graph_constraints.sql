-- ═══════════════════════════════════════════════════════════
-- Migration 036: Database-level enums constraints triggers
-- ═══════════════════════════════════════════════════════════

-- ─── Node Type Constraints ──────────────────────────────────
CREATE TRIGGER IF NOT EXISTS val_graph_nodes_insert BEFORE INSERT ON graph_nodes
BEGIN
    SELECT CASE
        WHEN NEW.node_type NOT IN ('project', 'file', 'feature', 'memory', 'task', 'session', 'tag', 'class', 'def')
        THEN RAISE(ABORT, 'Data Integrity Error: Invalid node type. Must be one of project, file, feature, memory, task, session, tag, class, def')
    END;
END;

CREATE TRIGGER IF NOT EXISTS val_graph_nodes_update BEFORE UPDATE OF node_type ON graph_nodes
BEGIN
    SELECT CASE
        WHEN NEW.node_type NOT IN ('project', 'file', 'feature', 'memory', 'task', 'session', 'tag', 'class', 'def')
        THEN RAISE(ABORT, 'Data Integrity Error: Invalid node type. Must be one of project, file, feature, memory, task, session, tag, class, def')
    END;
END;

-- ─── Edge Type Constraints ──────────────────────────────────
CREATE TRIGGER IF NOT EXISTS val_graph_edges_insert BEFORE INSERT ON graph_edges
BEGIN
    SELECT CASE
        WHEN NEW.edge_type NOT IN ('imports', 'declares', 'references', 'verifies', 'contains', 'supersedes', 'co_edited', 'modified', 'read')
        THEN RAISE(ABORT, 'Data Integrity Error: Invalid edge type. Must be one of imports, declares, references, verifies, contains, supersedes, co_edited, modified, read')
    END;
END;

CREATE TRIGGER IF NOT EXISTS val_graph_edges_update BEFORE UPDATE OF edge_type ON graph_edges
BEGIN
    SELECT CASE
        WHEN NEW.edge_type NOT IN ('imports', 'declares', 'references', 'verifies', 'contains', 'supersedes', 'co_edited', 'modified', 'read')
        THEN RAISE(ABORT, 'Data Integrity Error: Invalid edge type. Must be one of imports, declares, references, verifies, contains, supersedes, co_edited, modified, read')
    END;
END;
