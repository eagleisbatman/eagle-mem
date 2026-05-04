-- Migration 031: Worker execution metadata for orchestration lanes.
-- Keeps worker routing, worktree, process, and log state durable so Claude Code
-- and Codex can hand off lane execution safely.

ALTER TABLE orchestration_lanes ADD COLUMN branch_name TEXT;
ALTER TABLE orchestration_lanes ADD COLUMN worker_agent TEXT;
ALTER TABLE orchestration_lanes ADD COLUMN worker_model TEXT;
ALTER TABLE orchestration_lanes ADD COLUMN worker_effort TEXT;
ALTER TABLE orchestration_lanes ADD COLUMN worker_pid INTEGER;
ALTER TABLE orchestration_lanes ADD COLUMN worker_log_path TEXT;
ALTER TABLE orchestration_lanes ADD COLUMN worker_exit_path TEXT;
ALTER TABLE orchestration_lanes ADD COLUMN worker_prompt_path TEXT;
ALTER TABLE orchestration_lanes ADD COLUMN worker_command TEXT;
ALTER TABLE orchestration_lanes ADD COLUMN worker_started_at TEXT;
ALTER TABLE orchestration_lanes ADD COLUMN worker_finished_at TEXT;

CREATE INDEX IF NOT EXISTS idx_orchestration_lanes_worker_pid
    ON orchestration_lanes(worker_pid);
CREATE INDEX IF NOT EXISTS idx_orchestration_lanes_branch
    ON orchestration_lanes(branch_name);
