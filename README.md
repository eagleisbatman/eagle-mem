```
█▀▀ ▄▀█ █▀▀ █   █▀▀   █▀▄▀█ █▀▀ █▀▄▀█
██▄ █▀█ █▄█ █▄▄ ██▄   █ ▀ █ ██▄ █ ▀ █
```

# Eagle Mem

Persistent memory for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Every session starts with context from previous sessions — summaries, memories, tasks, and project overviews — injected automatically via hooks.

**Zero per-instance overhead.** No daemon, no vector DB, no MCP server. Just bash scripts, sqlite3, and jq.

## Install

```bash
npm install -g eagle-mem
eagle-mem install
```

Start a new Claude Code session — Eagle Mem activates automatically:

```
█▀▀ ▄▀█ █▀▀ █   █▀▀   █▀▄▀█ █▀▀ █▀▄▀█
██▄ █▀█ █▄█ █▄▄ ██▄   █ ▀ █ ██▄ █ ▀ █

Project: my-app
Sessions: 5 recent | Memories: 3 | Tasks: 2 pending
Last: Added auth middleware with JWT validation
```

## What It Does

Eagle Mem hooks into Claude Code's lifecycle to solve the context loss problem:

- **Session summaries** — automatically captured when Claude's turn ends, stored in SQLite with FTS5 search
- **Memory mirror** — mirrors Claude Code's auto-memories, plans, and tasks into a searchable database
- **Context injection** — at session start, injects project overview + recent summaries + relevant memories + in-progress tasks
- **Compact survival** — after `/compact`, Eagle Mem re-injects full context so Claude picks up where it left off
- **Privacy** — wrap sensitive content in `<private>` tags and it's stripped before storage

## Hook Lifecycle

| Hook | Fires When | What It Does |
|------|-----------|--------------|
| **SessionStart** | startup, resume, clear, compact | Injects project overview, recent summaries, memories, and in-progress tasks |
| **UserPromptSubmit** | user sends a message | Searches FTS5 for memories relevant to the prompt |
| **Stop** | Claude's turn ends | Parses `<eagle-summary>` from transcript, saves to DB |
| **PostToolUse** | after tool calls | Captures observations, mirrors memory/plan/task writes |
| **SessionEnd** | session closes | Re-syncs tasks, marks session completed |

## Commands

| Command | What it does |
|---------|-------------|
| `eagle-mem refresh` | Full project sync: overview + scan + index + memories + tasks |
| `eagle-mem search <query>` | FTS5 search across summaries, memories, and code chunks |
| `eagle-mem search --timeline` | Recent sessions in chronological order |
| `eagle-mem overview` | View or set the project overview |
| `eagle-mem scan` | Analyze codebase structure (languages, frameworks, entry points) |
| `eagle-mem index` | Index source files into FTS5-searchable chunks |
| `eagle-mem memories` | View/sync mirrored Claude Code memories, plans, and tasks |
| `eagle-mem tasks` | View mirrored Claude Code tasks |
| `eagle-mem prune` | Remove old observations and orphaned chunks |
| `eagle-mem install` | First-time setup: hooks, database, skills |
| `eagle-mem update` | Re-deploy hooks and run pending migrations |
| `eagle-mem uninstall` | Remove hooks and optionally delete data |

## Skills

Seven skills available inside Claude Code sessions:

| Skill | What it does |
|-------|-------------|
| `/eagle-mem-search` | Progressive memory recall — search, expand, drill into sessions |
| `/eagle-mem-overview` | Build a structured project briefing from code, README, and git history |
| `/eagle-mem-scan` | Analyze codebase structure — languages, frameworks, entry points |
| `/eagle-mem-index` | Index source files for FTS5 code search across sessions |
| `/eagle-mem-memories` | View, search, and sync Claude Code's mirrored memories and plans |
| `/eagle-mem-tasks` | TaskAware Compact Loop — break work into tasks that survive compaction |
| `/eagle-mem-prune` | Database hygiene — graduated cleanup of stale data |

## Database

Single shared SQLite database at `~/.eagle-mem/memory.db`. WAL mode for concurrent sessions, FTS5 for full-text search.

| Table | Purpose |
|-------|---------|
| sessions | Active/completed sessions per project |
| summaries | Per-session summaries with FTS5 (UPSERT on session_id) |
| observations | Per-tool-use records with deduplication |
| overviews | One rolling overview per project (scan vs manual source tracking) |
| code_chunks | FTS5-indexed source file chunks |
| claude_memories | Mirror of Claude Code auto-memories |
| claude_plans | Mirror of Claude Code plans |
| claude_tasks | Mirror of Claude Code tasks |

## Architecture

```
Package (npm)                   Runtime (~/.eagle-mem/)
├── bin/eagle-mem   CLI         ├── memory.db         SQLite + FTS5
├── scripts/                    ├── eagle-mem.log     Debug log
│   ├── install.sh              ├── hooks/
│   ├── update.sh               │   ├── session-start.sh
│   ├── uninstall.sh            │   ├── user-prompt-submit.sh
│   ├── search.sh               │   ├── stop.sh
│   ├── overview.sh             │   ├── post-tool-use.sh
│   ├── tasks.sh                │   └── session-end.sh
│   ├── prune.sh                ├── lib/
│   ├── scan.sh                 │   ├── common.sh
│   ├── index.sh                │   ├── db.sh
│   ├── refresh.sh              │   └── hooks.sh
│   └── help.sh                 └── db/
├── hooks/          Source          ├── schema.sql
├── lib/            Source          └── [0-9]*.sql  Migrations
├── db/             Source
└── skills/         → ~/.claude/skills/
    ├── eagle-mem-search/
    ├── eagle-mem-overview/
    ├── eagle-mem-scan/
    ├── eagle-mem-index/
    ├── eagle-mem-memories/
    ├── eagle-mem-tasks/
    └── eagle-mem-prune/
```

## Uninstall

```bash
eagle-mem uninstall
npm uninstall -g eagle-mem
```

## Prerequisites

- `sqlite3` with FTS5 support (ships with macOS; the installer offers to install if missing)
- `jq` (the installer offers to install if missing)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed (`~/.claude/` must exist)

## License

MIT
