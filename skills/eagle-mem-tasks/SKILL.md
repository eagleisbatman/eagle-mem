---
name: eagle-mem-tasks
description: >
  TaskAware Compact Loop — break complex work into database-tracked subtasks with compaction
  between each. Use when: 'eagle tasks', 'break this into tasks', 'create task plan',
  'task loop', 'compact loop', 'eagle mem tasks'. Uses the eagle-mem CLI — never run raw sqlite3 queries.
---

# Eagle Mem — TaskAware Compact Loop

Break complex work into subtasks stored in Eagle Mem's database. Execute one task at a time, compact between each, and let Eagle Mem re-inject context for the next task.

## How it works

1. **Plan**: Break the user's request into ordered subtasks
2. **Store**: Add each subtask via the CLI
3. **Execute**: Work on the current task (marked `[ACTIVE]`)
4. **Compact**: When done, tell the user to run `/compact`
5. **Resume**: After compact, SessionStart re-injects memory + loads the next task
6. **Repeat**: Until all tasks are done

## Commands

### List tasks

```bash
eagle-mem tasks
eagle-mem tasks list
```

### Add tasks

When the user invokes `/eagle-mem-tasks` or asks to break work into tasks:

1. Analyze the request and break it into 3-8 focused subtasks
2. Each task should be completable in one context window
3. Add tasks using the CLI:

```bash
eagle-mem tasks add "Set up project structure" "Install deps, create folders, init config"
eagle-mem tasks add "Implement auth middleware" "JWT validation, role checks, error responses"
eagle-mem tasks add "Build CRUD endpoints" "Users and posts REST API with validation"
```

4. Show the task plan to the user for confirmation
5. After confirmation, start working on task #1

### Complete a task

```bash
eagle-mem tasks done <id>
```

After marking done:
1. Emit your `<eagle-summary>` block
2. Tell the user: **"Task #N complete. Run `/compact` to save progress and load the next task."**

### Block a task

```bash
eagle-mem tasks block <id>
```

### Set context snapshot

For tasks that depend on decisions from earlier tasks:

```bash
eagle-mem tasks context <id> "Using JWT with RS256, sessions stored in Redis"
```

### Clear completed tasks

```bash
eagle-mem tasks clear
```

## Options

| Flag | Description |
|------|-------------|
| `-p, --project <name>` | Target a specific project (default: current directory) |
| `-j, --json` | Output as JSON |

## Task design guidelines

- Each task should be **self-contained** — completable without mid-execution context from a previous task
- Include instructions with enough detail that a fresh context window can pick it up
- Use context snapshots for tasks that depend on decisions from earlier tasks
- Order tasks so that foundational work comes first (schema before API, API before UI)

## The compact cycle

```
User request → Plan tasks → Execute task 1 → /compact
→ Eagle Mem saves summary → Context cleared → Memory re-injected
→ Task 2 loaded as [ACTIVE] → Execute task 2 → /compact
→ ... repeat until all tasks done ...
→ Final summary: "All N tasks complete."
```
