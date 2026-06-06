# Claude Code Compatibility

Last verified: 2026-06-02

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

