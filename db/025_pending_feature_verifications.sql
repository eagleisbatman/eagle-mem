-- Migration 025: Enforced anti-regression verification state
-- Hooks record affected features here after edits. Release-boundary commands
-- are blocked while pending rows remain for the project.

CREATE TABLE IF NOT EXISTS pending_feature_verifications (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    project           TEXT NOT NULL,
    feature_id        INTEGER NOT NULL,
    feature_name      TEXT NOT NULL,
    file_path         TEXT NOT NULL DEFAULT '',
    reason            TEXT NOT NULL DEFAULT '',
    source_session_id TEXT,
    trigger_tool      TEXT,
    status            TEXT NOT NULL DEFAULT 'pending',
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    resolved_at       TEXT,
    notes             TEXT,
    FOREIGN KEY (feature_id) REFERENCES features(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pending_feature_verifications_open
    ON pending_feature_verifications(project, feature_id, file_path)
    WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_pending_feature_verifications_project
    ON pending_feature_verifications(project, status, updated_at);

CREATE INDEX IF NOT EXISTS idx_pending_feature_verifications_feature
    ON pending_feature_verifications(feature_id, status);
