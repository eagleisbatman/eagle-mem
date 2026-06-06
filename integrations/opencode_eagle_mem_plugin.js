// EAGLE_MEM_OPENCODE_PLUGIN
// OpenCode local plugin bridge for Eagle Mem.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

const HOOK_TIMEOUT_MS = 30000;
const STOP_TIMEOUT_MS = 60000;

function eagleHome() {
  return process.env.EAGLE_MEM_DIR || join(homedir(), ".eagle-mem");
}

function hookPath(name) {
  return join(eagleHome(), "hooks", `${name}.sh`);
}

function safeString(value) {
  return typeof value === "string" ? value : "";
}

function projectName(input, directory) {
  return safeString(input?.project?.name) || basename(directory || process.cwd()) || "unknown";
}

function normalizeToolName(tool) {
  switch (safeString(tool).toLowerCase()) {
    case "bash":
    case "shell":
      return "Bash";
    case "read":
      return "Read";
    case "write":
      return "Write";
    case "edit":
      return "Edit";
    case "patch":
    case "apply_patch":
      return "apply_patch";
    default:
      return safeString(tool);
  }
}

function toEagleToolInput(toolName, args = {}) {
  const input = { ...args };
  if (args.filePath !== undefined && input.file_path === undefined) {
    input.file_path = args.filePath;
  }
  if (args.path !== undefined && input.file_path === undefined) {
    input.file_path = args.path;
  }
  if (args.command !== undefined && input.command === undefined) {
    input.command = args.command;
  }
  if (toolName === "apply_patch" && args.patch !== undefined && input.command === undefined) {
    input.command = args.patch;
  }
  return input;
}

function fromEagleToolInput(updatedInput, originalArgs = {}) {
  const next = { ...originalArgs };
  for (const [key, value] of Object.entries(updatedInput || {})) {
    if (key === "file_path") {
      next.filePath = value;
      continue;
    }
    next[key] = value;
  }
  return next;
}

function textFromParts(parts = []) {
  return parts
    .filter((part) => part && part.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join("\n")
    .trim();
}

function parseHookSpecificOutput(stdout) {
  const lines = safeString(stdout).split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    try {
      const parsed = JSON.parse(lines[i]);
      return parsed.hookSpecificOutput || parsed;
    } catch {
      // Keep scanning for the last JSON line.
    }
  }
  return {};
}

function appendTextPart(output, text) {
  const context = safeString(text).trim();
  if (!context) return;

  const message = output?.message || {};
  if (!Array.isArray(output.parts)) output.parts = [];
  output.parts.push({
    id: `eagle-mem-${Date.now()}`,
    sessionID: safeString(message.sessionID),
    messageID: safeString(message.id),
    type: "text",
    text: `\n\n${context}`,
    synthetic: true,
    time: { start: Date.now() },
    metadata: { source: "eagle-mem" },
  });
}

function appendToolContext(output, text) {
  const context = safeString(text).trim();
  if (!context) return;

  output.metadata = {
    ...(output.metadata || {}),
    eagleMemContext: context,
  };
  output.output = `${safeString(output.output)}\n\n${context}`.trim();
}

function runHook(name, payload, timeoutMs = HOOK_TIMEOUT_MS) {
  const script = hookPath(name);
  if (!existsSync(script)) {
    return Promise.resolve({ stdout: "", stderr: "", code: 0, skipped: true });
  }

  return new Promise((resolve) => {
    const child = spawn("bash", [script], {
      env: {
        ...process.env,
        EAGLE_AGENT_SOURCE: "opencode",
      },
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let finished = false;
    const timer = setTimeout(() => {
      if (finished) return;
      finished = true;
      child.kill("SIGTERM");
      resolve({ stdout, stderr: `${stderr}\nHook timed out: ${name}`.trim(), code: 124 });
    }, timeoutMs);

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("close", (code) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      resolve({ stdout, stderr, code: code ?? 0 });
    });
    child.on("error", (error) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      resolve({ stdout, stderr: `${stderr}\n${error.message}`.trim(), code: 1 });
    });

    child.stdin.end(JSON.stringify(payload));
  });
}

function baseHookPayload(ctx, sessionID, extra = {}) {
  return {
    session_id: sessionID,
    cwd: ctx.directory,
    workspace: {
      current_dir: ctx.directory,
      project_dir: ctx.directory,
    },
    project: projectName(ctx, ctx.directory),
    agent: "opencode",
    ...extra,
  };
}

function taskID(sessionID, todo) {
  return `opencode-${createHash("sha256")
    .update(`${sessionID}:${todo?.content || ""}`)
    .digest("hex")
    .slice(0, 16)}`;
}

function normalizeTodoStatus(status) {
  switch (safeString(status)) {
    case "completed":
    case "cancelled":
    case "in_progress":
    case "pending":
      return status;
    default:
      return "pending";
  }
}

export const EagleMemPlugin = async (ctx) => {
  const startedSessions = new Set();
  const messageRoles = new Map();
  const textPartsByMessage = new Map();
  const latestAssistantMessageBySession = new Map();

  async function ensureSessionStarted(sessionID, source = "startup") {
    if (!sessionID) return "";
    const key = `${sessionID}:${source}`;
    if (source === "startup" && startedSessions.has(key)) return "";
    startedSessions.add(key);

    const result = await runHook("session-start", baseHookPayload(ctx, sessionID, {
      hook_event_name: "SessionStart",
      source,
      model: "opencode",
    }));
    const hookOutput = parseHookSpecificOutput(result.stdout);
    return safeString(hookOutput.additionalContext);
  }

  async function runUserPromptSubmit(sessionID, prompt) {
    if (!sessionID || !prompt) return "";
    const result = await runHook("user-prompt-submit", baseHookPayload(ctx, sessionID, {
      hook_event_name: "UserPromptSubmit",
      prompt,
    }));
    const hookOutput = parseHookSpecificOutput(result.stdout);
    return safeString(hookOutput.additionalContext);
  }

  async function mirrorTodos(sessionID, todos = []) {
    for (const todo of todos) {
      const sourceTaskID = taskID(sessionID, todo);
      const subject = safeString(todo?.content).trim();
      if (!subject) continue;

      const status = normalizeTodoStatus(todo?.status);
      const description = JSON.stringify({
        priority: safeString(todo?.priority) || "medium",
        status,
        source: "opencode.todo.updated",
      });

      await runHook("post-tool-use", baseHookPayload(ctx, sessionID, {
        hook_event_name: status === "completed" ? "TaskCompleted" : "TaskCreated",
        task_id: sourceTaskID,
        task_subject: subject,
        task_description: description,
      }));

      await runHook("post-tool-use", baseHookPayload(ctx, sessionID, {
        hook_event_name: "PostToolUse",
        tool_name: "TaskUpdate",
        tool_input: {
          taskId: sourceTaskID,
          status,
        },
      }));
    }
  }

  function rememberMessage(message) {
    if (!message?.id) return;
    messageRoles.set(message.id, message.role);
    const text = safeString(textPartsByMessage.get(message.id));
    if (message.role === "assistant" && text) {
      latestAssistantMessageBySession.set(message.sessionID, text);
    }
  }

  function rememberPart(part) {
    if (!part?.messageID || part.type !== "text") return;
    textPartsByMessage.set(part.messageID, safeString(part.text));
    if (messageRoles.get(part.messageID) === "assistant") {
      latestAssistantMessageBySession.set(part.sessionID, safeString(part.text));
    }
  }

  return {
    event: async ({ event }) => {
      if (!event?.type) return;
      const props = event.properties || {};
      const sessionID = props.sessionID || props.info?.id;

      if (event.type === "session.created") {
        await ensureSessionStarted(sessionID, "startup");
      }
      if (event.type === "message.updated") {
        rememberMessage(props.info);
      }
      if (event.type === "message.part.updated") {
        rememberPart(props.part);
      }
      if (event.type === "todo.updated") {
        await mirrorTodos(sessionID, props.todos || []);
      }
      if (event.type === "session.compacted") {
        await ensureSessionStarted(sessionID, "compact");
      }
      if (event.type === "session.idle") {
        await runHook("stop", baseHookPayload(ctx, sessionID, {
          hook_event_name: "Stop",
          agent_type: "main",
          last_assistant_message: safeString(latestAssistantMessageBySession.get(sessionID)),
        }), STOP_TIMEOUT_MS);
      }
      if (event.type === "session.deleted") {
        await runHook("session-end", baseHookPayload(ctx, sessionID, {
          hook_event_name: "SessionEnd",
        }));
      }
    },

    "chat.message": async (input, output) => {
      const sessionID = input?.sessionID || output?.message?.sessionID;
      const prompt = textFromParts(output?.parts || []);
      const startupContext = await ensureSessionStarted(sessionID, "startup");
      appendTextPart(output, startupContext);

      const recallContext = await runUserPromptSubmit(sessionID, prompt);
      appendTextPart(output, recallContext);
    },

    "tool.execute.before": async (input, output) => {
      const sessionID = input?.sessionID;
      const toolName = normalizeToolName(input?.tool);
      await ensureSessionStarted(sessionID, "startup");

      const payload = baseHookPayload(ctx, sessionID, {
        hook_event_name: "PreToolUse",
        tool_name: toolName,
        tool_input: toEagleToolInput(toolName, output?.args || {}),
      });
      const result = await runHook("pre-tool-use", payload);
      const hookOutput = parseHookSpecificOutput(result.stdout);
      if (hookOutput.permissionDecision === "deny") {
        throw new Error(hookOutput.permissionDecisionReason || "Eagle Mem denied this tool call");
      }
      if (hookOutput.updatedInput && output) {
        output.args = fromEagleToolInput(hookOutput.updatedInput, output.args || {});
      }
    },

    "tool.execute.after": async (input, output) => {
      const sessionID = input?.sessionID;
      const toolName = normalizeToolName(input?.tool);
      const result = await runHook("post-tool-use", baseHookPayload(ctx, sessionID, {
        hook_event_name: "PostToolUse",
        tool_name: toolName,
        tool_input: toEagleToolInput(toolName, input?.args || {}),
        tool_response: {
          stdout: safeString(output?.output),
          metadata: output?.metadata || {},
          title: safeString(output?.title),
        },
      }));
      const hookOutput = parseHookSpecificOutput(result.stdout);
      appendToolContext(output, hookOutput.additionalContext);
    },

    "shell.env": async (_input, output) => {
      output.env = {
        ...(output.env || {}),
        EAGLE_AGENT_SOURCE: "opencode",
        EAGLE_MEM_DIR: eagleHome(),
      };
    },

    "experimental.session.compacting": async (input, output) => {
      const sessionID = input?.sessionID;
      const compactContext = await ensureSessionStarted(sessionID, "compact");
      if (compactContext) {
        if (!Array.isArray(output.context)) output.context = [];
        output.context.push(`## Eagle Mem Compaction Context\n\n${compactContext}`);
      }
    },
  };
};

export default EagleMemPlugin;
