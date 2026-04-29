```
======================================
Eagle Mem
======================================
```

# Eagle Mem

Persistent memory for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Every session starts with context from previous sessions — summaries, memories, tasks, and project overviews — injected automatically via hooks.

**Zero per-instance overhead.** No daemon, no vector DB, no MCP server. Just bash scripts, sqlite3, and jq.

## Getting started

```bash
npm install -g eagle-mem
eagle-mem install
```

That's it. Open Claude Code in any project directory. Eagle Mem activates automatically:

```
======================================
       Eagle Mem Loaded
======================================
 Project      | my-app
 Sessions     | 42 (18 with summaries)
 Memories     | 7 stored
 Tasks        | 1 in progress, 3 pending
 Code Index   | 156 chunks
 Last Work    | Added auth middleware with JWT validation
======================================
```

Everything is automatic from here. Eagle Mem scans your codebase, indexes source files, captures session summaries, mirrors Claude's memories and tasks, learns which commands are noisy, and prunes stale data — all in the background via hooks.

## Commands

Six commands. Three for lifecycle, three for when you need to look something up or troubleshoot.

| Command | What it does |
|---------|-------------|
| `eagle-mem install` | First-time setup: hooks, database, skills |
| `eagle-mem update` | Re-deploy hooks and run migrations after `npm update` |
| `eagle-mem uninstall` | Remove hooks and optionally delete data |
| `eagle-mem search "query"` | Search past sessions, memories, and code (FTS5) |
| `eagle-mem health` | Diagnose pipeline health and background automation |
| `eagle-mem config` | View or change LLM provider settings |

## Skills (inside Claude Code)

| Skill | What it does |
|-------|-------------|
| `/eagle-mem-search` | Search memory and past sessions — Claude interprets results in context |
| `/eagle-mem-overview` | Build a rich project briefing from README, entry points, and git history |
| `/eagle-mem-memories` | View and search mirrored Claude Code memories and plans |
| `/eagle-mem-tasks` | TaskAware Compact Loop — break complex work into tasks that survive `/compact` |

## How it works

Six hooks fire automatically at different points in Claude Code's lifecycle:

| Hook | Fires when | What it does |
|------|-----------|--------------|
| **SessionStart** | startup, resume, clear, compact | Injects overview, summaries, memories, tasks. Auto-provisions new projects (scan, index). |
| **PreToolUse** | before Bash and Read calls | Rewrites noisy commands (learned rules), detects redundant reads |
| **UserPromptSubmit** | user sends a message | FTS5 search for relevant past context |
| **PostToolUse** | after tool calls | Records file touches, mirrors memory/plan/task writes, tracks modifications |
| **Stop** | Claude's turn ends | Extracts `<eagle-summary>`, strips `<private>` tags |
| **SessionEnd** | session closes | Re-syncs tasks, marks session completed |

### Background automation

These run automatically via SessionStart — no commands needed:

- **Auto-scan** — new project with no overview triggers a codebase scan
- **Auto-index** — new or stale project triggers FTS5 source indexing
- **Auto-prune** — observations over 10K rows trigger cleanup
- **Auto-curate** — the self-learning curator analyzes observation data and generates project-specific command rules (requires LLM provider)

### Token savings

Eagle Mem actively reduces token consumption:

- **Injection compression** — zero-value stats are elided from the banner, overview is capped, compact reloads get 1 recent session instead of 3
- **Command rewriting** — PreToolUse rewrites noisy Bash commands to pipe through `head -N` via `updatedInput`. Rules are learned by the curator from real usage, not hardcoded.
- **Read-after-modify detection** — detects when you read a file that was just edited or written, nudges that the diff is already in context
- **Read dedup tracking** — files read 3+ times in a session get a soft nudge

### Data

Single SQLite database at `~/.eagle-mem/memory.db` (WAL mode, FTS5 full-text search):

| Table | What it stores |
|-------|---------------|
| sessions | Active/completed sessions per project |
| summaries | Per-session summaries (FTS5-indexed) |
| observations | Per-tool-use file touch records |
| overviews | One overview per project (auto-scan or manual) |
| code_chunks | FTS5-indexed source file chunks |
| command_rules | Curator-learned command output rules |
| claude_memories | Mirror of Claude Code auto-memories |
| claude_plans | Mirror of Claude Code plans |
| claude_tasks | Mirror of Claude Code tasks |

## Prerequisites

- `sqlite3` with FTS5 support (ships with macOS; the installer offers to install if missing)
- `jq` (the installer offers to install if missing)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed (`~/.claude/` must exist)

## License

MIT
