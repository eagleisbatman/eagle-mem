-- ═══════════════════════════════════════════════════════════
-- Eagle Mem — Migration 006: Claude Code plan mirror
-- Captures Claude Code plan documents into Eagle Mem
-- ═══════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS claude_plans (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    project         TEXT NOT NULL DEFAULT '',
    file_path       TEXT NOT NULL UNIQUE,
    title           TEXT,
    content         TEXT,
    content_hash    TEXT,
    origin_session_id TEXT,
    captured_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_claude_plans_project ON claude_plans(project);

-- FTS5 for searching across plan content
CREATE VIRTUAL TABLE IF NOT EXISTS claude_plans_fts USING fts5(
    title,
    content,
    content='claude_plans',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS claude_plans_ai AFTER INSERT ON claude_plans BEGIN
    INSERT INTO claude_plans_fts(rowid, title, content)
    VALUES (new.id, new.title, new.content);
END;

CREATE TRIGGER IF NOT EXISTS claude_plans_ad AFTER DELETE ON claude_plans BEGIN
    INSERT INTO claude_plans_fts(claude_plans_fts, rowid, title, content)
    VALUES ('delete', old.id, old.title, old.content);
END;

CREATE TRIGGER IF NOT EXISTS claude_plans_au
AFTER UPDATE OF title, content ON claude_plans
BEGIN
    INSERT INTO claude_plans_fts(claude_plans_fts, rowid, title, content)
    VALUES ('delete', old.id, old.title, old.content);
    INSERT INTO claude_plans_fts(rowid, title, content)
    VALUES (new.id, new.title, new.content);
END;
