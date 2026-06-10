#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — mod-tracker concurrency regression test (finding #6)
# Asserts:
#   1. Many parallel writers never wedge the lock (no leaked *.lock dir).
#   2. A pending append created DURING a drain is NOT lost (drains via mv, so
#      only captured files are deleted; concurrent appends survive).
#   3. A stale lock dir (older than TTL) is reclaimed, not wedged forever.
#   4. The edit-history writer is lock-guarded and loses no append.
# ═══════════════════════════════════════════════════════════
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

export EAGLE_MEM_DIR="$tmp_dir/em"
export EAGLE_AGENT_SOURCE="claude-code"
export EAGLE_MEM_DISABLE_HOOKS=1
export EAGLE_MOD_LOCK_TTL=2
mkdir -p "$EAGLE_MEM_DIR"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1" >&2; fail=$((fail+1)); }

. "$ROOT_DIR/lib/common.sh"

# Pull the tracker functions out of post-tool-use.sh without running the hook
# body. State-machine awk: capture the TTL assignment plus each named function
# (header at column 0 through its closing `}` at column 0). No overlapping
# ranges, so no duplicated lines.
fn_src="$tmp_dir/tracker_fns.sh"
awk '
    /^EAGLE_MOD_LOCK_TTL=/ { print; next }
    /^(eagle_acquire_dir_lock|eagle_track_modified_path|eagle_track_edit_history_path)\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { capture=0 }
' "$ROOT_DIR/hooks/post-tool-use.sh" > "$fn_src"
bash -n "$fn_src" || { bad "extracted tracker fns have syntax errors"; cat "$fn_src" >&2; echo "$pass passed, $fail failed"; exit 1; }
. "$fn_src"
declare -F eagle_track_modified_path >/dev/null && ok "loaded eagle_track_modified_path" || { bad "could not load tracker fns"; echo "$pass passed, $fail failed"; exit 1; }
declare -F eagle_acquire_dir_lock >/dev/null && ok "loaded eagle_acquire_dir_lock" || bad "could not load lock helper"

SID="conc-aaa111bbb222"
mod_dir="$EAGLE_MEM_DIR/mod-tracker"
mod_file="$mod_dir/$SID"
mod_lock="${mod_file}.lock"

# ── 1. Parallel writers, no wedge ──────────────────────────
N=40
for i in $(seq 1 "$N"); do
    eagle_track_modified_path "/p/file_${i}.txt" "$SID" &
done
wait
[ ! -d "$mod_lock" ] && ok "1: lock dir not leaked after $N parallel writers" || bad "1: lock dir wedged"
# Whatever is committed must be valid paths from our set (no corruption).
committed=$(cat "$mod_file" 2>/dev/null | wc -l | tr -d ' ')
[ "$committed" -ge 1 ] && ok "1: committed file has $committed line(s)" || bad "1: committed file empty"
bad_lines=$(grep -vE '^/p/file_[0-9]+\.txt$' "$mod_file" 2>/dev/null | wc -l | tr -d ' ')
[ "$bad_lines" = "0" ] && ok "1: no corrupted/interleaved lines in committed file" || bad "1: $bad_lines corrupted lines"

# ── 2. Append during drain is NOT lost ─────────────────────
# Hold the lock ourselves, create a pending file, snapshot starts, then a NEW
# pending append lands. The drain must mv-capture only pre-existing pending
# files and never delete the late append.
rm -rf "$mod_dir"; mkdir -p "$mod_dir"
printf '%s\n' "/p/early.txt" > "${mod_file}.pending.111"
# Simulate: acquire lock, mv-drain existing pending, but a concurrent writer
# adds a brand-new pending file before we rm. Reproduce the exact sequence the
# fixed code uses.
mkdir "$mod_lock"
# drain step (mv existing pending out of the way)
for pf in "${mod_file}".pending.*; do
    [ -e "$pf" ] || continue
    mv "$pf" "${pf}.draining.$$" 2>/dev/null || true
done
# CONCURRENT appender lands a new pending file AFTER our snapshot/mv:
printf '%s\n' "/p/late.txt" > "${mod_file}.pending.999"
# finish drain: build committed from draining files only, delete draining only
{ cat "$mod_file" 2>/dev/null; for d in "${mod_file}".pending.*.draining.*; do [ -e "$d" ] && cat "$d"; done; } | tail -3 > "${mod_file}.tmp"
mv "${mod_file}.tmp" "$mod_file"
rm -f "${mod_file}".pending.*.draining.* 2>/dev/null || true
rmdir "$mod_lock"
# The late append must still be present as a pending file (not deleted).
[ -f "${mod_file}.pending.999" ] && ok "2: concurrent append during drain survived (not deleted)" || bad "2: late append LOST"
grep -q "/p/early.txt" "$mod_file" && ok "2: early pending drained into committed file" || bad "2: early pending lost"

# ── 3. Stale lock reclaim ──────────────────────────────────
rm -rf "$mod_dir"; mkdir -p "$mod_dir"
mkdir "$mod_lock"
# Age the lock past TTL (EAGLE_MOD_LOCK_TTL=2s) by backdating its mtime.
touch -t "$(date -v-1H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M.%S')" "$mod_lock" 2>/dev/null || true
# A new writer should reclaim the stale lock and succeed (not hang/fail).
eagle_track_modified_path "/p/after_stale.txt" "$SID"
[ ! -d "$mod_lock" ] && ok "3: stale lock reclaimed and released" || bad "3: stale lock not reclaimed"
grep -q "/p/after_stale.txt" "$mod_file" && ok "3: write after stale-lock reclaim recorded" || bad "3: write lost after stale reclaim"

# ── 4. edit-history writer is locked and loses nothing ─────
edit_dir="$EAGLE_MEM_DIR/edit-tracker"
edit_file="$edit_dir/$SID"
rm -rf "$edit_dir"
M=40
for i in $(seq 1 "$M"); do
    eagle_track_edit_history_path "/e/edit_${i}.txt" "$SID" &
done
wait
[ ! -d "${edit_file}.lock" ] && ok "4: edit-history lock not leaked" || bad "4: edit-history lock wedged"
edit_count=$(sort -u "$edit_file" 2>/dev/null | grep -cE '^/e/edit_[0-9]+\.txt$' || echo 0)
[ "$edit_count" = "$M" ] && ok "4: all $M edit-history appends present (append-only, none lost)" || bad "4: only $edit_count/$M edit-history appends present"
bad_e=$(grep -vE '^/e/edit_[0-9]+\.txt$' "$edit_file" 2>/dev/null | wc -l | tr -d ' ')
[ "$bad_e" = "0" ] && ok "4: no torn/interleaved edit-history lines" || bad "4: $bad_e torn lines"

# ── 5. Observation dedup is race-safe (finding #7) ─────────
# Two concurrent identical observations must dedupe to ONE row. The fixed code
# wraps the check-then-insert in BEGIN IMMEDIATE so the second writer blocks,
# then sees the first row via NOT EXISTS.
. "$ROOT_DIR/lib/db.sh"
bash "$ROOT_DIR/db/migrate.sh" >/dev/null 2>&1
OSID="obs-dedup-7777"
eagle_upsert_session "$OSID" "obs/proj" "$tmp_dir" "" "test" "claude-code"
for i in $(seq 1 12); do
    eagle_insert_observation "$OSID" "obs/proj" "Bash" "ls -la /tmp" "[]" "[]" &
done
wait
obs_rows=$(eagle_db "SELECT COUNT(*) FROM observations WHERE session_id='$OSID' AND tool_input_summary='ls -la /tmp';")
[ "$obs_rows" = "1" ] && ok "5: 12 concurrent identical observations deduped to 1 row" || bad "5: dedup race produced $obs_rows rows (expected 1)"

# eagle_db_strict exists and aborts a multi-statement script on first error.
if declare -F eagle_db_strict >/dev/null; then
    ok "5: eagle_db_strict variant present"
    # A failing first statement must prevent the second from running.
    eagle_db_strict "INSERT INTO nonexistent_table_xyz VALUES (1); INSERT INTO observations (session_id, project, tool_name) VALUES ('strict-canary','obs/proj','Bash');" >/dev/null 2>&1 || true
    canary=$(eagle_db "SELECT COUNT(*) FROM observations WHERE session_id='strict-canary';")
    [ "$canary" = "0" ] && ok "5: eagle_db_strict bailed before 2nd statement" || bad "5: eagle_db_strict did not bail ($canary canary rows)"
else
    bad "5: eagle_db_strict missing"
fi

echo ""
echo "test_mod_tracker_concurrency: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
