# Eagle Mem Rust Migration Plan

This is a compatibility-first migration plan for moving Eagle Mem from a Bash-first implementation to a Rust-first implementation without losing existing memory or breaking installed users.

## Non-Negotiable Requirements

1. Existing users keep their current database at `~/.eagle-mem/memory.db`.
2. Rust reads the existing SQLite schema before introducing any new schema.
3. Existing rows are never deleted, rewritten wholesale, or rekeyed as part of the first Rust release.
4. Schema changes must be additive migrations unless a separate backup, recovery, and explicit user-confirmation path exists.
5. The Bash `eagle-mem` CLI remains a compatibility wrapper until Rust reaches command and hook parity.
6. Old Bash hooks continue to work if the Rust binary is missing, disabled, or fails health checks.
7. Every hook/action emits structured observability events before Rust replaces the current shell path.
8. Tests must prove recall, compaction, indexing, statusline, memories, tasks, graph, dashboard, replay, and orchestration behavior before and after migration.

## Current Compatibility Boundary

The compatibility boundary is the SQLite database plus the public `eagle-mem` command surface.

Database:

- Location: `~/.eagle-mem/memory.db`
- Migration runner: `db/migrate.sh`
- Migration tracking table: `_migrations`
- Runtime contract: SQLite with FTS5 support

Core tables and virtual tables Rust must read first:

- `sessions`
- `observations`
- `summaries`
- `summaries_fts`
- `overviews`
- `code_chunks`
- `code_chunks_fts`
- `agent_memories`
- `agent_memories_fts`
- `agent_plans`
- `agent_plans_fts`
- `agent_tasks`
- `agent_tasks_fts`
- `features`
- `feature_dependencies`
- `feature_files`
- `feature_smoke_tests`
- `pending_feature_verifications`
- `command_rules`
- `guardrails`
- `file_hints`
- `graph_nodes`
- `graph_edges`
- `graph_nodes_fts`
- `orchestrations`
- `orchestration_lanes`
- `orchestration_workers`
- `recall_events`
- `eagle_events`
- `orchestration_auto_events`
- `eagle_meta`

Current CLI commands Rust must either implement or delegate without behavior drift:

- `install`
- `update`
- `uninstall`
- `search`
- `health`
- `doctor`
- `repair`
- `inspect`
- `replay`
- `dashboard`
- `logs`
- `config`
- `updates`
- `statusline`
- `guard`
- `overview`
- `graph`
- `session`
- `sessions`
- `memories`
- `tasks`
- `orchestrate`
- `curate`
- `feature`
- `grok-bootstrap`
- `test`
- `compaction`
- `prune`
- `scan`
- `index`
- `help`
- `version`

Current hook scripts Rust must either preserve or replace with fixture-backed parity:

- `hooks/session-start.sh`
- `hooks/user-prompt-submit.sh`
- `hooks/pre-tool-use.sh`
- `hooks/post-tool-use.sh`
- `hooks/stop.sh`
- `hooks/session-end.sh`

## Target Rust Workspace

The first Rust workspace should be added without changing default user behavior.

```text
crates/
  eagle-core/
  eagle-db/
  eagle-hooks/
  eagle-cli/
  eagle-tui/
```

Recommended libraries:

- SQLite: `rusqlite` for synchronous local-first access, or `sqlx` if compile-time query checks become valuable.
- Serialization: `serde` and `serde_json`.
- TUI: `ratatui` and `crossterm`.
- CLI: `clap`.
- Errors: `anyhow` for binaries and `thiserror` for libraries.

## Phase 0: Freeze The Bash Contract

Goal: know what must not break before writing Rust code.

Tasks:

- Tag the last Bash-first release as `v4-last-bash`.
- Keep this `MIGRATION.md` current with the command, hook, and schema contract.
- Add snapshot tests for current CLI JSON output shapes.
- Add hook input fixtures for Claude Code and Codex under `tests/fixtures/agent-hooks/`.
- Export sanitized sample `memory.db` fixtures that contain sessions, summaries, memories, tasks, features, graph nodes, graph edges, recall events, and orchestration lanes.
- Document every current command and hook behavior before replacing it.

Exit criteria:

- The Bash test suite passes against an isolated temp database.
- The compatibility docs gate passes.
- A Rust contributor can see the current command, hook, and table surface without reverse-engineering shell scripts.

## Phase 1: Rust Core, Read-Only First

Goal: Rust can inspect existing Eagle Mem state without mutating it.

Tasks:

- Create the Rust workspace and crates.
- Implement config loading for `EAGLE_MEM_DIR`, `HOME`, project detection, and database path resolution.
- Implement SQLite connection setup with FTS5 checks.
- Implement read-only accessors for the current tables listed above.
- Implement Rust commands:
  - `stats`
  - `sessions`
  - `memories`
  - `tasks`
  - `search`
  - `session inspect`
  - `statusline stats`
- Add tests that load a migrated Bash fixture DB and verify Rust reads the same counts and key rows.

Exit criteria:

- Rust reads the existing `memory.db` fixture without schema changes.
- Rust does not write to the database in this phase.
- Bash remains the default `eagle-mem` path.

## Phase 2: Observability Events

Goal: make every important action replayable and auditable.

Add an additive migration for `eagle_events`:

```sql
CREATE TABLE IF NOT EXISTS eagle_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT,
  session_id TEXT,
  agent TEXT,
  event_type TEXT NOT NULL,
  command TEXT,
  hook_event_name TEXT,
  status TEXT NOT NULL DEFAULT 'ok',
  detail_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_eagle_events_project_created
ON eagle_events(project, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_eagle_events_session_created
ON eagle_events(session_id, created_at DESC);
```

Events that must be recorded:

- `hook_started`
- `hook_completed`
- `memory_created`
- `memory_retrieved`
- `context_injected`
- `compact_started`
- `compact_completed`
- `index_started`
- `index_completed`
- `lane_created`
- `task_created`
- `task_completed`
- `graph_rebuilt`
- `dashboard_generated`
- `replay_generated`

Exit criteria:

- Bash and Rust can both append `eagle_events`.
- `eagle-mem replay` can show hook, retrieval, injection, tool, summary, compaction, and post-compact recall evidence for one session.
- Event writes never block the user workflow if the event insert fails; failures are surfaced through doctor/health.

## Phase 3: Compatibility CLI Wrapper

Goal: introduce Rust command equivalents gradually.

Tasks:

- Add an opt-in environment flag such as `EAGLE_MEM_RUST=1`.
- Teach the Bash `bin/eagle-mem` wrapper to delegate only commands that have passed parity.
- Keep Bash fallback for every delegated command.
- Add `eagle-mem doctor` output that reports:
  - Bash runtime path
  - Rust runtime path
  - Rust version
  - parity status per command
  - database integrity
  - migration status
- Add parity tests that compare Bash JSON output to Rust JSON output for delegated commands.

Exit criteria:

- Users can opt in to Rust for read-only commands.
- Disabling or removing the Rust binary restores Bash behavior.
- No command is delegated until a parity test exists.

## Phase 4: Hook Compatibility

Goal: replace hook internals only after each agent contract is verified.

Tasks:

- Re-read the official docs listed in `docs/agent-compatibility/`.
- Update `Last verified` dates and source URLs.
- Add or update input fixtures for every changed hook event.
- Implement Rust hook handlers behind a wrapper that preserves the existing shell command paths.
- Keep hook output compact and user-clean for Codex.
- Preserve Claude Code statusline behavior and first-line stdout contract.

Exit criteria:

- `tests/test_agent_compatibility_docs_gate.sh` passes.
- Existing hook tests pass with Rust disabled and Rust enabled.
- Hook output is byte-stable or intentionally migrated with golden-test approval.

## Phase 5: Rust Indexer And Project Graph

Goal: improve indexing without breaking current graph memory.

Tasks:

- Port incremental indexing for source files.
- Preserve current `code_chunks` and `code_chunks_fts` behavior.
- Preserve current `graph_nodes` and `graph_edges` rows.
- Improve extraction incrementally by language, with fallback to current regex behavior when parsing fails.
- Add semantic project graph writes for:
  - Feature
  - Decision
  - Task
  - Session
  - File
  - Memory
- Add indexing tests for:
  - new project first index
  - ongoing project re-index
  - deleted file cleanup
  - graph edge preservation

Exit criteria:

- Rust indexer can be run in dry-run mode.
- Existing Bash indexer remains available.
- Graph output remains useful even when language-specific parsing fails.

## Phase 6: Rust TUI

Goal: make memory visible without mutating data by default.

Screens:

- Project Brain
- Sessions
- Memories
- Graph
- Hook Replay
- Compaction Replay
- Tasks and Lanes
- Index Health
- Doctor and Repair Preview

Rules:

- The first TUI release is read-only except for explicit repair or verification actions.
- The TUI reads live SQLite data.
- The TUI must show when data is unavailable, stale, malformed, or still indexing.
- The graph is a project graph, not only a file graph.

Exit criteria:

- TUI can inspect a real migrated DB fixture.
- TUI handles malformed DB state without panicking.
- TUI has snapshot or terminal-render tests for empty, healthy, stale, and malformed states.

## Phase 7: Dashboard And Graph Viewer

Goal: keep the local HTML dashboard as the high-fidelity visual surface.

Tasks:

- Preserve `eagle-mem dashboard` as a static local HTML output.
- Add a graph visualization for Feature, Decision, Task, Session, File, and Memory nodes.
- Add recall and replay views backed by `recall_events` and `eagle_events`.
- Keep generated dashboard output local-first.

Exit criteria:

- Dashboard generation works with Bash and Rust data paths.
- Dashboard output includes project brain, recall inspector, timeline, file intelligence, agent comparison, and graph views.

## Data Migration Rules

- Never mutate the live user database without a backup.
- Never make destructive migrations automatic.
- New Rust migrations must be additive by default.
- Any table rebuild must:
  - copy all old rows
  - preserve primary keys where possible
  - preserve timestamps
  - run inside a transaction
  - leave a backup or recovery path
  - have fixture coverage against an older database
- FTS rebuilds are allowed only when base table rows remain intact.
- Repair flows must preview before mutation and require explicit confirmation.

## Required Test Matrix

Before Rust becomes the default path, these must pass in both Bash and Rust modes:

| Area | Required evidence |
| --- | --- |
| DB compatibility | Existing fixture DB opens, migrates additively, and preserves row counts |
| Search | Summary, memory, task, code, and graph search return expected rows |
| Recall | `UserPromptSubmit` records matches, refs, injected chars, and token estimate |
| Replay | One session shows prompt, retrieval, injection, tool observations, summary, and compaction events |
| Compaction | Pre-compact state survives into post-compact recall and graph traversal |
| Indexing | New project and re-indexing both update chunks and graph without duplicate churn |
| Statusline | Healthy, empty, and malformed DB states render honest status |
| Dashboard | Local HTML generates and includes project brain, recall, timeline, file, agent, and graph sections |
| Tasks | Agent tasks survive session changes and mirror orchestration lanes |
| Orchestration | Broad prompt detection creates lanes and durable tasks without relying on agent obedience |
| Repair | Malformed DB preview is read-only, and recovery is explicit |
| Agent docs | Compatibility docs and fixtures are updated with hook/statusline/config changes |

## Release Gate

Rust must not become the default until:

- `eagle-mem test` passes with Rust disabled.
- `eagle-mem test` passes with Rust enabled.
- Bash/Rust parity tests pass for every delegated command.
- A sanitized migrated database fixture proves old memory survives.
- `doctor` reports both Bash and Rust runtime health.
- The release notes explain fallback behavior and how users can disable Rust delegation.
