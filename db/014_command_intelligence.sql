-- Migration 014: Command intelligence — output size tracking + command rules
-- Adds output metrics to observations for adaptive command filtering.

ALTER TABLE observations ADD COLUMN output_bytes INTEGER;
ALTER TABLE observations ADD COLUMN output_lines INTEGER;
ALTER TABLE observations ADD COLUMN command_category TEXT;

-- Command rules table — populated by curator, consumed by PreToolUse hook
CREATE TABLE IF NOT EXISTS command_rules (
    id INTEGER PRIMARY KEY,
    project TEXT,
    pattern TEXT NOT NULL,
    strategy TEXT NOT NULL DEFAULT 'summary',
    max_lines INTEGER,
    reason TEXT,
    times_seen INTEGER DEFAULT 0,
    avg_output_bytes INTEGER DEFAULT 0,
    enabled INTEGER DEFAULT 1,
    created_at TIMESTAMP DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TIMESTAMP DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(project, pattern)
);

CREATE INDEX IF NOT EXISTS idx_command_rules_pattern ON command_rules(pattern);
CREATE INDEX IF NOT EXISTS idx_observations_category ON observations(command_category);
