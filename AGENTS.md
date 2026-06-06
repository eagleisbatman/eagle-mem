# AGENTS.md

## Scope

These are project-specific instructions for this Eagle Mem repository. They supplement the global Codex instructions in `~/.codex/AGENTS.md`.

## Prime Directive

Follow `AGENTS.md` strictly.

Create a task ledger first. Then execute each task one by one. Do not stop after planning. Continue until the goal is complete, verified, or genuinely blocked.

## Task Ledger

Maintain a visible task ledger in the conversation for every implementation, review, release, or debugging request.

Use exactly these status markers:

- [ ] Task not started
- [~] Task in progress
- [x] Task complete
- [!] Blocked

Rules:

- Create the ledger before starting tool work unless the user asks a simple factual question.
- Keep exactly one task marked `[~]` at a time.
- Before starting a new task, update the ledger.
- A task is complete only when the code/doc change is done, relevant verification has passed, and any follow-up work is recorded.
- If new requirements appear, add them under `## Later / Backlog` unless the user explicitly changes priority.

## Eagle Mem Sync

Keep the visible ledger, agent plan state, and Eagle Mem durable task state aligned.

For all agents:
- For durable multi-step work, mirror tasks into Eagle Mem with `eagle-mem tasks add --agent <agent-tag>`.
- Start the matching durable task before working on it with `eagle-mem tasks start <id> --agent <agent-tag>`.
- Complete the matching durable task after verification with `eagle-mem tasks complete <id> --agent <agent-tag>`.
- If a task changes, fails, or is partially complete, update the Eagle Mem task description with the new context before moving on or compacting.

Agent Specific Planning & Sync Modes:
- **Codex**: Uses `AGENTS.md` clean-output memory instructions and the live plan tool (`--agent codex`).
- **Claude Code**: Uses `CLAUDE.md` summary instructions (`--agent claude-code`).
- **Google Antigravity**: Uses standard planning mode artifacts (`implementation_plan.md`, `task.md`, `walkthrough.md`) in its brain directory, which are automatically indexed and synced by `eagle-mem` (`--agent antigravity`).
- **Grok**: Uses symlinked skills and CLI workflows (`--agent grok`).
- **OpenCode**: Uses the global local plugin under `~/.config/opencode/plugins/eagle-mem.js` plus symlinked skills (`--agent opencode`).

Use durable Eagle Mem task records when any of these are true:

- the work has four or more meaningful steps
- the work may cross a context compaction
- the task affects release, publish, install, hooks, recall, verification, or anti-regression behavior
- the user explicitly asks for task persistence, a task loop, a plan, or Eagle Mem coordination
- a pending Eagle Mem verification must be completed or waived before push, PR, publish, or release

For small single-turn fixes, keep the visible ledger and final summary clear; Eagle Mem will capture the transcript automatically.

## Religious Hook Operation & Graph Memory Utilization

To ensure that the self-wiring codebase graph is fully utilized, all supported agents (Claude Code, Codex, OpenCode, Grok, and Google Antigravity) MUST execute hooks/plugins and query the knowledge graph religiously:

1. **Verify Hook Settings**: Do not bypass, disable, or mock the hook pipelines (`session-start`, `pre-tool-use`, `post-tool-use`, `session-end`) under any conditions. They are the core engine of `eagle-mem`.
2. **Consult Codebase Graph First**: Before starting any development task or formulating implementation plans, run `eagle-mem graph` or `eagle-mem graph query` to inspect dependencies, declares, and semantic references of the target files.
3. **Compiled Truth Memory Structure**: When writing agent memories, align with the curated structure:
   - Place a `--- Compiled Truth ---` section at the top detailing the best, structured, up-to-date understanding of the subsystem or gotchas.
   - Place a `--- Evidence Trail ---` separator with chronological logs/timeline entries below it. This enables the background "Dream Cycle" curator to cluster and merge redundant memories cleanly.

## Agent Compatibility Gate

Before modifying any hook integration, coding-agent integration, statusline integration, config installation logic, or agent instruction injection:

1. Read the current official documentation for the affected agent surface.
2. Update `docs/agent-compatibility/<agent>.md` with the verification date, source URLs, exact behavior relied on, dependent Eagle Mem files, and fixture or golden-test coverage.
3. Add or update a fixture or regression test before changing implementation behavior.
4. Do not implement Claude Code, Codex, or OpenCode hook/plugin/statusline/config behavior from memory.

Run `tests/test_agent_compatibility_docs_gate.sh` before marking these changes complete.

## Sync Discipline

Treat task state in this order:

1. Current user instruction
2. Visible conversation ledger
3. Codex live plan
4. Eagle Mem durable task records
5. Older recalled memory

If these disagree, reconcile them before continuing. Do not silently follow stale Eagle Mem tasks over the user's latest instruction.

When Eagle Mem injects relevant memory, briefly attribute it as `Eagle Mem recalls:`. Do not print raw Eagle Mem XML, JSON, hook payloads, database rows, or internal templates unless the user explicitly asks for raw internals.

Record important decisions, gotchas, verification results, and next steps in normal prose. Eagle Mem captures the transcript automatically, so Codex final answers must stay clean and user-readable.

## Verification

Run the smallest relevant verification before marking a task complete:

1. targeted unit test or smoke command
2. related integration test
3. lint/typecheck
4. full test suite only when needed

If Eagle Mem reports pending feature verification, add it to the ledger and verify or waive it before push, PR, publish, or release.

## Command Reference

Use these commands when durable task sync is needed:

```bash
eagle-mem tasks
eagle-mem tasks add "Task title" --agent <agent-tag> --desc "Self-contained task description with decisions, files, verification, and handoff context"
eagle-mem tasks start <id> --agent <agent-tag>
eagle-mem tasks update <id> --agent <agent-tag> --desc "Updated context, decisions, partial progress, blocker, or failure details"
eagle-mem tasks complete <id> --agent <agent-tag>
```

*(Note: Replace `<agent-tag>` with `codex`, `claude-code`, `opencode`, `grok`, or `antigravity` based on the active agent)*
```

Good Eagle Mem task descriptions must be self-contained. A future context window should be able to read the task description alone and continue without rediscovering the plan.
