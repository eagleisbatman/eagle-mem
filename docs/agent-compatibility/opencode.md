# OpenCode Compatibility

Last verified: 2026-06-10

## Official Sources

- Plugins reference: https://opencode.ai/docs/plugins/
- Config reference: https://opencode.ai/docs/config/
- Config schema: https://opencode.ai/config.json

## Installed Surface Verified Locally

- OpenCode CLI: `opencode --version` reported `1.14.24`.
- OpenCode plugin package: `@opencode-ai/plugin@1.14.24`.
- Resolved config path: `~/.config/opencode/opencode.json`.
- Global plugin directory: `~/.config/opencode/plugins/`.

## Behavior Relied On

- OpenCode local plugins are JavaScript or TypeScript modules placed in `.opencode/plugins/` for project scope or `~/.config/opencode/plugins/` for global scope.
- Files in those plugin directories are loaded automatically at startup.
- NPM plugins are declared with the top-level `plugin` array in `opencode.json`, but Eagle Mem uses the global local-plugin directory so it does not need to mutate the user plugin array.
- Plugin functions receive a context object with `project`, `directory`, `worktree`, `client`, and `$`, then return a hooks object.
- The plugin event bus includes `session.created`, `session.updated`, `session.idle`, `session.compacted`, `session.deleted`, `message.updated`, `message.part.updated`, and `todo.updated`.
- Direct hook keys include `chat.message`, `tool.execute.before`, `tool.execute.after`, `shell.env`, and `experimental.session.compacting`.
- `tool.execute.before` can deny a tool call by throwing an error and can mutate `output.args` before execution.
- `tool.execute.after` receives tool output fields that can be annotated for the model.
- `experimental.session.compacting` fires before compaction and can push additional strings into `output.context`.
- `opencode --pure` runs without external plugins; doctor checks should report that Eagle Mem OpenCode support depends on non-pure OpenCode sessions.

## Eagle Mem Mapping

- `chat.message` maps to Eagle Mem `SessionStart` once per session and `UserPromptSubmit` on each user message.
- `tool.execute.before` maps to Eagle Mem `PreToolUse`; denial becomes a thrown OpenCode plugin error and `updatedInput` mutates `output.args`.
- `tool.execute.after` maps to Eagle Mem `PostToolUse`; additional context is appended to the tool output so the agent can see guardrail or stale-memory hints.
- `todo.updated` maps OpenCode todos into Eagle Mem task records through synthetic `TaskCreated` and `TaskUpdate` hook payloads.
- `session.idle` maps to Eagle Mem `Stop` using the latest assistant text accumulated from message events.
- `session.deleted` maps to Eagle Mem `SessionEnd`.
- `experimental.session.compacting` maps to Eagle Mem compact recall by running `SessionStart` with `source=compact` and appending the returned context.
- Session capture follows the shared clean-capture flow: the agent may run `eagle-mem session save --session-id <id> ...` at wrap-up (sets `capture_source = agent`, authoritative) and keep replies prose-only. The `session.idle` → `Stop` path then only fills gaps and never clobbers an agent-authored row.

## Eagle Mem Files Depending On This

- `integrations/opencode_eagle_mem_plugin.js`
- `lib/opencode-hooks.sh`
- `lib/common.sh`
- `scripts/install.sh`
- `scripts/update.sh`
- `scripts/uninstall.sh`
- `scripts/doctor.sh`
- `scripts/test.sh`
- `hooks/session-start.sh`
- `hooks/user-prompt-submit.sh`
- `hooks/pre-tool-use.sh`
- `hooks/post-tool-use.sh`
- `hooks/stop.sh`
- `hooks/session-end.sh`

## Fixtures And Tests

- `tests/fixtures/agent-hooks/opencode-chat-message.json`
- `tests/fixtures/agent-hooks/opencode-tool-execute-before.json`
- `tests/fixtures/agent-hooks/opencode-tool-execute-after.json`
- `tests/fixtures/agent-hooks/opencode-todo-updated.json`
- `tests/fixtures/agent-hooks/opencode-session-compacting.json`
- `tests/test_agent_compatibility_docs_gate.sh`
- `tests/test_opencode_hooks_config.sh`
- `tests/test_opencode_plugin_adapter.sh`

## Reverification Notes

When editing OpenCode support, re-read the plugins and config docs first. If OpenCode changes plugin load order, local plugin directories, hook names, `tool.execute.*` mutation semantics, `chat.message` payloads, or compaction hooks, update these fixtures before implementation.
