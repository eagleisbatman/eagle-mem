# Eagle Mem Visible Surface UX Contract

Eagle Mem has two audiences for visible output:

- The user, who should see a calm product surface.
- The active agent, which needs compact operational context without raw internals.

Default output must be useful without exposing implementation details. Raw database
IDs, file paths, session IDs, backing JSON, hook payloads, and source file content
belong behind `--raw`, `--debug`, or `--json`.

## Output Modes

| Mode | Purpose | Allowed Content |
| --- | --- | --- |
| Default | Human product UX | Brand, status, concise summaries, freshness, next action |
| `--json` | Machine-readable automation | Structured complete fields |
| `--raw` | Developer inspection | IDs, source paths, backing files, raw task JSON |
| `--debug` | Troubleshooting | Same as `--raw`, plus diagnostic hints where useful |

## Visible Surfaces

| Surface | User Sees It? | Default Standard |
| --- | --- | --- |
| `SessionStart` | Yes, in agent transcript | Branded compact briefing: project, memory, relevant now, work state, guardrails |
| `UserPromptSubmit` | Yes, in agent transcript | `Eagle Mem recalls` with 1-2 useful bullets and relevant code |
| `PreToolUse` | Sometimes, when blocking | Calm explanation, recommended fix, one-off bypass if appropriate |
| `PostToolUse` | Sometimes, after reads/edits | Structured memory/decision/feature notes, no separator blocks for Codex |
| `statusline` | Yes | Short branded status: version, sessions, memories, turn |
| `search` | Yes | Freshness-aware results, no raw IDs in headings |
| `memories` | Yes | Project-scoped list by default, no source paths unless raw/debug |
| `tasks` | Yes | Task subject/status/source, no session/task IDs unless raw/debug |
| `feature` | Yes | Pending work grouped by action, raw diff fingerprints only when needed |
| `health` | Yes | Overall verdict first, then sectioned checks and next action |
| `install/update/uninstall` | Yes | Explain changed footprint, reversibility, backups, and success/failure plainly |
| `doctor` | Yes | Trust report: installed runtime, hooks, SQLite/FTS5, install manifest, drift, uninstall coverage |

## Product Voice

- Use `Eagle Mem` or `Eagle`; avoid cryptic `EM` in user-facing output.
- Prefer headings like `Relevant now`, `Work state`, `Guardrail`, and `Next`.
- Prefer freshness labels like `Fresh`, `Recent`, `Older`, or `may be stale`.
- Avoid dumping raw hook payloads, XML templates, SQL results, or JSON unless the user requested raw/debug output.
- Keep Codex transcript injections more compact than Claude Code injections.

## Install/Update/Uninstall Standard

- Before mutating user config or runtime files, show a short "What will change" plan.
- Treat `--dry-run` as a first-class product path for destructive or cleanup commands.
- Back up user-owned config files before editing `~/.claude` or `~/.codex` state.
- Preserve `~/.eagle-mem/memory.db` by default; require explicit confirmation before deleting stored memory.
- After install/update, write a manifest with runtime file metadata so `doctor` can verify drift without noisy shell dumps.
- Prefer one clear verdict first (`Healthy`, `Needs attention`, or `Broken`), then details.
