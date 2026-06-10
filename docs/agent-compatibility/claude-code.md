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

