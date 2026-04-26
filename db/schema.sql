-- ═══════════════════════════════════════════════════════════
-- Eagle Mem — Schema v1
-- Single shared SQLite database at ~/.eagle-mem/memory.db
-- ═══════════════════════════════════════════════════════════

-- NOTE: PRAGMAs are connection-scoped and do NOT persist.
-- These only apply during migration. Runtime PRAGMAs are set
-- in lib/db.sh EAGLE_DB_SETUP on every connection.
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA temp_store = memory;

-- ─── Migration tracking ────────────────────────────────────

CREATE TABLE IF NOT EXISTS _migrations (
    id         INTEGER PRIMARY KEY,
    name       TEXT    NOT NULL UNIQUE,
    applied_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- ─── Sessions ──────────────────────────────────────────────
-- Sessions are parent rows for summaries, tasks, and observations (FK).
-- Never delete sessions — prune children instead.

CREATE TABLE IF NOT EXISTS sessions (
    id              TEXT PRIMARY KEY,
    project         TEXT NOT NULL,
    cwd             TEXT,
    model           TEXT,
    source          TEXT,
    started_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    ended_at        TEXT,
    status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed', 'abandoned'))
);

CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);

-- ─── Observations ──────────────────────────────────────────
-- Lightweight per-tool-use records: what files were touched

CREATE TABLE IF NOT EXISTS observations (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL REFERENCES sessions(id),
    project         TEXT NOT NULL,
    tool_name       TEXT NOT NULL,
    tool_input_summary TEXT,
    files_read      TEXT DEFAULT '[]',
    files_modified  TEXT DEFAULT '[]',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_observations_session ON observations(session_id);
CREATE INDEX IF NOT EXISTS idx_observations_project ON observations(project);

-- ─── Summaries ─────────────────────────────────────────────
-- Per-session summaries: what was accomplished

CREATE TABLE IF NOT EXISTS summaries (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL REFERENCES sessions(id),
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

CREATE INDEX IF NOT EXISTS idx_summaries_session ON summaries(session_id);
CREATE INDEX IF NOT EXISTS idx_summaries_project ON summaries(project);

-- ─── Tasks (TaskAware Compact Loop) ───────────────────────
-- Subtasks for multi-step work with compaction between each

CREATE TABLE IF NOT EXISTS tasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    project         TEXT NOT NULL,
    session_id      TEXT REFERENCES sessions(id),
    parent_id       INTEGER REFERENCES tasks(id),
    title           TEXT NOT NULL,
    instructions    TEXT,
    context_snapshot TEXT,
    status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'done', 'blocked', 'cancelled')),
    ordinal         INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    started_at      TEXT,
    completed_at    TEXT
);

CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_id);

-- ─── FTS5: Full-text search on summaries ───────────────────

CREATE VIRTUAL TABLE IF NOT EXISTS summaries_fts USING fts5(
    request,
    investigated,
    learned,
    completed,
    next_steps,
    notes,
    content='summaries',
    content_rowid='id'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS summaries_ai AFTER INSERT ON summaries BEGIN
    INSERT INTO summaries_fts(rowid, request, investigated, learned, completed, next_steps, notes)
    VALUES (new.id, new.request, new.investigated, new.learned, new.completed, new.next_steps, new.notes);
END;

CREATE TRIGGER IF NOT EXISTS summaries_ad AFTER DELETE ON summaries BEGIN
    INSERT INTO summaries_fts(summaries_fts, rowid, request, investigated, learned, completed, next_steps, notes)
    VALUES ('delete', old.id, old.request, old.investigated, old.learned, old.completed, old.next_steps, old.notes);
END;

CREATE TRIGGER IF NOT EXISTS summaries_au AFTER UPDATE ON summaries BEGIN
    INSERT INTO summaries_fts(summaries_fts, rowid, request, investigated, learned, completed, next_steps, notes)
    VALUES ('delete', old.id, old.request, old.investigated, old.learned, old.completed, old.next_steps, old.notes);
    INSERT INTO summaries_fts(rowid, request, investigated, learned, completed, next_steps, notes)
    VALUES (new.id, new.request, new.investigated, new.learned, new.completed, new.next_steps, new.notes);
END;

-- ─── FTS5: Full-text search on tasks ──────────────────────

CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5(
    title,
    instructions,
    context_snapshot,
    content='tasks',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS tasks_ai AFTER INSERT ON tasks BEGIN
    INSERT INTO tasks_fts(rowid, title, instructions, context_snapshot)
    VALUES (new.id, new.title, new.instructions, new.context_snapshot);
END;

CREATE TRIGGER IF NOT EXISTS tasks_ad AFTER DELETE ON tasks BEGIN
    INSERT INTO tasks_fts(tasks_fts, rowid, title, instructions, context_snapshot)
    VALUES ('delete', old.id, old.title, old.instructions, old.context_snapshot);
END;

CREATE TRIGGER IF NOT EXISTS tasks_au AFTER UPDATE ON tasks BEGIN
    INSERT INTO tasks_fts(tasks_fts, rowid, title, instructions, context_snapshot)
    VALUES ('delete', old.id, old.title, old.instructions, old.context_snapshot);
    INSERT INTO tasks_fts(rowid, title, instructions, context_snapshot)
    VALUES (new.id, new.title, new.instructions, new.context_snapshot);
END;
