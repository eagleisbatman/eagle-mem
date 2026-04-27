---
name: eagle-mem-index
description: >
  Index source files into FTS5-searchable chunks. Use when: 'eagle index', 'index this project',
  'make code searchable', 'reindex', 'update index', 'index after pull',
  'code search setup'. Uses the eagle-mem CLI.
---

# Eagle Mem — Index

## Purpose

**For the user:** Claude Code can find code they wrote weeks ago -- across sessions, without needing to remember which file it was in. Every prompt automatically surfaces relevant code chunks from the index, so past work stays accessible.

**For you (Claude Code):** The UserPromptSubmit hook searches `code_chunks` on every user prompt and injects matching file references into your context. You don't call a search command for this -- it happens automatically. But the index must exist and be current for it to work. That's what this skill manages.

## Judgment

**Index when:**
- First time setting up Eagle Mem on a project (`eagle-mem index .`)
- After a `git pull` or branch switch that brought in significant changes
- After a major refactor (renamed files, moved directories, new modules)
- The user says "index this project" or "make code searchable"
- You notice the UserPromptSubmit hook isn't surfacing relevant code -- the index may be stale

**Don't index when:**
- You just need to read a specific file -- use Read directly
- The project was recently indexed and no files changed (mtime dedup handles this, but don't waste time running it)
- You're in the middle of a task -- index at session boundaries, not mid-work

**Decision rule:** Index is a maintenance task, not a search tool. Run it to *prepare* the database, then rely on the automatic hook to *use* it. If the hook isn't surfacing what you expect, the index is stale -- re-run.

## Steps

### 1. Run the indexer

```bash
eagle-mem index .
```
Indexes the current directory. The script:
- Collects source files (respects `.gitignore`, skips binaries/lockfiles)
- Filters to known source extensions (sh, js, ts, py, go, rs, java, etc.)
- Skips files over 1MB
- Compares mtime against stored mtime -- only re-indexes changed files
- Chunks each file into segments (default 80 lines) and inserts into `code_chunks` with FTS5

The mtime check makes re-running cheap. On a project with 200 files where 5 changed, it processes only those 5.

### 2. Understand chunk size

Default: 80 lines per chunk. Override with:
```bash
EAGLE_MEM_CHUNK_SIZE=40 eagle-mem index .
```

**Smaller chunks (30-50):** More precise search matches. Better for codebases with many small, distinct functions. Produces more chunks -- larger DB.

**Larger chunks (100-150):** More context per match. Better for files with long, cohesive blocks. Fewer chunks -- smaller DB.

**When to change:** If the hook is surfacing irrelevant matches (chunks too big, mixing unrelated code), shrink. If matches lack context (cutting functions in half), grow. The default of 80 works well for most projects.

### 3. Know what gets indexed

The indexer processes files matching these extensions:
`sh bash zsh js jsx mjs cjs ts tsx mts py rb go rs java kt kts swift c h cpp cc cxx hpp cs php sql html htm css scss vue svelte dart ex exs zig lua r scala yaml yml toml json md`

Silently skipped: images, binaries, lockfiles (`package-lock.json` etc. are over 1MB), `.git/` contents, anything in `.gitignore`.

### 4. Understand how indexed code reaches the user

The flow is:
1. You run `eagle-mem index .` -- code is chunked and stored in `code_chunks` table
2. User submits a prompt in any future session
3. UserPromptSubmit hook extracts keywords from the prompt
4. Hook searches `code_chunks` FTS5 index for matches
5. Matching file paths + line ranges are injected into your context as "EAGLE MEM — Relevant Code"

There is no manual "search code" CLI command. The index feeds the hook, and the hook feeds you. Your job is to keep the index current.

### 5. Verify the index

After indexing, confirm it worked:
```bash
eagle-mem search --stats
```
Check the "Code chunks" count. For a typical project:
- 50-file project ~ 200-500 chunks
- 200-file project ~ 800-2000 chunks
- 0 chunks after indexing = something went wrong (check file extensions, directory path)

Also verify the hook is using it: on the next user prompt with 3+ words, you should see "EAGLE MEM — Relevant Code" injected if any chunks match.

### 6. When indexing gets stale

The index reflects the state of files *when you last ran it*. It goes stale when:
- `git pull` brings in changes from others
- `git checkout` switches branches (different file contents, possibly different files)
- A major refactor renames or moves files (old paths stay in the index, new paths are missing)
- Dependencies are updated and source files regenerate

**After any of these, re-run `eagle-mem index .`** The mtime check ensures only changed files are re-processed. Old chunks for unchanged files are kept. Chunks for changed files are atomically replaced (DELETE + INSERT in a transaction).

## What makes a good indexing practice

**Good:**
> Indexed the project after pulling the team's changes from main. Stats show 1,247 chunks across 189 files. The UserPromptSubmit hook should now surface the new API routes the team added.

**Bad:**
> Indexed once when Eagle Mem was installed and never again. The hook keeps surfacing stale code from deleted files, and misses the 30 new files added over the past month.

## Reference

| Command / Flag | What it does |
|---|---|
| `eagle-mem index .` | Index current directory (incremental via mtime) |
| `eagle-mem index /path/to/dir` | Index a specific directory |
| `EAGLE_MEM_CHUNK_SIZE=N` | Override chunk size (default: 80 lines) |
| `eagle-mem search --stats` | Verify chunk count after indexing |
| Max file size | 1MB (larger files silently skipped) |
| Dedup | mtime-based -- re-running is cheap and safe |
