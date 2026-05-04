```
======================================
       Eagle Mem
 shared memory | guardrails | lanes
======================================
```

# Eagle Mem

**Shared memory, release guardrails, and worker lanes for Claude Code and Codex.**

Eagle Mem turns AI coding sessions into compounding project knowledge. It gives Claude Code and Codex the same local memory, labels which agent created each memory, blocks risky release commands until affected features are verified, and lets broad work split into durable worker lanes.

**v4.8.5 hardens first-run setup:** `eagle-mem config init` now falls through cleanly when Ollama is not running, and DB-backed commands fail loudly when the active `sqlite3` lacks FTS5 support.

**Website:** [Product](https://eagleisbatman.github.io/eagle-mem/) |
[Architecture](https://eagleisbatman.github.io/eagle-mem/architecture.html) |
[About](https://eagleisbatman.github.io/eagle-mem/about.html)

## Why People Install It

- **Start warmer** - every new session can recall project overviews, decisions, gotchas, summaries, hot files, mirrored memories, plans, and tasks.
- **Ship safer** - feature-mapped changes create pending verification records, and release-boundary commands stay blocked until the current diff is verified or waived.
- **Waste fewer tokens** - Eagle Mem injects compact context, nudges duplicate reads, and can route noisy shell output through RTK.
- **Coordinate agents** - Codex and Claude Code can share one project memory while worker lanes record owner, model, effort, worktree, logs, validation, and handoff.
- **Stay local** - no daemon, no hosted memory service, no vector database. The core is hooks plus SQLite/FTS5.

## The Problem

Claude Code and Codex start every session with amnesia. They don't remember what you built yesterday, what decisions you made, what files matter, or what broke last time. Every `/compact` wipes context. Every new session is a cold start. You waste tokens re-explaining your project, re-reading files, and watching agents repeat mistakes you already corrected.

The longer you work with Claude Code, the worse this gets. Projects accumulate history — decisions, gotchas, architectural patterns, feature dependencies — and none of it survives across sessions.

## The Product

Eagle Mem is a local runtime layer for AI coding agents. It adds three things that ordinary agent sessions do not have by default:

| Layer | What users feel | What Eagle Mem does |
|-------|-----------------|---------------------|
| **Recall** | "The agent remembers this repo." | Loads project overviews, summaries, decisions, memories, tasks, plans, and relevant indexed code. |
| **Guardrails** | "The agent cannot casually undo known decisions or push unverified feature changes." | Surfaces decisions before edits and enforces feature verification on push, PR, and publish boundaries. |
| **Lanes** | "A big task can survive compaction and split across agents." | Persists orchestrations, worker lanes, worktrees, logs, validation commands, and handoffs. |

Both agents share the same SQLite database at `~/.eagle-mem/memory.db`, and captured rows are source-attributed as `Claude Code` or `Codex`.

**Zero per-instance overhead.** No daemon, no vector DB, no MCP server. Just bash scripts, sqlite3 (WAL mode, FTS5 full-text search), and jq.

```
======================================
       Eagle Mem Recall Ready
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

That's it. Open Claude Code or Codex in any project directory. Eagle Mem activates automatically.

Everything is automatic from here. Eagle Mem scans your codebase, indexes source files, captures session summaries, mirrors Claude's memories and tasks, learns which commands are noisy, prunes stale data, and installs patch bug fixes — all in the background via hooks.

For Codex, the installer enables `codex_hooks` in `~/.codex/config.toml`, registers hooks in `~/.codex/hooks.json`, symlinks Eagle Mem skills into `~/.codex/skills`, and patches `~/.codex/AGENTS.md` with the Eagle Mem summary contract. For Claude Code, it keeps using `~/.claude/settings.json`, `CLAUDE.md`, `~/.claude/skills`, and the existing Claude memory/task locations.

### Prerequisites

- `sqlite3` with FTS5 support (ships with macOS; the installer offers to install if missing)
- `jq` (the installer offers to install if missing)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Codex, or both installed

## How It Works

Hooks fire automatically at different points in the agent lifecycle:

| Hook | Fires When | What It Does |
|------|-----------|--------------|
| **SessionStart** | startup, resume, clear, compact | Injects overview, summaries, memories, tasks, core files, working set. Auto-provisions new projects (scan, index). |
| **PreToolUse** | before Bash/shell, Read, Edit, Write, apply_patch | Surfaces guardrails and decisions before edits. Blocks release-boundary commands while feature verification is pending. Rewrites noisy commands through RTK when available. Detects redundant reads, nudges co-edit partners, detects stuck loops. |
| **UserPromptSubmit** | user sends a message | FTS5 search across past sessions and indexed code for relevant context |
| **PostToolUse** | after tool calls | Records file touches, mirrors memory/plan/task writes, surfaces decision history and feature impacts on reads, stale memory warnings on edits |
| **Stop** | agent turn ends | Extracts `<eagle-summary>` blocks for rich session summaries from Claude Code and Codex transcripts |
| **SessionEnd** | session closes | Re-syncs tasks, marks session completed |

Codex shell hooks are registered for `Bash`, `exec_command`, `shell_command`, and `unified_exec` tool names so release-boundary protection works across current Codex shell paths.
Codex recall is emitted as compact hook JSON, so local Codex sessions get shared memory without the multi-screen hook dumps.

### Background Automation

These run automatically via SessionStart — no commands needed:

- **Auto-scan** — new project with no overview triggers a codebase scan
- **Auto-index** — new or stale project triggers FTS5 source indexing
- **Auto-prune** — observations over 10K rows trigger cleanup
- **Auto-curate** — the self-learning curator analyzes observation data and generates command rules, co-edit patterns, hot file detection, and guardrails (partially requires LLM provider)
- **Auto-update** — patch releases install automatically by default, then hooks, skills, migrations, and runtime files refresh through `eagle-mem update`

### Token Savings

Eagle Mem actively reduces token consumption:

- **Injection compression** — zero-value stats are elided from the banner, overview is capped, compact reloads get 1 recent session instead of 3
- **Command rewriting** — PreToolUse routes noisy shell output through RTK when available and blocks known raw-output commands in enforce mode when RTK is missing.
- **Read-after-modify detection** — detects when you read a file that was just edited or written, nudges that the diff is already in context
- **Read dedup tracking** — files read 3+ times in a session get a soft nudge
- **Co-edit nudges** — learned from observation data: when you edit file X, PreToolUse reminds you that you usually also touch file Y
- **Hot file awareness** — curator identifies files read in 50%+ of sessions; SessionStart flags them as "likely in context" to reduce re-reads
- **Working set recovery** — on compact, SessionStart injects the files you were actively editing so you resume without re-reading everything
- **Stuck loop detection** — if the same file is edited 5+ times in one session, PreToolUse nudges to reconsider the approach
- **RTK token guard** — optional `rtk` integration can rewrite or block noisy shell commands before raw output enters Claude Code or Codex context. Configure with `eagle-mem config set token_guard.rtk auto|off|enforce`.

### Anti-Regression

Eagle Mem prevents Claude from repeating past mistakes:

- **Decision surfacing** — when you edit a file that has past decisions recorded (from `<eagle-summary>` blocks), PreToolUse reminds Claude not to revert without asking
- **Guardrails** — file-level rules (manual or curator-discovered) that fire before every Edit/Write
- **Feature verification** — tracks features with smoke tests and dependencies; current git diffs create fingerprinted pending verification records, and release-boundary commands such as `git push`, `gh pr create`, and package publish are blocked until the current fingerprint is verified or waived
- **Gotcha surfacing** — past surprises and gotchas are surfaced when editing related files
- **Stale memory detection** — warns when edits may contradict stored memories
- **Token guard** — when `rtk` is installed, raw shell output commands are rewritten or blocked with an RTK equivalent so large output is compacted before it enters agent context
- **Orchestration lanes** — long-running work can be split into durable worker lanes with owners, validation commands, worktree paths, status notes, and handoff output shared by Claude Code and Codex

## Commands

| Command | What It Does |
|---------|-------------|
| `eagle-mem install` | First-time setup: hooks, database, skills |
| `eagle-mem update` | Re-deploy hooks and run migrations after `npm update` |
| `eagle-mem uninstall` | Remove hooks and optionally delete data |
| `eagle-mem search` | Search past sessions, memories, and code |
| `eagle-mem health` | Diagnose pipeline health and background automation |
| `eagle-mem config` | View or change LLM provider and token-guard settings |
| `eagle-mem updates` | View or change auto-update policy |
| `eagle-mem guard` | Manage regression guardrails for files |
| `eagle-mem overview` | Build or view project overview |
| `eagle-mem session` | Save a manual fallback session summary |
| `eagle-mem memories` | View/sync agent memories |
| `eagle-mem tasks` | View mirrored tasks |
| `eagle-mem orchestrate` | Coordinate durable worker lanes across agents |
| `eagle-mem curate` | Run curator (co-edits, hot files, guardrails) |
| `eagle-mem feature` | Track and verify features |
| `eagle-mem prune` | Clean old sessions and stale data |
| `eagle-mem scan` | Scan codebase and generate overview |
| `eagle-mem index` | Index source files for FTS5 code search |

### v4.9.3 Patch

Follow-up hardening for the v4.9.2 project-key repair: Claude transcript workspace detection now reads complete early JSONL records instead of a fixed byte slice, so large SessionStart hook context cannot hide the first `cwd`. Metadata-only memory/plan/task repairs also avoid touching FTS-indexed columns, preventing SQLite FTS update triggers from firing during safe project/source rekeys.

### v4.9.2 Patch

Nested-repo Claude Code projects now use one stable project key. When a Claude workspace contains a git repo subdirectory, hooks prefer the Claude transcript workspace root while repo-local CLI commands can still use git-root keys where appropriate. Memory sync and backfill also repair unchanged memory rows whose content hash stayed the same but whose project key was stale. FTS5 update triggers now ignore metadata-only project rekeys, avoiding SQLite virtual-table errors during safe repairs.

Installer parity also improved: first-time install now auto-provisions RTK when Cargo is available, the Eagle Mem statusline shows version/session/memory/turn counts, `eagle-mem statusline` is available as a CLI command, and Codex instructions explicitly call out that Codex currently has hook recall plus the statusline command rather than Claude Code's persistent custom statusline UI.

### v4.9.1 Patch

`eagle-mem updates status` now refreshes the npm version live, and install/update seed the local latest-version cache with the installed version. This avoids confusing status output immediately after an update.

### v4.9.0 Patch

Eagle Mem now auto-updates by default for patch bug fixes. SessionStart performs a throttled background npm check, applies eligible patch releases with a lock and runtime/database backup, runs `eagle-mem update`, and records a one-time notice for the next session. Minor and major releases stay outside the default auto-apply range unless users opt in with `eagle-mem updates enable minor` or `eagle-mem updates enable major`.

### v4.8.6 Patch

`eagle-mem session save --summary "..."` now exists as a clean manual fallback for agents that need to persist an explicit session note. It writes through the same `sessions` and `summaries` tables used by Stop hooks, keeps Claude Code/Codex source attribution, and is immediately searchable through normal recall.

### v4.8.5 Patch

First-run configuration no longer exits silently when Ollama is not listening on `localhost:11434`; Eagle Mem falls through to the installed Codex/Claude CLI provider or API-key providers. SQLite/FTS5 failures are now surfaced before DB-backed commands run, including the exact `sqlite3` binary being used and PATH guidance for common macOS Android SDK shadowing. Worker worktree paths are also canonicalized back to the main project key so backfill cannot move feature guardrails into disposable orchestration worktrees.

### v4.8.4 Patch

The orchestration handoff path is now Bash 3.2-safe, so `eagle-mem orchestrate handoff` works even when no lane options are present. This patch was verified with a real Codex coordinator -> Claude Code worker proof lane using `claude-opus-4-7` at `xhigh`; the completed lane is visible through `eagle-mem orchestrate --json`, `eagle-mem tasks completed`, and the generated handoff output. Release-boundary detection also ignores Eagle Mem's own `feature verify`/`waive` commands, so verification notes can mention dry-run checks without blocking themselves.

### v4.8.3 Patch

GitHub Pages now keeps hero text readable over the terminal background and the homepage explicitly explains installer-created/updated `CLAUDE.md` and `AGENTS.md` sections plus orchestrator/worker mode. Installer/update output also uses the new clean-output Codex wording instead of saying it added eagle-summary instructions.

### v4.8.2 Patch

Codex no longer gets instructed to print large user-visible `<eagle-summary>` XML blocks. The installer/update path rewrites existing `~/.codex/AGENTS.md` Eagle Mem instructions to the clean-output contract, context-pressure nudges use normal prose, and Codex-oriented skills/worker prompts avoid raw capture templates.

### v4.8.1 Patch

`eagle-mem memories sync` is now safe on large Claude Code/Codex memory files. The memory mirror parser no longer uses early-exit pipelines under `pipefail`, avoiding exit `141` during sync.

### Search Modes

```bash
eagle-mem search "auth bug"        # keyword search across summaries
eagle-mem search --timeline        # recent sessions in chronological order
eagle-mem search --overview        # project overview
eagle-mem search --memories        # mirrored agent memories
eagle-mem search --tasks           # in-flight tasks (pending/in-progress)
eagle-mem search --files           # most frequently modified files
eagle-mem search --stats           # project statistics
eagle-mem search --session <id>    # full observation trail for one session
eagle-mem session save --summary "fixed auth flow"  # manual fallback capture
eagle-mem updates status           # auto-update state and policy
```

### Feature Verification

```bash
eagle-mem feature pending
eagle-mem feature verify "Feature name" --notes "smoke test passed"
eagle-mem feature waive 12 --reason "docs-only change, no runtime impact"
```

Verification is tied to the current git diff fingerprint. If the same diff was already verified, release-boundary hooks do not reopen it. If the file changes again, Eagle Mem creates a new pending verification for the new fingerprint.

Dry-run validation stays unblocked. For example, `gh pr create --dry-run` and `npm publish --dry-run` are treated as validation. Explicit real commands such as `npm publish --dry-run=false` are treated as release boundaries and will enforce pending feature verification.

### Orchestrator/Worker Lanes

Use orchestration when a broad task is split across Claude Code, Codex, subagents, or separate worktrees. These are **agent-run commands**: Eagle Mem injects the protocol into Claude Code/Codex, and the active agent runs the lane/status/spawn commands itself. Users should not have to operate this manually.

By default Eagle Mem uses the opposite-agent worker model:

- Codex coordinator -> Claude Code worker using `claude-opus-4-7` at `xhigh`
- Claude Code coordinator -> Codex worker using `gpt-5.5` at `xhigh`

Worker models, effort, route, and worktree behavior are configurable in `~/.eagle-mem/config.toml` under `[orchestration]`.

```bash
eagle-mem orchestrate init "Ship auth cleanup"
eagle-mem orchestrate lane add api --agent codex --desc "API fixes + tests" --validate "npm test"
eagle-mem orchestrate lane add docs --agent claude-code --desc "README and release notes"
eagle-mem orchestrate spawn api
eagle-mem orchestrate sync
eagle-mem orchestrate complete
eagle-mem orchestrate handoff --write docs/handoff-context.md
```

`spawn` creates a git worktree, writes a self-contained worker prompt, launches the selected worker CLI, captures its log/exit status under `~/.eagle-mem/orchestrations/`, and updates lane/task state when the worker finishes. Worker hooks export the original Eagle Mem project name, so observations and summaries created inside worktrees still attach to the main project memory.
Use `lane complete` or `lane block` manually only when work happened outside the wrapper or the worker needs an explicit correction.

Each lane is stored in `orchestration_lanes` and mirrored into `agent_tasks`, so the next Claude Code or Codex session sees what is pending, who owns it, which worktree/log belongs to it, and how to validate it.

### Shared Claude Code + Codex Memory

Both agents write to `~/.eagle-mem/memory.db`:

- `sessions.agent` records whether a session came from Claude Code or Codex
- `summaries.agent` records which agent produced the session summary
- mirrored memories, plans, and tasks include `origin_agent`
- SessionStart recall labels sources as `Claude Code` or `Codex`

That means opening the same project in Claude Code and Codex does not create two isolated memory worlds. They recall the same project history while preserving the source of each memory.

## Skills (Inside Claude Code and Codex)

| Skill | What It Does |
|-------|-------------|
| `/eagle-mem-search` | Search memory and past sessions — Claude interprets results in context |
| `/eagle-mem-overview` | Build a rich project briefing from README, entry points, and git history |
| `/eagle-mem-memories` | View and search mirrored agent memories and plans |
| `/eagle-mem-tasks` | TaskAware Compact Loop — break complex work into tasks that survive `/compact` |
| `/eagle-mem-orchestrate` | Orchestrator/worker lane handoffs across Claude Code and Codex |

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
| `features` | Feature tracking with names and descriptions |
| `feature_files` | Files belonging to each feature |
| `feature_dependencies` | Inter-feature dependency relationships |
| `feature_smoke_tests` | Smoke test definitions for feature verification |
| `pending_feature_verifications` | Release blockers created when files tied to features change |
| `orchestrations` | Durable multi-agent work plans per project |
| `orchestration_lanes` | Worker lane ownership, status, validation, worktree, and notes |
| `eagle_meta` | Internal metadata (last scan, last curate, etc.) |
| `agent_memories` | Mirror of agent memory files, with source attribution |
| `agent_plans` | Mirror of agent plan files, with source attribution |
| `agent_tasks` | Mirror of agent task records, with source attribution |

### Project Identity

Projects are identified by their HOME-relative path (e.g., `personal_projects/eagle-mem`). This ensures uniqueness even when multiple projects share the same directory name. Git repositories use the repo root; non-git directories use the working directory.

### Namespace Migration

When upgrading from older versions, `eagle-mem update` automatically migrates project data to the new namespace format. The migration preserves newer data when conflicts exist and cleans up stale entries.

## LLM Provider (Optional)

Some features (curator auto-enrichment, overview generation) can use an LLM for richer output. Configure with:

```bash
eagle-mem config
eagle-mem config set provider.type agent_cli
eagle-mem config set agent_cli.preferred current
```

Provider preference is local-first: Ollama is auto-detected when running, then Eagle Mem can use the installed Codex/Claude CLI via `agent_cli` before falling back to explicit Anthropic/OpenAI API providers. Eagle Mem works fully without a provider — LLM features gracefully degrade to heuristic fallbacks.

RTK is configured separately from the LLM provider:

```bash
eagle-mem config set token_guard.rtk auto      # default: use RTK when available
eagle-mem config set token_guard.rtk enforce   # block known raw-output commands if RTK is missing
eagle-mem config set token_guard.rtk off       # disable RTK behavior
eagle-mem config set token_guard.raw_bash block
```

## License

MIT
