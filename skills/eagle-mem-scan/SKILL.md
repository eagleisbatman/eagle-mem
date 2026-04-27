---
name: eagle-mem-scan
description: >
  Structural codebase analysis — language breakdown, framework detection, entry
  points, tests, dependencies. Use when: 'eagle scan', 'scan this project',
  'analyze codebase structure', 'what is this project made of', bootstrapping
  a new project's overview, empty repo with no README.
---

# Eagle Mem — Scan

## Purpose

**For the user:** Machine-readable project analysis. Answers "what is this project made of?" with hard numbers — languages, line counts, frameworks, entry points, test presence, monorepo structure. No interpretation, just structure.

**For you (Claude Code):** Scan is the structural foundation that overview builds on. It tells you what languages and frameworks are present, how the project is organized, and whether tests exist — all without reading any source files. Use it when you need facts about project composition, not understanding of project purpose.

## Judgment

**Scan when:**
- No overview exists and the project has no README (scan is the best starting point)
- You need structural facts: "how many TypeScript files?", "is this a monorepo?", "what test framework?"
- Bootstrapping a brand-new project in Eagle Mem for the first time
- After major restructuring — added new packages, new languages, reorganized directories

**Don't scan when:**
- A rich overview already exists -- scan auto-skips when the overview exceeds 300 chars (use `--force` to override)
- You need to understand what the project does or why it's built a certain way -- that's overview's job
- You just want to look at the project -- use `ls` and `Read` instead

**Scan vs overview -- they complement each other:**
- `eagle-mem scan .` = machine analysis. Counts files, detects frameworks, finds entry points. Fast, no model reasoning. Produces a factual one-liner stored as the overview. Auto-skips if a rich overview exists.
- `/eagle-mem-overview` = model-driven analysis. You read source files, understand architecture, write a multi-paragraph briefing. Slower, much richer.

The typical flow for a new project: scan first (get the structural snapshot), then build a proper overview on top of it (which replaces the scan output with something richer).

## What scan detects

**Language breakdown:** Top 5 languages by line count. Maps file extensions to language names (`.ts`/`.tsx` = TypeScript, `.py` = Python, etc.). Reports file counts and line counts per language.

**Framework detection:** Checks `package.json` dependencies (React, Next.js, Express, Hono, Prisma, Tailwind, etc.), Python markers (Django, Flask, FastAPI), and ecosystem files (Cargo.toml, go.mod, Gemfile, pubspec.yaml, mix.exs, etc.).

**Structure:** Top-level directories with file counts. Uses `git ls-files` in git repos, falls back to `find` otherwise.

**Entry points:** Looks for `bin/*`, `src/index.*`, `src/main.*`, `src/app.*`, `index.*`, `main.*`, `app.*`, `server.*`, `cli.*`.

**Tests:** Counts files matching test patterns (`test/`, `tests/`, `__tests__/`, `.test.`, `.spec.`, `_test.`). Detects test frameworks (Jest, Vitest, Mocha, pytest).

**Config files:** Finds Dockerfile, docker-compose, tsconfig, ESLint, Biome, Tailwind config, Vite/Next/Webpack config, railway.json, CLAUDE.md, and others.

**Dependencies:** Counts npm deps/devDeps from package.json, Go modules from go.mod.

**Monorepo:** Detects npm workspaces, pnpm-workspace.yaml, Lerna, Turborepo.

## Steps

### 1. Run the scan

```bash
eagle-mem scan .                 # current directory
eagle-mem scan /path/to/project  # specific path
```

### 2. Read the output

Scan prints each detection as it goes:
```
  + 47 files found
  + Languages: TypeScript (12k lines, 35 files), Bash (2k lines, 8 files)
  + Frameworks: Hono, Prisma, Tailwind
  + Structure: src/ (28), db/ (10), scripts/ (8), hooks/ (5)
  + Entry points: bin/eagle-mem, src/index.ts
  + Tests: 6 test files (Vitest)
  + Config: tsconfig.json, CLAUDE.md, railway.json
  + Dependencies: npm: 12 deps, 8 devDeps
```

**What to look for:**
- "No tests detected" — notable, worth mentioning to the user
- 0 entry points — unusual, might mean non-standard project structure
- Missing framework detection — scan only checks known patterns; niche frameworks won't appear
- Very high file counts with few lines — lots of config/generated files

### 3. Decide what's next

**If this is a new project with no overview:** The scan output is now stored as the overview. Tell the user: "Structural overview saved. Run `/eagle-mem-overview` for a richer briefing once you're ready."

**If a rich overview already existed:** You just overwrote it. Re-run `/eagle-mem-overview` immediately to rebuild the semantic understanding on top of the new structural data.

## What makes a good scan decision

**Good:**
> Fresh repo, no README, no overview in Eagle Mem. Running `eagle-mem scan .` to get a structural baseline, then building a proper overview from the source code.

**Bad:**
> The project already has a detailed 4-paragraph overview from last session. Running `eagle-mem scan --force .` to "refresh the data." [This replaces the rich overview with a one-liner.]

The scan is a starting point, not a maintenance tool. Once a proper overview exists, update it with `/eagle-mem-overview` -- don't overwrite it with scan.

## Reference

```bash
eagle-mem scan .                 # scan current directory (skips if rich overview exists)
eagle-mem scan --force .         # scan and overwrite even if rich overview exists
eagle-mem scan /path/to/project  # scan specific path
eagle-mem overview               # view the current overview
eagle-mem overview set "..."     # manually set overview (what /eagle-mem-overview does)
```

| Detail | Notes |
|--------|-------|
| Output stored in | `overviews` table (same as `overview set`) |
| Overwrites existing overview | Only with `--force` -- auto-skips if overview > 300 chars |
| Respects .gitignore | Yes, uses `git ls-files` in git repos |
| Requires model reasoning | No -- pure bash + awk analysis |
| Typical runtime | Under 2 seconds for most projects |
