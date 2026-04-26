-- ═══════════════════════════════════════════════════════════
-- Migration 009: Drop dead tasks table
-- The original tasks table (from schema.sql / migration 001)
-- was replaced by claude_tasks (migration 007). No code
-- references the old table. This cleans up the vestigial
-- schema: 3 FTS triggers, the FTS virtual table, 3 indexes,
-- and the table itself.
--
-- NOTE: schema.sql (migration 001) still contains the CREATE
-- TABLE tasks definition. We do NOT edit applied migrations.
-- Fresh installs will CREATE (001) then DROP (009). Existing
-- installs just run 009. Verified 0 rows in production.
-- ═══════════════════════════════════════════════════════════

-- Drop FTS sync triggers first (they reference the tasks table)
DROP TRIGGER IF EXISTS tasks_ai;
DROP TRIGGER IF EXISTS tasks_ad;
DROP TRIGGER IF EXISTS tasks_au;

-- Drop the FTS virtual table
DROP TABLE IF EXISTS tasks_fts;

-- Drop indexes (implicit in DROP TABLE, but explicit for clarity)
DROP INDEX IF EXISTS idx_tasks_project;
DROP INDEX IF EXISTS idx_tasks_status;
DROP INDEX IF EXISTS idx_tasks_parent;

-- Drop the dead tasks table
DROP TABLE IF EXISTS tasks;
