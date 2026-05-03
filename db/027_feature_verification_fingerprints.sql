-- Migration 027: Diff-fingerprint feature verification
-- Verification must attach to the current repository change, not only to a
-- feature/file pair. This prevents release hooks from reopening already
-- verified rows when the diff has not changed.

ALTER TABLE pending_feature_verifications ADD COLUMN change_fingerprint TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_pending_feature_verifications_fingerprint
    ON pending_feature_verifications(project, feature_id, file_path, change_fingerprint, status);
