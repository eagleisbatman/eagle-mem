```
███████╗ █████╗  ██████╗ ██╗     ███████╗
██╔════╝██╔══██╗██╔════╝ ██║     ██╔════╝
█████╗  ███████║██║  ██╗ ██║     █████╗
██╔══╝  ██╔══██║██║  ╚██╗██║     ██╔══╝
███████╗██║  ██║╚██████╔╝███████╗███████╗
╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚══════╝
           ███╗   ███╗███████╗███╗   ███╗
           ████╗ ████║██╔════╝████╗ ████║
           ██╔████╔██║█████╗  ██╔████╔██║
           ██║╚██╔╝██║██╔══╝  ██║╚██╔╝██║
           ██║ ╚═╝ ██║███████╗██║ ╚═╝ ██║
           ╚═╝     ╚═╝╚══════╝╚═╝     ╚═╝
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
Eagle Mem  Install
─────��───────────────────────────────

Checking prerequisites...

✓  sqlite3 (3.39.5)
✓  FTS5 support
✗  jq not found
?  Install jq? [y/N] y
→  Running: brew install jq
✓  jq installed (1.7.1)
✓  Claude Code (~/.claude/)

Installing Eagle Mem...

✓  Files copied to ~/.eagle-mem
✓  Database ready
✓  SessionStart hook
✓  Stop hook
✓  PostToolUse hook
✓  SessionEnd hook
✓  UserPromptSubmit hook
✓  Skill: eagle-mem-overview
✓  Skill: eagle-mem-search
✓  Skill: eagle-mem-tasks

Eagle Mem installed successfully.
```

Start a new Claude Code session — Eagle Mem activates automatically.

## Commands

| Command | What it does |
|---------|-------------|
| `eagle-mem install` | First-time setup: checks prerequisites, deploys hooks, creates database, installs skills |
| `eagle-mem update` | Re-deploys hooks/lib files and runs pending database migrations |
| `eagle-mem scan .` | Analyze a project and generate an overview (auto-injected at session start) |
| `eagle-mem index .` | Index source files into FTS5-searchable chunks (incremental via mtime) |
| `eagle-mem uninstall` | Removes hooks from settings.json and optionally deletes data |
| `eagle-mem help` | Shows usage, commands, and available skills |
| `eagle-mem version` | Shows current version |

## Why

Claude Code sessions lose context on `/compact` and between sessions. Eagle Mem solves this with:

- **Automatic session summaries** saved to a shared SQLite database
- **TaskAware Compact Loop** for breaking complex work into subtasks that survive compaction
- **FTS5 full-text search** across all sessions and projects
- **Contextual memory injection** — relevant past sessions surfaced when you ask related questions
- **Privacy controls** — `<private>` tags strip sensitive content before storage
- **Observation deduplication** — prevents DB bloat from repeated tool calls
- **Project overviews** — persistent one-paragraph project summaries injected at session start
- **Concurrent-safe** WAL mode with busy timeout — runs fine across 4-5 simultaneous sessions
- **Codebase scanning** — auto-generates project overviews from structure analysis
- **Code indexing** — FTS5-searchable source chunks with incremental re-indexing

## How It Works

### Hook Lifecycle

| Hook | Fires When | What It Does |
|------|-----------|--------------|
| **SessionStart** | startup, resume, clear, compact | Queries DB for project overview, recent summaries, and pending tasks. Injects context via stdout. |
| **UserPromptSubmit** | user sends a message | Searches FTS5 for memories relevant to the user's prompt. Injects matching context. |
| **Stop** | Claude's turn ends | Parses `<eagle-summary>` from transcript (strips `<private>` tags first). Heuristic fallback extracts user prompt + file paths. Saves summary to DB. |
| **PostToolUse** | after Read/Write/Edit/Bash | Captures lightweight observations with deduplication (5-second window). |
| **SessionEnd** | session closes | Marks session as completed with timestamp. |

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

### Key Design Choices

- **WAL mode** for concurrent readers across sessions
- **busy_timeout=5000** to retry on write contention instead of failing
- **FTS5 content-sync** with auto-triggers to keep search indexes in sync
- **trusted_schema=ON** required for FTS5 virtual tables
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
│   └── help.sh                ├── lib/
├── hooks/          Source      │   ├── common.sh
├── lib/            Source      │   └── db.sh
│   ├── common.sh              └── db/
│   └── db.sh                      ├── migrate.sh
├── db/             Source          ├── schema.sql
│   ├── migrate.sh                 ├── 002_overviews.sql
│   ├── schema.sql                 └── 003_code_chunks.sql
│   ├── 002_overviews.sql
│   └── 003_code_chunks.sql
└── skills/         Symlinked → ~/.claude/skills/
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
- [ ] Integration into [Eagle Skills](https://github.com/eagleisbatman/eagle-skills)
- [ ] Timeline report skill (narrative project history from pure SQL)
- [ ] GitHub Pages site (matching Eagle Skills)

## License

MIT
