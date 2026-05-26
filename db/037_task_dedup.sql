-- ═══════════════════════════════════════════════════════════
-- Migration 037: Deduplicate agent tasks
-- Deletes duplicate task entries keeping the latest one
-- and sets up a partial unique index on project + source_task_id.
-- ═══════════════════════════════════════════════════════════

-- Delete duplicate tasks, keeping the most recent (highest ID)
DELETE FROM agent_tasks
WHERE source_task_id IS NOT NULL AND source_task_id != ''
  AND id NOT IN (
      SELECT MAX(id)
      FROM agent_tasks
      WHERE source_task_id IS NOT NULL AND source_task_id != ''
      GROUP BY project, source_task_id
  );

-- Create partial unique index to guarantee no duplicates for valid source task IDs
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_tasks_dedup
    ON agent_tasks(project, source_task_id)
    WHERE source_task_id IS NOT NULL AND source_task_id != '';
