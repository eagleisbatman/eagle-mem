-- Migration 028: Promote mirrored artifact tables from Claude-specific names
-- to agent-generic names. The original names were correct when Eagle Mem only
-- mirrored Claude Code artifacts; Codex support made the stored data model
-- multi-agent. Keep read-only legacy views so older ad-hoc SELECT queries do
-- not break immediately.

DROP TRIGGER IF EXISTS claude_memories_ai;
DROP TRIGGER IF EXISTS claude_memories_ad;
DROP TRIGGER IF EXISTS claude_memories_au;
DROP TRIGGER IF EXISTS claude_plans_ai;
DROP TRIGGER IF EXISTS claude_plans_ad;
DROP TRIGGER IF EXISTS claude_plans_au;
DROP TRIGGER IF EXISTS claude_tasks_ai;
DROP TRIGGER IF EXISTS claude_tasks_ad;
DROP TRIGGER IF EXISTS claude_tasks_au;

DROP TABLE IF EXISTS claude_memories_fts;
DROP TABLE IF EXISTS claude_plans_fts;
DROP TABLE IF EXISTS claude_tasks_fts;

ALTER TABLE claude_memories RENAME TO agent_memories;
ALTER TABLE claude_plans RENAME TO agent_plans;
ALTER TABLE claude_tasks RENAME TO agent_tasks;

DROP INDEX IF EXISTS idx_claude_memories_project;
DROP INDEX IF EXISTS idx_claude_memories_type;
DROP INDEX IF EXISTS idx_claude_memories_origin_agent;
DROP INDEX IF EXISTS idx_claude_plans_project;
DROP INDEX IF EXISTS idx_claude_plans_origin_agent;
DROP INDEX IF EXISTS idx_claude_tasks_project;
DROP INDEX IF EXISTS idx_claude_tasks_session;
DROP INDEX IF EXISTS idx_claude_tasks_status;
DROP INDEX IF EXISTS idx_claude_tasks_origin_agent;

CREATE INDEX IF NOT EXISTS idx_agent_memories_project ON agent_memories(project);
CREATE INDEX IF NOT EXISTS idx_agent_memories_type ON agent_memories(memory_type);
CREATE INDEX IF NOT EXISTS idx_agent_memories_origin_agent ON agent_memories(origin_agent);
CREATE INDEX IF NOT EXISTS idx_agent_plans_project ON agent_plans(project);
CREATE INDEX IF NOT EXISTS idx_agent_plans_origin_agent ON agent_plans(origin_agent);
CREATE INDEX IF NOT EXISTS idx_agent_tasks_project ON agent_tasks(project);
CREATE INDEX IF NOT EXISTS idx_agent_tasks_session ON agent_tasks(source_session_id);
CREATE INDEX IF NOT EXISTS idx_agent_tasks_status ON agent_tasks(status);
CREATE INDEX IF NOT EXISTS idx_agent_tasks_origin_agent ON agent_tasks(origin_agent);

CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts USING fts5(
    memory_name,
    description,
    content,
    content='agent_memories',
    content_rowid='id'
);

CREATE VIRTUAL TABLE IF NOT EXISTS agent_plans_fts USING fts5(
    title,
    content,
    content='agent_plans',
    content_rowid='id'
);

CREATE VIRTUAL TABLE IF NOT EXISTS agent_tasks_fts USING fts5(
    subject,
    description,
    content='agent_tasks',
    content_rowid='id'
);

INSERT INTO agent_memories_fts(agent_memories_fts) VALUES('rebuild');
INSERT INTO agent_plans_fts(agent_plans_fts) VALUES('rebuild');
INSERT INTO agent_tasks_fts(agent_tasks_fts) VALUES('rebuild');

CREATE TRIGGER IF NOT EXISTS agent_memories_ai AFTER INSERT ON agent_memories BEGIN
    INSERT INTO agent_memories_fts(rowid, memory_name, description, content)
    VALUES (new.id, new.memory_name, new.description, new.content);
END;

CREATE TRIGGER IF NOT EXISTS agent_memories_ad AFTER DELETE ON agent_memories BEGIN
    INSERT INTO agent_memories_fts(agent_memories_fts, rowid, memory_name, description, content)
    VALUES ('delete', old.id, old.memory_name, old.description, old.content);
END;

CREATE TRIGGER IF NOT EXISTS agent_memories_au AFTER UPDATE ON agent_memories BEGIN
    INSERT INTO agent_memories_fts(agent_memories_fts, rowid, memory_name, description, content)
    VALUES ('delete', old.id, old.memory_name, old.description, old.content);
    INSERT INTO agent_memories_fts(rowid, memory_name, description, content)
    VALUES (new.id, new.memory_name, new.description, new.content);
END;

CREATE TRIGGER IF NOT EXISTS agent_plans_ai AFTER INSERT ON agent_plans BEGIN
    INSERT INTO agent_plans_fts(rowid, title, content)
    VALUES (new.id, new.title, new.content);
END;

CREATE TRIGGER IF NOT EXISTS agent_plans_ad AFTER DELETE ON agent_plans BEGIN
    INSERT INTO agent_plans_fts(agent_plans_fts, rowid, title, content)
    VALUES ('delete', old.id, old.title, old.content);
END;

CREATE TRIGGER IF NOT EXISTS agent_plans_au AFTER UPDATE ON agent_plans BEGIN
    INSERT INTO agent_plans_fts(agent_plans_fts, rowid, title, content)
    VALUES ('delete', old.id, old.title, old.content);
    INSERT INTO agent_plans_fts(rowid, title, content)
    VALUES (new.id, new.title, new.content);
END;

CREATE TRIGGER IF NOT EXISTS agent_tasks_ai AFTER INSERT ON agent_tasks BEGIN
    INSERT INTO agent_tasks_fts(rowid, subject, description)
    VALUES (new.id, new.subject, new.description);
END;

CREATE TRIGGER IF NOT EXISTS agent_tasks_ad AFTER DELETE ON agent_tasks BEGIN
    INSERT INTO agent_tasks_fts(agent_tasks_fts, rowid, subject, description)
    VALUES ('delete', old.id, old.subject, old.description);
END;

CREATE TRIGGER IF NOT EXISTS agent_tasks_au AFTER UPDATE ON agent_tasks BEGIN
    INSERT INTO agent_tasks_fts(agent_tasks_fts, rowid, subject, description)
    VALUES ('delete', old.id, old.subject, old.description);
    INSERT INTO agent_tasks_fts(rowid, subject, description)
    VALUES (new.id, new.subject, new.description);
END;

CREATE VIEW IF NOT EXISTS claude_memories AS SELECT * FROM agent_memories;
CREATE VIEW IF NOT EXISTS claude_plans AS SELECT * FROM agent_plans;
CREATE VIEW IF NOT EXISTS claude_tasks AS SELECT * FROM agent_tasks;
