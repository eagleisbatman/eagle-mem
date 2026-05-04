-- Migration 029: Orchestrator/worker lane tracking.
-- Stores durable multi-agent work plans so Claude Code and Codex can share
-- lane ownership, status, validation commands, and handoff context.

CREATE TABLE IF NOT EXISTS orchestrations (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    project      TEXT NOT NULL,
    name         TEXT NOT NULL,
    goal         TEXT,
    status       TEXT NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active', 'completed', 'cancelled')),
    baseline_ref TEXT,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(project, name)
);

CREATE INDEX IF NOT EXISTS idx_orchestrations_project_status
    ON orchestrations(project, status);

CREATE TABLE IF NOT EXISTS orchestration_lanes (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    orchestration_id INTEGER NOT NULL REFERENCES orchestrations(id) ON DELETE CASCADE,
    project          TEXT NOT NULL,
    lane_key         TEXT NOT NULL,
    title            TEXT NOT NULL,
    description      TEXT,
    agent            TEXT NOT NULL DEFAULT 'codex',
    worktree_path    TEXT,
    validation       TEXT,
    status           TEXT NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'in_progress', 'blocked', 'completed', 'cancelled')),
    source_task_id   TEXT,
    notes            TEXT,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(orchestration_id, lane_key)
);

CREATE INDEX IF NOT EXISTS idx_orchestration_lanes_orchestration
    ON orchestration_lanes(orchestration_id);
CREATE INDEX IF NOT EXISTS idx_orchestration_lanes_project_status
    ON orchestration_lanes(project, status);
CREATE INDEX IF NOT EXISTS idx_orchestration_lanes_agent
    ON orchestration_lanes(agent);
