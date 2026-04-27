---
name: eagle-mem-search
description: >
  Search Eagle Mem's persistent memory. Use when: 'eagle search', 'search memory',
  'what did I do', 'find in memory', 'past sessions', 'what happened with',
  'search my history', 'what do you remember about', 'show recent sessions',
  'what files changed', 'memory stats'. Uses the eagle-mem CLI.
---

# Eagle Mem — Search

## Purpose

**For the user:** Never repeat yourself. Every decision, every debug session, every architectural choice is searchable across months and projects. "What did we do with auth?" gets a real answer, not a guess.

**For you (Claude Code):** Access to the past. When the user references prior work, you can find it instead of fabricating it. Search gives you summaries, observations, file history, and cross-project patterns -- all FTS5-indexed.

## Judgment

**Search when:**
- The user asks about past work ("what did we do with X?", "when did we change Y?")
- You need context before making a decision (was this pattern tried before? what broke last time?)
- The user references something from a prior session and you have no context
- You want to understand the trajectory of a project (timeline mode)

**Don't search when:**
- The answer is in the current codebase -- read the code instead
- The user is asking you to do something, not recall something
- You already have the answer from SessionStart context injection

**Decision rule:** If the question is about *what happened* or *why we decided*, search memory. If the question is about *what the code does now*, read the code.

## Steps

### 1. Start specific, then broaden (3-layer recall)

**Layer 1 -- Keyword search.** Start with the most specific terms.
```bash
eagle-mem search "webhook retry logic"
```
This searches summaries (session request, completed, learned fields). Look at session IDs in results -- you'll need them for Layer 2.

**Layer 2 -- Session drill-down.** When a summary looks relevant, expand it to see every tool call in that session.
```bash
eagle-mem search --session <id>
```
This shows the full observation trail: what files were read, written, what bash commands ran. This is where you find the actual sequence of work.

**Layer 3 -- Correlate across sessions.** If you see a pattern in one session, broaden to find related work.
```bash
eagle-mem search "webhook" --all        # cross-project
eagle-mem search "retry" --limit 20     # more results
eagle-mem search --timeline             # recent work chronology
```

### 2. Use FTS5 syntax effectively

The query goes through FTS5 with light sanitization. What works:
- `word1 word2` -- implicit AND (both must appear)
- `word1 OR word2` -- either term matches
- Single words -- broadest match

What does NOT work (stripped by sanitizer):
- `"exact phrase"` -- quotes are removed, words match independently
- `prefix*` -- asterisks are stripped
- Parenthesized groups -- stripped

**Practical tip:** If `webhook retry` returns nothing, try `webhook OR retry` to loosen the match. If results are noisy, add more specific terms to narrow.

### 3. Use the right mode for the question

| Question type | Command | What you get |
|---|---|---|
| "What did we do with X?" | `search "X"` | Matching summaries with request/completed/learned |
| "What happened recently?" | `search --timeline` | Last N sessions in date order |
| "Show me that session" | `search --session <id>` | Every observation in the session |
| "What are the hot files?" | `search --files` | Files ranked by modification frequency |
| "How much is stored?" | `search --stats` | Session, summary, observation, chunk counts |

### 4. Synthesize — don't dump

Raw search output is not an answer. After searching:
- **Summarize patterns.** "You worked on auth across 4 sessions over the past 2 weeks. The main change was moving from JWT to session cookies, driven by mobile client limitations."
- **Cite session IDs.** "Session #42 is where the retry logic was added" -- lets the user drill down if they want.
- **Flag gaps.** If the topic predates Eagle Mem's install or the results are thin, say so. Don't fill gaps with guesses.

### 5. Cross-project search

When the user works on multiple projects, patterns may span them.
```bash
eagle-mem search "rate limiting" --all
```
This drops the project filter and searches everything. Useful for: "Have I implemented rate limiting before?", "What projects used Redis?", finding reusable patterns.

## What makes a good search response

**Good:**
> Eagle Mem found 3 sessions related to webhook retry logic. The pattern evolved across sessions: #31 added basic retries with exponential backoff, #35 fixed a bug where retries weren't respecting the max-attempts config, and #38 added dead-letter queue support after retries exhaust. The key decision (session #35) was to cap retries at 5 with a 30-second max delay -- you noted this was to avoid overwhelming the target service.

**Bad:**
> Here are the search results:
> #31 2024-03-01 Request: add webhook retries Completed: added retry logic
> #35 2024-03-05 Request: fix retry bug Completed: fixed retry config
> #38 2024-03-10 Request: webhook improvements Completed: added DLQ

## Reference

| Flag | What it does |
|---|---|
| `"query"` | FTS5 keyword search across summaries |
| `--timeline` `-t` | Recent sessions in chronological order |
| `--session <id>` `-s` | Full observations for one session |
| `--files` `-f` | Most frequently modified files |
| `--stats` | Database counts (sessions, summaries, observations, code chunks) |
| `--all` `-a` | Cross-project search (drops project filter) |
| `--limit N` `-n` | Max results (default: 10) |
| `--project <name>` `-p` | Override project (default: current directory) |
| `--json` `-j` | Machine-readable JSON output |
