---
name: eagle-mem-prune
description: >
  Clean up old observations and orphaned data to keep Eagle Mem's database lean. Use when:
  'eagle prune', 'clean up memory', 'prune database', 'eagle mem prune', 'database too large',
  'remove old data'. Uses the eagle-mem CLI.
---

# Eagle Mem — Prune

Remove old observations, orphaned code chunks, and stale data from Eagle Mem's database.

## Commands

### Prune with defaults (90 days)

```bash
eagle-mem prune
```

### Prune older than N days

```bash
eagle-mem prune --days 30
```

### Dry run (see what would be removed)

```bash
eagle-mem prune --dry-run
```

### Prune a specific project

```bash
eagle-mem prune --project my-app
```

## Options

| Flag | Description |
|------|-------------|
| `-d, --days <N>` | Remove observations older than N days (default: 90) |
| `-p, --project <name>` | Target a specific project |
| `-n, --dry-run` | Show what would be pruned without deleting |

## What gets pruned

- **Old observations** — tool-use records older than the threshold
- **Orphaned code chunks** — chunks for files that no longer exist

## What is preserved

- Session records (never deleted)
- All summaries
- Claude Code mirrored memories and plans
- Task records

## When to use

- Database feels slow or is growing large
- After removing a project or major refactor
- Periodic maintenance (monthly is fine for most users)
