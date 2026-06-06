#!/usr/bin/env bash
# Regression coverage for the OpenCode local plugin bridge.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-opencode-plugin.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
export PROJECT_DIR="$tmp_dir/project"
mkdir -p "$HOME" "$EAGLE_MEM_DIR/hooks" "$PROJECT_DIR" "$tmp_dir/module"

fail() {
    echo "opencode plugin adapter test failed: $*" >&2
    exit 1
}

for required in jq node; do
    command -v "$required" >/dev/null 2>&1 || fail "missing required command: $required"
done

cp "$ROOT_DIR/integrations/opencode_eagle_mem_plugin.js" "$tmp_dir/module/eagle-mem-plugin.js"
printf '%s\n' '{"type":"module"}' > "$tmp_dir/module/package.json"
export PLUGIN_PATH="$tmp_dir/module/eagle-mem-plugin.js"

cat > "$EAGLE_MEM_DIR/hooks/session-start.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
payload=$(cat)
printf '%s\n' "$payload" | jq -c . >> "$EAGLE_MEM_DIR/session-start.jsonl"
source=$(printf '%s\n' "$payload" | jq -r '.source // "startup"')
jq -nc --arg ctx "session context: $source" '{"hookSpecificOutput":{"additionalContext":$ctx}}'
HOOK

cat > "$EAGLE_MEM_DIR/hooks/user-prompt-submit.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
payload=$(cat)
printf '%s\n' "$payload" | jq -c . >> "$EAGLE_MEM_DIR/user-prompt-submit.jsonl"
jq -nc '{"hookSpecificOutput":{"additionalContext":"recall context"}}'
HOOK

cat > "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
payload=$(cat)
printf '%s\n' "$payload" | jq -c . >> "$EAGLE_MEM_DIR/pre-tool-use.jsonl"
command_value=$(printf '%s\n' "$payload" | jq -r '.tool_input.command // ""')
if [ "$command_value" = "deny" ]; then
    jq -nc '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"blocked by test"}}'
elif [ "$command_value" = "raw" ]; then
    jq -nc '{"hookSpecificOutput":{"updatedInput":{"command":"safe"}}}'
else
    jq -nc '{"hookSpecificOutput":{}}'
fi
HOOK

cat > "$EAGLE_MEM_DIR/hooks/post-tool-use.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
payload=$(cat)
printf '%s\n' "$payload" | jq -c . >> "$EAGLE_MEM_DIR/post-tool-use.jsonl"
tool_name=$(printf '%s\n' "$payload" | jq -r '.tool_name // ""')
if [ "$tool_name" = "Read" ]; then
    jq -nc '{"hookSpecificOutput":{"additionalContext":"post context"}}'
else
    jq -nc '{"hookSpecificOutput":{}}'
fi
HOOK

cat > "$EAGLE_MEM_DIR/hooks/stop.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
cat | jq -c . >> "$EAGLE_MEM_DIR/stop.jsonl"
jq -nc '{"hookSpecificOutput":{}}'
HOOK

cat > "$EAGLE_MEM_DIR/hooks/session-end.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
cat | jq -c . >> "$EAGLE_MEM_DIR/session-end.jsonl"
jq -nc '{"hookSpecificOutput":{}}'
HOOK

node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const pluginUrl = pathToFileURL(process.env.PLUGIN_PATH).href;
const mod = await import(pluginUrl);
const hooks = await mod.default({
  project: { name: "opencode-fixture-project" },
  directory: process.env.PROJECT_DIR,
  worktree: process.env.PROJECT_DIR,
});

const chatOutput = {
  message: {
    id: "message-user-1",
    sessionID: "session-1",
    role: "user",
    time: { created: 1 },
    agent: "build",
    model: { providerID: "openai", modelID: "gpt-5" },
  },
  parts: [
    {
      id: "part-user-1",
      sessionID: "session-1",
      messageID: "message-user-1",
      type: "text",
      text: "Review auth memory",
    },
  ],
};

await hooks["chat.message"]({ sessionID: "session-1" }, chatOutput);
assert(chatOutput.parts.some((part) => part.text.includes("session context: startup")));
assert(chatOutput.parts.some((part) => part.text.includes("recall context")));

const beforeOutput = { args: { command: "raw" } };
await hooks["tool.execute.before"]({ tool: "bash", sessionID: "session-1", callID: "call-1" }, beforeOutput);
assert.equal(beforeOutput.args.command, "safe");

await assert.rejects(
  () => hooks["tool.execute.before"]({ tool: "bash", sessionID: "session-1", callID: "call-2" }, { args: { command: "deny" } }),
  /blocked by test/,
);

const afterOutput = { title: "Read", output: "file body", metadata: {} };
await hooks["tool.execute.after"](
  { tool: "read", sessionID: "session-1", callID: "call-3", args: { filePath: "/tmp/auth.ts" } },
  afterOutput,
);
assert(afterOutput.output.includes("post context"));
assert.equal(afterOutput.metadata.eagleMemContext, "post context");

await hooks.event({
  event: {
    type: "todo.updated",
    properties: {
      sessionID: "session-1",
      todos: [{ content: "Ship OpenCode", status: "in_progress", priority: "high" }],
    },
  },
});

const compactOutput = {};
await hooks["experimental.session.compacting"]({ sessionID: "session-1" }, compactOutput);
assert(compactOutput.context.some((entry) => entry.includes("Eagle Mem Compaction Context")));

await hooks.event({
  event: {
    type: "message.updated",
    properties: {
      sessionID: "session-1",
      info: { id: "message-assistant-1", sessionID: "session-1", role: "assistant" },
    },
  },
});
await hooks.event({
  event: {
    type: "message.part.updated",
    properties: {
      sessionID: "session-1",
      part: { messageID: "message-assistant-1", sessionID: "session-1", type: "text", text: "Assistant done" },
      time: 1,
    },
  },
});
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-1" } } });
await hooks.event({ event: { type: "session.deleted", properties: { sessionID: "session-1" } } });

const shellOutput = {};
await hooks["shell.env"]({}, shellOutput);
assert.equal(shellOutput.env.EAGLE_AGENT_SOURCE, "opencode");
assert.equal(shellOutput.env.EAGLE_MEM_DIR, process.env.EAGLE_MEM_DIR);
NODE

jq -e 'select(.hook_event_name == "UserPromptSubmit" and .prompt == "Review auth memory" and .agent == "opencode")' "$EAGLE_MEM_DIR/user-prompt-submit.jsonl" >/dev/null \
    || fail "UserPromptSubmit payload did not preserve the raw prompt"

jq -e 'select(.hook_event_name == "PreToolUse" and .tool_name == "Bash" and .tool_input.command == "raw" and .agent == "opencode")' "$EAGLE_MEM_DIR/pre-tool-use.jsonl" >/dev/null \
    || fail "PreToolUse payload did not normalize bash command input"

jq -e 'select(.hook_event_name == "PostToolUse" and .tool_name == "Read" and .tool_input.file_path == "/tmp/auth.ts")' "$EAGLE_MEM_DIR/post-tool-use.jsonl" >/dev/null \
    || fail "PostToolUse payload did not normalize read filePath input"

jq -e 'select(.hook_event_name == "TaskCreated" and .task_subject == "Ship OpenCode")' "$EAGLE_MEM_DIR/post-tool-use.jsonl" >/dev/null \
    || fail "todo.updated did not emit a synthetic TaskCreated payload"

jq -e 'select(.tool_name == "TaskUpdate" and .tool_input.status == "in_progress")' "$EAGLE_MEM_DIR/post-tool-use.jsonl" >/dev/null \
    || fail "todo.updated did not emit a TaskUpdate payload"

jq -e 'select(.hook_event_name == "Stop" and .last_assistant_message == "Assistant done")' "$EAGLE_MEM_DIR/stop.jsonl" >/dev/null \
    || fail "session.idle did not emit Stop with latest assistant text"

jq -e 'select(.hook_event_name == "SessionEnd")' "$EAGLE_MEM_DIR/session-end.jsonl" >/dev/null \
    || fail "session.deleted did not emit SessionEnd"

echo "opencode plugin adapter test passed"
