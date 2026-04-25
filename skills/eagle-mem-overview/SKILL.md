---
name: eagle-mem-overview
description: >
  Generate or update a project overview for Eagle Mem. Use when: 'eagle overview',
  'project overview', 'summarize this project', 'eagle mem overview', 'what is this project',
  'update overview'. Creates a persistent one-paragraph project summary injected at session start.
---

# Eagle Mem — Project Overview

Generate a concise project overview that Eagle Mem injects at the start of every session. This gives fresh context windows an instant understanding of what the project is and what's been happening.

## How it works

1. Query recent summaries and observations for the current project
2. Synthesize them into a concise overview (2-4 sentences)
3. Save to the `overviews` table — one row per project, updated in place

The overview is automatically injected by the SessionStart hook.

## Generating an overview

### Step 1: Gather context

```bash
sqlite3 ~/.eagle-mem/memory.db "
SELECT request, completed, learned, next_steps, created_at
FROM summaries
WHERE project = '<project>'
ORDER BY created_at DESC
LIMIT 10;
"
```

Also check frequently modified files:

```bash
sqlite3 ~/.eagle-mem/memory.db "
PRAGMA trusted_schema=ON;
SELECT json_each.value as file, COUNT(*) as times
FROM observations, json_each(observations.files_modified)
WHERE observations.project = '<project>'
GROUP BY json_each.value
ORDER BY times DESC
LIMIT 10;
"
```

### Step 2: Write the overview

Synthesize the data into a concise overview covering:
- **What** the project is (one sentence)
- **Current state** — what's been worked on recently
- **Key patterns** — tech stack, architecture decisions, active conventions

Keep it under 500 characters. This gets injected into every session start, so brevity matters.

### Step 3: Save to database

```bash
sqlite3 ~/.eagle-mem/memory.db "
PRAGMA trusted_schema=ON;
INSERT INTO overviews (project, content, updated_at)
VALUES ('<project>', '<overview text>', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
ON CONFLICT(project) DO UPDATE SET
    content = excluded.content,
    updated_at = excluded.updated_at;
"
```

## Viewing the current overview

```bash
sqlite3 ~/.eagle-mem/memory.db "
SELECT project, content, updated_at FROM overviews
WHERE project = '<project>';
"
```

## Listing all project overviews

```bash
sqlite3 ~/.eagle-mem/memory.db "
SELECT project, substr(content, 1, 80) || '...', updated_at
FROM overviews
ORDER BY updated_at DESC;
"
```

## Deleting an overview

```bash
sqlite3 ~/.eagle-mem/memory.db "
DELETE FROM overviews WHERE project = '<project>';
"
```

## Guidelines

- Update the overview when the project direction changes significantly
- Keep it factual — what IS, not what SHOULD BE
- Don't include task lists or TODOs — those belong in the tasks table
- The overview supplements (doesn't replace) recent session summaries
