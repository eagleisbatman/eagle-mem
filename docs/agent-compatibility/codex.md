# Codex Compatibility

Last verified: 2026-06-02

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
- `SessionStart`, `PreToolUse`, `PostToolUse`, `PreCompact`, `PostCompact`, `UserPromptSubmit`, `SubagentStop`, and `Stop` run at the documented lifecycle scopes.
- `SessionStart` matchers use `startup`, `resume`, `clear`, and `compact`.
- `PreToolUse` and `PostToolUse` match tool names, including `Bash`, `apply_patch`, MCP tool names, and aliases such as `Edit` and `Write` for `apply_patch`.
- `UserPromptSubmit` and `Stop` do not support matchers; configured matchers are ignored for those events.
- Hook `timeout` is measured in seconds; `statusMessage` is optional.
- Codex memory files are generated state. Required team guidance belongs in `AGENTS.md` or checked-in documentation, not only in local memories.

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
