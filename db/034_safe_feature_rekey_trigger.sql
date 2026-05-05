-- Migration 034: Make feature FTS updates safe for project-key repairs.
--
-- Project-key repairs update features.project, but the older trigger fired on
-- every UPDATE and tried to rewrite the FTS5 row even when searchable text did
-- not change. Restrict it to the indexed columns so metadata-only rekeys are
-- safe.

DROP TRIGGER IF EXISTS features_au;

CREATE TRIGGER features_au
AFTER UPDATE OF name, description ON features
BEGIN
    INSERT INTO features_fts(features_fts, rowid, name, description)
    VALUES ('delete', old.id, old.name, old.description);
    INSERT INTO features_fts(rowid, name, description)
    VALUES (new.id, new.name, new.description);
END;
