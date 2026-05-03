-- Migration 026: Multi-agent source attribution
-- Eagle Mem is shared by Claude Code and Codex. Keep lifecycle source
-- (startup/resume/clear) separate from the agent that wrote each row.

ALTER TABLE sessions ADD COLUMN agent TEXT NOT NULL DEFAULT 'claude-code';
ALTER TABLE observations ADD COLUMN agent TEXT NOT NULL DEFAULT 'claude-code';
ALTER TABLE summaries ADD COLUMN agent TEXT NOT NULL DEFAULT 'claude-code';

ALTER TABLE claude_memories ADD COLUMN origin_agent TEXT NOT NULL DEFAULT 'claude-code';
ALTER TABLE claude_plans ADD COLUMN origin_agent TEXT NOT NULL DEFAULT 'claude-code';
ALTER TABLE claude_tasks ADD COLUMN origin_agent TEXT NOT NULL DEFAULT 'claude-code';

CREATE INDEX IF NOT EXISTS idx_sessions_agent ON sessions(agent);
CREATE INDEX IF NOT EXISTS idx_observations_agent ON observations(agent);
CREATE INDEX IF NOT EXISTS idx_summaries_agent ON summaries(agent);
CREATE INDEX IF NOT EXISTS idx_claude_memories_origin_agent ON claude_memories(origin_agent);
CREATE INDEX IF NOT EXISTS idx_claude_plans_origin_agent ON claude_plans(origin_agent);
CREATE INDEX IF NOT EXISTS idx_claude_tasks_origin_agent ON claude_tasks(origin_agent);
