# Changelog

All notable changes to the **Eagle Mem** project are documented here.

---

## v4.13.1 Test-Suite & Packaging Hygiene

Follow-up cleanup that clears the bounded items left after the v4.13.0 review. No runtime behavior change for normal sessions.

- **`eagle-mem test` is now green from a published install.** Two suites failed when run from an installed package rather than a source checkout:
  - *Compaction Survival Matrix* created its fixture repo inside `$ROOT_DIR`; from a published install that path is under `node_modules/`, which the code scanner excludes — so the fixture indexed 0 files and the post-compact "Relevant Code" recall never appeared. The fixture now lives in a neutral system temp dir and is indexed explicitly (no longer relying on a racy background auto-index).
  - *Rust Migration Plan* guards `MIGRATION.md`, a maintainer roadmap intentionally not shipped in the npm package. It now **skips cleanly** when the doc is absent and runs strictly from a source checkout.
  - The test runner learned an honest **"skipped"** state (a dev-only contract test with absent preconditions is neither a pass nor a failure).
- **Antigravity Python hook test is now in the suite.** `tests/test_antigravity_hook.py` (mocked, stdlib-only) ran only by hand before; it's now a guarded python lane that skips cleanly if `python3` is unavailable.
- **One source of truth for Claude hook registration.** `install.sh` and `update.sh` each held their own copy of the event→matcher→script mapping (the historical drift class). Extracted `eagle_register_claude_hooks` into `lib/hooks.sh`; both call it (installer verbose, updater quiet). Behavior preserved exactly.
- **Dead-function sweep — analyzed, nothing removed.** A full cross-surface call-graph (`.sh`/`.py`/`.js`/skills/`bin`, 280 functions) found zero unreferenced functions and no computed-name dispatch; the "no shell caller" candidates are all reached via tests, skills, adapters, or the public CLI. Removing any would be regression risk with no benefit.

---

## v4.13.0 Full-Spectrum Security & Reliability Hardening

A six-lens fix-in-place review of the whole codebase (security, data integrity, reliability, token economy, code quality, architecture). 32 files hardened, 6 new regression suites, full smoke suite green. No behavioral surface for normal sessions changed — recall and capture are byte-for-byte the same; what changed is the failure, concurrency, and trust behavior underneath.

**Security**
- **Unattended workers no longer default to full access (highest severity).** Orchestration workers previously spawned `--sandbox danger-full-access` / `--permission-mode dontAsk` on prompts assembled from DB-stored lane text — a stored-prompt-injection path to unattended arbitrary execution. New `[orchestration] worker_autonomy` defaults to **safe** (`workspace-write` / `on-request` / `acceptEdits`); `danger` is now an explicit opt-in.
- **LLM inputs are redacted, not just outputs.** Transcript excerpts sent to providers (including remote APIs via fallback) and persisted to the enrich job file are now run through `eagle_redact` before send/persist; `recall_events.prompt_snippet` is redacted before insert; the Bash command summary is redacted *before* truncation so a boundary-split secret can't leak.
- **Antigravity binary-hijack fix.** The Python hook resolves `bin/eagle-mem` and hook scripts from its install dir instead of `os.getcwd()`, and validates `SESSION_ID`.
- Prompts passed to provider CLIs now go over stdin (not `ps`-visible argv); `logs show|tail` canonicalizes paths (realpath) before the runs-root containment check; the Codex hook passes event names via jq `--arg`; the dead `[redaction] extra_patterns` knob is now wired into `eagle_redact`.

**Data integrity & database**
- **Fail-open `SQLITE_BUSY` reads fixed.** Standalone `sqlite3` reads (statusline, tasks, updater, project-identity lookups) now set `busy_timeout` so a momentary lock waits instead of being misread as "no data."
- **Mod-tracker data-loss & lock-wedge fixed.** Stale-lock TTL reclaim, atomic mv-based pending drain (a concurrent append is never lost), and the edit-history append is now locked. Verified by a 40-parallel-writer regression test.
- Summary `project` is sticky on conflict for agent-authored rows (hook-path project drift can no longer rekey them); added `eagle_db_strict` (`.bail on`) for fail-fast callers; observation dedup runs in `BEGIN IMMEDIATE`.

**Reliability / self-healing**
- **Auto-scan no longer self-blocks for 24h on failure.** A short-lived *in-flight* marker now debounces concurrent spawns, while the durable *freshness* marker is set only on genuine success — a crashed or output-less scan retries instead of being suppressed for a day.
- **`eagle_events` retention.** The hook-observability table (≈99k unbounded rows in practice) is now pruned by age (30 days) at SessionEnd. `pending_feature_verifications` is deliberately left un-pruned (expiring it would let an unverified change ship).

**Token economy**
- **SessionStart injection ceiling.** A generous global budget (`context_budget.sessionstart_chars`, default 24000 chars / ~6K tokens) drops whole low-priority sections from the bottom when the recall body is pathologically large, always keeping overview/recent/memories + capture instructions and never splitting a section. Normal-sized recall is emitted unchanged.

**Code quality**
- **Test runner no longer aborts at the first failure.** `((errors++))` returns exit 1 when the count is 0, so under `set -euo pipefail` the first failing check killed the suite before it could report the count; switched to `errors=$((errors + 1))`.

Full findings report (every item marked fixed-with-its-test or proposed) lives at `docs/reviews/2026-06-10-full-spectrum-hardening.md`, including the propose-only architecture backlog (`common.sh` decomposition, orchestrate lifecycle, curator→guardrail provenance, Grok/bare-shell gate parity).

---

## v4.12.1 Deploy-Path Fixes for v4.12.0

Two install/update-path bugs that defeated or destabilized the v4.12.0 rollout:

- **CLAUDE.md capture doctrine never updated (critical)**: `eagle_patch_claude_md` detected the outdated section with `grep -qF 'request: \[what user asked\] | completed:'`. Under `grep -F` the backslashes are literal, so the pattern never matched the real `[what user asked]` text — the installed CLAUDE.md kept telling agents to emit `<eagle-summary>`, silently defeating the whole clean-capture feature. Detection now keys on the *absence* of the current section's unique `session save --session-id` sentinel, so any pre-CLI-first section is rewritten (and the rewrite is idempotent). New regression test `tests/test_claude_md_capture_doctrine.sh`.
- **Migration runner fail-open on lock**: `db/migrate.sh`'s "already applied?" guard ran a fresh `sqlite3` without `busy_timeout`; a momentary `SQLITE_BUSY` (a hook touching the DB mid-update) made it exit non-zero, the `|| echo 0` fail-open then re-ran an already-applied migration and the body errored with `duplicate column` / UNIQUE-constraint failures. The guard now sets `busy_timeout=5000` and waits for the lock instead of guessing.
- Registered `tests/test_clean_session_capture.sh` and the new doctrine test in `scripts/test.sh` (both were running only when invoked directly).

---

## v4.12.0 Clean, Branded Session Capture

Session endings are now clean across every agent — no more raw `<eagle-summary>` XML blocks in the visible reply.

- **CLI-first capture**: Agents persist structured summaries by running `eagle-mem session save --session-id <id> ...` (a pre-approved, quiet Bash call), then end with a short human recap plus one branded line: `Eagle Mem | Session captured — N decisions, M gotchas`. The installer adds a `permissions.allow` entry so the capture runs without a prompt.
- **Extended `session save`**: New flags `--session-id`, `--completed`, `--investigated`, `--files-read`, `--files-modified`, `--affected-features`, `--verified-features`, `--regression-risks`. With `--session-id` the capture merges into the live session row instead of creating a standalone `manual-*` row, and no longer marks the session completed.
- **Capture-integrity fixes**: New `capture_source` column (`agent`/`hook`/`enrich`) with an atomic fill-only upsert. Agent-authored captures are authoritative — Stop-hook heuristics and background LLM enrichment now only fill empty gaps and can never clobber richer data (previously the winning-COALESCE upsert could overwrite it). Enrichment queueing is skipped once a session is agent-authored.
- **Cross-agent**: Claude Code, Codex, OpenCode, Grok, and Antigravity all capture through the same CLI. Instruction text updated in SessionStart/UserPromptSubmit (Claude + Codex), the installed CLAUDE.md/AGENTS.md sections, and `compaction.sh`.
- **Backward compatible**: The Stop hook still parses any `<eagle-summary>` block it finds; agents are simply no longer instructed to emit one.

---

## v4.11.0 Agent Compatibility and Governance Surfaces

This feature release expands Eagle Mem from Claude/Codex memory hooks into a broader multi-agent governance substrate:

- **Agent Compatibility Docs**: Added official-doc-backed compatibility notes for Claude Code, Codex, and OpenCode hook/plugin behavior.
- **OpenCode Integration**: Added a local OpenCode plugin adapter, hook normalization fixtures, and install/update checks.
- **Compaction Survival**: Expanded compaction recovery tests across summaries, memories, tasks, feature verification, recall, and graph memory.
- **Orchestration Events**: Added durable event tables for orchestration and hook observability, with dashboard and replay/inspect/repair utilities.
- **Trust Surfaces**: Hardened doctor, statusline, JSON output, repair, and release verification behavior with new regression coverage.
- **Web/Docs Refresh**: Updated README, architecture page, and compatibility docs to describe the current hook, plugin, dashboard, and governance model.

---

## v4.10.13 Feature Gate Monorepo Hardening

This hotfix closes the feature verification gate false positives found in monorepos with repeated basenames:

- **Full-Path Feature Matching**: Feature impact lookup now matches exact paths and path-boundary suffixes instead of broad basename-only `%server.js%` patterns when feature files store full paths.
- **LIKE Escaping Hardening**: Feature path matching now treats `%`, `_`, and backslashes literally, preventing stored feature paths from becoming accidental SQL `LIKE` wildcards.
- **Waive Safety**: Waived pending verifications are now scoped to the current change fingerprint, so a future edit to the same feature file reopens verification instead of being permanently bypassed.
- **Release Guard Precision**: Eagle Mem state commands such as `orchestrate` and `tasks` no longer trip the release-boundary guard just because their descriptive text mentions `npm publish` or `git push`.
- **Regression Coverage**: Added end-to-end feature gate coverage for monorepo path collisions, literal wildcard characters in paths, PreToolUse `git push` denial output, and same-fingerprint verification/waive behavior.

---

## v4.10.12 Spectral Review Closure

This patch closes the multi-CLI Spectral review findings on v4.10.11:

- **Run Log Containment**: `eagle-mem logs show|tail` now resolves only run-log IDs, filenames, or absolute paths under `~/.eagle-mem/runs`, preventing arbitrary file reads through the logs subcommand.
- **Run Log Retention**: Added `eagle-mem logs prune --days N --keep N` plus automatic pruning when command-scoped run logs start, defaulting to logs older than 14 days and retaining the latest 50.
- **Run Log Diagnostics**: `eagle_log` messages now mirror into the active command run log, so failure log paths include provider and internal diagnostic messages instead of only command stdout/stderr.
- **PostToolUse Tracker Locking**: Modification tracking now writes every modified file through the same lock path, retries lock acquisition, avoids unlocked appends to the trimmed tracker, and records all files from multi-file `apply_patch` operations.
- **Curator JSON Robustness**: Dream Cycle consolidation parsing now tolerates provider text wrapped around the JSON payload while preserving strict `jq` validation.
- **Regression Coverage**: Expanded reliability tests for log path rejection, log pruning, mirrored run diagnostics, unsupported agent target logging, and multi-file modification tracking.

---

## v4.10.11 Reliability Guards and Provider Fallback

This patch closes the active reliability items that remained after the Dream Cycle hotfix:

- **Command-Scoped Logs**: `scan`, `index`, and `curate` now write per-run logs under `~/.eagle-mem/runs`, preserve normal CLI output, and print the log path on command failure. Added `eagle-mem logs list|tail|show` for inspection.
- **Provider Fallback Transparency**: Provider calls now use an explicit fallback chain. `agent_cli` can fall through from a failed preferred Codex call to Claude Code when available, and provider display now shows the actual chain instead of `unknown`.
- **Read Prediction / Token Guard Scoring**: `PreToolUse` now scores repeated, large, or recently modified reads and emits a targeted read-score nudge. A configurable `read_guard.mode=block` path is available for stricter high-confidence duplicate-read gating.
- **Auto-Scan Retry Reliability**: SessionStart auto-scan/index freshness markers are now cleared when the background job fails, so failed scans do not block retries for the next 24 hours.
- **Hook Field Parsing**: Hook JSON field extraction now uses the intended unit separator in `PreToolUse`, `UserPromptSubmit`, and `Stop`, preserving clean `tool_name`, `session_id`, and `cwd` parsing.
- **Regression Coverage**: Added an isolated reliability test for provider fallback, read scoring, auto-scan failure state cleanup, and run-log creation.

---

## v4.10.10 Dream Cycle Consolidation Hardening

This patch closes the review findings from the multi-model Spectral pass:

- **Structured Consolidation Parsing**: Dream Cycle memory consolidation now asks providers for strict JSON and validates the response with `jq`, removing the brittle `CONSOLIDATE:` text parser that could break on punctuation, arrows, pipes, or whitespace in memory names.
- **Dry-Run Safety**: Memory graph consolidation dry-runs now preview graph wiring and skip the provider call, avoiding token spend and provider side effects during preview.
- **Regression Coverage**: The Dream Cycle regression now covers JSON consolidation with punctuation-heavy names, `NONE` responses, malformed legacy text responses, idempotent reruns, and dry-run provider skipping.
- **Indexer Edge Coverage**: Graph-memory indexing now verifies dot-command-like source lines, leading blank lines, all-whitespace chunks, and empty-file behavior.

---

## v4.10.9 Dream Cycle Graph Memory Hotfix

This hotfix closes the remaining graph-memory curation gap:

- **Memory Node Wiring**: Dream Cycle curation now creates graph `memory` nodes for active mirrored agent memories before consolidation runs, so consolidated memories can supersede real source memory nodes instead of depending on fuzzy or accidental matches.
- **Regression Coverage**: The smoke suite now runs an isolated Dream Cycle graph-memory regression that proves multiline memory content does not become bogus graph nodes and that consolidated memories supersede both originals.

---

## v4.10.8 Graph Neighbors Hotfix

This hotfix tightens the final graph-memory verification path:

- **Exact Neighbor Matching**: `eagle-mem graph neighbors <node>` now prefers exact `node_name` matches before fuzzy matches, and prefers file nodes when names are otherwise ambiguous.
- **Regression Coverage**: The graph-memory regression suite now verifies that `graph neighbors "a.sh"` selects the exact file node rather than a declaration node whose scoped name merely contains the file path.

---

## v4.10.7 Graph Rebuild Hotfix

This hotfix closes an installed-runtime failure found after the v4.10.6 graph-memory release:

- **Import Parser Hardening**: Restricts quoted local import detection to `./` and `../` paths, and limits shell `source` parsing to shell-like files so SQL columns named `source` are not mistaken for shell commands.
- **SQL-Safe Import Lookup**: Escapes import lookup terms before querying graph file nodes, preventing single quotes in source files from breaking `eagle-mem graph rebuild`.
- **Regression Coverage**: Extends the graph-memory regression test with a SQL fixture containing `source TEXT NOT NULL DEFAULT 'manual'`, matching the installed-runtime failure mode.

---

## v4.10.6 Graph Memory Rebuild Release

This patch turns the local graph-memory workarounds into supported product behavior:

- **Official Graph Rebuild Path**: Added `eagle-mem graph rebuild` and `eagle-mem index --force` so stale code chunks, declaration nodes, file nodes, and import edges can be rebuilt without manual SQLite deletes.
- **Graph Node Type Migration**: Added migration `db/038_graph_node_types.sql` to recreate graph node validation triggers with all declaration node types emitted by the indexer: `class`, `struct`, `function`, `func`, `fn`, and `def`.
- **File-Scoped Declarations**: Declaration nodes now use file-scoped names like `path/to/file.sh::finishDictation`, avoiding collisions when multiple files define the same function/class name.
- **Dream Cycle Batching**: Replaced per-edge sqlite subprocess calls in session-to-file graph wiring with one batched transaction, and normalized absolute observation paths back to project-relative graph file nodes.
- **Stale File Filtering**: `eagle_collect_files` now filters deleted-but-tracked paths from `git ls-files`, so scans and rebuilds represent the current filesystem.
- **Overview Graph Sync**: `eagle-mem overview set` now syncs the graph project node value, keeping graph search aligned with the canonical overview.
- **Four-Agent Update Surface**: `eagle-mem update` now refreshes Antigravity integrations and Grok skill links in addition to Claude Code and Codex hooks/skills.

---

## v4.10.5 Hardening Release

This patch release hardens the database architecture, improves CLI usability, and increases programmatic test coverage for all core features:

- **Database-Level Task Deduplication**: Normalized synthetic task file paths to `event://${task_id}` in `hooks/post-tool-use.sh`, making task tracking constant across sessions. Added a partial unique index `idx_agent_tasks_dedup` on `(project, source_task_id)` via migration `db/037_task_dedup.sql` to block duplicate task rows on repeated sync loops.
- **Resilient Curation Engine (`curate.sh`)**: Refactored vulnerable inline conditional `&& continue` statements to safe, standard `if` blocks, preventing pipeline subshell crashes under `set -e` and guaranteeing metadata and footer summaries complete successfully.
- **CLI Usability & Previews (`--help` / `--dry-run`)**: Integrated structured option parsing cases for `-h`/`--help` and `--dry-run` to both `curate.sh` and `install.sh`. Covered all installer filesystem writes, hook updates, and migrations in `install.sh --dry-run` to enable a zero-risk preview of planned changes.
- **Core Smoke Test suite (`test.sh`)**: Expanded the automated smoke test suite to run concrete checks for **7 core features** (`compaction-survival`, `feature-verification`, `grok-cli-integration`, `agent-orchestration`, `Cross Agent Memory`, `Installer And Updater`, `Code Scan And Index`), automatically updating the SQLite database to mark them verified upon success.
- **Stale Task Cleanup**: Resolved compaction warning overhead by marking stale, in-progress tasks (`840`, `895`, `968`, `970`) as `'completed'`.

---

## v4.10.4 Minor Release

This release introduces native relational **Knowledge Graph Memories** and an automated background **Dream Cycle** curator to consolidate multi-agent developer context:

- **Graph-based Memories**: Full integration of custom semantic code graph database primitives (`lib/db-graph.sh` and migrations `db/035_graph_memories.sql` and `db/036_graph_constraints.sql`) to link files, functions, variables, sessions, and memories.
- **Background Dream Cycle Curation**: Structured offline compilation in `scripts/curate.sh` that merges redundant, overlapping memories into clean `--- Compiled Truth ---` with an underlying `--- Evidence Trail ---`.
- **Database Firewalls**: Enforced strict enums check triggers on `node_type` and `edge_type` to guarantee complete data integrity.
- **Sanitized FTS Wildcards**: Safe search query sanitization in `eagle_graph_search` to prevent SQLite MATCH syntax errors on special characters.
- **Unified Global Porting**: Symlinked advanced nested specialist developer skills and HTTP Model Context Protocol (MCP) gateways natively into the Google Antigravity active configuration.

---

## v4.10.2 Patch

This release expands the Eagle Mem adapter layer and addresses multi-agent planning synchronization and gap remediations across all four supported agents:

- **Google Antigravity SDK Hook**: Fully integrated programmatic, asynchronous Python async hooks (`google_antigravity_hook.py`) mapping turn lifecycles (`SessionStart` to `Stop`/`SessionEnd`) and context survival.
- **Automatic Brain Artifact Synchronization**: Extracted and mirrored `implementation_plan.md`, `task.md`, and `walkthrough.md` generated by Claude, Codex, and Antigravity directly to SQLite and FTS5 search indexes.
- **PreToolUse Codex Enhancement**: Removed early-exits to enable full advisory, command rewrite, and feature verification support on Codex shell paths.
- **Agent Settings Backups**: Added timestamped configurations backups (`settings.json.bak` and `config.toml.bak`) before any mutations by the installer/update process.
- **Unified 4-Agent Documentation**: Generalization of the architecture tutorial (`architecture.html`), product README (`README.md`), and developer instructions (`AGENTS.md`) to treat all four agents as first-class, natively supported surfaces.

---

## v4.10.1 Patch

This documentation patch clarifies npm download-count behavior and Eagle Mem privacy expectations:

- npm download counts are aggregate tarball-serving statistics.
- Package maintainers cannot identify who downloaded the package from npm's public stats.
- Eagle Mem remains local-first and does not include install telemetry or phone-home analytics.

---

## v4.10.0 Minor Release

This release makes Eagle Mem broader and safer across agent workflows:

- Grok is now a first-class skill/CLI target: install detects `~/.grok`, links Eagle Mem skills into `~/.grok/skills`, and adds `eagle-mem grok-bootstrap`.
- `eagle-mem compaction` reports Compaction Survival readiness from shared project state: enriched summaries, durable tasks, stale tasks, active lanes, and last durable update.
- `eagle-mem test` provides a built-in smoke harness for the memory layer.
- `eagle-mem tasks stale` and `[STALE - Nd]` warnings make long-running task drift visible.
- `eagle-mem health` now surfaces orchestration lanes, learned command rules, and curator timing.

---

## v4.9.7 Patch

This patch is a release-readiness and UX-hardening pass:

- `eagle-mem doctor` reports the install footprint, selected SQLite binary, FTS5 availability, hook registration, statusline wiring, install-manifest health, and runtime drift.
- Install/update show a clear preflight plan, refresh the manifest, and keep rollback backups aware of the manifest/version files.
- Uninstall supports `--dry-run`, backs up config files, removes Claude/Codex hook and instruction integrations, cleans up skill links, and preserves runtime data by default.
- Claude statusline/HUD rendering is centralized through `scripts/statusline-em.sh --hud`.
- Statusline project resolution now prefers the live session row and avoids `$HOME` ancestor leakage, so new projects show their own sessions/memories instead of stale counts from older workspaces.
- Default hook/search/memory output follows the visible-surface UX contract: branded, compact, freshness-aware, and free of raw IDs/paths unless `--raw`, `--debug`, or `--json` is requested.

---

## v4.9.6 Patch

`eagle-mem update` now queues project-key backfill in the background by default, so install/update can finish, write the installed version marker, and return control to the user. Use `EAGLE_MEM_UPDATE_BACKFILL=sync eagle-mem update` only when you intentionally want to wait for a full backfill.

---

## v4.9.5 Patch

Stop hooks now use a fast path: they save heuristic summaries immediately, extract explicit summary blocks when present, and queue LLM enrichment in the background so Codex/Claude lifecycle hooks do not time out. SQLite access now goes through a shared FTS5-capable binary resolver used by migrations, DB helpers, updater backups, install checks, and the statusline, avoiding Android SDK or other PATH shims that shadow working SQLite builds.

---

## v4.9.4 Patch

Project-key hardening for agents that move between folders: hooks now keep a per-session project identity instead of recalculating from every new cwd, and statuslines prefer the stored session project before falling back to folder paths. Install/update also repairs older embedded Eagle Mem statusline blocks so nested-repo projects stop showing `Memories: 0` when the session belongs to the parent workspace.

---

## v4.9.3 Patch

Follow-up hardening for the v4.9.2 project-key repair: Claude transcript workspace detection now reads complete early JSONL records instead of a fixed byte slice, so large SessionStart hook context cannot hide the first `cwd`. Metadata-only memory/plan/task repairs also avoid touching FTS-indexed columns, preventing SQLite FTS update triggers from firing during safe project/source rekeys.

---

## v4.9.2 Patch

Nested-repo Claude Code projects now use one stable project key. When a Claude workspace contains a git repo subdirectory, hooks prefer the Claude transcript workspace root while repo-local CLI commands can still use git-root keys where appropriate. Memory sync and backfill also repair unchanged memory rows whose content hash stayed the same but whose project key was stale. FTS5 update triggers now ignore metadata-only project rekeys, avoiding SQLite virtual-table errors during safe repairs.

Installer parity also improved: first-time install now auto-provisions RTK when Cargo is available, the Eagle Mem statusline shows version/session/memory/turn counts, `eagle-mem statusline` is available as a CLI command, and Codex instructions explicitly call out that Codex currently has hook recall plus the statusline command rather than Claude Code's persistent custom statusline UI.

---

## v4.9.1 Patch

`eagle-mem updates status` now refreshes the npm version live, and install/update seed the local latest-version cache with the installed version. This avoids confusing status output immediately after an update.

---

## v4.9.0 Patch

Eagle Mem now auto-updates by default for patch bug fixes. SessionStart performs a throttled background npm check, applies eligible patch releases with a lock and runtime/database backup, runs `eagle-mem update`, and records a one-time notice for the next session. Minor and major releases stay outside the default auto-apply range unless users opt in with `eagle-mem updates enable minor` or `eagle-mem updates enable major`.

---

## v4.8.6 Patch

`eagle-mem session save --summary "..."` now exists as a clean manual fallback for agents that need to persist an explicit session note. It writes through the same `sessions` and `summaries` tables used by Stop hooks, keeps Claude Code/Codex source attribution, and is immediately searchable through normal recall.

---

## v4.8.5 Patch

First-run configuration no longer exits silently when Ollama is not listening on `localhost:11434`; Eagle Mem falls through to the installed Codex/Claude CLI provider or API-key providers. SQLite/FTS5 failures are now surfaced before DB-backed commands run, including the exact `sqlite3` binary being used and PATH guidance for common macOS Android SDK shadowing. Worker worktree paths are also canonicalized back to the main project key so backfill cannot move feature guardrails into disposable orchestration worktrees.

---

## v4.8.4 Patch

The orchestration handoff path is now Bash 3.2-safe, so `eagle-mem orchestrate handoff` works even when no lane options are present. This patch was verified with a real Codex coordinator -> Claude Code worker proof lane using `claude-opus-4-7` at `xhigh`; the completed lane is visible through `eagle-mem orchestrate --json`, `eagle-mem tasks completed`, and the generated handoff output. Release-boundary detection also ignores Eagle Mem's own `feature verify`/`waive` commands, so verification notes can mention dry-run checks without blocking themselves.

---

## v4.8.3 Patch

GitHub Pages now keeps hero text readable over the terminal background and the homepage explicitly explains installer-created/updated `CLAUDE.md` and `AGENTS.md` sections plus orchestrator/worker mode. Installer/update output also uses the new clean-output Codex wording instead of saying it added eagle-summary instructions.

---

## v4.8.2 Patch

Codex no longer gets instructed to print large user-visible `<eagle-summary>` XML blocks. The installer/update path rewrites existing `~/.codex/AGENTS.md` Eagle Mem instructions to the clean-output contract, context-pressure nudges use normal prose, and Codex-oriented skills/worker prompts avoid raw capture templates.

---

## v4.8.1 Patch

`eagle-mem memories sync` is now safe on large Claude Code/Codex memory files. The memory mirror parser no longer uses early-exit pipelines under `pipefail`, avoiding exit `141` during sync.
