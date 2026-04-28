```
======================================
Eagle Mem
======================================
```

# Eagle Mem

Persistent memory for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Every session starts with context from previous sessions — summaries, memories, tasks, and project overviews — injected automatically via hooks.

**Zero per-instance overhead.** No daemon, no vector DB, no MCP server. Just bash scripts, sqlite3, and jq.

## Getting started

**1. Install** (once — this is the only setup step):

```bash
npm install -g eagle-mem
eagle-mem install
```

**2. Open Claude Code** in any project directory. Eagle Mem activates and shows what it loaded:

```
======================================
       Eagle Mem Loaded
======================================
 Project      | my-app
 Sessions     | 42 total (18 with summaries)
 Memories     | 7 stored
 Plans        | 2 saved
 Tasks        | 1 in progress, 3 pending, 12 completed
 Code Index   | 156 chunks indexed
 Observations | 340 captured
 Last Active  | 2026-04-28
 Last Work    | Added auth middleware with JWT validation
======================================
```

From here, everything is automatic. You don't run any commands — Eagle Mem captures session summaries, mirrors Claude's memories and tasks, and re-injects context after every `/compact` or new session.

**3. Already have Claude Code history on a project?** Run this inside the project directory:

```bash
cd ~/projects/my-app
eagle-mem refresh
```

This backfills everything into Eagle Mem:

```
Eagle Mem  Refresh
─────────────────────────────────────

Step 1/4: Scanning codebase structure...
  ✓  120 files found
  ✓  Languages: TypeScript (15k lines), CSS (2k lines)
  ✓  Frameworks: Next.js, React, Tailwind, Prisma
  ✓  Scan complete

Step 2/4: Indexing source files...
  ✓  Index complete

Step 3/4: Syncing Claude Code memories, plans, and tasks...
  ✓  Memory sync complete

Step 4/4: Verifying...
  Sessions:    12
  Code chunks: 340
  Memories:    8
  Tasks:       15
```

Now open Claude Code in that project — it sees your full history from the start.

## Commands

Eagle Mem gives you terminal commands for when you need to look something up or manage your data outside of Claude Code.

### Search past sessions

```bash
eagle-mem search "auth middleware"
```

Searches across session summaries, Claude memories, and indexed code using FTS5. Use this when you know you worked on something last week but can't remember the details.

```bash
eagle-mem search --timeline
```

Shows your most recent sessions in chronological order — useful for catching up after a break.

### View or set your project overview

```bash
eagle-mem overview
```

Shows the overview that gets injected into every Claude Code session. This is what Claude reads first to understand your project.

```bash
eagle-mem overview set "My app is a Next.js dashboard for monitoring API health..."
```

Set a custom overview. You can also let Claude write one for you by running `/eagle-mem-overview` inside a Claude Code session — it reads your README, entry points, and git history to synthesize one.

### Sync everything

```bash
eagle-mem refresh
```

Run this inside a project directory after major changes (new packages, restructured directories, pulling a large branch). It re-scans the codebase, re-indexes source files, and syncs any new Claude Code memories and tasks.

### Other commands

| Command | When to use it |
|---------|---------------|
| `eagle-mem scan` | Re-analyze codebase structure (languages, frameworks, entry points) |
| `eagle-mem index` | Re-index source files for code search |
| `eagle-mem memories` | View or sync mirrored Claude Code memories and plans |
| `eagle-mem tasks` | View mirrored Claude Code tasks |
| `eagle-mem prune` | Clean up old observations and orphaned code chunks |

## Skills (inside Claude Code)

Inside a Claude Code session, you have slash commands that let Claude do the work for you:

### `/eagle-mem-search`

Search past sessions from within Claude Code. Claude interprets results and connects them to your current work — better than raw terminal search when you need context, not just a match.

### `/eagle-mem-overview`

Build a rich project briefing. Claude reads your README, entry points, recent git history, and current codebase to write a 2-3 paragraph overview that captures what the project *does*, not just its file counts. This overview is injected at every session start.

### `/eagle-mem-tasks`

Break complex work into tasks that survive `/compact`. Uses Claude Code's native `TaskCreate`/`TaskUpdate` with dependency support. When context fills up and you compact, Eagle Mem re-injects the task state so Claude picks up where it left off.

### Other skills

| Skill | What it does |
|-------|-------------|
| `/eagle-mem-scan` | Analyze codebase structure — languages, frameworks, entry points |
| `/eagle-mem-index` | Index source files for FTS5 code search |
| `/eagle-mem-memories` | View, search, and sync Claude Code's mirrored memories and plans |
| `/eagle-mem-prune` | Database hygiene — graduated cleanup of stale data |

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
