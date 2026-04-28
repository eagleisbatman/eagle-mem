-- Fix: command_rules.project has same NULL uniqueness flaw as eagle_meta had.
-- Change to NOT NULL DEFAULT '' for consistent UNIQUE constraint behavior.
CREATE TABLE IF NOT EXISTS command_rules_new (
    id INTEGER PRIMARY KEY,
    project TEXT NOT NULL DEFAULT '',
    pattern TEXT NOT NULL,
    strategy TEXT NOT NULL DEFAULT 'summary' CHECK (strategy IN ('summary', 'truncate')),
    max_lines INTEGER,
    reason TEXT,
    times_seen INTEGER DEFAULT 0,
    avg_output_bytes INTEGER DEFAULT 0,
    enabled INTEGER DEFAULT 1,
    created_at TIMESTAMP DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TIMESTAMP DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(project, pattern)
);

INSERT OR REPLACE INTO command_rules_new (id, project, pattern, strategy, max_lines, reason, times_seen, avg_output_bytes, enabled, created_at, updated_at)
SELECT id, COALESCE(project, ''), pattern, strategy, max_lines, reason, times_seen, avg_output_bytes, enabled, created_at, updated_at FROM command_rules;

DROP TABLE command_rules;
ALTER TABLE command_rules_new RENAME TO command_rules;
CREATE INDEX IF NOT EXISTS idx_command_rules_pattern ON command_rules(pattern);
