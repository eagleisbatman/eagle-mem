#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Regression: eagle_patch_claude_md must rewrite an outdated
# Eagle Mem capture section to the CLI-first doctrine.
#
# Guards against the v4.12.0 bug where the detection used
# `grep -qF 'request: \[what user asked\] | completed:'` — under
# grep -F the backslashes are literal, so it never matched the
# real `[what user asked]` text and the section was never updated,
# silently defeating the clean-capture feature on every install.
# ═══════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0
fail=0
ok()   { echo "  ok: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

run_case() {
    local label="$1" body="$2"
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/.claude"
    printf '%s\n' "$body" > "$tmp/.claude/CLAUDE.md"

    ( export HOME="$tmp"; . "$REPO_DIR/lib/common.sh" >/dev/null 2>&1; eagle_patch_claude_md >/dev/null 2>&1 )

    if grep -qF 'session save --session-id' "$tmp/.claude/CLAUDE.md"; then
        ok "$label: CLI-first doctrine present after patch"
    else
        bad "$label: section was NOT rewritten to CLI-first"
    fi
    if [ "$(grep -c '## Eagle Mem — Persistent Memory' "$tmp/.claude/CLAUDE.md")" = "1" ]; then
        ok "$label: exactly one Eagle Mem section (no duplication)"
    else
        bad "$label: section count != 1"
    fi
    rm -rf "$tmp"
}

# Case 1: old <eagle-summary>-emit section with surrounding user content.
run_case "old-eagle-summary" '# Custom global instructions

Pre-section user content.

---

## Eagle Mem — Persistent Memory

**Rule:** Before your final response, emit an `<eagle-summary>` block.

```
<eagle-summary>
request: [what user asked] | completed: [what shipped]
</eagle-summary>
```

---

## Behavioral Rules

Post-section user content that must survive.'

# Verify surrounding content survives the rewrite (separate explicit check).
TMP=$(mktemp -d); mkdir -p "$TMP/.claude"
printf '%s\n' '# Custom

KEEP_BEFORE_MARKER

---

## Eagle Mem — Persistent Memory

**Rule:** emit an `<eagle-summary>` block.

---

## Behavioral Rules

KEEP_AFTER_MARKER' > "$TMP/.claude/CLAUDE.md"
( export HOME="$TMP"; . "$REPO_DIR/lib/common.sh" >/dev/null 2>&1; eagle_patch_claude_md >/dev/null 2>&1 )
grep -q 'KEEP_BEFORE_MARKER' "$TMP/.claude/CLAUDE.md" && ok "preserve: content before section kept" || bad "preserve: clobbered content before section"
grep -q 'KEEP_AFTER_MARKER'  "$TMP/.claude/CLAUDE.md" && ok "preserve: content after section kept"  || bad "preserve: clobbered content after section"
grep -q 'emit an `<eagle-summary>` block' "$TMP/.claude/CLAUDE.md" && bad "preserve: stale emit instruction still present" || ok "preserve: stale emit instruction removed"

# Idempotency: rewriting again must not add a second section.
before=$(cksum "$TMP/.claude/CLAUDE.md" | awk '{print $1}')
( export HOME="$TMP"; . "$REPO_DIR/lib/common.sh" >/dev/null 2>&1; eagle_patch_claude_md >/dev/null 2>&1 )
[ "$(grep -c '## Eagle Mem — Persistent Memory' "$TMP/.claude/CLAUDE.md")" = "1" ] && ok "idempotent: still one section after 2nd run" || bad "idempotent: section duplicated on 2nd run"
rm -rf "$TMP"

echo ""
echo "test_claude_md_capture_doctrine: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
