---
name: eagle-mem-tasks
description: >
  TaskAware Compact Loop — break complex work into Claude Code tasks with dependencies,
  compact between each. Use when: 'eagle tasks', 'break this into tasks', 'create task plan',
  'task loop', 'compact loop', 'eagle mem tasks'. Uses Claude Code's native TaskCreate/TaskUpdate.
---

# Eagle Mem — TaskAware Compact Loop

Break complex work into subtasks using Claude Code's native task system. Execute one task at a time, compact between each, and let Eagle Mem re-inject task state for the next task.

## How it works

1. **Plan**: Break the user's request into ordered subtasks
2. **Create**: Add each subtask via `TaskCreate` with dependencies via `addBlockedBy`
3. **Execute**: Work on the current task (mark `in_progress` with `TaskUpdate`)
4. **Complete**: Mark done with `TaskUpdate(completed)`, emit `<eagle-summary>`
5. **Compact**: Tell the user to run `/compact`
6. **Resume**: After compact, SessionStart re-injects memory + loads task state from Eagle Mem's mirror
7. **Repeat**: Until all tasks are done

## Creating tasks

Use Claude Code's `TaskCreate` tool. Each task gets `pending` status automatically.

For tasks that depend on earlier work, use `addBlockedBy` in `TaskUpdate`:

```
TaskCreate({ subject: "Set up project structure", description: "Install deps, create folders, init config" })
TaskCreate({ subject: "Implement auth middleware", description: "JWT validation, role checks, error responses" })
TaskCreate({ subject: "Build CRUD endpoints", description: "Users and posts REST API with validation" })

// Then set dependencies:
TaskUpdate({ taskId: "3", addBlockedBy: ["1", "2"] })
```

## Working on a task

1. Call `TaskUpdate({ taskId: "N", status: "in_progress" })` before starting work
2. Do the work
3. Call `TaskUpdate({ taskId: "N", status: "completed" })` when done
4. Emit your `<eagle-summary>` block
5. Tell the user: **"Task complete. Run `/compact` to save progress and load the next task."**

## Viewing tasks

Use `TaskList` to see all tasks, or the CLI for cross-session history:

```bash
eagle-mem tasks              # pending/in-progress (from mirror)
eagle-mem tasks list         # all tasks
eagle-mem tasks search <q>   # FTS5 search across task history
```

## Cross-session context

When a task depends on decisions made in earlier tasks, put that context in the task's `description` field — it persists across compactions via Eagle Mem's mirror.

For example, if task 1 decides to use JWT with RS256:

```
TaskUpdate({ taskId: "2", description: "Implement auth middleware. Decision from task 1: using JWT with RS256, sessions stored in Redis." })
```

## Task design guidelines

- Each task should be **self-contained** — completable in one context window
- Include enough detail in `description` that a fresh context window can pick it up
- Use `addBlockedBy` for tasks that depend on earlier tasks
- Order tasks so foundational work comes first (schema before API, API before UI)
- Keep tasks focused: 3-8 tasks per plan

## The compact cycle

```
User request -> Plan tasks (TaskCreate) -> Execute task 1 (TaskUpdate: in_progress)
-> Complete task 1 (TaskUpdate: completed) -> /compact
-> Eagle Mem saves summary -> Context cleared -> Task state re-injected
-> Execute task 2 -> /compact
-> ... repeat until all tasks done ...
-> Final summary: "All N tasks complete."
```

## Status reference

| Status | Meaning |
|---|---|
| `pending` | Not started yet |
| `in_progress` | Currently being worked on |
| `completed` | Done |
| `deleted` | Removed |
