-- ═══════════════════════════════════════════════════════════
-- Migration 007: Claude Code task mirror
-- Mirrors TaskCreate/TaskUpdate artifacts from ~/.claude/tasks/
-- ═══════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS claude_tasks (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    project           TEXT NOT NULL DEFAULT '',
    source_session_id TEXT NOT NULL,
    source_task_id    TEXT NOT NULL,
    file_path         TEXT UNIQUE,
    subject           TEXT,
    description       TEXT,
    active_form       TEXT,
    status            TEXT NOT NULL DEFAULT 'pending',
    blocks            TEXT DEFAULT '[]',
    blocked_by        TEXT DEFAULT '[]',
    content_hash      TEXT,
    captured_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_claude_tasks_project ON claude_tasks(project);
CREATE INDEX IF NOT EXISTS idx_claude_tasks_session ON claude_tasks(source_session_id);
CREATE INDEX IF NOT EXISTS idx_claude_tasks_status ON claude_tasks(status);

-- FTS5 for full-text search on subject + description
CREATE VIRTUAL TABLE IF NOT EXISTS claude_tasks_fts USING fts5(
    subject,
    description,
    content='claude_tasks',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS claude_tasks_ai AFTER INSERT ON claude_tasks BEGIN
    INSERT INTO claude_tasks_fts(rowid, subject, description)
    VALUES (new.id, new.subject, new.description);
END;

CREATE TRIGGER IF NOT EXISTS claude_tasks_ad AFTER DELETE ON claude_tasks BEGIN
    INSERT INTO claude_tasks_fts(claude_tasks_fts, rowid, subject, description)
    VALUES ('delete', old.id, old.subject, old.description);
END;

CREATE TRIGGER IF NOT EXISTS claude_tasks_au AFTER UPDATE ON claude_tasks BEGIN
    INSERT INTO claude_tasks_fts(claude_tasks_fts, rowid, subject, description)
    VALUES ('delete', old.id, old.subject, old.description);
    INSERT INTO claude_tasks_fts(rowid, subject, description)
    VALUES (new.id, new.subject, new.description);
END;
