---
name: eagle-mem-search
description: >
  Search Eagle Mem's persistent memory database. Use when: 'eagle search', 'search memory',
  'what did I do', 'eagle mem search', 'find in memory', 'past sessions', 'what happened with',
  'search my history'. Uses the eagle-mem CLI — never run raw sqlite3 queries.
---

# Eagle Mem — Memory Search

Search the Eagle Mem database for past session summaries, observations, and task history using the `eagle-mem` CLI.

## Search commands

### Keyword search (default)

Search past sessions by keyword. Returns matching summaries ranked by relevance.

```bash
eagle-mem search "auth middleware"
```

Cross-project search:
```bash
eagle-mem search "deploy issue" --all
```

### Timeline (chronological)

Show recent sessions for the current project in time order.

```bash
eagle-mem search --timeline
eagle-mem search --timeline --limit 20
```

### Session details

View all tool observations (files read/written, commands run) for a specific session.

```bash
eagle-mem search --session <session_id>
```

### Frequently modified files

Show which files are touched most often in this project.

```bash
eagle-mem search --files
```

### Project stats

Get counts of sessions, summaries, observations, tasks, and code chunks.

```bash
eagle-mem search --stats
```

## Options

| Flag | Description |
|------|-------------|
| `-p, --project <name>` | Target a specific project (default: current directory) |
| `-n, --limit <N>` | Max results (default: 10) |
| `-a, --all` | Search across all projects |
| `-j, --json` | Output as JSON (for programmatic use) |

## Three-layer pattern

Start with **keyword search** — it's fast and usually sufficient. If the user needs chronological context, use **--timeline**. If they need exact file-level detail, use **--session** with a specific session ID from a previous search result.

## Usage tips

- Keyword search supports FTS5 syntax: `word1 AND word2`, `"exact phrase"`, `word1 OR word2`
- The `--json` flag is useful when you need to parse results programmatically
- Project name defaults to the basename of the current working directory
