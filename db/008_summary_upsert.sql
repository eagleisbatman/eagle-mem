-- Migration 008: Enforce one summary per session
-- Removes duplicate summaries (keeps the latest) and adds UNIQUE constraint.
-- Recreates FTS triggers since DROP TABLE removes them.

-- Delete duplicates, keeping only the row with the highest id per session
DELETE FROM summaries WHERE id NOT IN (
    SELECT MAX(id) FROM summaries GROUP BY session_id
);

-- Rebuild FTS index to match cleaned data
INSERT INTO summaries_fts(summaries_fts) VALUES('rebuild');

-- Drop old triggers (they'll be gone after table rebuild anyway)
DROP TRIGGER IF EXISTS summaries_ai;
DROP TRIGGER IF EXISTS summaries_ad;
DROP TRIGGER IF EXISTS summaries_au;

-- Recreate table with UNIQUE(session_id)
CREATE TABLE summaries_new (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL UNIQUE REFERENCES sessions(id),
    project         TEXT NOT NULL,
    request         TEXT,
    investigated    TEXT,
    learned         TEXT,
    completed       TEXT,
    next_steps      TEXT,
    files_read      TEXT DEFAULT '[]',
    files_modified  TEXT DEFAULT '[]',
    notes           TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

INSERT INTO summaries_new SELECT * FROM summaries;
DROP TABLE summaries;
ALTER TABLE summaries_new RENAME TO summaries;

CREATE INDEX IF NOT EXISTS idx_summaries_session ON summaries(session_id);
CREATE INDEX IF NOT EXISTS idx_summaries_project ON summaries(project);

-- Recreate FTS content-sync triggers
CREATE TRIGGER summaries_ai AFTER INSERT ON summaries BEGIN
    INSERT INTO summaries_fts(rowid, request, investigated, learned, completed, next_steps, notes)
    VALUES (new.id, new.request, new.investigated, new.learned, new.completed, new.next_steps, new.notes);
END;

CREATE TRIGGER summaries_ad AFTER DELETE ON summaries BEGIN
    INSERT INTO summaries_fts(summaries_fts, rowid, request, investigated, learned, completed, next_steps, notes)
    VALUES ('delete', old.id, old.request, old.investigated, old.learned, old.completed, old.next_steps, old.notes);
END;

CREATE TRIGGER summaries_au
AFTER UPDATE OF request, investigated, learned, completed, next_steps, notes ON summaries
BEGIN
    INSERT INTO summaries_fts(summaries_fts, rowid, request, investigated, learned, completed, next_steps, notes)
    VALUES ('delete', old.id, old.request, old.investigated, old.learned, old.completed, old.next_steps, old.notes);
    INSERT INTO summaries_fts(rowid, request, investigated, learned, completed, next_steps, notes)
    VALUES (new.id, new.request, new.investigated, new.learned, new.completed, new.next_steps, new.notes);
END;
