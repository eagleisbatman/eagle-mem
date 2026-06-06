CREATE TABLE IF NOT EXISTS recall_events (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id              TEXT,
    project                 TEXT NOT NULL,
    cwd                     TEXT,
    agent                   TEXT,
    hook_name               TEXT NOT NULL DEFAULT 'UserPromptSubmit',
    prompt_snippet          TEXT,
    fts_query               TEXT,
    summary_matches         INTEGER NOT NULL DEFAULT 0,
    memory_matches          INTEGER NOT NULL DEFAULT 0,
    code_matches            INTEGER NOT NULL DEFAULT 0,
    summary_refs            TEXT NOT NULL DEFAULT '[]',
    memory_refs             TEXT NOT NULL DEFAULT '[]',
    code_refs               TEXT NOT NULL DEFAULT '[]',
    injected_chars          INTEGER NOT NULL DEFAULT 0,
    injected_token_estimate INTEGER NOT NULL DEFAULT 0,
    status                  TEXT NOT NULL DEFAULT 'ok',
    error                   TEXT,
    created_at              TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_recall_events_project_created
ON recall_events(project, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_recall_events_session
ON recall_events(session_id, created_at DESC);
