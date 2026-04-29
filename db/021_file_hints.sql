-- Migration 021: File hints — learned file access patterns from curator
-- Stores co-edit patterns, hot files, and other learned behaviors.

CREATE TABLE IF NOT EXISTS file_hints (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project TEXT NOT NULL,
    hint_type TEXT NOT NULL CHECK (hint_type IN ('co_edit', 'hot_file', 'read_threshold', 'session_profile')),
    file_path TEXT NOT NULL DEFAULT '',
    hint_value TEXT NOT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(project, hint_type, file_path)
);

CREATE INDEX IF NOT EXISTS idx_file_hints_lookup ON file_hints(project, hint_type, file_path);
