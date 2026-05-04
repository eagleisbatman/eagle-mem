---
name: eagle-mem-orchestrate
description: >
  Coordinate multi-agent work with Eagle Mem's durable orchestrator/worker
  lanes. Use when the user wants an orchestrator model, parallel lanes,
  Claude Code and Codex sharing worker status, worktree coordination,
  handoffs, or long-running implementation split across agents.
---

# Eagle Mem — Orchestrator/Worker Lanes

## Purpose

Use this skill when work is too broad for one agent turn and needs durable
coordination across Claude Code, Codex, or both.

The commands in this skill are for **you, the active agent**, to run from the
terminal. Do not hand them to the user as setup steps. The user should only see
brief progress updates or the final handoff when that helps them.

Eagle Mem stores each lane in shared SQLite tables and mirrors it into
`agent_tasks`, so SessionStart can re-inject in-flight lane state after
compaction or when another agent opens the same project.

By default, Eagle Mem routes work to the opposite agent:
- Codex coordinator -> Claude Code worker (`claude-opus-4-7`, `xhigh`)
- Claude Code coordinator -> Codex worker (`gpt-5.5`, `xhigh`)

Workers run in git worktrees so their edits stay isolated until the coordinator
reviews and integrates them. The worker wrapper preserves the original Eagle
Mem project name, so memories and observations recorded inside the worktree
still attach to the main project.

## When To Use

Use orchestration when:
- The work has separate independent lanes, such as API, database, UI, docs, or
  release validation.
- Claude Code and Codex may work in the same repo and must not duplicate work.
- A lane needs its own worktree, validation command, or owner.
- The user asks for an orchestrator/worker model, agent lanes, subagent lanes,
  or durable handoff.

Use `eagle-mem tasks` instead when the work is a simple sequential checklist
that one agent will execute in order.

## Workflow

### 1. Start The Orchestration Yourself

```bash
eagle-mem orchestrate init "Ship the release safely"
```

This records the goal and current git baseline for the project.

### 2. Add Worker Lanes Yourself

Create one lane per independent workstream. The description should be
self-contained enough for a fresh agent context.

```bash
eagle-mem orchestrate lane add api \
  --agent codex \
  --title "API fixes" \
  --desc "Fix release-boundary checks and add shell-hook regression tests." \
  --validate "npm test"

eagle-mem orchestrate lane add docs \
  --agent claude-code \
  --title "Docs and release notes" \
  --desc "Update README and usage docs after implementation is verified."
```

### 3. Spawn Worker Lanes Yourself

After adding a lane, launch the worker yourself. Do not ask the user to run
this command.

```bash
eagle-mem orchestrate spawn api
```

This creates a git worktree, writes a lane prompt, launches the target CLI, and
records the worker process/log/exit paths in Eagle Mem. Use `--foreground` when
you need to watch a short worker run inline, `--no-launch` when you only want
the worktree and prompt prepared, and `--dry-run` to inspect the planned worker
without creating a worktree.

### 4. Sync Or Mark Lane State As Work Proceeds

```bash
eagle-mem orchestrate sync
eagle-mem orchestrate lane start api
eagle-mem orchestrate lane block api --notes "Waiting for failing test output."
eagle-mem orchestrate lane complete api --notes "npm test passed."
```

Lane state should reflect reality. If a lane is blocked, record the blocker so
the next agent does not repeat the same attempt.

### 5. Check Status Before Taking Work

```bash
eagle-mem orchestrate
eagle-mem tasks
```

Use the lane owner and status to decide what you should work on. Do not take a
lane that another agent already owns unless the user explicitly redirects it.

### 6. Create A Durable Handoff

```bash
eagle-mem orchestrate handoff --write docs/handoff-context.md
```

Use this before compaction, before handing work to another agent, or before
ending a broad session.

## Rules For Agents

- Main agent acts as coordinator: define lanes, avoid duplicate work, integrate
  results, and run final validation.
- The agent runs orchestration commands, including `spawn` and `sync`. Do not
  tell the user to run them.
- Workers own their lane only. They should not rewrite unrelated lanes or
  revert other agents' changes.
- Every lane should have a validation command when one is obvious.
- If a lane is blocked, update the lane with a concrete note rather than
  silently stopping.
- After completing a lane, emit an `<eagle-summary>` so Eagle Mem captures the
  decision and files touched.

## Reference

```bash
eagle-mem orchestrate                           # status
eagle-mem orchestrate --json                    # lane JSON
eagle-mem orchestrate init "Goal"
eagle-mem orchestrate lane add <key> --agent codex --desc "Scope"
eagle-mem orchestrate spawn <key>                # worktree + worker process
eagle-mem orchestrate sync [key]                 # reconcile worker state
eagle-mem orchestrate lane start <key>
eagle-mem orchestrate lane block <key> --notes "Blocker"
eagle-mem orchestrate lane complete <key> --notes "Validation passed"
eagle-mem orchestrate complete
eagle-mem orchestrate handoff --write docs/handoff-context.md
```
