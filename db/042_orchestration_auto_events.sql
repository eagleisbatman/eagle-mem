-- Migration 042: Auto-orchestration detection events.
-- Records when hooks detect broad work and create durable lane/task state.

CREATE TABLE IF NOT EXISTS orchestration_auto_events (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id       TEXT,
    project          TEXT NOT NULL,
    cwd              TEXT,
    agent            TEXT,
    prompt_snippet   TEXT,
    trigger          TEXT NOT NULL DEFAULT 'broad_prompt',
    orchestration_id INTEGER REFERENCES orchestrations(id) ON DELETE SET NULL,
    orchestration_name TEXT NOT NULL DEFAULT 'auto',
    lanes            TEXT NOT NULL DEFAULT '[]',
    status           TEXT NOT NULL DEFAULT 'created',
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_orchestration_auto_events_project_created
ON orchestration_auto_events(project, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_orchestration_auto_events_session
ON orchestration_auto_events(session_id, created_at DESC);
