---
name: eagle-mem-search
description: >
  Search Eagle Mem's persistent memory database. Use when: 'eagle search', 'search memory',
  'what did I do', 'eagle mem search', 'find in memory', 'past sessions', 'what happened with',
  'search my history'. Three-layer search: compact index (fast) → timeline (chronological) →
  full details (complete observations).
---

# Eagle Mem — Memory Search

Search the Eagle Mem database for past session summaries, observations, and task history.

## Three-layer search pattern

### Layer 1: Compact search (default)

Fast keyword search across session summaries. Returns ~50-100 tokens per result.

```bash
sqlite3 ~/.eagle-mem/memory.db "
PRAGMA trusted_schema=ON;
SELECT s.id, s.request, s.completed, s.created_at, s.project
FROM summaries s
JOIN summaries_fts f ON f.rowid = s.id
WHERE summaries_fts MATCH '<query>'
ORDER BY rank
LIMIT 10;
"
```

Use this first. If the user needs more detail, go to Layer 2 or 3.

### Layer 2: Timeline (chronological context)

Show recent sessions for a project in time order. Good for "what have I been working on?"

```bash
sqlite3 ~/.eagle-mem/memory.db "
SELECT s.request, s.completed, s.learned, s.next_steps, s.created_at
FROM summaries s
WHERE s.project = '<project>'
ORDER BY s.created_at DESC
LIMIT <N>;
"
```

### Layer 3: Full details (observations)

When the user needs to know exactly what files were touched or what tools were used:

```bash
sqlite3 ~/.eagle-mem/memory.db "
PRAGMA trusted_schema=ON;
SELECT o.tool_name, o.tool_input_summary, o.files_read, o.files_modified, o.created_at
FROM observations o
WHERE o.session_id = '<session_id>'
ORDER BY o.created_at ASC;
"
```

## Additional queries

### Cross-project search

```bash
sqlite3 ~/.eagle-mem/memory.db "
PRAGMA trusted_schema=ON;
SELECT s.project, s.request, s.completed, s.created_at
FROM summaries s
JOIN summaries_fts f ON f.rowid = s.id
WHERE summaries_fts MATCH '<query>'
ORDER BY rank
LIMIT 10;
"
```

### Files frequently modified

```bash
sqlite3 ~/.eagle-mem/memory.db "
PRAGMA trusted_schema=ON;
SELECT json_each.value as file, COUNT(*) as times
FROM observations, json_each(observations.files_modified)
WHERE observations.project = '<project>'
GROUP BY json_each.value
ORDER BY times DESC
LIMIT 20;
"
```

### Task history

```bash
sqlite3 ~/.eagle-mem/memory.db "
SELECT id, title, status, completed_at
FROM tasks
WHERE project = '<project>'
ORDER BY ordinal ASC, id ASC;
"
```

### Session count and stats

```bash
sqlite3 ~/.eagle-mem/memory.db "
SELECT
    COUNT(DISTINCT s.id) as sessions,
    COUNT(DISTINCT su.id) as summaries,
    COUNT(DISTINCT o.id) as observations,
    COUNT(DISTINCT t.id) as tasks
FROM sessions s
LEFT JOIN summaries su ON su.project = s.project
LEFT JOIN observations o ON o.session_id = s.id
LEFT JOIN tasks t ON t.project = s.project
WHERE s.project = '<project>';
"
```

## Usage tips

- Start with Layer 1 (compact search) — it's fast and usually sufficient
- Use FTS5 query syntax: `word1 AND word2`, `"exact phrase"`, `word1 OR word2`, `word1 NOT word2`
- The `project` column maps to the directory name (basename of cwd)
- Cross-project search omits the WHERE project clause
- Observations are high-volume — query by session_id, not full table scans
