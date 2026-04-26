---
name: eagle-mem-memories
description: >
  View and sync Claude Code auto-memories, plans, and tasks mirrored in Eagle Mem. Use when:
  'eagle memories', 'show memories', 'list memories', 'sync memories', 'eagle mem memories',
  'what does claude remember', 'show plans', 'show tasks'. Uses the eagle-mem CLI.
---

# Eagle Mem — Memories

View, search, and sync Claude Code's auto-memories, plans, and tasks that are mirrored into Eagle Mem's SQLite + FTS5 database.

## Commands

### List mirrored memories

```bash
eagle-mem memories
eagle-mem memories list
```

### Search memories

```bash
eagle-mem memories search "auth middleware"
```

### Show a specific memory

```bash
eagle-mem memories show <name>
```

### List mirrored plans

```bash
eagle-mem memories plans
```

### List mirrored tasks

```bash
eagle-mem memories tasks
```

### Sync all from Claude Code

Backfill all memories, plans, and tasks from Claude Code's filesystem into Eagle Mem:

```bash
eagle-mem memories sync
```

## Options

| Flag | Description |
|------|-------------|
| `-p, --project <name>` | Target a specific project (default: current directory) |
| `-n, --limit <N>` | Max results (default: 20) |
| `-j, --json` | Output as JSON |

## How it works

Eagle Mem automatically mirrors Claude Code writes via the PostToolUse hook:
- **Memories** from `~/.claude/projects/*/memory/*.md`
- **Plans** from `~/.claude/plans/*.md`
- **Tasks** from Claude Code's TaskCreate/TaskUpdate calls

The `sync` command does a full backfill for anything the hooks missed.

## When to use

- To check what Claude Code has auto-saved about this project
- To search across memories from multiple projects
- After installing Eagle Mem on an existing project (run `sync` to backfill)
