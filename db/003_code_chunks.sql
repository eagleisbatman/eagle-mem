-- ═══════════════════════════════════════════════════════════
-- Eagle Mem — Migration 003: Code chunks for source indexing
-- FTS5 searchable chunks of source files
-- ═══════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS code_chunks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    project     TEXT NOT NULL,
    file_path   TEXT NOT NULL,
    language    TEXT,
    start_line  INTEGER NOT NULL,
    end_line    INTEGER NOT NULL,
    content     TEXT NOT NULL,
    mtime       INTEGER NOT NULL,
    indexed_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_chunks_project ON code_chunks(project);
CREATE INDEX IF NOT EXISTS idx_chunks_file ON code_chunks(project, file_path);

-- FTS5 for searching code content
CREATE VIRTUAL TABLE IF NOT EXISTS code_chunks_fts USING fts5(
    file_path,
    content,
    content='code_chunks',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON code_chunks BEGIN
    INSERT INTO code_chunks_fts(rowid, file_path, content)
    VALUES (new.id, new.file_path, new.content);
END;

CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON code_chunks BEGIN
    INSERT INTO code_chunks_fts(code_chunks_fts, rowid, file_path, content)
    VALUES ('delete', old.id, old.file_path, old.content);
END;

CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON code_chunks BEGIN
    INSERT INTO code_chunks_fts(code_chunks_fts, rowid, file_path, content)
    VALUES ('delete', old.id, old.file_path, old.content);
    INSERT INTO code_chunks_fts(rowid, file_path, content)
    VALUES (new.id, new.file_path, new.content);
END;
