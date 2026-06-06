-- Migration 040: Allow durable decision nodes in the project graph.
-- Decisions are first-class compaction-survival entities captured from summaries.

DROP TRIGGER IF EXISTS val_graph_nodes_insert;
DROP TRIGGER IF EXISTS val_graph_nodes_update;

CREATE TRIGGER val_graph_nodes_insert BEFORE INSERT ON graph_nodes
BEGIN
    SELECT CASE
        WHEN NEW.node_type NOT IN ('project', 'file', 'feature', 'memory', 'task', 'session', 'decision', 'tag', 'class', 'struct', 'function', 'func', 'fn', 'def')
        THEN RAISE(ABORT, 'Data Integrity Error: Invalid node type. Must be one of project, file, feature, memory, task, session, decision, tag, class, struct, function, func, fn, def')
    END;
END;

CREATE TRIGGER val_graph_nodes_update BEFORE UPDATE OF node_type ON graph_nodes
BEGIN
    SELECT CASE
        WHEN NEW.node_type NOT IN ('project', 'file', 'feature', 'memory', 'task', 'session', 'decision', 'tag', 'class', 'struct', 'function', 'func', 'fn', 'def')
        THEN RAISE(ABORT, 'Data Integrity Error: Invalid node type. Must be one of project, file, feature, memory, task, session, decision, tag, class, struct, function, func, fn, def')
    END;
END;
