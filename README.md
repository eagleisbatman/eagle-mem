```
======================================
       Eagle Mem
======================================
```

# Eagle Mem

## The Problem

Claude Code starts every session with amnesia. It doesn't remember what you built yesterday, what decisions you made, what files matter, or what broke last time. Every `/compact` wipes context. Every new session is a cold start. You waste tokens re-explaining your project, re-reading files, and watching Claude repeat mistakes you already corrected.

The longer you work with Claude Code, the worse this gets. Projects accumulate history — decisions, gotchas, architectural patterns, feature dependencies — and none of it survives across sessions.

## The Solution

Eagle Mem gives Claude Code persistent memory. Every session starts with context from previous sessions — summaries, decisions, memories, tasks, project overviews, and relevant code — injected automatically via hooks. No commands to run, no prompts to write. It just works.

**Zero per-instance overhead.** No daemon, no vector DB, no MCP server. Just bash scripts, sqlite3 (WAL mode, FTS5 full-text search), and jq.

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

## Getting Started

```bash
npm install -g eagle-mem
eagle-mem install
```

That's it. Open Claude Code in any project directory. Eagle Mem activates automatically.

Everything is automatic from here. Eagle Mem scans your codebase, indexes source files, captures session summaries, mirrors Claude's memories and tasks, learns which commands are noisy, and prunes stale data — all in the background via hooks.

### Prerequisites

- `sqlite3` with FTS5 support (ships with macOS; the installer offers to install if missing)
- `jq` (the installer offers to install if missing)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed (`~/.claude/` must exist)

## How It Works

Six hooks fire automatically at different points in Claude Code's lifecycle:

| Hook | Fires When | What It Does |
|------|-----------|--------------|
| **SessionStart** | startup, resume, clear, compact | Injects overview, summaries, memories, tasks, core files, working set. Auto-provisions new projects (scan, index). |
| **PreToolUse** | before Bash, Read, Edit, Write | Surfaces guardrails and decisions before edits. Rewrites noisy commands (learned rules). Detects redundant reads, nudges co-edit partners, detects stuck loops. |
| **UserPromptSubmit** | user sends a message | FTS5 search across past sessions and indexed code for relevant context |
| **PostToolUse** | after tool calls | Records file touches, mirrors memory/plan/task writes, surfaces decision history on reads |
| **Stop** | Claude's turn ends | Extracts `<eagle-summary>` blocks for rich session summaries |
| **SessionEnd** | session closes | Re-syncs tasks, marks session completed |

### Background Automation

These run automatically via SessionStart — no commands needed:

- **Auto-scan** — new project with no overview triggers a codebase scan
- **Auto-index** — new or stale project triggers FTS5 source indexing
- **Auto-prune** — observations over 10K rows trigger cleanup
- **Auto-curate** — the self-learning curator analyzes observation data and generates command rules, co-edit patterns, hot file detection, and guardrails (partially requires LLM provider)

### Token Savings

Eagle Mem actively reduces token consumption:

- **Injection compression** — zero-value stats are elided from the banner, overview is capped, compact reloads get 1 recent session instead of 3
- **Command rewriting** — PreToolUse rewrites noisy Bash commands to pipe through `head -N` via `updatedInput`. Rules are learned by the curator from real usage, not hardcoded.
- **Read-after-modify detection** — detects when you read a file that was just edited or written, nudges that the diff is already in context
- **Read dedup tracking** — files read 3+ times in a session get a soft nudge
- **Co-edit nudges** — learned from observation data: when you edit file X, PreToolUse reminds you that you usually also touch file Y
- **Hot file awareness** — curator identifies files read in 50%+ of sessions; SessionStart flags them as "likely in context" to reduce re-reads
- **Working set recovery** — on compact, SessionStart injects the files you were actively editing so you resume without re-reading everything
- **Stuck loop detection** — if the same file is edited 5+ times in one session, PreToolUse nudges to reconsider the approach

### Anti-Regression

Eagle Mem prevents Claude from repeating past mistakes:

- **Decision surfacing** — when you edit a file that has past decisions recorded (from `<eagle-summary>` blocks), PreToolUse reminds Claude not to revert without asking
- **Guardrails** — file-level rules (manual or curator-discovered) that fire before every Edit/Write
- **Feature verification** — tracks features with smoke tests and dependencies; reminds you to verify on `git push`
- **Gotcha surfacing** — past surprises and gotchas are surfaced when editing related files

## Commands

| Command | What It Does |
|---------|-------------|
| `eagle-mem install` | First-time setup: hooks, database, skills |
| `eagle-mem update` | Re-deploy hooks and run migrations after `npm update` |
| `eagle-mem uninstall` | Remove hooks and optionally delete data |
| `eagle-mem search` | Search past sessions, memories, and code |
| `eagle-mem health` | Diagnose pipeline health and background automation |
| `eagle-mem config` | View or change LLM provider settings |
| `eagle-mem guard` | Manage regression guardrails for files |
| `eagle-mem overview` | Build or view project overview |
| `eagle-mem memories` | View/sync Claude Code memories |
| `eagle-mem tasks` | View mirrored tasks |
| `eagle-mem curate` | Run curator (co-edits, hot files, guardrails) |
| `eagle-mem feature` | Track and verify features |
| `eagle-mem prune` | Clean old sessions and stale data |
| `eagle-mem scan` | Scan codebase and generate overview |
| `eagle-mem index` | Index source files for FTS5 code search |

### Search Modes

```bash
eagle-mem search "auth bug"        # keyword search across summaries
eagle-mem search --timeline        # recent sessions in chronological order
eagle-mem search --overview        # project overview
eagle-mem search --memories        # mirrored Claude Code memories
eagle-mem search --tasks           # in-flight tasks (pending/in-progress)
eagle-mem search --files           # most frequently modified files
eagle-mem search --stats           # project statistics
eagle-mem search --session <id>    # full observation trail for one session
```

## Skills (Inside Claude Code)

| Skill | What It Does |
|-------|-------------|
| `/eagle-mem-search` | Search memory and past sessions — Claude interprets results in context |
| `/eagle-mem-overview` | Build a rich project briefing from README, entry points, and git history |
| `/eagle-mem-memories` | View and search mirrored Claude Code memories and plans |
| `/eagle-mem-tasks` | TaskAware Compact Loop — break complex work into tasks that survive `/compact` |

## Data

Single SQLite database at `~/.eagle-mem/memory.db` (WAL mode, FTS5 full-text search):

| Table | What It Stores |
|-------|---------------|
| `sessions` | Active/completed sessions per project |
| `summaries` | Per-session summaries with decisions, gotchas, key files (FTS5-indexed) |
| `observations` | Per-tool-use file touch records |
| `overviews` | One overview per project (auto-scan or manual) |
| `code_chunks` | FTS5-indexed source file chunks |
| `command_rules` | Curator-learned command output rules |
| `file_hints` | Curator-learned file access patterns (co-edit pairs, hot files) |
| `guardrails` | File-level regression rules (manual or curator-discovered) |
| `features` | Feature tracking with smoke tests and dependencies |
| `eagle_meta` | Internal metadata (last scan, last curate, etc.) |
| `claude_memories` | Mirror of Claude Code auto-memories |
| `claude_plans` | Mirror of Claude Code plans |
| `claude_tasks` | Mirror of Claude Code tasks |

### Project Identity

Projects are identified by their HOME-relative path (e.g., `personal_projects/eagle-mem`). This ensures uniqueness even when multiple projects share the same directory name. Git repositories use the repo root; non-git directories use the working directory.

### Namespace Migration

When upgrading from older versions, `eagle-mem update` automatically migrates project data to the new namespace format. The migration preserves newer data when conflicts exist and cleans up stale entries.

## LLM Provider (Optional)

Some features (curator auto-enrichment, overview generation) can use an LLM for richer output. Configure with:

```bash
eagle-mem config
```

Supported providers: Ollama (auto-detected), Anthropic, OpenAI. Eagle Mem works fully without a provider — LLM features gracefully degrade to heuristic fallbacks.

## License

MIT
