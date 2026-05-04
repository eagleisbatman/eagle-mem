-- Migration 032: Stable run identity for reusable orchestration names.
-- A project may reuse the default orchestration name ("main") for multiple
-- goals, so worker branches and worktrees need a per-run key.

ALTER TABLE orchestrations ADD COLUMN run_key TEXT;

UPDATE orchestrations
SET run_key = 'r' || id
WHERE run_key IS NULL OR run_key = '';
