-- Migration 012: Add decisions, gotchas, key_files columns to summaries
-- These capture WHY choices were made, WHAT went wrong, and WHERE to start reading.
-- Also adds them to FTS5 so they're searchable across sessions.

-- Add new columns
ALTER TABLE summaries ADD COLUMN decisions TEXT;
ALTER TABLE summaries ADD COLUMN gotchas TEXT;
ALTER TABLE summaries ADD COLUMN key_files TEXT;

-- Rebuild FTS5 to include new columns
DROP TRIGGER IF EXISTS summaries_ai;
DROP TRIGGER IF EXISTS summaries_ad;
DROP TRIGGER IF EXISTS summaries_au;

DROP TABLE IF EXISTS summaries_fts;

CREATE VIRTUAL TABLE summaries_fts USING fts5(
    request,
    investigated,
    learned,
    completed,
    next_steps,
    notes,
    decisions,
    gotchas,
    key_files,
    content='summaries',
    content_rowid='id'
);

-- Backfill FTS from existing data
INSERT INTO summaries_fts(rowid, request, investigated, learned, completed, next_steps, notes, decisions, gotchas, key_files)
SELECT id, request, investigated, learned, completed, next_steps, notes, decisions, gotchas, key_files FROM summaries;

-- Recreate content-sync triggers with new columns
CREATE TRIGGER summaries_ai AFTER INSERT ON summaries BEGIN
    INSERT INTO summaries_fts(rowid, request, investigated, learned, completed, next_steps, notes, decisions, gotchas, key_files)
    VALUES (new.id, new.request, new.investigated, new.learned, new.completed, new.next_steps, new.notes, new.decisions, new.gotchas, new.key_files);
END;

CREATE TRIGGER summaries_ad AFTER DELETE ON summaries BEGIN
    INSERT INTO summaries_fts(summaries_fts, rowid, request, investigated, learned, completed, next_steps, notes, decisions, gotchas, key_files)
    VALUES ('delete', old.id, old.request, old.investigated, old.learned, old.completed, old.next_steps, old.notes, old.decisions, old.gotchas, old.key_files);
END;

CREATE TRIGGER summaries_au AFTER UPDATE ON summaries BEGIN
    INSERT INTO summaries_fts(summaries_fts, rowid, request, investigated, learned, completed, next_steps, notes, decisions, gotchas, key_files)
    VALUES ('delete', old.id, old.request, old.investigated, old.learned, old.completed, old.next_steps, old.notes, old.decisions, old.gotchas, old.key_files);
    INSERT INTO summaries_fts(rowid, request, investigated, learned, completed, next_steps, notes, decisions, gotchas, key_files)
    VALUES (new.id, new.request, new.investigated, new.learned, new.completed, new.next_steps, new.notes, new.decisions, new.gotchas, new.key_files);
END;
