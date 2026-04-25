---
name: eagle-mem-tasks
description: >
  TaskAware Compact Loop — break complex work into database-tracked subtasks with compaction
  between each. Use when: 'eagle tasks', 'break this into tasks', 'create task plan',
  'task loop', 'compact loop', 'eagle mem tasks'. Prevents context bloat and hallucination
  by executing one task at a time with memory re-injection after each /compact.
---

# Eagle Mem — TaskAware Compact Loop

Break complex work into subtasks stored in Eagle Mem's database. Execute one task at a time, compact between each, and let Eagle Mem re-inject context for the next task.

## How it works

1. **Plan**: Break the user's request into ordered subtasks
2. **Store**: Write each subtask to the Eagle Mem database
3. **Execute**: Work on the current task (marked `[ACTIVE]`)
4. **Compact**: When done, tell the user to run `/compact`
5. **Resume**: After compact, SessionStart re-injects memory + loads the next task
6. **Repeat**: Until all tasks are done

## Commands

### Creating tasks

When the user invokes `/eagle-mem-tasks` or asks to break work into tasks:

1. Analyze the request and break it into 3-8 focused subtasks
2. Each task should be completable in one context window (~50-100K tokens of work)
3. Write tasks to the database using this pattern:

```bash
~/.eagle-mem/db/task-ops.sh add "<project>" "<title>" "<instructions>" <ordinal>
```

If `task-ops.sh` doesn't exist yet, write directly:

```bash
sqlite3 ~/.eagle-mem/memory.db "
PRAGMA trusted_schema=ON;
INSERT INTO tasks (project, title, instructions, ordinal)
VALUES ('<project>', '<title>', '<instructions>', <ordinal>);
"
```

4. Show the task plan to the user for confirmation
5. After confirmation, start working on task #1

### Viewing tasks

```bash
sqlite3 ~/.eagle-mem/memory.db "
SELECT id, title, status, ordinal FROM tasks
WHERE project = '<project>'
ORDER BY ordinal ASC, id ASC;
"
```

### Completing a task

When the current task is done:

1. Mark it complete:
```bash
sqlite3 ~/.eagle-mem/memory.db "
PRAGMA trusted_schema=ON;
UPDATE tasks SET status = 'done', completed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE id = <task_id>;
"
```

2. Emit your `<eagle-summary>` block
3. Tell the user: **"Task #N complete. Run `/compact` to save progress and load the next task."**

### Skipping/blocking a task

```bash
sqlite3 ~/.eagle-mem/memory.db "
UPDATE tasks SET status = 'blocked'
WHERE id = <task_id>;
"
```

## Task design guidelines

- Each task should be **self-contained** — completable without needing context from mid-execution of a previous task
- Include `instructions` with enough detail that a fresh context window can pick it up
- Include a `context_snapshot` for tasks that depend on decisions from earlier tasks:
```bash
sqlite3 ~/.eagle-mem/memory.db "
PRAGMA trusted_schema=ON;
UPDATE tasks SET context_snapshot = '<key decisions and state>'
WHERE id = <task_id>;
"
```
- Order tasks so that foundational work comes first (schema before API, API before UI)

## The compact cycle

```
User request → Plan tasks → Execute task 1 → /compact
→ Eagle Mem saves summary → Context cleared → Memory re-injected
→ Task 2 loaded as [ACTIVE] → Execute task 2 → /compact
→ ... repeat until all tasks done ...
→ Final summary: "All N tasks complete."
```

This prevents context window bloat. Each task gets a fresh window with only relevant memory injected.

## Example

User: "Build a REST API with auth, CRUD endpoints, and tests"

Tasks created:
1. Set up project structure and dependencies
2. Implement auth middleware (JWT)
3. Build CRUD endpoints for users
4. Build CRUD endpoints for posts
5. Write integration tests
6. Add error handling and validation

Each task executes in its own compact cycle with full memory of what came before.
