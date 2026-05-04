-- Migration 030: Scope orchestration lane identity to each orchestration.
-- Early 029 builds made lane_key unique per project, which allowed a lane
-- named "api" in one named orchestration to overwrite the same key in another.

DROP INDEX IF EXISTS idx_orchestration_lanes_orchestration;
DROP INDEX IF EXISTS idx_orchestration_lanes_project_status;
DROP INDEX IF EXISTS idx_orchestration_lanes_agent;

CREATE TABLE IF NOT EXISTS orchestration_lanes_new (
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

INSERT OR IGNORE INTO orchestration_lanes_new (
    id, orchestration_id, project, lane_key, title, description, agent,
    worktree_path, validation, status, source_task_id, notes, created_at, updated_at
)
SELECT
    id, orchestration_id, project, lane_key, title, description, agent,
    worktree_path, validation, status, source_task_id, notes, created_at, updated_at
FROM orchestration_lanes;

DROP TABLE orchestration_lanes;
ALTER TABLE orchestration_lanes_new RENAME TO orchestration_lanes;

CREATE INDEX IF NOT EXISTS idx_orchestration_lanes_orchestration
    ON orchestration_lanes(orchestration_id);
CREATE INDEX IF NOT EXISTS idx_orchestration_lanes_project_status
    ON orchestration_lanes(project, status);
CREATE INDEX IF NOT EXISTS idx_orchestration_lanes_agent
    ON orchestration_lanes(agent);

UPDATE orchestration_lanes
SET source_task_id = 'lane-' || (
        SELECT name FROM orchestrations WHERE orchestrations.id = orchestration_lanes.orchestration_id
    ) || '-' || lane_key
WHERE source_task_id IS NULL
   OR source_task_id = ''
   OR source_task_id = 'lane-' || lane_key;

UPDATE agent_tasks
SET source_task_id = (
        SELECT l.source_task_id
        FROM orchestration_lanes l
        JOIN orchestrations o ON o.id = l.orchestration_id
        WHERE l.project = agent_tasks.project
          AND (
              agent_tasks.file_path = 'orchestration-lane://' || l.project || '/' || l.lane_key
              OR agent_tasks.file_path = 'orchestration-lane://' || l.project || '/' || o.name || '/' || l.lane_key
          )
        LIMIT 1
    ),
    file_path = (
        SELECT 'orchestration-lane://' || l.project || '/' || o.name || '/' || l.lane_key
        FROM orchestration_lanes l
        JOIN orchestrations o ON o.id = l.orchestration_id
        WHERE l.project = agent_tasks.project
          AND (
              agent_tasks.file_path = 'orchestration-lane://' || l.project || '/' || l.lane_key
              OR agent_tasks.file_path = 'orchestration-lane://' || l.project || '/' || o.name || '/' || l.lane_key
          )
        LIMIT 1
    )
WHERE source_session_id = 'orchestration'
  AND EXISTS (
      SELECT 1
      FROM orchestration_lanes l
      JOIN orchestrations o ON o.id = l.orchestration_id
      WHERE l.project = agent_tasks.project
        AND (
            agent_tasks.file_path = 'orchestration-lane://' || l.project || '/' || l.lane_key
            OR agent_tasks.file_path = 'orchestration-lane://' || l.project || '/' || o.name || '/' || l.lane_key
        )
  );
