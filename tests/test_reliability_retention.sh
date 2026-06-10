#!/usr/bin/env bash
# Phase 3 reliability hardening regressions:
#  A. Auto-scan/index in-flight vs freshness marker separation — a crashed or
#     output-less job must NOT block retry for a day (only a genuine success
#     sets the freshness marker; the foreground touch is a short-lived debounce).
#  B. eagle_events retention — the hook-observability table is pruned by age.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-reliability.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR"

. "$ROOT_DIR/lib/common.sh"
"$ROOT_DIR/db/migrate.sh" >/dev/null
. "$ROOT_DIR/lib/db.sh"
. "$ROOT_DIR/lib/hooks-sessionstart.sh"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
assert()     { if eval "$1"; then ok "$2"; else bad "$2"; fi; }
assert_not() { if eval "$1"; then bad "$2"; else ok "$2"; fi; }

project="test/reliability"

# ── A. In-flight vs freshness ───────────────────────────────────────────────
# Crashed/output-less job: only the in-flight marker exists, never the freshness one.
_eagle_state_touch "scan-inflight" "$project"
assert_not '_eagle_state_fresh "scan" "$project" 1' \
    "A1: in-flight-only does NOT satisfy the 1-day freshness gate (retry not blocked for a day)"
assert '_eagle_state_inflight_fresh "scan" "$project" 15' \
    "A2: a recent in-flight marker debounces concurrent spawns"

# Genuine success sets the freshness marker.
_eagle_state_touch "scan" "$project"
assert '_eagle_state_fresh "scan" "$project" 1' \
    "A3: a success-set freshness marker satisfies the freshness gate"

# A stale in-flight marker (job died long ago) must age out so retry reopens.
stale_inflight=$(_eagle_state_file "index-inflight" "$project")
mkdir -p "$(dirname "$stale_inflight")"
: > "$stale_inflight"
touch -t 202001010000 "$stale_inflight"
assert_not '_eagle_state_inflight_fresh "index" "$project" 15' \
    "A4: a stale in-flight marker is not 'fresh' — retry is allowed after the debounce window"

# ── B. eagle_events retention ───────────────────────────────────────────────
p1=$(eagle_sql_escape "$project")
p2=$(eagle_sql_escape "other/project")
eagle_db "INSERT INTO eagle_events (project, session_id, agent, event_type, status, created_at)
          VALUES ('$p1','s-old','codex','hook_started','ok', strftime('%Y-%m-%dT%H:%M:%fZ','now','-60 days'));" >/dev/null
eagle_db "INSERT INTO eagle_events (project, session_id, agent, event_type, status, created_at)
          VALUES ('$p1','s-new','codex','hook_started','ok', strftime('%Y-%m-%dT%H:%M:%fZ','now'));" >/dev/null
eagle_db "INSERT INTO eagle_events (project, session_id, agent, event_type, status, created_at)
          VALUES ('$p2','s-old2','codex','hook_started','ok', strftime('%Y-%m-%dT%H:%M:%fZ','now','-60 days'));" >/dev/null

eagle_prune_events 30 "$project"
old_p1=$(eagle_db "SELECT COUNT(*) FROM eagle_events WHERE project='$p1' AND session_id='s-old';")
new_p1=$(eagle_db "SELECT COUNT(*) FROM eagle_events WHERE project='$p1' AND session_id='s-new';")
old_p2=$(eagle_db "SELECT COUNT(*) FROM eagle_events WHERE project='$p2' AND session_id='s-old2';")
[ "$old_p1" = "0" ] && ok "B1: old event (60d) pruned for the target project" || bad "B1: old event not pruned (got $old_p1)"
[ "$new_p1" = "1" ] && ok "B2: recent event retained" || bad "B2: recent event lost (got $new_p1)"
[ "$old_p2" = "1" ] && ok "B3: project filter — other project's old event untouched" || bad "B3: project filter leaked (got $old_p2)"

eagle_prune_events 30
old_p2b=$(eagle_db "SELECT COUNT(*) FROM eagle_events WHERE project='$p2' AND session_id='s-old2';")
[ "$old_p2b" = "0" ] && ok "B4: unscoped prune removes other project's old event" || bad "B4: unscoped prune missed it (got $old_p2b)"

echo ""
echo "test_reliability_retention: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
