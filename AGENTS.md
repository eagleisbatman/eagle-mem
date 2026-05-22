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

Keep the visible ledger, Codex plan state, and Eagle Mem durable task state aligned.

For Codex:

- Use the live Codex plan tool for active progress when the work has multiple steps.
- For durable multi-step work, also mirror tasks into Eagle Mem with `eagle-mem tasks add --agent codex`.
- Start the matching durable task before working on it with `eagle-mem tasks start <id> --agent codex`.
- Complete the matching durable task after verification with `eagle-mem tasks complete <id> --agent codex`.
- If a task changes, fails, or is partially complete, update the Eagle Mem task description with the new context before moving on or compacting.

Use durable Eagle Mem task records when any of these are true:

- the work has four or more meaningful steps
- the work may cross a context compaction
- the task affects release, publish, install, hooks, recall, verification, or anti-regression behavior
- the user explicitly asks for task persistence, a task loop, a plan, or Eagle Mem coordination
- a pending Eagle Mem verification must be completed or waived before push, PR, publish, or release

For small single-turn fixes, keep the visible ledger and final summary clear; Eagle Mem will capture the transcript automatically.

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
eagle-mem tasks add "Task title" --agent codex --desc "Self-contained task description with decisions, files, verification, and handoff context"
eagle-mem tasks start <id> --agent codex
eagle-mem tasks update <id> --agent codex --desc "Updated context, decisions, partial progress, blocker, or failure details"
eagle-mem tasks complete <id> --agent codex
```

Good Eagle Mem task descriptions must be self-contained. A future context window should be able to read the task description alone and continue without rediscovering the plan.
