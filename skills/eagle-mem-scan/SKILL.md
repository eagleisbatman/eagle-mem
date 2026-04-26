---
name: eagle-mem-scan
description: >
  Scan and analyze a project's codebase to generate a persistent overview. Use when: 'eagle scan',
  'scan this project', 'analyze codebase', 'eagle mem scan', 'generate overview from code',
  'what does this project look like'. Uses the eagle-mem CLI.
---

# Eagle Mem — Scan

Analyze the current project's codebase and generate a concise overview that Eagle Mem injects at the start of every session.

## What it does

Scans the project directory to collect:
- File count, directory structure, languages used
- Entry points, config files, test presence
- Framework/library detection from package.json, go.mod, etc.

Then saves a compact overview to the database.

## Commands

### Scan current project

```bash
eagle-mem scan .
```

### Scan a specific directory

```bash
eagle-mem scan /path/to/project
```

## When to use

- First time opening a project with Eagle Mem
- After major restructuring (new packages, renamed dirs)
- When the current overview feels stale or wrong

The overview is automatically injected by the SessionStart hook, so every fresh session starts with project context.

## Notes

- Scans respect .gitignore — only tracked/untracked files are analyzed
- The overview is stored once per project and updated in place
- Keep the generated overview factual — it supplements session summaries
