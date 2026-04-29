---
name: eagle-mem-overview
description: >
  Build or update a structured project overview for Eagle Mem. Use when: 'eagle overview',
  'project overview', 'summarize this project', 'what is this project', 'update overview',
  or when SessionStart says no overview exists. Produces a multi-paragraph briefing.
---

# Eagle Mem — Project Overview

## Purpose

**For the user:** Every new Claude Code session starts cold. The overview eliminates the "explain what this project is" tax — Claude already knows what it's working on, how the project is structured, and what's been happening.

**For you (Claude Code):** The overview is your orientation document. It's injected at SessionStart before the user says anything. A good overview lets you give informed answers from message one. A shallow one ("42 files, Node.js") gives you nothing — you'll spend the first 3 exchanges just figuring out what the project does.

## Judgment

**Build an overview when:**
- SessionStart shows a scan-generated overview (file counts, directory listings) — upgrade it to a rich briefing
- The user asks: "update overview", "summarize this project", "what is this project"
- The project has changed significantly since the last overview (new major feature, architecture shift)

Note: New projects are auto-scanned at SessionStart. The scan produces structural metadata. This skill upgrades that into a briefing with intent, architecture, and current state.

**Don't rebuild when:**
- The overview is already rich and current — just use it
- The user needs help with a specific task — do the task first, update overview after if needed

## Steps

### 1. Read the project (skip files that don't exist)

**Identity:** README.md, package.json / go.mod / pyproject.toml / Cargo.toml
**Architecture:** Main entry point (bin/*, src/index.*, main.*, app.*), key config (tsconfig.json, Dockerfile, etc.)
**Activity:** `git log --oneline -20` for recent direction
**Structure:** `ls` the top-level directories to understand the layout

Read these files yourself — don't run `eagle-mem scan`. Scan produces structural metadata (file counts, language breakdown). You need to understand intent, not count files.

### 2. Synthesize a structured briefing

Write 4-6 paragraphs covering these layers:

**What and why** — What does this project do? Who is it for? What problem does it solve? Lead with the purpose, not the tech stack.

**How it's built** — Architecture, key abstractions, data flow. What are the main modules/packages and how do they connect? What tech choices matter (framework, database, deployment target)?

**Where to start** — Entry points, key files a new contributor would need to read first. The files that, if you understand them, you understand the project.

**Current state** — What version is it at? What's the recent direction from git log? Is it actively developed, stable, or in a transition? What was the most recent significant change?

### 3. Save and verify

```bash
eagle-mem overview set "<your structured overview>"
```

Then verify it actually saved:
```bash
eagle-mem overview
```

If the output is empty or doesn't match what you wrote, the save failed. Retry once. If it fails again, tell the user.

### 4. Fallback for empty repos

If no readable source files exist (fresh repo, no README), Eagle Mem's auto-scan has already generated a structural overview in the background. Tell the user: "Auto-scan has captured the project structure. Once you add a README or source code, re-run `/eagle-mem-overview` for a richer briefing."

## What makes a good overview

A good overview lets a fresh Claude Code context window give useful answers without reading any files first.

**Good:**
> eagle-mem is a persistent memory system for Claude Code that solves the context-loss problem across sessions. It hooks into Claude Code's lifecycle (SessionStart, Stop, PostToolUse, SessionEnd, UserPromptSubmit) to automatically capture session summaries, observations, and code context into a single SQLite database with FTS5 full-text search.
>
> The architecture is pure bash scripts and sqlite3 — no daemon, no vector DB, no MCP server. Hooks in hooks/ fire during Claude Code events and call into lib/ (common.sh, db.sh) for database operations. The db/ directory holds the schema and numbered migration files. CLI commands in scripts/ expose search, overview management, code indexing, and database maintenance.
>
> Key entry point is bin/eagle-mem, which dispatches to scripts/. Skills in skills/ are symlinked into ~/.claude/skills/ and teach Claude Code how to use each capability. The database lives at ~/.eagle-mem/memory.db.
>
> Currently at v2.0.0. Recent work focused on memory mirroring (Claude Code's auto-memories, plans, and tasks into FTS5), task-aware compact loops, and skill quality improvements.

**Bad:**
> eagle-mem: Node.js project (42 files, ~5k lines). Structure: bin/ (1), db/ (10), hooks/ (5), lib/ (3), scripts/ (13), skills/ (7). Entry: bin/eagle-mem. No tests detected.

## How automation works

Eagle Mem v4.0 auto-scans new projects at SessionStart — no user action needed. This skill exists to *upgrade* that scan into a rich, multi-paragraph briefing that captures intent, architecture, and current state.

## Reference

```bash
eagle-mem overview              # view current overview
eagle-mem overview set "..."    # save new overview
eagle-mem overview list         # all projects with overviews
eagle-mem overview delete       # remove current project's overview
```
