-- ═══════════════════════════════════════════════════════════
-- Eagle Mem — Migration 010: Session activity tracking
-- Adds last_activity_at for accurate stuck-session sweeping
-- ═══════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

ALTER TABLE sessions ADD COLUMN last_activity_at TEXT;

UPDATE sessions SET last_activity_at = COALESCE(ended_at, started_at);

CREATE TRIGGER IF NOT EXISTS observations_touch_session AFTER INSERT ON observations
BEGIN
    UPDATE sessions SET last_activity_at = NEW.created_at WHERE id = NEW.session_id;
END;
