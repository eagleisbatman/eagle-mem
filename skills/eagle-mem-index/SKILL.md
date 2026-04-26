---
name: eagle-mem-index
description: >
  Index source files into FTS5-searchable chunks for code-level search. Use when: 'eagle index',
  'index this project', 'index codebase', 'eagle mem index', 'make code searchable',
  'update code index'. Uses the eagle-mem CLI.
---

# Eagle Mem — Index

Chunk and index source files into Eagle Mem's FTS5 search index. Enables code-level search across sessions.

## What it does

- Walks the project directory for source files
- Splits each file into chunks (default 80 lines)
- Stores chunks in the `code_chunks` table with FTS5 indexing
- Incremental: only re-indexes files modified since the last run (via mtime)

## Commands

### Index current project

```bash
eagle-mem index .
```

### Index a specific directory

```bash
eagle-mem index /path/to/project
```

## When to use

- After initial project setup to make code searchable
- After pulling significant changes
- When `/eagle-mem-search` isn't finding code you know exists

## How it integrates

Once indexed, the UserPromptSubmit hook can surface relevant code chunks when you ask questions. The `/eagle-mem-search` skill also searches indexed code.

## Notes

- Respects .gitignore — only indexes tracked/untracked source files
- Skips binary files and files over 1MB
- Chunk size is configurable via `EAGLE_MEM_CHUNK_SIZE` env var (default: 80 lines)
- Re-running is safe — unchanged files are skipped automatically
