-- Migration 015: Data integrity fixes
-- 1. Add CHECK constraints for status fields (claude_tasks, features, command_rules)
-- 2. Add UNIQUE constraint to feature_smoke_tests to prevent duplicates
-- 3. Deduplicate any existing smoke test rows before adding constraint

-- ─── 1. CHECK constraints via table rebuild ──────────────────

-- claude_tasks: enforce status values
CREATE TABLE claude_tasks_new (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    project           TEXT NOT NULL DEFAULT '',
    source_session_id TEXT NOT NULL,
    source_task_id    TEXT NOT NULL,
    file_path         TEXT UNIQUE,
    subject           TEXT,
    description       TEXT,
    active_form       TEXT,
    status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'in_progress', 'completed', 'cancelled')),
    blocks            TEXT DEFAULT '[]',
    blocked_by        TEXT DEFAULT '[]',
    content_hash      TEXT,
    captured_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

INSERT INTO claude_tasks_new SELECT * FROM claude_tasks;
DROP TABLE claude_tasks;
ALTER TABLE claude_tasks_new RENAME TO claude_tasks;

CREATE INDEX IF NOT EXISTS idx_claude_tasks_project ON claude_tasks(project);
CREATE INDEX IF NOT EXISTS idx_claude_tasks_session ON claude_tasks(source_session_id);
CREATE INDEX IF NOT EXISTS idx_claude_tasks_status ON claude_tasks(status);

-- Recreate FTS triggers (dropped with table)
CREATE TRIGGER claude_tasks_ai AFTER INSERT ON claude_tasks BEGIN
    INSERT INTO claude_tasks_fts(rowid, subject, description)
    VALUES (new.id, new.subject, new.description);
END;

CREATE TRIGGER claude_tasks_ad AFTER DELETE ON claude_tasks BEGIN
    INSERT INTO claude_tasks_fts(claude_tasks_fts, rowid, subject, description)
    VALUES ('delete', old.id, old.subject, old.description);
END;

CREATE TRIGGER claude_tasks_au AFTER UPDATE ON claude_tasks BEGIN
    INSERT INTO claude_tasks_fts(claude_tasks_fts, rowid, subject, description)
    VALUES ('delete', old.id, old.subject, old.description);
    INSERT INTO claude_tasks_fts(rowid, subject, description)
    VALUES (new.id, new.subject, new.description);
END;

-- features: enforce status values
CREATE TABLE features_new (
    id INTEGER PRIMARY KEY,
    project TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'archived', 'deprecated')),
    last_verified_at TIMESTAMP,
    last_verified_notes TEXT,
    created_at TIMESTAMP DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TIMESTAMP DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(project, name)
);

INSERT INTO features_new SELECT * FROM features;
DROP TABLE features;
ALTER TABLE features_new RENAME TO features;

-- Recreate FTS triggers for features (dropped with table)
CREATE TRIGGER features_ai AFTER INSERT ON features BEGIN
    INSERT INTO features_fts(rowid, name, description)
    VALUES (new.id, new.name, new.description);
END;

CREATE TRIGGER features_ad AFTER DELETE ON features BEGIN
    INSERT INTO features_fts(features_fts, rowid, name, description)
    VALUES ('delete', old.id, old.name, old.description);
END;

CREATE TRIGGER features_au AFTER UPDATE ON features BEGIN
    INSERT INTO features_fts(features_fts, rowid, name, description)
    VALUES ('delete', old.id, old.name, old.description);
    INSERT INTO features_fts(rowid, name, description)
    VALUES (new.id, new.name, new.description);
END;

-- Rebuild child tables with CASCADE FKs (they reference features.id)
-- feature_dependencies: recreate to pick up new parent table
CREATE TABLE feature_dependencies_new (
    id INTEGER PRIMARY KEY,
    feature_id INTEGER NOT NULL,
    kind TEXT NOT NULL,
    target TEXT NOT NULL,
    name TEXT NOT NULL,
    notes TEXT,
    FOREIGN KEY (feature_id) REFERENCES features(id) ON DELETE CASCADE,
    UNIQUE(feature_id, kind, target, name)
);
INSERT INTO feature_dependencies_new SELECT * FROM feature_dependencies;
DROP TABLE feature_dependencies;
ALTER TABLE feature_dependencies_new RENAME TO feature_dependencies;

-- feature_files: recreate to pick up new parent table
CREATE TABLE feature_files_new (
    id INTEGER PRIMARY KEY,
    feature_id INTEGER NOT NULL,
    file_path TEXT NOT NULL,
    role TEXT,
    FOREIGN KEY (feature_id) REFERENCES features(id) ON DELETE CASCADE,
    UNIQUE(feature_id, file_path)
);
INSERT INTO feature_files_new SELECT * FROM feature_files;
DROP TABLE feature_files;
ALTER TABLE feature_files_new RENAME TO feature_files;

-- ─── 2. feature_smoke_tests: deduplicate + add UNIQUE constraint ──

-- Remove duplicates, keeping the row with the lowest id per (feature_id, command)
DELETE FROM feature_smoke_tests WHERE id NOT IN (
    SELECT MIN(id) FROM feature_smoke_tests GROUP BY feature_id, command
);

CREATE TABLE feature_smoke_tests_new (
    id INTEGER PRIMARY KEY,
    feature_id INTEGER NOT NULL,
    command TEXT NOT NULL,
    description TEXT,
    FOREIGN KEY (feature_id) REFERENCES features(id) ON DELETE CASCADE,
    UNIQUE(feature_id, command)
);
INSERT INTO feature_smoke_tests_new SELECT * FROM feature_smoke_tests;
DROP TABLE feature_smoke_tests;
ALTER TABLE feature_smoke_tests_new RENAME TO feature_smoke_tests;

-- ─── 3. command_rules: add CHECK on strategy ─────────────────

CREATE TABLE command_rules_new (
    id INTEGER PRIMARY KEY,
    project TEXT,
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
INSERT INTO command_rules_new SELECT * FROM command_rules;
DROP TABLE command_rules;
ALTER TABLE command_rules_new RENAME TO command_rules;

CREATE INDEX IF NOT EXISTS idx_command_rules_pattern ON command_rules(pattern);
