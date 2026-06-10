#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Regression: scripts/test.sh must NOT abort mid-run when a
# single check fails.
#
# Guards against the `set -e` masking bug where the failure
# accumulator used `((errors++))`. Under `set -euo pipefail`,
# `((errors++))` returns exit status 1 when the pre-increment
# value is 0 (post-increment evaluates the old, falsy value),
# so the FIRST failing check aborted the entire runner —
# skipping every later check and the failure-count summary.
# The fix uses the assignment form `errors=$((errors + 1))`,
# which always returns 0.
# ═══════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_SH="$REPO_DIR/scripts/test.sh"

pass=0
fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# 1. The buggy idiom must be gone from the runner's executable code.
#    Match only non-comment lines so the explanatory comment that names
#    the old idiom does not trip the check.
if grep -vE '^\s*#' "$TEST_SH" | grep -qE '\(\(errors\+\+\)\)'; then
    bad "scripts/test.sh still uses ((errors++)) in code (aborts under set -e)"
else
    ok "scripts/test.sh no longer uses ((errors++)) in code"
fi
if grep -qF 'errors=$((errors + 1))' "$TEST_SH"; then
    ok "scripts/test.sh uses the safe assignment form"
else
    bad "scripts/test.sh missing safe assignment accumulator"
fi

# 2. Behavioral proof: replicate the runner's exact accumulation loop
#    under `set -euo pipefail`, force the FIRST check to fail, and
#    confirm execution reaches the end with a correct count.
result=$(
    set -euo pipefail
    errors=0
    run_check() {
        if eval "$2" >/dev/null 2>&1; then
            :
        else
            errors=$((errors + 1))
        fi
    }
    run_check "first-fails" "false"   # errors goes 0 -> 1
    run_check "second-ok"   "true"
    run_check "third-fails"  "false"  # errors goes 1 -> 2
    echo "REACHED_END errors=$errors"
)
status=$?

if [ "$status" -eq 0 ] && printf '%s' "$result" | grep -qF 'REACHED_END errors=2'; then
    ok "runner reaches summary after failures with correct count (errors=2)"
else
    bad "runner aborted early or miscounted (status=$status, out='$result')"
fi

# 3. Sanity: the old idiom genuinely aborts (proves the test is meaningful).
#    Run as a separate `bash` process so `set -e` is fully active (a `|| ...`
#    on a subshell would disable `set -e` inside it and hide the abort).
control_tmp=$(mktemp)
cat > "$control_tmp" <<'CTRL'
set -euo pipefail
errors=0
((errors++))          # pre-value 0 -> command returns 1 -> set -e aborts here
echo "SHOULD_NOT_PRINT"
CTRL
control_out=$(bash "$control_tmp" 2>/dev/null); control_status=$?
rm -f "$control_tmp"
if [ "$control_status" -ne 0 ] && ! printf '%s' "$control_out" | grep -qF 'SHOULD_NOT_PRINT'; then
    ok "control: ((errors++)) from 0 aborts under set -e (bug is real)"
else
    bad "control: ((errors++)) did not abort (status=$control_status) — test premise invalid"
fi

echo ""
echo "test_test_runner_no_abort: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
