-- Migration 033: Make FTS triggers safe for project-key repairs.
--
-- SQLite FTS5 external-content tables can throw unsafe virtual-table errors
-- when UPDATE triggers try to delete/reinsert FTS rows during metadata-only
-- repairs. Project rekeys do not change searchable text, so the FTS UPDATE
-- triggers should only run when indexed columns change.

DROP TRIGGER IF EXISTS summaries_au;
DROP TRIGGER IF EXISTS chunks_au;
DROP TRIGGER IF EXISTS agent_memories_au;
DROP TRIGGER IF EXISTS agent_plans_au;
DROP TRIGGER IF EXISTS agent_tasks_au;

CREATE TRIGGER summaries_au
AFTER UPDATE OF request, investigated, learned, completed, next_steps, notes, decisions, gotchas, key_files ON summaries
BEGIN
    INSERT INTO summaries_fts(summaries_fts, rowid, request, investigated, learned, completed, next_steps, notes, decisions, gotchas, key_files)
    VALUES ('delete', old.id, old.request, old.investigated, old.learned, old.completed, old.next_steps, old.notes, old.decisions, old.gotchas, old.key_files);
    INSERT INTO summaries_fts(rowid, request, investigated, learned, completed, next_steps, notes, decisions, gotchas, key_files)
    VALUES (new.id, new.request, new.investigated, new.learned, new.completed, new.next_steps, new.notes, new.decisions, new.gotchas, new.key_files);
END;

CREATE TRIGGER chunks_au
AFTER UPDATE OF file_path, content ON code_chunks
BEGIN
    INSERT INTO code_chunks_fts(code_chunks_fts, rowid, file_path, content)
    VALUES ('delete', old.id, old.file_path, old.content);
    INSERT INTO code_chunks_fts(rowid, file_path, content)
    VALUES (new.id, new.file_path, new.content);
END;

CREATE TRIGGER agent_memories_au
AFTER UPDATE OF memory_name, description, content ON agent_memories
BEGIN
    INSERT INTO agent_memories_fts(agent_memories_fts, rowid, memory_name, description, content)
    VALUES ('delete', old.id, old.memory_name, old.description, old.content);
    INSERT INTO agent_memories_fts(rowid, memory_name, description, content)
    VALUES (new.id, new.memory_name, new.description, new.content);
END;

CREATE TRIGGER agent_plans_au
AFTER UPDATE OF title, content ON agent_plans
BEGIN
    INSERT INTO agent_plans_fts(agent_plans_fts, rowid, title, content)
    VALUES ('delete', old.id, old.title, old.content);
    INSERT INTO agent_plans_fts(rowid, title, content)
    VALUES (new.id, new.title, new.content);
END;

CREATE TRIGGER agent_tasks_au
AFTER UPDATE OF subject, description ON agent_tasks
BEGIN
    INSERT INTO agent_tasks_fts(agent_tasks_fts, rowid, subject, description)
    VALUES ('delete', old.id, old.subject, old.description);
    INSERT INTO agent_tasks_fts(rowid, subject, description)
    VALUES (new.id, new.subject, new.description);
END;
