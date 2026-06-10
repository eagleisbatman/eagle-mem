# Claude Code Compatibility

Last verified: 2026-06-10

## Official Sources

- Hooks reference: https://code.claude.com/docs/en/hooks
- Statusline reference: https://code.claude.com/docs/en/statusline
- Settings reference: https://code.claude.com/docs/en/settings

## Behavior Relied On

- Command hooks receive JSON on stdin.
- `SessionStart` runs when a session begins or resumes.
- `UserPromptSubmit` runs before Claude processes the user prompt and can add context.
- `PreToolUse` and `PostToolUse` match tool names such as `Bash`, `Read`, `Edit`, and `Write`.
- `TaskCreated` and `TaskCompleted` expose durable task fields that can be mirrored into Eagle Mem.
- `Stop` runs after the main assistant response and exposes the last assistant message.
- `PreCompact` runs before manual or automatic compaction and receives `trigger` plus `custom_instructions`.
- `PostCompact` runs after compaction and receives `trigger` plus `compact_summary`.
- `SessionEnd` runs when a session terminates.
- The custom statusline is configured with `statusLine` in Claude settings; its command receives JSON on stdin and the first stdout line becomes the visible statusline text.

## Session Capture Behavior

- Eagle Mem no longer instructs Claude to print a raw `<eagle-summary>` block. `SessionStart` injects guidance to capture the session by running `eagle-mem session save --session-id <session_id> ...` (a quiet shell call), then to end the turn with human prose plus one branded line: `Eagle Mem | Session captured — N decisions, M gotchas`.
- The `session_id` injected into the instruction is the same id Claude passes to every hook, so the CLI capture merges into the live session row rather than creating a standalone `manual-*` row.
- The installer adds `permissions.allow: ["Bash(eagle-mem session save:*)"]` to Claude settings so the capture runs without a permission prompt. The instruction must use that exact command prefix (no leading path, no `cd &&`) for the permission to match.
- Agent-authored captures are authoritative (`capture_source = agent`). The `Stop` hook still parses any `<eagle-summary>` block for backward compatibility, but when an agent row already exists its heuristics only fill empty fields and background enrichment is skipped — neither can clobber agent data.
- `UserPromptSubmit` context-pressure nudges (≥20 / ≥30 turns) also point at `eagle-mem session save`, not the raw block.
- On install/update the managed `## Eagle Mem — Persistent Memory` section in `~/.claude/CLAUDE.md` is rewritten to this CLI-first doctrine whenever it predates it. Detection keys on the absence of the current section's `session save --session-id` sentinel (v4.12.1 fixed a `grep -F` escaping bug that left the section — and therefore the clean-capture behavior — un-updated). Covered by `tests/test_claude_md_capture_doctrine.sh`.

## Eagle Mem Files Depending On This

- `lib/hooks.sh`
- `scripts/install.sh`
- `scripts/update.sh`
- `scripts/uninstall.sh`
- `scripts/statusline-em.sh`
- `hooks/session-start.sh`
- `hooks/user-prompt-submit.sh`
- `hooks/pre-tool-use.sh`
- `hooks/post-tool-use.sh`
- `hooks/stop.sh`
- `hooks/session-end.sh`

## Fixtures And Tests

- `tests/fixtures/agent-hooks/claude-user-prompt-submit.json`
- `tests/fixtures/agent-hooks/claude-statusline.json`
- `tests/test_agent_compatibility_docs_gate.sh`
- `tests/test_recall_observability.sh`
- `tests/test_compaction_survival_matrix.sh`
- `tests/test_trust_surfaces.sh`

## Reverification Notes

When editing Claude Code hooks, update this file with the new verification date and include the exact hook event names, input fields, and output semantics used by the implementation. When editing brand visibility or statusline behavior, re-read the statusline reference first and update `claude-statusline.json` if the stdin schema changed.

### Evidence: data-integrity hardening (2026-06-10)

Phase 2 data-integrity hardening touched the PostToolUse hook and the statusline without changing any Claude Code contract — no hook event names, stdin field reads, or stdout/exit semantics changed; `claude-statusline.json` is unaffected. Specifically:

- `hooks/post-tool-use.sh`: the `mod-tracker`/`edit-tracker` writers (internal `~/.eagle-mem` state, not Claude I/O) gained a stale-lock TTL reclaim, an atomic mv-based pending drain so a concurrent append is never lost, and a lock around the edit-history append. The PostToolUse stdin parse (`session_id`, `cwd`, `tool_name`, `hook_event_name`, `tool_input`) is unchanged.
- `scripts/statusline-em.sh`: the hottest standalone stats query now runs `PRAGMA busy_timeout=10000;` so a momentary `SQLITE_BUSY` waits for the lock instead of being misread as a DB-integrity error. Statusline stdin schema and output rendering are unchanged.

Covered by `tests/test_mod_tracker_concurrency.sh` and `tests/test_trust_surfaces.sh` (statusline integrity-status path).

### Evidence: reliability/self-healing hardening (2026-06-10)

Phase 3 reliability hardening touched SessionStart auto-provisioning and SessionEnd without changing any Claude Code contract — hook event names, stdin field reads, and stdout/exit semantics are unchanged. Specifically:

- `lib/hooks-sessionstart.sh` (sourced by SessionStart): auto-scan/auto-index now debounce concurrent spawns with a short-lived in-flight marker and set the durable freshness marker ONLY when the background job genuinely succeeds, so a crashed/output-less scan no longer blocks retry for ~24h. Pure background-state behavior; no change to injected context format or stdin parse.
- `hooks/session-end.sh`: now also prunes `eagle_events` (hook-observability telemetry) older than 30 days; `pending_feature_verifications` is deliberately left un-pruned (documented inline). SessionEnd input/exit semantics unchanged.

Covered by `tests/test_reliability_retention.sh`.

### Evidence: SessionStart injection ceiling (2026-06-10)

Phase 4 token-economy hardening added a generous global size ceiling on the recall body that SessionStart injects, without changing any Claude Code contract — the hook still emits the same `additionalContext` via the existing `eagle_emit_context_for_agent` path, with unchanged stdin field reads (`session_id`, `cwd`, `source`, `model`) and exit semantics. Specifically:

- `lib/common.sh`: added `eagle_sessionstart_inject_budget` (config key `context_budget.sessionstart_chars`, default 24000 chars / ~6K tokens, floored at 4000) and `eagle_trim_inject_body`, which drops whole `=== Eagle Mem: ...` sections from the END (lowest priority appended last) until the body fits. Sections are never split, so no recall surface is half-emitted, and the top-priority sections (overview, recent recall, memories) always survive.
- `hooks/session-start.sh`: applies the ceiling to the accumulated recall body for the non-Codex path BEFORE the trailing Active/instructions block is appended, so capture instructions are never trimmed. When it trims it logs an observable `WARN` ("injection over budget … trimmed N low-priority section(s)") and records `sections_trimmed` in the hook observability detail. Normal-sized recall is emitted byte-for-byte unchanged (verified by test).

Covered by `tests/test_context_budget.sh`.

