CREATE TABLE IF NOT EXISTS eagle_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    project         TEXT,
    session_id      TEXT,
    agent           TEXT,
    event_type      TEXT NOT NULL,
    command         TEXT,
    hook_event_name TEXT,
    status          TEXT NOT NULL DEFAULT 'ok',
    detail_json     TEXT NOT NULL DEFAULT '{}',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_eagle_events_project_created
ON eagle_events(project, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_eagle_events_session_created
ON eagle_events(session_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_eagle_events_type_created
ON eagle_events(event_type, created_at DESC);

