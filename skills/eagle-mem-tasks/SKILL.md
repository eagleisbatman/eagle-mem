---
name: eagle-mem-tasks
description: >
  TaskAware Compact Loop — break complex work into tasks that survive context
  compaction. Use when: 'break this into tasks', 'create task plan', 'task loop',
  'compact loop', work is too large for one context window, multi-step implementation.
---

# Eagle Mem — TaskAware Compact Loop

## Purpose

**For the user:** Multi-step work doesn't get lost when Claude Code or Codex compacts. A 6-task implementation plan survives intact across compactions — no re-explaining what was decided, no drift from the original direction.

**For you:** Each task description is a message to a future context window with ZERO memory of what happened before. After compaction, SessionStart re-injects pending/in-progress tasks from Eagle Mem's `agent_tasks` table. That re-injected text is all the next context window gets. If the description says "implement auth middleware," the next window has nothing to work with. If it says "implement auth middleware — JWT with RS256, sessions in Redis, errors use RFC 7807 format (decided in task 1)," the next window can execute immediately.

## Judgment

**Use the task loop when:**
- Work requires 4+ distinct steps
- You'll likely need to `/compact` mid-way
- The user says "break this into tasks" or "create a plan"
- Different steps touch different parts of the codebase (schema, API, UI)

**Don't use when:**
- The work fits in one context window — just do it directly
- It's a single-file fix or a quick question
- The user is exploring, not building (use search/overview instead)
- The work needs parallel agent lanes or ownership across Claude Code and Codex
  (use `eagle-mem-orchestrate` instead)

## Steps

### 1. Plan — decompose into 3-8 tasks

Break the request into tasks that are each completable in one context window. Think about what a fresh context window needs to execute each task independently.

**Sizing rules:**
- If a task would touch more than ~10 files or require reading large code to understand, split it
- If a task is "change one line," merge it into an adjacent task
- Each task should produce a testable or verifiable result

**Ordering:** Foundational work first — schema before API, API before UI, config before features.

### 2. Create — write self-contained descriptions

Use the agent-native task mechanism when available. In Claude Code, use `TaskCreate`. In Codex, use `update_plan` for the live UI and `eagle-mem tasks add --agent codex` for durable cross-session task records. The description is the most important field — it must carry forward every decision from the planning conversation.

**Context transfer pattern:** For each task, ask: "If I read only this description with zero prior context, can I execute it?" If not, add what's missing.

```
TaskCreate / eagle-mem tasks add:
  subject: "Add JWT auth middleware"
  description: "Add Express middleware that validates JWT tokens on protected
    routes. Decisions: RS256 algorithm, public key from env JWT_PUBLIC_KEY,
    sessions stored in Redis (connection config already in lib/redis.ts from
    task 1). Error responses use RFC 7807 format. Protect all /api/* routes
    except /api/auth/login and /api/health."
```

**Dependencies:** Use `addBlockedBy` when a task genuinely can't start without another's output. Don't over-chain — most tasks in a plan can run in declared order without formal blocking.

### 3. Execute — one task at a time

Mark the current task in progress (`TaskUpdate(in_progress)` in Claude Code, or `eagle-mem tasks start <id> --agent codex` in Codex). Do the work. Stay focused on that task — don't drift into adjacent tasks.

### 4. Complete — record what happened

Mark the task completed (`TaskUpdate(completed)` in Claude Code, or `eagle-mem tasks complete <id> --agent codex` in Codex). In Claude Code, use the Eagle Mem summary block when that UI handles it cleanly. In Codex, keep the final reply clean and record durable decisions in normal prose; Eagle Mem captures the transcript automatically.

If the task produced decisions that downstream tasks need, update those task descriptions now:
```
TaskUpdate / update durable task description:
  taskId: "3"
  description: "...original description... Note from task 2: the user table
    uses UUID primary keys, not auto-increment. Auth tokens table FKs to
    users.id (UUID)."
```

### 5. Compact — hand off to the next context window

Tell the user: "Task complete. Run `/compact` to free context for the next task."

### 6. Resume — pick up where you left off

After compaction, SessionStart re-injects all pending/in-progress tasks. Pick the next unblocked task and continue.

## Handling scope changes and failures

**User changes direction mid-plan:** Update the remaining task descriptions to reflect the new direction. Delete tasks that no longer apply. Don't start over unless the change invalidates everything.

**A task fails or produces unexpected results:** Update the task description with what was learned and what went wrong. Don't just retry blindly — the description should carry the failure context so the next attempt (or the next context window) doesn't repeat the same mistake.

```
TaskUpdate / task record update:
  taskId: "4"
  description: "...original description... FAILED ATTEMPT: Prisma migrate
    errored because the users table already has a conflicting unique
    constraint on email. Need to drop the old constraint first. See
    migration 003_auth.sql for the current state."
```

**Partial completion:** If a task is half-done when you need to compact, update the description with exactly what's done and what remains. Mark it as still `in_progress`, not completed.

## The compact cycle — how task state survives

1. Claude Code path: you call `TaskCreate`/`TaskUpdate`; Claude Code writes task JSON to `~/.claude/tasks/$session_id/*.json`; Eagle Mem mirrors it.
2. Codex path: you call `update_plan` for live progress and `eagle-mem tasks add/start/complete --agent codex` for durable records.
3. Eagle Mem stores both paths in the shared `agent_tasks` FTS5 table with `origin_agent`.
4. SessionEnd does a final Claude Code task sweep where native task files exist.
5. On compaction (or new session), SessionStart queries `agent_tasks` for pending/in-progress tasks from the last 7 days and injects them into context.

The task descriptions you write ARE the context that survives. Everything else — your reasoning, the conversation, the files you read — gets compacted away.

## What makes a good task plan

**Good:**
> Task 1: "Set up database schema for auth. Create users table (id UUID PK, email unique, password_hash, created_at) and sessions table (id UUID PK, user_id FK, token, expires_at). Use Prisma migration. Add seed script for test user."
>
> Task 2: "Implement login endpoint POST /api/auth/login. Accepts {email, password}, returns {token, expires_at}. Hash comparison with bcrypt (already in deps). Session created in DB. Error: 401 with RFC 7807 body. Schema from task 1: users.email is unique, sessions.token is the JWT."

**Bad:**
> Task 1: "Set up the database"
> Task 2: "Add authentication"

The bad version forces the next context window to re-discover every decision. The good version carries decisions forward — the next window can start coding immediately.

## Reference

```bash
# Viewing tasks
eagle-mem tasks                # pending/in-progress for current project
eagle-mem tasks list           # all tasks (including completed)
eagle-mem tasks completed      # completed tasks only
eagle-mem tasks search <q>     # FTS5 search across task history
eagle-mem tasks --json         # JSON output for scripting

# Codex durable task records
eagle-mem tasks add "Implement auth middleware" --agent codex --desc "Use RS256, Redis sessions, RFC 7807 errors"
eagle-mem tasks update <id> --agent codex --desc "New context or failure details"
eagle-mem tasks start <id> --agent codex
eagle-mem tasks complete <id> --agent codex

# Claude Code task tools
TaskCreate                     # create a new task
TaskUpdate                     # update status, description, dependencies
```
