# Eagle Mem — Full-Spectrum Review & Hardening (2026-06-10)

Branch `review/arch-hardening` (off `main` @ v4.12.1). Six-lens review, fix-in-place.
**32 files changed (+1275 / −101); 6 new regression suites (registered checks 33 → 39); full `scripts/test.sh` suite green.** Nothing published — release is a separate, user-gated step.

| Phase | Lens | Commit |
|---|---|---|
| 1 | Security | `be08b31` |
| 2 | Data integrity & DB | `1fdaa2e` |
| 3 | Reliability / self-healing | `9451cdd` |
| 4 | Performance / token economy | `0ef772e` |
| 5 | Code quality | `d50ba86` |
| 6 | Architecture / coupling | this document (assessment + proposals) |

---

## Fixed (with the test that proves it)

### Phase 1 — Security (`be08b31`)
1. **Unredacted LLM input** — transcript excerpts were sent to providers (remote APIs via fallback) and written to the enrich job file in the clear. Now `eagle_redact` runs on the input before send/persist (`hooks/stop.sh`, `scripts/enrich-summary.sh`).
2. **Raw prompt in `recall_events`** — `prompt_snippet` now redacted before insert (`lib/db-observations.sh`).
3. **Truncate-before-redact** — Bash command summary now redacted *then* truncated (`hooks/post-tool-use.sh`).
4. **Dead `extra_patterns` knob** — `[redaction] extra_patterns` config now wired into `eagle_redact` (`lib/common.sh`).
5. **Antigravity binary hijack** — hook resolves `bin/eagle-mem` + hook scripts from the install dir, not `os.getcwd()`; validates `SESSION_ID` (`integrations/google_antigravity_hook.py`).
6. **Prompt via argv (`ps`-visible)** — Claude CLI provider + antigravity summary now pass prompts via stdin (`lib/provider.sh`, `scripts/session.sh`).
7. **Non-canonical log containment** — `logs.sh` canonicalizes (realpath) before the runs-root containment check.
8. **jq program-string interpolation** — codex-hooks event name passed via `--arg` (`lib/codex-hooks.sh`).
9. **Unattended full-access workers (highest severity)** — orchestration workers no longer default to `--sandbox danger-full-access` / `dontAsk` on DB-assembled prompts. `[orchestration] worker_autonomy` defaults to **safe** (`workspace-write` / `on-request` / `acceptEdits`); `danger` is explicit opt-in (`scripts/orchestrate.sh`).
   *Proof:* `tests/test_redaction_coverage.sh` (seeds fake secrets; asserts none reach provider input / recall_events / enrich job; asserts safe-mode run-scripts carry no full-access flags).

### Phase 2 — Data integrity & DB (`1fdaa2e`)
- **Fail-open `sqlite3` guards** — standalone reads now set `busy_timeout` so `SQLITE_BUSY` waits instead of reading as "no data" (`lib/common.sh` ×2, `scripts/statusline-em.sh`, `scripts/tasks.sh`, `lib/updater.sh`); `eagle_project_has_table_row` allowlists its table identifier; `tasks.sh` escapes a DB-read value + uses `eagle_db`.
- **Mod-tracker data loss / lock wedge** — stale-lock TTL reclaim, atomic mv-based pending drain (no append lost), and the edit-history append is now locked (`hooks/post-tool-use.sh`).
- **Project clobber** — summary `project` is now sticky on conflict for agent rows (`lib/db-summaries.sh`).
- **Error masking** — added `eagle_db_strict` (`.bail on`) for fail-fast callers (left `eagle_db` continue-on-error to avoid breaking ~200 callers); observation dedup runs in `BEGIN IMMEDIATE`; the project-repair transaction now logs failure (`lib/db-core.sh`, `lib/db-observations.sh`, `lib/db-sessions.sh`).
- **PRAGMA-stripping footgun** documented in `db/migrate.sh`.
   *Proof:* `tests/test_data_integrity_hardening.sh` (migrate idempotency, SQL-escaping, summary precedence/clobber) + `tests/test_mod_tracker_concurrency.sh` (40 parallel writers, no lost append, lock reclaim, dedup race).

### Phase 3 — Reliability / self-healing (`9451cdd`)
- **24h auto-scan block** — the foreground touch now sets a short-lived *in-flight* marker (debounce); the durable *freshness* marker is set only on genuine background success, so a crashed/output-less scan no longer blocks retry for a day (`lib/hooks-sessionstart.sh`).
- **Unbounded `eagle_events`** (≈99k rows on this machine) — pruned by age (30d) at SessionEnd via new `eagle_prune_events` (`lib/db-events.sh`, `hooks/session-end.sh`).
- **`pending_feature_verifications`** — deliberately *not* TTL'd (documented; expiring it would let an unverified change ship).
   *Proof:* `tests/test_reliability_retention.sh`.

### Phase 4 — Performance / token economy (`0ef772e`)
- **SessionStart injection ceiling** — added a generous global budget (`context_budget.sessionstart_chars`, default 24000 chars / ~6K tokens, floored at 4000) that drops whole low-priority sections from the bottom (never splits a section; always keeps overview/recent/memories + capture instructions), logs a trim, and records `sections_trimmed`. Normal recall is byte-for-byte unchanged. The earlier "3 git diffs per tool call" concern was verified overstated (gated behind release-boundary detection).
   *Proof:* `tests/test_context_budget.sh`.

### Phase 5 — Code quality (`d50ba86`)
- **Test runner aborted at first failure** — `((errors++))` returns 1 when `errors==0`, so under `set -euo pipefail` the first failing check killed the runner before it could report the count. Switched to `errors=$((errors + 1))`. (This is why a failing check earlier showed truncated output.)
   *Proof:* `tests/test_test_runner_no_abort.sh` (incl. a control proving the old form aborts).
- Audited: all remaining `grep -F` sites are genuinely literal; `feature.sh`'s `changes()` pattern is benign; all shell tests registered; `extra_patterns` confirmed live.

---

## Phase 6 — Architecture assessment (propose only)

The system is sound and unusually well-instrumented for a bash project (durable feature gate, hook observability, redaction, FTS recall). The structural risks below are about *coupling and blast radius*, not correctness; none were auto-refactored because they move code across gate-watched files and would destabilize every adapter mid-review.

1. **`lib/common.sh` is a 2k-line nexus.** It owns project-identity resolution, redaction, command classification, release-boundary detection, the token-budget trim, and CLAUDE.md/AGENTS.md patching — and every hook and adapter depends on it. *Proposal:* decompose into focused libs (`lib/identity.sh`, `lib/redact.sh`, `lib/cmd-classify.sh`, `lib/claude-md.sh`) behind the current function names, one module at a time, each with the existing tests as the safety net. High value, medium risk; do it as its own series, not inside a review.

2. **`scripts/orchestrate.sh` (largest script, 1.3k lines) ↔ `bin/eagle-mem` re-entrancy.** Worker lifecycle state is spread across DB rows + run-dir files (`exit_code`, `.done`) + PIDs, with recorded cancellation/resume gaps. Now that autonomy is gated (Phase 1), the next step is a single source of truth for lane state and an explicit cancel/resume contract. *Proposal, separate effort.*

3. **Curator → guardrail → PreToolUse feedback loop.** LLM output (`PROMOTE:` lines, learned command rules) becomes enforcement input that steers future command execution, with only format-level validation. *Proposal:* tag model-derived guardrails/rules with provenance and require confirmation (or a confidence threshold) before they can rewrite commands — closes the loop between the curator and the autonomy work done in Phase 1.

4. **Adapter parity is convention-held; Grok has no hook lifecycle.** Five agents × six events × three transports (native hooks / JS plugin / Python shim) are kept in line only by `docs/agent-compatibility/` + the docs gate. Grok is skills-only — no capture, no guardrails, **no release gate** — and bare-shell pushes also bypass the gate (it lives only in PreToolUse). *Proposal:* either document Grok/bare-shell as explicitly out-of-gate scope, or add a lightweight pre-push wrapper so governance isn't silently skippable.

5. **install.sh / update.sh duplication.** Currently *in sync*, but the hook matchers are duplicated literals across both — the historical drift class. *Proposal (from Phase 5):* extract `eagle_register_claude_hooks` into `lib/hooks.sh` and call it from both.

---

## Deferred proposals (rationale)

- **PostToolUse zero-state short-circuit** — skip stale-memory / decision FTS on empty projects; needs a cached count to avoid adding a query (recall-sensitive).
- **UserPromptSubmit query consolidation** — the 3 FTS queries hit different tables/ranking; UNION would entangle parsing for ~1 process spawn saved. Recommend leaving as-is.
- **Provider LLM-output cache** — correctness risk (stale enrichment); needs content-hash invalidation.
- **`tests/test_antigravity_hook.py`** runs only manually — add a guarded python lane to `scripts/test.sh` or document as dev-only.
- **Dead-function sweep** — ~18 lib functions have no shell caller, but several are public aliases / dynamic-dispatch; needs an owner-confirmed call-graph (incl. `.py`/`.js`) before removal.

---

## Verification

- Per phase: `bash scripts/test.sh` fully green; `bash -n` on every touched shell file; `py_compile` + `tests/test_antigravity_hook.py` for the Python hook.
- New coverage: redaction (provider input / recall_events / enrich job / autonomy / log paths), migration idempotency + SQL escaping + summary precedence, 40-writer mod-tracker concurrency, scan in-flight/freshness + events retention, context budget, test-runner no-abort.
- The docs gate (`tests/test_agent_compatibility_docs_gate.sh`) was satisfied with truthful dated evidence notes for each phase that touched a sensitive integration file.

## Releasing

Not auto-shipped. To release (likely `v4.13.0`): bump + CHANGELOG, clear the feature gate, `npm publish`, `npm install -g eagle-mem@<v>` → `eagle-mem update`, verify the installed `~/.eagle-mem` runtime, then gh-pages + GitHub release.
