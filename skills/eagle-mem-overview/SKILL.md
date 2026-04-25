---
name: eagle-mem-overview
description: >
  Generate or update a project overview for Eagle Mem. Use when: 'eagle overview',
  'project overview', 'summarize this project', 'eagle mem overview', 'what is this project',
  'update overview'. Uses the eagle-mem CLI — never run raw sqlite3 queries.
---

# Eagle Mem — Project Overview

Generate a concise project overview that Eagle Mem injects at the start of every session. This gives fresh context windows an instant understanding of what the project is.

## How it works

1. Gather context about the project (recent sessions, file activity)
2. Synthesize into a concise overview (2-4 sentences)
3. Save via the CLI — one overview per project, updated in place

The overview is automatically injected by the SessionStart hook.

## Commands

### View current overview

```bash
eagle-mem overview
```

### Auto-generate from code analysis

```bash
eagle-mem scan .
```

This scans the project structure (files, languages, frameworks, entry points, tests) and saves an overview automatically.

### Set overview manually

When you want to write a custom overview based on session history:

1. First, gather recent context:
```bash
eagle-mem search --timeline --limit 10
eagle-mem search --files
```

2. Synthesize the data into a concise overview covering:
   - **What** the project is (one sentence)
   - **Current state** — what's been worked on recently
   - **Key patterns** — tech stack, architecture decisions

3. Save it:
```bash
eagle-mem overview set "eagle-mem: Node.js CLI tool providing persistent memory for Claude Code via SQLite + FTS5. Currently at v1.0.3 with 5 hooks, 3 skills, and CLI subcommands for search/tasks/overview."
```

Keep it under 500 characters — this gets injected into every session start.

### List all project overviews

```bash
eagle-mem overview list
```

### Delete an overview

```bash
eagle-mem overview delete
```

## Options

| Flag | Description |
|------|-------------|
| `-p, --project <name>` | Target a specific project (default: current directory) |
| `-j, --json` | Output as JSON |

## Guidelines

- Update the overview when the project direction changes significantly
- Keep it factual — what IS, not what SHOULD BE
- Don't include task lists or TODOs — those belong in the tasks table
- The overview supplements (doesn't replace) recent session summaries
