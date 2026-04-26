-- ═══════════════════════════════════════════════════════════
-- Eagle Mem — Migration 005: Claude Code memory mirror
-- Captures Claude Code auto-memory writes into Eagle Mem
-- ═══════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS claude_memories (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    project         TEXT NOT NULL,
    file_path       TEXT NOT NULL UNIQUE,
    memory_name     TEXT,
    description     TEXT,
    memory_type     TEXT,
    content         TEXT,
    content_hash    TEXT,
    origin_session_id TEXT,
    captured_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_claude_memories_project ON claude_memories(project);
CREATE INDEX IF NOT EXISTS idx_claude_memories_type ON claude_memories(memory_type);

-- FTS5 for searching across memory content
CREATE VIRTUAL TABLE IF NOT EXISTS claude_memories_fts USING fts5(
    memory_name,
    description,
    content,
    content='claude_memories',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS claude_memories_ai AFTER INSERT ON claude_memories BEGIN
    INSERT INTO claude_memories_fts(rowid, memory_name, description, content)
    VALUES (new.id, new.memory_name, new.description, new.content);
END;

CREATE TRIGGER IF NOT EXISTS claude_memories_ad AFTER DELETE ON claude_memories BEGIN
    INSERT INTO claude_memories_fts(claude_memories_fts, rowid, memory_name, description, content)
    VALUES ('delete', old.id, old.memory_name, old.description, old.content);
END;

CREATE TRIGGER IF NOT EXISTS claude_memories_au AFTER UPDATE ON claude_memories BEGIN
    INSERT INTO claude_memories_fts(claude_memories_fts, rowid, memory_name, description, content)
    VALUES ('delete', old.id, old.memory_name, old.description, old.content);
    INSERT INTO claude_memories_fts(rowid, memory_name, description, content)
    VALUES (new.id, new.memory_name, new.description, new.content);
END;
