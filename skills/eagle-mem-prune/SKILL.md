---
name: eagle-mem-prune
description: >
  Database hygiene — remove stale observations and orphaned code chunks. Use when:
  'eagle prune', 'clean up memory', 'prune database', 'database too large',
  'remove old data', 'memory maintenance', search feels slow.
---

# Eagle Mem — Prune

## Purpose

**For the user:** Keep Eagle Mem fast and focused. A database that accumulates months of observations without cleanup gets noisy — search results surface stale context, and queries slow down as row counts grow.

**For you (Claude Code):** Understand what data matters most and what's safe to remove. Pruning is a graduated operation — you're trimming low-value data, never touching the high-value records that give sessions continuity.

## Judgment

**Prune when:**
- `eagle-mem search --stats` shows high observation counts (1000+ for a single project is worth checking)
- The user says search feels slow or results are stale
- After removing a project directory or completing a major refactor that invalidated old code paths
- Periodic maintenance — monthly is enough for most projects

**Don't prune when:**
- The database is small and search is fast — pruning a clean database is pointless
- You're unsure what the observations contain — run `--dry-run` first
- The user is mid-task — prune between work sessions, not during

**Start conservative.** Default 90 days is right for routine cleanup. Only go aggressive (30 days) when there's a clear reason: project was deleted, architecture was overhauled, or the user explicitly asks for it.

## Data hierarchy — what's protected, what's pruned

**Never pruned (high-value):**
- `sessions` — your session history, parent rows for everything else
- `summaries` + `summaries_fts` — what was accomplished each session
- `claude_tasks` — task state that survives compaction
- `claude_memories` — mirrored auto-memories
- `claude_plans` — mirrored plans
- `overviews` — project overviews injected at SessionStart

**Pruned by age (medium-value):**
- `observations` — per-tool-use records (which files were read/written). Useful for recent context, but stale observations from 3 months ago rarely help. Default threshold: 90 days.

**Pruned by orphan check (low-value when stale):**
- `code_chunks` — indexed source code. Chunks for files that no longer exist on disk are orphaned and safe to remove. The prune script checks each file path against the project directory.

## Steps

### 1. Assess — understand the current state

```bash
eagle-mem search --stats
```

Look at: total observations, total code chunks, project breakdown. This tells you whether pruning is even needed.

### 2. Preview — always dry-run first

```bash
eagle-mem prune --dry-run
```

The output shows:
- Current counts: "Database: N observations, N chunks"
- What would be removed: "Would prune N observations older than 90 days"
- Orphaned chunks: "Would prune N orphaned files from 'project-name'"

**What the numbers mean:**
- 0 observations to prune: database is already clean, nothing to do
- 50-200 observations: normal cleanup, proceed
- 500+ observations: significant cleanup — review the project name to make sure it's correct
- Orphaned chunks: always safe to remove (the source files don't exist anymore)

### 3. Execute — prune with the right threshold

```bash
# Standard cleanup (90 days)
eagle-mem prune

# Conservative (only very old data)
eagle-mem prune --days 180

# Aggressive (use only with good reason)
eagle-mem prune --days 30

# Target one project
eagle-mem prune --project my-app
```

### 4. Verify — confirm the result

The prune output shows before/after counts:
```
Observations: 342 (was 891)
Code chunks:  45 (was 72)
```

If the numbers look wrong (pruned too much or too little), there's no undo — but sessions, summaries, tasks, and memories are intact. Observations will rebuild naturally as you keep working.

## When aggressive cleanup is safe

- **Project removed entirely:** The directory is gone, all observations and chunks for it are orphaned. Use `--project <name>` to target just that project.
- **Major refactor:** You renamed half the files, restructured directories. Old observations reference paths that no longer exist. Prune orphaned chunks, then re-index with `eagle-mem index`.
- **Fresh start:** The user explicitly wants to clear old noise. `--days 30` removes everything except the last month.

## What makes a good prune decision

**Good:**
> "eagle-mem search --stats shows 2,400 observations for this project, most from 4 months ago when the architecture was different. I'll dry-run first, then prune with default 90 days."

**Bad:**
> "Let me clean up the database" [runs `eagle-mem prune --days 7` without checking stats or dry-running first]

The good version assesses before acting. The bad version risks removing recent, useful observations with no preview.

## Reference

| Flag | What it does |
|------|-------------|
| `--dry-run`, `-n` | Preview what would be removed, no changes |
| `--days N`, `-d N` | Age threshold in days (default: 90) |
| `--project <name>`, `-p` | Target a single project |

```bash
eagle-mem prune --dry-run           # always start here
eagle-mem prune                     # standard 90-day cleanup
eagle-mem prune --days 30           # aggressive (with good reason)
eagle-mem prune -p my-app -n        # dry-run for one project
eagle-mem search --stats            # check database health first
```
