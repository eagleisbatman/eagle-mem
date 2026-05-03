---
name: eagle-mem-memories
description: >
  View and sync Claude Code and Codex memories, plans, and tasks mirrored in Eagle Mem. Use when:
  'eagle memories', 'show memories', 'sync memories', 'what does the agent remember',
  'show plans', 'show tasks', 'mirror memories', 'onboard project',
  'what did past sessions learn'. Uses the eagle-mem CLI.
---

# Eagle Mem — Memories

## Purpose

**For the user:** Claude Code and Codex remember across sessions. Decisions, preferences, project context, and architectural plans survive session boundaries. The user never has to re-explain "we chose Postgres because..." or "don't use semicolons in this project."

**For you:** Access to what past Claude Code and Codex sessions learned about this project. Memories tell you *why* decisions were made. Plans tell you *what's coming*. Tasks tell you *what's in flight*. Together they're the knowledge bridge that makes you effective from message one.

## Judgment

**Check memories when:**
- The user references a past decision ("remember when we decided to...", "what's our convention for...")
- You're about to make an architectural or style choice -- memories may record the user's preference
- You need project context that isn't in CLAUDE.md or README (relationships between services, deployment quirks, naming conventions)
- The user asks "what does Claude/Codex/Eagle Mem remember about X?"

**Check plans when:**
- The user asks about upcoming work or roadmap
- You need to understand a multi-session effort that's in progress
- The user says "continue where we left off"

**Check tasks when:**
- The user asks about in-flight work across sessions
- You need to understand what sub-tasks are pending/completed in a larger effort

**Don't check memories when:**
- The answer is in the current code -- read the file instead
- The question is about *what the code does now* (memories record past decisions, code records current state)
- You already have the context from SessionStart injection

**Decision rule:** Memories = *why we decided*. Code = *what it does now*. If the question is about rationale, conventions, or preferences, check memories first. If the question is about current behavior, read code first.

## Steps

### 1. Know the three data types

**Memories** -- Claude Code auto-memory files (`~/.claude/projects/*/memory/*.md`) plus top-level Codex memory files (`~/.codex/memories/MEMORY.md`, `memory_summary.md`). These contain user preferences, project conventions, and feedback. Each mirrored row is source-attributed.
```bash
eagle-mem memories list                    # all memories
eagle-mem memories search "typescript"     # FTS5 search
eagle-mem memories show <file_path>        # full content
```

**Plans** -- Claude Code plan files (`~/.claude/plans/*.md`) and future agent plan files as support is added. Multi-step strategies for complex work. Each has a title, optional project tag, and markdown content.
```bash
eagle-mem memories plans                   # all plans
eagle-mem memories plans search "migration"
eagle-mem memories plans show <file_path>
```

**Tasks** -- Claude Code task JSON (`~/.claude/tasks/<session>/*.json`) and Eagle Mem task records created directly by agents such as Codex. Individual units of work with status tracking (pending/in_progress/completed).
```bash
eagle-mem memories tasks                   # all tasks
eagle-mem memories tasks search "refactor"
eagle-mem memories tasks show <file_path>
```

### 2. Understand how data flows in

Two paths feed the mirror:

**Real-time hooks.** Claude Code memory/plan/task files are mirrored when written. Codex sessions are captured through SessionStart/UserPromptSubmit/PostToolUse/Stop hooks, and important durable facts should be placed in `<eagle-summary>` so they become shared recall.

**Backfill (sync command).** For memories, plans, and tasks that existed before Eagle Mem was installed, or that were written outside a hooked session:
```bash
eagle-mem memories sync
```
This scans known Claude Code and Codex memory/task locations, hashes each file, skips unchanged ones, and mirrors anything new or modified. It also backfills project names from transcripts. Safe to run repeatedly -- content-hash dedup prevents double-insertion.

### 3. Search effectively

The search hits FTS5 indexes across all three types independently. Start with the most likely container:

- User asked about a preference or convention? Search **memories** first.
- User asked about a multi-step plan? Search **plans** first.
- User asked about what's been done vs. what's left? Search **tasks** first.
- Not sure? Search all three -- they're fast:
```bash
eagle-mem memories search "auth"
eagle-mem memories plans search "auth"
eagle-mem memories tasks search "auth"
```

### 4. Scope by project when needed

Unlike `eagle-mem search` (which auto-scopes to the current project), memories commands are **cross-project by default** -- list and search show everything across all projects. This makes sense because memories, plans, and preferences often apply broadly.

To narrow to a specific project:
```bash
eagle-mem memories search "testing" -p eagle-mem
eagle-mem memories plans -p my-api
```

This asymmetry is intentional but easy to forget. If you're getting too many irrelevant results from other projects, add `-p`.

### 5. Onboard an existing project

When Eagle Mem is installed on a project that already has Claude Code or Codex history:
```bash
eagle-mem memories sync
```
This is the first thing to run. It pulls in all existing memories, plans, and tasks. The output shows counts: "12 synced, 3 unchanged" -- verify the numbers make sense given the project's history.

### 6. Verify the mirror is working

After sync or after expecting the hook to fire:
```bash
eagle-mem memories list          # should show recent memories
eagle-mem search --stats         # check counts are non-zero
```
If memories list is empty after sync, check that `~/.claude/projects/` or `~/.codex/memories/` contains memory files. If the hook isn't capturing new writes, check Claude Code `settings.json` or Codex `hooks.json`.

## What makes a good memory lookup

**Good:**
> I checked Eagle Mem's memories before choosing an error handling pattern. Memory "project_error-conventions" [project type] records that you prefer Result types over try/catch in this codebase, and that error messages should include the operation name and original error. Following that convention here.

**Bad:**
> I'll use try/catch for error handling here.
> *(Didn't check -- missed a recorded preference that would have changed the approach.)*

## Reference

| Command | What it does |
|---|---|
| `memories list` | All mirrored memories (name, type, description, date) |
| `memories search "query"` | FTS5 search across memory content |
| `memories show <path>` | Full content of one memory |
| `memories plans` | All captured plans |
| `memories plans search "query"` | FTS5 search across plan content |
| `memories plans show <path>` | Full content of one plan |
| `memories tasks` | All captured tasks |
| `memories tasks search "query"` | FTS5 search across task content |
| `memories tasks show <path>` | Full content of one task |
| `memories sync` | Backfill all memories + plans + tasks from disk |
| `-p <name>` / `--project` | Filter by project name |
| `-l N` / `--limit` | Max results (default: 20) |
