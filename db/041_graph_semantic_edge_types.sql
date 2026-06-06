-- Migration 041: Allow semantic project-graph relationships.
-- These edges connect durable context entities used for compaction survival.

DROP TRIGGER IF EXISTS val_graph_edges_insert;
DROP TRIGGER IF EXISTS val_graph_edges_update;

CREATE TRIGGER val_graph_edges_insert BEFORE INSERT ON graph_edges
BEGIN
    SELECT CASE
        WHEN NEW.edge_type NOT IN ('imports', 'declares', 'references', 'verifies', 'contains', 'supersedes', 'co_edited', 'modified', 'read', 'covers', 'mentions', 'touches', 'recorded_in', 'originated_in', 'planned_in')
        THEN RAISE(ABORT, 'Data Integrity Error: Invalid edge type. Must be one of imports, declares, references, verifies, contains, supersedes, co_edited, modified, read, covers, mentions, touches, recorded_in, originated_in, planned_in')
    END;
END;

CREATE TRIGGER val_graph_edges_update BEFORE UPDATE OF edge_type ON graph_edges
BEGIN
    SELECT CASE
        WHEN NEW.edge_type NOT IN ('imports', 'declares', 'references', 'verifies', 'contains', 'supersedes', 'co_edited', 'modified', 'read', 'covers', 'mentions', 'touches', 'recorded_in', 'originated_in', 'planned_in')
        THEN RAISE(ABORT, 'Data Integrity Error: Invalid edge type. Must be one of imports, declares, references, verifies, contains, supersedes, co_edited, modified, read, covers, mentions, touches, recorded_in, originated_in, planned_in')
    END;
END;
