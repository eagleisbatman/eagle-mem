#!/usr/bin/env bash
# Release-gate parity at the git layer (`eagle-mem gate`). The PreToolUse hook
# blocks release-boundary commands for Claude/Codex; this proves the SAME
# feature-verification gate is enforceable for bare-shell / Grok pushes via an
# opt-in pre-push hook, blocks when verifications are pending, fails OPEN where
# blocking would be wrong, and never clobbers a foreign pre-push hook.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT_DIR/bin/eagle-mem"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/eagle-gate-prepush.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR"

. "$ROOT_DIR/lib/common.sh"
"$ROOT_DIR/db/migrate.sh" >/dev/null
. "$ROOT_DIR/lib/db.sh"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# ── git repo fixture with a committed, feature-mapped file ──────────────────
project="gate-prepush-test"
export EAGLE_MEM_PROJECT="$project"
repo="$HOME/proj"; mkdir -p "$repo/src"
(
  cd "$repo"
  git init -q
  git config user.email t@example.com
  git config user.name tester
  printf 'console.log("v1");\n' > src/app.js
  git add -A && git commit -qm init
)

eagle_upsert_feature "$project" "app-entry" "app entrypoint"
fid=$(eagle_get_feature_id "$project" "app-entry")
eagle_add_feature_file "$fid" "src/app.js" "entrypoint" >/dev/null

# ── 1. clean working tree → gate passes ────────────────────────────────────
if ( cd "$repo" && "$BIN" gate check ) >/dev/null 2>&1; then
    ok "clean working tree passes the gate (exit 0)"
else
    bad "clean working tree should pass the gate"
fi

# ── 2. uncommitted change to a feature file → gate blocks ──────────────────
printf 'console.log("v2");\n' > "$repo/src/app.js"
out=$( cd "$repo" && "$BIN" gate check 2>&1 ) && rc=0 || rc=$?
[ "$rc" -eq 1 ] && ok "pending verification blocks the push (exit 1)" || bad "expected block exit 1, got $rc"
case "$out" in *"blocked this push"*) ok "block message is shown" ;; *) bad "block message missing: $out" ;; esac

# ── 3. EAGLE_MEM_DISABLE_HOOKS bypasses even with a pending verification ────
if ( cd "$repo" && EAGLE_MEM_DISABLE_HOOKS=1 "$BIN" gate check ) >/dev/null 2>&1; then
    ok "EAGLE_MEM_DISABLE_HOOKS=1 bypasses the gate"
else
    bad "EAGLE_MEM_DISABLE_HOOKS=1 should bypass the gate"
fi

# ── 4. verifying the feature unblocks the gate ─────────────────────────────
( cd "$repo" && "$BIN" feature verify "app-entry" --notes "tested" ) >/dev/null 2>&1 || true
if ( cd "$repo" && "$BIN" gate check ) >/dev/null 2>&1; then
    ok "verified feature unblocks the gate (exit 0)"
else
    bad "verified feature should unblock the gate"
fi

# ── 5. fail-open outside a recognized project ──────────────────────────────
other=$(mktemp -d "$tmp_dir/other.XXXXXX")
if ( cd "$other" && env -u EAGLE_MEM_PROJECT "$BIN" gate check ) >/dev/null 2>&1; then
    ok "fails open outside a recognized project (exit 0)"
else
    bad "should fail open outside a recognized project"
fi

# ── 6. install writes a managed, executable pre-push hook ──────────────────
rm -f "$repo/.git/hooks/pre-push"
( cd "$repo" && "$BIN" gate install ) >/dev/null 2>&1 || true
if [ -x "$repo/.git/hooks/pre-push" ] && grep -q "eagle-mem-managed-pre-push" "$repo/.git/hooks/pre-push"; then
    ok "gate install writes a managed, executable pre-push hook"
else
    bad "gate install should write a managed pre-push hook"
fi

# ── 7. install refuses to clobber a FOREIGN pre-push hook ──────────────────
printf '#!/bin/sh\necho keepme\n' > "$repo/.git/hooks/pre-push"
if ( cd "$repo" && "$BIN" gate install ) >/dev/null 2>&1; then
    bad "gate install should refuse a foreign pre-push hook"
else
    ok "gate install refuses to clobber a foreign pre-push hook"
fi
grep -q "echo keepme" "$repo/.git/hooks/pre-push" && ok "foreign pre-push hook preserved" || bad "foreign pre-push hook was clobbered"

# ── 8. uninstall leaves a foreign hook alone ───────────────────────────────
( cd "$repo" && "$BIN" gate uninstall ) >/dev/null 2>&1 || true
grep -q "echo keepme" "$repo/.git/hooks/pre-push" && ok "uninstall leaves a foreign hook untouched" || bad "uninstall removed a foreign hook"

echo ""
echo "test_release_gate_prepush: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
