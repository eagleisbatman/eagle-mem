-- Eagle meta key-value store for system state (curator timestamps, etc.)
CREATE TABLE IF NOT EXISTS eagle_meta (
    key TEXT NOT NULL,
    project TEXT,
    value TEXT NOT NULL,
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(key, project)
);
