#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — SessionStart injection budget regression suite
# Proves the global recall-injection ceiling:
#   (a) normal-sized recall is emitted UNCHANGED (no trimming)
#   (b) a pathologically large recall is capped at the budget,
#       drops whole low-priority sections from the bottom, keeps the
#       highest-priority top sections, and LOGS a trim (observable)
# ═══════════════════════════════════════════════════════════
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (expected='$2' actual='$1')"
}

assert_contains() {
    case "$1" in *"$2"*) ;; *) fail "$3 (missing: $2)" ;; esac
}

assert_not_contains() {
    case "$1" in *"$2"*) fail "$3 (unexpectedly present: $2)" ;; esac
}

. "$ROOT_DIR/lib/common.sh"

trim_count_file="$tmp_dir/.trim-count"
export EAGLE_INJECT_TRIM_COUNT="$trim_count_file"

# ─── Budget helper: sane default + floor against self-defeating values ──
default_budget=$(eagle_sessionstart_inject_budget)
[ "$default_budget" -ge 4000 ] 2>/dev/null \
    || fail "default budget unexpectedly small ($default_budget)"

floored=$(EAGLE_MEM_DIR="$tmp_dir" bash -c "
    . '$ROOT_DIR/lib/common.sh'
    mkdir -p '$tmp_dir'
    printf '[context_budget]\nsessionstart_chars = 10\n' > '$tmp_dir/config.toml'
    eagle_sessionstart_inject_budget
")
[ "$floored" -ge 4000 ] 2>/dev/null \
    || fail "tiny configured budget was not floored ($floored)"

# ─── (a) Normal-sized recall — emitted UNCHANGED ──────────────────────
normal_body="=== Eagle Mem: Project Overview ===
A small project overview that fits comfortably.
=== Eagle Mem: Recent Recall ===
One recent session summary.
=== Eagle Mem: Stored Memories ===
  - [project][claude] Some memory: short description (today)
=== Eagle Mem: Core Files ===
  - main.sh
=== Eagle Mem: Working Set ===
  - app.ts (2 edits)"

normal_out=$(printf '%s' "$normal_body" | eagle_trim_inject_body 24000)
normal_dropped=$(cat "$trim_count_file")

assert_eq "$normal_out" "$normal_body" "normal recall was modified by the budget"
assert_eq "$normal_dropped" "0" "normal recall reported a non-zero trim"

# ─── (b) Pathological recall — capped, low-priority dropped, top kept ──
# Build a body whose top section is small but whose trailing sections are
# huge, so the ceiling must engage.
huge=$(head -c 9000 /dev/zero | tr '\0' 'x')
big_body="=== Eagle Mem: Project Overview ===
KEEP_OVERVIEW_MARKER top-priority overview must survive.
=== Eagle Mem: Recent Recall ===
$huge
=== Eagle Mem: Tasks ===
$huge
=== Eagle Mem: Core Files ===
$huge
=== Eagle Mem: Working Set ===
$huge"

budget=12000
big_out=$(printf '%s' "$big_body" | eagle_trim_inject_body "$budget")
big_dropped=$(cat "$trim_count_file")

[ "${#big_out}" -le "$budget" ] 2>/dev/null \
    || fail "trimmed body still exceeds budget (${#big_out} > $budget)"
[ "$big_dropped" -gt 0 ] 2>/dev/null \
    || fail "pathological recall did not report any trimmed sections"
assert_contains "$big_out" "KEEP_OVERVIEW_MARKER" \
    "top-priority Overview section was dropped"
assert_not_contains "$big_out" "=== Eagle Mem: Working Set ===" \
    "lowest-priority Working Set section survived past the budget"

# ─── Termination safety: a single oversized first section is kept whole ──
oversized=$(head -c 20000 /dev/zero | tr '\0' 'y')
solo_body="=== Eagle Mem: Project Overview ===
$oversized"
solo_out=$(printf '%s' "$solo_body" | eagle_trim_inject_body 5000)
solo_dropped=$(cat "$trim_count_file")
assert_contains "$solo_out" "=== Eagle Mem: Project Overview ===" \
    "oversized lone section was discarded instead of kept whole"
assert_eq "$solo_dropped" "0" "oversized lone section reported a phantom trim"

# A body with no section markers is returned verbatim (no infinite loop).
nomarker_out=$(printf '%s' "$oversized" | eagle_trim_inject_body 5000)
assert_eq "${#nomarker_out}" "${#oversized}" "marker-less body was altered"

# ─── Observable trim: the hook logs a WARN when it trims ──────────────
# The hook engages the ceiling and logs a WARN with the dropped-section count
# whenever it trims; assert that observable surface exists in the hook.
grep -q 'SessionStart: injection over budget' "$ROOT_DIR/hooks/session-start.sh" \
    || fail "session-start.sh missing observable over-budget WARN log"
grep -q 'trimmed .* low-priority section' "$ROOT_DIR/hooks/session-start.sh" \
    || fail "session-start.sh WARN log does not report trimmed section count"

echo "PASS: SessionStart injection budget (normal unchanged, pathological capped + logged)"
