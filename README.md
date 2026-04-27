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

That's it. Eagle Mem registers 5 lifecycle hooks in Claude Code and is fully automatic from here.

## New project

Open Claude Code in your project. Eagle Mem activates and shows:

```
█▀▀ ▄▀█ █▀▀ █   █▀▀   █▀▄▀█ █▀▀ █▀▄▀█
██▄ █▀█ █▄█ █▄▄ ██▄   █ ▀ █ ██▄ █ ▀ █

Project: my-app
Sessions: 0 recent | Memories: 0 | Tasks: 0 pending
```

Since no overview exists, Eagle Mem prompts Claude to build one on your first message. After that, every session starts with full context — you don't do anything.

**What happens automatically:**
- Every Claude turn end: session summary saved
- Every tool use: file touches recorded, Claude's memories/plans/tasks mirrored
- Every session start (including after `/compact`): overview + summaries + memories + tasks injected
- Every prompt: FTS5 searches past sessions for relevant context

## Existing project

If you've been using Claude Code on a project and want to backfill everything:

```bash
eagle-mem refresh .
```

This runs three steps:
1. **Scan** — analyzes your codebase structure (languages, frameworks, entry points)
2. **Index** — chunks source files into FTS5-searchable pieces
3. **Memory sync** — imports all existing Claude Code memories, plans, and tasks

Now open Claude Code. Eagle Mem injects your full history from the start.

## Day-to-day usage

Most of the time you don't run anything manually. The hooks handle everything. But when you need to:

| When | What to do |
|------|-----------|
| Search past sessions | `eagle-mem search "auth middleware"` |
| See recent timeline | `eagle-mem search --timeline` |
| View project overview | `eagle-mem overview` |
| Set a custom overview | `eagle-mem overview set "..."` |
| Full re-sync after major changes | `eagle-mem refresh .` |
| Clean up old data | `eagle-mem prune` |

Inside Claude Code, you also have skills (slash commands):

| Skill | When to use it |
|-------|---------------|
| `/eagle-mem-search` | Find something from a past session |
| `/eagle-mem-overview` | Build a rich project briefing from code + README + git |
| `/eagle-mem-tasks` | Break complex work into tasks that survive `/compact` |

## Updating

```bash
npm update -g eagle-mem
eagle-mem update
```

The `update` command copies new files, runs any pending database migrations, and re-registers hooks. Your data is preserved.

## How it works

Five hooks fire automatically at different points in Claude Code's lifecycle:

| Hook | Fires when | What it does |
|------|-----------|--------------|
| **SessionStart** | startup, resume, clear, compact | Injects overview, summaries, memories, tasks |
| **UserPromptSubmit** | user sends a message | FTS5 search for relevant past context |
| **PostToolUse** | after tool calls | Records file touches, mirrors memory/plan/task writes |
| **Stop** | Claude's turn ends | Extracts `<eagle-summary>`, strips `<private>` tags |
| **SessionEnd** | session closes | Re-syncs tasks, marks session completed |

Data lives in a single SQLite database at `~/.eagle-mem/memory.db` (WAL mode, FTS5 full-text search):

| Table | What it stores |
|-------|---------------|
| sessions | Active/completed sessions per project |
| summaries | Per-session summaries (FTS5-indexed) |
| observations | Per-tool-use file touch records |
| overviews | One overview per project (scan or manual) |
| code_chunks | FTS5-indexed source file chunks |
| claude_memories | Mirror of Claude Code auto-memories |
| claude_plans | Mirror of Claude Code plans |
| claude_tasks | Mirror of Claude Code tasks |

## All commands

| Command | What it does |
|---------|-------------|
| `eagle-mem install` | First-time setup: hooks, database, skills |
| `eagle-mem update` | Re-deploy hooks and run pending migrations |
| `eagle-mem uninstall` | Remove hooks and optionally delete data |
| `eagle-mem refresh` | Full sync: scan + index + memories in one command |
| `eagle-mem search <query>` | FTS5 search across summaries, memories, and code |
| `eagle-mem overview` | View or set the project overview |
| `eagle-mem scan` | Analyze codebase structure |
| `eagle-mem index` | Index source files for code search |
| `eagle-mem memories` | View/sync mirrored Claude Code memories and plans |
| `eagle-mem tasks` | View mirrored Claude Code tasks |
| `eagle-mem prune` | Remove old observations and orphaned chunks |

## All skills

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
