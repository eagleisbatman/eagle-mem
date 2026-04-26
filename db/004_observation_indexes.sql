-- ═══════════════════════════════════════════════════════════
-- Eagle Mem — Migration 004: Observation indexes
-- Adds created_at index for efficient pruning and time-bound queries
-- ═══════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

CREATE INDEX IF NOT EXISTS idx_observations_created_at ON observations(created_at);
CREATE INDEX IF NOT EXISTS idx_sessions_ended_at ON sessions(status, ended_at);
