# Codex Compatibility

Last verified: 2026-06-10

## Official Sources

- Codex manual: https://developers.openai.com/codex/codex-manual.md
- Hooks reference: https://developers.openai.com/codex/hooks.md
- AGENTS.md reference: https://developers.openai.com/codex/guides/agents-md.md
- Advanced config reference: https://developers.openai.com/codex/config-advanced.md
- Memories reference: https://developers.openai.com/codex/memories.md

## Behavior Relied On

- `AGENTS.md` is the durable repo-instruction surface for Codex. Closer nested files override earlier guidance because Codex concatenates instruction files from the project root down to the current working directory.
- Codex hooks are discovered from active config layers through `hooks.json` or inline `[hooks]` tables in `config.toml`.
- `features.hooks` is the canonical feature key. `features.codex_hooks` is a deprecated alias and should not be the primary setting.
- Hook entries are registered into `hooks.<Event>` via jq. The event name is passed as `--arg` and indexed dynamically (`.hooks[$event]`), never interpolated into the jq program; the emitted `hooks.json` shape is unchanged. Re-verified during the 2026-06-10 security hardening pass (jq injection hardening, secret redaction before provider calls/persistence); no Codex hook contract changed.
- `SessionStart`, `PreToolUse`, `PostToolUse`, `PreCompact`, `PostCompact`, `UserPromptSubmit`, `SubagentStop`, and `Stop` run at the documented lifecycle scopes.
- `SessionStart` matchers use `startup`, `resume`, `clear`, and `compact`.
- `PreToolUse` and `PostToolUse` match tool names, including `Bash`, `apply_patch`, MCP tool names, and aliases such as `Edit` and `Write` for `apply_patch`.
- `UserPromptSubmit` and `Stop` do not support matchers; configured matchers are ignored for those events.
- Hook `timeout` is measured in seconds; `statusMessage` is optional.
- Codex memory files are generated state. Required team guidance belongs in `AGENTS.md` or checked-in documentation, not only in local memories.

## Session Capture Behavior

- Codex replies stay prose-only; Eagle Mem never asks Codex to print summary blocks, XML, or hook payloads. The `Stop` hook captures a summary from the Codex rollout transcript automatically.
- For a richer structured capture, Codex may run `eagle-mem session save --session-id <session_id> --agent codex ...` once at wrap-up (injected by `SessionStart` and the `AGENTS.md` section). This sets `capture_source = agent`, which is authoritative: later Stop-hook heuristics only fill empty fields and background enrichment is skipped, so the capture is never clobbered.
- Modified-file lists are most reliable when Codex passes `--files-modified` explicitly; the transcript heuristic is Claude-shaped and may not populate file lists from Codex rollout tool calls.

## Eagle Mem Files Depending On This

- `lib/codex-hooks.sh`
- `lib/provider.sh`
- `scripts/install.sh`
- `scripts/update.sh`
- `scripts/uninstall.sh`
- `hooks/session-start.sh`
- `hooks/user-prompt-submit.sh`
- `hooks/pre-tool-use.sh`
- `hooks/post-tool-use.sh`
- `hooks/stop.sh`
- `AGENTS.md`

## Fixtures And Tests

- `tests/fixtures/agent-hooks/codex-user-prompt-submit.json`
- `tests/fixtures/agent-hooks/codex-pre-tool-use.json`
- `tests/test_agent_compatibility_docs_gate.sh`
- `tests/test_codex_hooks_config.sh`
- `tests/test_auto_orchestration_detection.sh`
- `tests/test_recall_observability.sh`
- `tests/test_trust_surfaces.sh`

## Reverification Notes

When editing Codex hooks or install/update behavior, update this file with the new verification date and source URLs. If a future Codex version changes hook feature flags, matcher support, trust review, event names, or input/output schema, update fixtures first and then implementation.
