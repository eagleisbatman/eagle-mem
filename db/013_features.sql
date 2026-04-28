-- Migration 013: Feature graph for deployment regression prevention
-- Features are persistent entities with lifecycle, dependencies, files, and smoke tests.
-- Auto-discovered by curator from accumulated session data (tasks, key_files, decisions).

CREATE TABLE IF NOT EXISTS features (
    id INTEGER PRIMARY KEY,
    project TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    status TEXT DEFAULT 'active',
    last_verified_at TIMESTAMP,
    last_verified_notes TEXT,
    created_at TIMESTAMP DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TIMESTAMP DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(project, name)
);

CREATE TABLE IF NOT EXISTS feature_dependencies (
    id INTEGER PRIMARY KEY,
    feature_id INTEGER NOT NULL,
    kind TEXT NOT NULL,
    target TEXT NOT NULL,
    name TEXT NOT NULL,
    notes TEXT,
    FOREIGN KEY (feature_id) REFERENCES features(id) ON DELETE CASCADE,
    UNIQUE(feature_id, kind, target, name)
);

CREATE TABLE IF NOT EXISTS feature_files (
    id INTEGER PRIMARY KEY,
    feature_id INTEGER NOT NULL,
    file_path TEXT NOT NULL,
    role TEXT,
    FOREIGN KEY (feature_id) REFERENCES features(id) ON DELETE CASCADE,
    UNIQUE(feature_id, file_path)
);

CREATE TABLE IF NOT EXISTS feature_smoke_tests (
    id INTEGER PRIMARY KEY,
    feature_id INTEGER NOT NULL,
    command TEXT NOT NULL,
    description TEXT,
    FOREIGN KEY (feature_id) REFERENCES features(id) ON DELETE CASCADE
);

-- FTS5 for feature search
CREATE VIRTUAL TABLE IF NOT EXISTS features_fts USING fts5(
    name,
    description,
    content='features',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS features_ai AFTER INSERT ON features BEGIN
    INSERT INTO features_fts(rowid, name, description)
    VALUES (new.id, new.name, new.description);
END;

CREATE TRIGGER IF NOT EXISTS features_ad AFTER DELETE ON features BEGIN
    INSERT INTO features_fts(features_fts, rowid, name, description)
    VALUES ('delete', old.id, old.name, old.description);
END;

CREATE TRIGGER IF NOT EXISTS features_au AFTER UPDATE ON features BEGIN
    INSERT INTO features_fts(features_fts, rowid, name, description)
    VALUES ('delete', old.id, old.name, old.description);
    INSERT INTO features_fts(rowid, name, description)
    VALUES (new.id, new.name, new.description);
END;
