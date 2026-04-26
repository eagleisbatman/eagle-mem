```
        .~~~~-.
       /    ,__`)
      |      \o/|'-.
      |         /  ,\
      |        ('--./
      /         \
     /  ,  ,  ,  \
     `--'--'--'--'

███████╗░█████╗░░██████╗░██╗░░░░░███████╗  ███╗░░░███╗███████╗███╗░░░███╗
██╔════╝██╔══██╗██╔════╝░██║░░░░░██╔════╝  ████╗░████║██╔════╝████╗░████║
█████╗░░███████║██║░░██╗░██║░░░░░█████╗░░  ██╔████╔██║█████╗░░██╔████╔██║
██╔══╝░░██╔══██║██║░░╚██╗██║░░░░░██╔══╝░░  ██║╚██╔╝██║██╔══╝░░██║╚██╔╝██║
███████╗██║░░██║╚██████╔╝███████╗███████╗  ██║░╚═╝░██║███████╗██║░╚═╝░██║
╚══════╝╚═╝░░╚═╝░╚═════╝░╚══════╝╚══════╝  ╚═╝░░░░░╚═╝╚══════╝╚═╝░░░░░╚═╝
```

# Eagle Mem

Lightweight persistent memory for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Inspired by [claude-mem](https://github.com/thedotmack/claude-mem) but without the resource-heavy Chroma DB + Bun daemon architecture that consumed 300-600MB per instance.

**Zero per-instance overhead.** No daemon, no vector DB, no MCP server. Just bash scripts, sqlite3, and jq.

## Install

```bash
npm install -g eagle-mem
eagle-mem install
```

The installer checks prerequisites and offers to install missing ones:

```
        .~~~~-.
       /    ,__`)
      |      \o/|'-.
      |         /  ,\
      |        ('--./
      /         \
     /  ,  ,  ,  \
     `--'--'--'--'

  Eagle Mem  Install
  ─────────────────────────────────────

  Checking prerequisites...

  ✓  sqlite3 (3.39.5)
  ✓  FTS5 support
  ✓  jq (1.7.1)
  ✓  Claude Code (~/.claude/)

  Installing Eagle Mem...

  ✓  Files copied to ~/.eagle-mem
  ✓  Database ready
  ✓  Hooks registered
  ✓  Skills installed

  Eagle Mem installed successfully.
```

Start a new Claude Code session — Eagle Mem activates automatically and shows:

```
        .~~~~-.
       /    ,__`)
      |      \o/|'-.       Eagle Mem loaded
      |         /  ,\       Project: my-app
      |        ('--./       Sessions: 5 recent | Memories: 3 | Tasks: 2 pending
      /         \           Last: Added auth middleware with JWT validation
     /  ,  ,  ,  \
     `--'--'--'--'
```

## Commands

| Command | What it does |
|---------|-------------|
| `eagle-mem install` | First-time setup: checks prerequisites, deploys hooks, creates database, installs skills |
| `eagle-mem update` | Re-deploys hooks/lib files, runs pending migrations, backfills project names |
| `eagle-mem scan .` | Analyze a project and generate an overview (auto-injected at session start) |
| `eagle-mem index .` | Index source files into FTS5-searchable chunks (incremental via mtime) |
| `eagle-mem search <query>` | Full-text search across summaries, observations, and code chunks |
| `eagle-mem tasks` | List, filter, and manage tasks from the TaskAware Compact Loop |
| `eagle-mem overview` | View or regenerate project overviews |
| `eagle-mem memories` | List, search, and sync Claude Code auto-memories, plans, and tasks |
| `eagle-mem memories sync` | Backfill all Claude Code memories, plans, and tasks into Eagle Mem |
| `eagle-mem prune` | Clean up orphan code chunks and stale data |
| `eagle-mem uninstall` | Removes hooks from settings.json and optionally deletes data |
| `eagle-mem help` | Shows usage, commands, and available skills |
| `eagle-mem version` | Shows current version |

## Why

Claude Code sessions lose context on `/compact` and between sessions. Eagle Mem solves this with:

- **Automatic session summaries** saved to a shared SQLite database
- **Claude Code memory mirror** — mirrors Claude's auto-memories, plans, and tasks into Eagle Mem's SQLite + FTS5
- **Session-start injection** — project overview, recent summaries, memories, plans, and in-progress tasks surfaced automatically
- **Compact-safe reload** — full context re-injects after compaction with trigger awareness
- **TaskAware Compact Loop** for breaking complex work into subtasks that survive compaction
- **FTS5 full-text search** across all sessions and projects
- **Contextual memory injection** — relevant past sessions surfaced when you ask related questions
- **Privacy controls** — `<private>` tags strip sensitive content before storage
- **Observation deduplication** — prevents DB bloat from repeated tool calls
- **Project overviews** — persistent one-paragraph project summaries injected at session start
- **Concurrent-safe** WAL mode with busy timeout — runs fine across 4-5 simultaneous sessions
- **Codebase scanning** — auto-generates project overviews from structure analysis
- **Code indexing** — FTS5-searchable source chunks with incremental re-indexing
- **Stale data filtering** — noisy auto-captured summaries and 7-day-old tasks are excluded from injection

## How It Works

### Hook Lifecycle

| Hook | Fires When | What It Does |
|------|-----------|--------------|
| **SessionStart** | startup, resume, clear, compact | Queries DB for project overview, recent summaries, memories, plans, and in-progress tasks. Injects context via stdout. Shows trigger type (startup/compact/clear/resume). |
| **UserPromptSubmit** | user sends a message | Searches FTS5 for memories relevant to the user's prompt. Injects matching context with ASCII eagle branding. |
| **Stop** | Claude's turn ends | Parses `<eagle-summary>` from transcript (strips `<private>` tags first). Heuristic fallback extracts user prompt + file paths. Saves summary to DB. |
| **PostToolUse** | after Read/Write/Edit/Bash/TaskCreate/TaskUpdate | Captures lightweight observations with deduplication (5-second window). Mirrors Claude Code auto-memory, plan, and task writes. |
| **SessionEnd** | session closes | Re-syncs all task files from `~/.claude/tasks/` to catch status changes, then marks session as completed. |

### Claude Code Memory Mirror

Eagle Mem intercepts Claude Code's built-in memory, plan, and task writes via the PostToolUse hook:

- **Memories** — when Claude writes to `~/.claude/projects/*/memory/*.md`, Eagle Mem mirrors the content with FTS5 indexing
- **Plans** — when Claude writes to `~/.claude/plans/*.md`, Eagle Mem captures the plan
- **Tasks** — when Claude calls `TaskCreate` or `TaskUpdate`, Eagle Mem captures the task JSON

These are injected at session start (top 5 memories, top 3 plans, in-progress tasks) and can be searched via CLI:

```bash
eagle-mem memories               # list all mirrored memories
eagle-mem memories search "auth" # full-text search
eagle-mem memories plans         # list captured plans
eagle-mem memories tasks         # list captured tasks
eagle-mem memories sync          # backfill everything from Claude Code
```

**Task resync:** At session end, Eagle Mem re-reads all task JSON files to catch status changes that bypassed the PostToolUse hook (Claude Code can update tasks internally without tool calls).

### Summary Extraction

Eagle Mem injects instructions for Claude to emit an `<eagle-summary>` block before its final response:

```
<eagle-summary>
request: What the user asked for
investigated: Key files/areas explored
learned: Non-obvious discoveries
completed: What was accomplished
next_steps: What should happen next
files_read: [list of files read]
files_modified: [list of files modified]
</eagle-summary>
```

The Stop hook parses this from the transcript. If Claude doesn't emit one, a heuristic fallback captures the first user prompt and files touched via tool calls.

### Privacy

Wrap sensitive content in `<private>` tags and it will be stripped before storage:

```
<private>
API_KEY=sk-secret-123
DB_PASSWORD=hunter2
</private>
```

The Stop hook removes `<private>` blocks at the edge — before any data reaches the database.

### TaskAware Compact Loop

For complex multi-step work:

1. **Plan** — Break the work into subtasks stored in the DB
2. **Execute** — Work on one task at a time
3. **Compact** — Run `/compact` when context fills up
4. **Resume** — SessionStart re-injects memory + the next pending task

This prevents context bloat and hallucination on long tasks.

## Database

Single shared SQLite database at `~/.eagle-mem/memory.db` with a `project` column on every table for filtering.

### Tables

- **sessions** — Track active/completed sessions per project
- **observations** — Per-tool-use records with deduplication (files read/modified)
- **summaries** — Per-session summaries with FTS5 search
- **tasks** — Subtasks for the TaskAware Compact Loop with FTS5 search
- **overviews** — One rolling overview per project (injected at session start)
- **code_chunks** — FTS5-indexed source file chunks for code-level search
- **claude_memories** — Mirror of Claude Code auto-memories with FTS5 search
- **claude_plans** — Mirror of Claude Code plan files with FTS5 search
- **claude_tasks** — Mirror of Claude Code task JSON files with FTS5 search

### Key Design Choices

- **WAL mode** for concurrent readers across sessions
- **busy_timeout=5000** to retry on write contention instead of failing
- **FTS5 content-sync** with auto-triggers to keep search indexes in sync
- **trusted_schema=ON** required for FTS5 virtual tables
- **Project identification** via `git rev-parse --show-toplevel` (handles monorepo subdirectories correctly)
- **Backfill system** resolves project names from Claude Code transcript files at `~/.claude/projects/`
- PRAGMAs set on every connection (they're connection-scoped, not persistent)

## Skills

Eagle Mem ships with three skills for use inside Claude Code sessions:

- **eagle-mem-search** — 3-layer search: compact FTS5 search, timeline view, full observations
- **eagle-mem-tasks** — TaskAware Compact Loop: create, view, complete, and manage subtasks
- **eagle-mem-overview** — Generate and update a persistent project overview

## Architecture

```
Package (npm)                   Runtime (~/.eagle-mem/)
├── bin/eagle-mem   CLI         ├── memory.db         SQLite + FTS5
├── scripts/                    ├── eagle-mem.log     Debug log
│   ├── style.sh                ├── hooks/
│   ├── install.sh              │   ├── session-start.sh
│   ├── uninstall.sh            │   ├── user-prompt-submit.sh
│   ├── update.sh               │   ├── stop.sh
│   ├── scan.sh                 │   ├── post-tool-use.sh
│   ├── index.sh                │   └── session-end.sh
│   ├── search.sh               ├── lib/
│   ├── tasks.sh                │   ├── common.sh
│   ├── overview.sh             │   └── db.sh
│   ├── memories.sh             └── db/
│   ├── prune.sh                    ├── migrate.sh
│   └── help.sh                    ├── schema.sql
├── hooks/          Source          ├── 002_overviews.sql
├── lib/            Source          ├── 003_code_chunks.sql
│   ├── common.sh                  ├── 004_observation_indexes.sql
│   └── db.sh                      ├── 005_claude_memories.sql
├── db/             Source          ├── 006_claude_plans.sql
│   ├── migrate.sh                 └── 007_claude_tasks.sql
│   ├── schema.sql
│   └── migrations
└── skills/         Symlinked → ~/.claude/skills/
    ├── eagle-mem-search/
    ├── eagle-mem-tasks/
    └── eagle-mem-overview/
```

## Uninstall

```bash
eagle-mem uninstall
```

Removes hooks from `~/.claude/settings.json` and skill symlinks. Optionally deletes `~/.eagle-mem/` (prompts for confirmation).

To also remove the npm package:

```bash
npm uninstall -g eagle-mem
```

## Prerequisites

- `sqlite3` with FTS5 support (ships with macOS; the installer offers to install if missing)
- `jq` (the installer offers to install if missing)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed (`~/.claude/` must exist)

## Roadmap

- [ ] **v2**: sqlite-vec embeddings for semantic code search
- [ ] Timeline report skill (narrative project history from pure SQL)
- [x] ~~Claude Code memory/plan/task mirror~~
- [x] ~~ASCII eagle branding across hooks and CLI~~
- [x] ~~Compact-safe context reload~~

## License

MIT
