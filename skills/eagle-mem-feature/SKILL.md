---
name: eagle-mem-feature
description: >
  Manage Eagle Mem feature verification and anti-regression guardrails. Use when:
  'feature pending', 'verify feature', 'waive feature', 'feature verification',
  'pending verifications', 'release blocked', 'feature guard', 'smoke test',
  'what needs verification', 'mark feature verified', 'skip verification'.
  Uses the eagle-mem CLI.
---

# Eagle Mem — Feature Verification

## Purpose

**For the user:** Every tracked feature has files, dependencies, and smoke tests. When you edit a tracked file, Eagle Mem automatically flags the feature as needing re-verification. Release-boundary commands stay blocked until all pending verifications are resolved. This prevents shipping regressions.

**For you:** The pending verification list tells you what's at risk after your edits. Resolve each one: run smoke tests and `verify`, or explain why it's safe and `waive`. Don't leave pending items unresolved — they block the user's workflow.

## Core Concepts

### Verify vs Waive

These are semantically different operations:

**Verify** = "I tested this exact change and it works." Fingerprint-specific — tied to the current diff hash. If the file changes again, a new pending verification appears.

**Waive** = "I accept changes to this feature+file pair." Fingerprint-agnostic — covers the current change AND all future changes to that file for that feature. Use when the change is known-safe (e.g., comment-only edit, unrelated code path).

**Decision rule:** Did you run the smoke test or manually confirm behavior? Use `verify`. Is the change structurally irrelevant to the feature? Use `waive`.

### Pending Verifications

When you Edit/Write a file tracked by a feature, PostToolUse automatically creates a pending verification record. Each record is keyed by (project, feature, file, fingerprint). The `pending` list shows what needs attention before release.

### Release Boundary

Release-boundary commands (publish, deploy) check for unresolved pending verifications. If any exist, the command is blocked with a list of what's pending. This is the enforcement mechanism — it only gates release, not development.

## Steps

### 1. Check what's pending

```bash
eagle-mem feature pending              # current project
eagle-mem feature pending --raw        # include trigger, fingerprint, timestamp
eagle-mem feature pending --limit 100  # show more than default 50
```

Each entry shows: feature name, file path, reason, and smoke test command (if registered).

### 2. Resolve by verifying

After running smoke tests or confirming the feature works:

```bash
eagle-mem feature verify <feature-name> --notes "smoke tests pass, tested login flow"
```

This marks ALL pending verifications for that feature as verified (for the current fingerprints) and updates the feature's `last_verified_at` timestamp.

### 3. Resolve by waiving

When a change is known-safe without testing — waive by feature name:

```bash
eagle-mem feature waive <feature-name> --reason "comment-only change, no behavior impact"
```

Or waive a single pending record by ID:

```bash
eagle-mem feature waive <id> --reason "unrelated code path"
```

**Prefer waive-by-name** over waive-by-ID. IDs are ephemeral (new edits create new IDs), but names are stable. Waiving by name resolves all pending records for that feature at once.

A reason is always required — it's the audit trail for why verification was skipped.

### 4. Register a new feature

```bash
eagle-mem feature add auth-flow \
  --desc "User authentication and session management" \
  --file src/auth/login.ts \
  --file src/auth/session.ts \
  --smoke "npm test -- --grep auth" \
  --requires env_var:AUTH_SECRET
```

### 5. List and inspect features

```bash
eagle-mem feature list                 # all active features
eagle-mem feature show <name>          # files, deps, smoke tests, last verified
```

## Judgment

**Always verify when:**
- You edited core logic in a tracked file
- The smoke test exists and is quick to run
- Multiple features depend on the changed file

**Waive when:**
- The edit is cosmetic (formatting, comments, imports)
- The changed code path is unrelated to the feature's functionality
- The feature's smoke test would test something you already tested another way

**Don't ignore pending verifications.** If you see them in the recall block, address them before your session ends. The user will be blocked on release otherwise.

## Reference

| Command | What it does |
|---|---|
| `feature list` | All active features with file/dep/test counts |
| `feature show <name>` | Full detail: files, dependencies, smoke tests |
| `feature pending` | All unresolved pending verifications |
| `feature verify <name>` | Mark feature verified (fingerprint-specific) |
| `feature waive <name\|id>` | Waive verification (fingerprint-agnostic for name) |
| `feature add <name>` | Register a new feature with files/deps/tests |
| `--notes "text"` | Attach notes to verify/waive (audit trail) |
| `--reason "text"` | Required for waive — explains why safe |
| `--raw` | Show trigger, fingerprint, and timestamp in pending |
