"""
Native Google Antigravity (AGY) SDK integration module for Eagle Mem.
Enables Antigravity agents to automatically record session summaries, observations,
and tasks, enforce release-boundary guardrails, and survive context compaction.
"""

import os
import re
import sys
import json
import asyncio
import logging
import inspect
from typing import Any, Dict, List, Optional

# Setup dedicated logger
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("eagle_mem.antigravity")

# Trusted install roots, resolved relative to THIS hook file (never os.getcwd()),
# so an opened/untrusted workspace cannot shadow the real eagle-mem binaries or
# hook scripts by dropping bin/eagle-mem or hooks/*.sh into the working dir.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_EAGLE_HOME = os.path.join(os.path.expanduser("~"), ".eagle-mem")


def _resolve_eagle_mem_bin() -> Optional[str]:
    """Resolve the eagle-mem binary from trusted install roots only."""
    for path in (
        os.path.join(_EAGLE_HOME, "bin", "eagle-mem"),
        os.path.join(_REPO_ROOT, "bin", "eagle-mem"),
    ):
        if os.path.exists(path):
            return path
    return None


def _resolve_hook_script(script_name: str) -> Optional[str]:
    """Resolve an Eagle Mem hook script from trusted install roots only."""
    for path in (
        os.path.join(_EAGLE_HOME, "hooks", script_name),
        os.path.join(_REPO_ROOT, "hooks", script_name),
    ):
        if os.path.exists(path):
            return path
    return None

# --- Import and Mock Fallback for google-antigravity SDK ---
try:
    from google.antigravity import types
    from google.antigravity.hooks import hooks
    HAS_ANTIGRAVITY = True
except ImportError:
    HAS_ANTIGRAVITY = False
    
    # Mock fallback to prevent import errors and allow standalone execution/testing
    class MockHooksRegistry:
        def on_session_start(self, func):
            return func
        def on_session_end(self, func):
            return func
        def pre_turn(self, func):
            return func
        def post_turn(self, func):
            return func
        def pre_tool_call_decide(self, func):
            return func
        def post_tool_call(self, func):
            return func
        def on_tool_error(self, func):
            return func
        def on_compaction(self, func):
            return func
        def on_interaction(self, func):
            return func
        
        async def inject_agent_context(self, context: str):
            logger.info(f"[Mock SDK] Injected context:\n{context[:100]}...")

    class MockTypes:
        class HookResult:
            def __init__(self, allow: bool = True):
                self.allow = allow
        class ToolCallResult:
            def __init__(self, tool_call: Any, output: str):
                self.tool_call = tool_call
                self.output = output
        class ToolCall:
            def __init__(self, name: str, arguments: Dict[str, Any]):
                self.name = name
                self.arguments = arguments

    hooks = MockHooksRegistry()
    types = MockTypes()

# --- Asynchronous Subprocess Helpers ---

async def run_cmd_async(cmd: List[str], stdin_data: Optional[str] = None) -> str:
    """Runs a shell command asynchronously and returns stdout.

    Resolves the eagle-mem binary from the install dir (next to this hook file),
    never from os.getcwd(), so an opened workspace cannot shadow the real binary.
    Optional stdin_data is piped in so sensitive values stay out of `ps`.
    """
    if cmd and cmd[0] == "eagle-mem":
        resolved = _resolve_eagle_mem_bin()
        if resolved:
            cmd = [resolved] + cmd[1:]

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE if stdin_data is not None else None,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdin_bytes = stdin_data.encode('utf-8') if stdin_data is not None else None
        stdout, stderr = await proc.communicate(input=stdin_bytes)
        if proc.returncode == 0:
            return stdout.decode('utf-8', errors='ignore')
        else:
            err_msg = stderr.decode('utf-8', errors='ignore').strip()
            logger.warning(f"Command {' '.join(cmd)} failed with code {proc.returncode}: {err_msg}")
            return ""
    except FileNotFoundError:
        # Fallback if command still fails (e.g. if local_bin substitution didn't happen or is broken)
        logger.error(f"Executable not found for: {cmd[0]}")
        return ""
    except Exception as e:
        logger.error(f"Error running {' '.join(cmd)}: {e}")
        return ""

async def run_hook_async(script_name: str, input_data: Dict[str, Any]) -> str:
    """Runs an Eagle Mem bash hook script asynchronously, piping JSON via stdin."""
    # Resolve the hook script from trusted install roots only (~/.eagle-mem/hooks
    # then the repo's hooks/). Never os.getcwd() — an opened workspace could
    # otherwise shadow the real hook with a malicious script.
    hook_path = _resolve_hook_script(script_name)
    if not hook_path:
        logger.error(f"Eagle Mem hook script not found: {script_name}")
        return ""

    try:
        proc = await asyncio.create_subprocess_exec(
            "bash", hook_path,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        input_json = json.dumps(input_data).encode('utf-8')
        stdout, stderr = await proc.communicate(input=input_json)
        if proc.returncode == 0:
            return stdout.decode('utf-8', errors='ignore')
        else:
            err_msg = stderr.decode('utf-8', errors='ignore').strip()
            logger.warning(f"Hook script {script_name} failed with code {proc.returncode}: {err_msg}")
            return ""
    except Exception as e:
        logger.error(f"Error executing hook {script_name}: {e}")
        return ""

# --- Utility Helpers ---

_SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


def get_session_id() -> str:
    """Retrieves or generates a persistent session ID for the current context."""
    # Use environment variables if present (matches Claude/Codex). Validate the
    # value: the session ID flows into file paths inside the bash hooks, so an
    # unvalidated env var could enable path traversal. Reject anything that is
    # not a UUID/hex-style token and fall back to a generated ID.
    session_id = os.environ.get("EAGLE_SESSION_ID") or os.environ.get("SESSION_ID")
    if not session_id or not _SESSION_ID_RE.match(session_id):
        if session_id:
            logger.warning("Ignoring malformed session ID from environment; generating a new one")
        import uuid
        session_id = f"agy-{uuid.uuid4().hex[:16]}"
    return session_id

def map_tool_name(agy_name: str) -> str:
    """Maps Google Antigravity SDK tool names to Eagle Mem canonical tool names."""
    name = agy_name.lower()
    if "command" in name or "bash" in name or "shell" in name:
        return "Bash"
    elif "read" in name or "view" in name:
        return "Read"
    elif "write" in name or "create" in name:
        return "Write"
    elif "edit" in name or "replace" in name or "patch" in name:
        return "Edit"
    return agy_name

# --- Eagle Mem Antigravity Hook Implementation ---

class EagleMemAntigravityHook:
    """
    Natively compatible Google Antigravity SDK lifecycle hooks class for Eagle Mem.
    Translates and routes events directly to Eagle Mem's native bash scripts.
    """
    def __init__(self, agent_name: str = "antigravity"):
        self.agent_name = agent_name

    async def on_session_start(self):
        """Fires when the agent session starts. Injects overview, memories, tasks, and history."""
        logger.info("Eagle Mem Hook: Session starting. Syncing context...")
        session_id = get_session_id()
        cwd = os.getcwd()
        
        input_data = {
            "session_id": session_id,
            "cwd": cwd,
            "source": "startup",
            "model": "gemini",
            "agent": self.agent_name
        }
        
        # Execute session-start.sh via stdin
        stdout = await run_hook_async("session-start.sh", input_data)
        context_injected = False
        
        if stdout.strip():
            try:
                output_json = json.loads(stdout)
                context = output_json.get("hookSpecificOutput", {}).get("additionalContext", "")
                if context.strip():
                    res = hooks.inject_agent_context(context)
                    if inspect.isawaitable(res):
                        await res
                    context_injected = True
                    logger.info("Eagle Mem Hook: Injected session briefing.")
            except Exception as e:
                logger.warning(f"Eagle Mem Hook: Failed to parse session-start JSON: {e}")
                
        # Robust fallback if native sessionstart failed or returned empty
        if not context_injected:
            logger.info("Eagle Mem Hook: Running fallback search context...")
            timeline_task = run_cmd_async(["eagle-mem", "search", "--timeline"])
            overview_task = run_cmd_async(["eagle-mem", "search", "--overview"])
            timeline, overview = await asyncio.gather(timeline_task, overview_task)
            
            fallback_context = ""
            if overview.strip():
                fallback_context += f"=== Eagle Mem Project Overview ===\n{overview.strip()}\n\n"
            if timeline.strip():
                fallback_context += f"=== Eagle Mem Session Timeline ===\n{timeline.strip()}\n"
                
            if fallback_context.strip():
                res = hooks.inject_agent_context(fallback_context)
                if inspect.isawaitable(res):
                    await res
                logger.info("Eagle Mem Hook: Injected fallback context.")

    async def pre_tool_call_decide(self, tool_call: Any) -> Any:
        """Fires before a tool execution. Blocks dangerous tasks or injects co-edits/recalls."""
        tool_name = getattr(tool_call, "name", "")
        tool_args = getattr(tool_call, "arguments", getattr(tool_call, "args", {}))
        if not isinstance(tool_args, dict):
            tool_args = {}
            
        mapped_tool = map_tool_name(tool_name)
        session_id = get_session_id()
        cwd = os.getcwd()
        
        # Build stdin payload matching PreToolUse schema
        tool_input = {}
        if mapped_tool == "Bash":
            cmd = tool_args.get("CommandLine", tool_args.get("command", ""))
            tool_input["command"] = cmd
        else:
            fp = tool_args.get("AbsolutePath", tool_args.get("TargetFile", tool_args.get("file_path", tool_args.get("path", ""))))
            tool_input["file_path"] = fp

        input_data = {
            "session_id": session_id,
            "cwd": cwd,
            "tool_name": mapped_tool,
            "tool_input": tool_input,
            "agent": self.agent_name
        }
        
        stdout = await run_hook_async("pre-tool-use.sh", input_data)
        if not stdout.strip():
            return types.HookResult(allow=True)
            
        try:
            output_json = json.loads(stdout)
            specific_output = output_json.get("hookSpecificOutput", {})
            
            # 1. Check for deny decisions (safety guards/release boundaries)
            if specific_output.get("permissionDecision") == "deny":
                reason = specific_output.get("permissionDecisionReason", "Blocked by Eagle Mem guardrail.")
                # Print clearly to the user's console
                print(f"\n\033[1;31m[Eagle Mem Blocked]\033[0m {reason}\n", file=sys.stderr, flush=True)
                return types.HookResult(allow=False)
                
            # 2. Check for advisory additionalContext (co-edits, stuck loops, decision recalls)
            additional_context = specific_output.get("additionalContext", "")
            if additional_context.strip():
                res = hooks.inject_agent_context(additional_context)
                if inspect.isawaitable(res):
                    await res
                logger.info(f"Eagle Mem Hook: Injected pre-tool context.")
                
            # 3. Check for updatedInput (RTK rewriting)
            updated_input = specific_output.get("updatedInput", {})
            if updated_input and mapped_tool == "Bash" and "command" in updated_input:
                rewritten_cmd = updated_input["command"]
                logger.info(f"Eagle Mem Hook: Rewrote command to: {rewritten_cmd}")
                if hasattr(tool_call, "arguments") and isinstance(tool_call.arguments, dict):
                    if "CommandLine" in tool_call.arguments:
                        tool_call.arguments["CommandLine"] = rewritten_cmd
                    elif "command" in tool_call.arguments:
                        tool_call.arguments["command"] = rewritten_cmd
                elif hasattr(tool_call, "args") and isinstance(tool_call.args, dict):
                    if "CommandLine" in tool_call.args:
                        tool_call.args["CommandLine"] = rewritten_cmd
                    elif "command" in tool_call.args:
                        tool_call.args["command"] = rewritten_cmd

        except Exception as e:
            logger.warning(f"Eagle Mem Hook: Failed to parse pre-tool JSON: {e}")
            
        return types.HookResult(allow=True)

    async def post_tool_call(self, tool_call_result: Any):
        """Fires after a tool completes. Records observations and triggers curation in the background."""
        tool_call = getattr(tool_call_result, "tool_call", None)
        tool_name = getattr(tool_call, "name", "") if tool_call else ""
        tool_args = getattr(tool_call, "arguments", getattr(tool_call, "args", {})) if tool_call else {}
        if not isinstance(tool_args, dict):
            tool_args = {}
            
        mapped_tool = map_tool_name(tool_name)
        session_id = get_session_id()
        cwd = os.getcwd()
        
        tool_input = {}
        if mapped_tool == "Bash":
            cmd = tool_args.get("CommandLine", tool_args.get("command", ""))
            tool_input["command"] = cmd
        else:
            fp = tool_args.get("AbsolutePath", tool_args.get("TargetFile", tool_args.get("file_path", tool_args.get("path", ""))))
            tool_input["file_path"] = fp

        output_str = getattr(tool_call_result, "output", getattr(tool_call_result, "result", ""))
        if not isinstance(output_str, str):
            output_str = str(output_str)

        input_data = {
            "session_id": session_id,
            "cwd": cwd,
            "tool_name": mapped_tool,
            "tool_input": tool_input,
            "tool_response": {"stdout": output_str},
            "agent": self.agent_name
        }
        
        # 1. Trigger post-tool-use.sh in background
        asyncio.create_task(run_hook_async("post-tool-use.sh", input_data))
        
        # 2. Concurrently run eagle-mem curate in background to index changes
        asyncio.create_task(run_cmd_async(["eagle-mem", "curate"]))

    async def post_turn(self, final_response: str):
        """Fires after each response. Records observaciones and saves sessions in the background."""
        session_id = get_session_id()
        cwd = os.getcwd()
        
        input_data = {
            "session_id": session_id,
            "cwd": cwd,
            "last_assistant_message": final_response,
            "agent": self.agent_name
        }
        
        # 1. Trigger Stop hook (stop.sh) in background to capture transcript/summary
        asyncio.create_task(run_hook_async("stop.sh", input_data))
        
        # 2. Concurrently trigger session save CLI in background. Pass the
        # summary via stdin (not argv) so it is not visible in `ps`.
        summary = final_response[:200] if final_response else ""
        asyncio.create_task(run_cmd_async([
            "eagle-mem", "session", "save",
            "--summary-stdin",
            "--agent", self.agent_name
        ], stdin_data=summary))

    async def on_compaction(self, data: Any):
        """Fires when context is compacted. Queries active tasks and injects them to survive compaction."""
        logger.info("Eagle Mem Hook: Compaction event. Preserving active tasks...")
        
        # Query active tasks from SQLite FTS5 index
        tasks_text = await run_cmd_async(["eagle-mem", "tasks"])
        if tasks_text.strip():
            compaction_banner = (
                f"\n=== Eagle Mem: Context Compaction Task Survival ===\n"
                f"The following active tasks have survived compaction:\n"
                f"{tasks_text.strip()}\n"
                f"==================================================\n"
            )
            res = hooks.inject_agent_context(compaction_banner)
            if inspect.isawaitable(res):
                await res
            logger.info("Eagle Mem Hook: Tasks injected for compaction survival.")

    async def on_session_end(self):
        """Fires when the agent session closes. Cleans up runtime lock files."""
        logger.info("Eagle Mem Hook: Session ending. Pruning locks...")
        session_id = get_session_id()
        cwd = os.getcwd()
        
        input_data = {
            "session_id": session_id,
            "cwd": cwd,
            "agent": self.agent_name
        }
        
        # 1. Trigger session-end.sh in background
        asyncio.create_task(run_hook_async("session-end.sh", input_data))
        
        # 2. Concurrently trigger prune CLI in background
        asyncio.create_task(run_cmd_async(["eagle-mem", "prune"]))

# --- Expose Bound Methods as Global Functions ---

_global_hook = EagleMemAntigravityHook()

@hooks.on_session_start
async def on_session_start():
    await _global_hook.on_session_start()

@hooks.pre_tool_call_decide
async def pre_tool_call_decide(tool_call: Any) -> Any:
    return await _global_hook.pre_tool_call_decide(tool_call)

@hooks.post_tool_call
async def post_tool_call(tool_call_result: Any):
    await _global_hook.post_tool_call(tool_call_result)

@hooks.post_turn
async def post_turn(final_response: str):
    await _global_hook.post_turn(final_response)

@hooks.on_compaction
async def on_compaction(data: Any):
    await _global_hook.on_compaction(data)

@hooks.on_session_end
async def on_session_end():
    await _global_hook.on_session_end()
