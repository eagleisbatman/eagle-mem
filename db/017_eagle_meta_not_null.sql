-- Fix: UNIQUE(key, project) fails with NULL project (each NULL is unique in SQL).
-- Change project to NOT NULL DEFAULT '' so ON CONFLICT works for global keys.
CREATE TABLE IF NOT EXISTS eagle_meta_new (
    key TEXT NOT NULL,
    project TEXT NOT NULL DEFAULT '',
    value TEXT NOT NULL,
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(key, project)
);

INSERT OR REPLACE INTO eagle_meta_new (key, project, value, updated_at)
SELECT key, COALESCE(project, ''), value, updated_at FROM eagle_meta;

DROP TABLE eagle_meta;
ALTER TABLE eagle_meta_new RENAME TO eagle_meta;
