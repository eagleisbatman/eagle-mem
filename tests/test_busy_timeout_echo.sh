#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — busy_timeout echo regression test
#
# Root cause guarded here: an inline value-setting `PRAGMA busy_timeout=N;`
# run in the SAME sqlite3 invocation as a SELECT echoes its value ("10000")
# as the FIRST output row. Any caller that reads the first line then mis-reads
# the timeout value as data:
#   - eagle_get_session_project_light -> returns "10000" as the project,
#     mis-filing every session under a phantom "10000" project.
#   - eagle_project_has_table_row -> `[ "10000" = "1" ]` is false, so it
#     ALWAYS reports "no row", breaking ancestor-project repair.
#   - statusline stats -> `IFS='|' read` parses "10000" as sessions, 0 memories.
# The fix sets the timeout via the silent `-cmd ".timeout"` dot-command, which
# emits no output. This test reproduces the failure (buggy code returns 10000
# / always-false) and structurally guards against re-introducing the shape.
# ═══════════════════════════════════════════════════════════
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

export EAGLE_MEM_DIR="$tmp_dir/em"
export EAGLE_AGENT_SOURCE="claude-code"
export EAGLE_MEM_DISABLE_HOOKS=1
mkdir -p "$EAGLE_MEM_DIR"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1" >&2; fail=$((fail+1)); }

bash "$ROOT_DIR/db/migrate.sh" >/dev/null 2>&1

. "$ROOT_DIR/lib/common.sh"
. "$ROOT_DIR/lib/db.sh"

# ── eagle_get_session_project_light returns the real project ────────────────
SID="sess-busy-timeout-001"
PROJ="personal_projects/eagle-mem"
eagle_upsert_session "$SID" "$PROJ" "$tmp_dir" "" "test" "claude-code"

got=$(eagle_get_session_project_light "$SID")
if [ "$got" = "10000" ]; then
    bad "eagle_get_session_project_light returned the busy_timeout echo ('10000') as the project"
elif [ "$got" = "$PROJ" ]; then
    ok "eagle_get_session_project_light returns the real project ('$got')"
else
    bad "eagle_get_session_project_light returned unexpected value: '$got' (expected '$PROJ')"
fi

# Unknown session must resolve to nothing (rc=1), never the echo value.
if unknown=$(eagle_get_session_project_light "sess-does-not-exist-999"); then
    bad "eagle_get_session_project_light succeeded for unknown session, returned '$unknown'"
else
    ok "eagle_get_session_project_light fails closed for unknown session"
fi

# ── eagle_project_has_table_row: true for present, false for absent ──────────
if eagle_project_has_table_row "sessions" "$PROJ"; then
    ok "eagle_project_has_table_row finds the existing project row"
else
    bad "eagle_project_has_table_row reports 'no row' for a project that HAS a row (busy_timeout echo broke the '= 1' test)"
fi

if eagle_project_has_table_row "sessions" "no/such/project-xyz"; then
    bad "eagle_project_has_table_row reports a row for a project with none"
else
    ok "eagle_project_has_table_row correctly reports no row for an absent project"
fi

# ── Structural guard: no inline value-setting PRAGMA before a parsed SELECT ──
# (comment lines are stripped so the explanatory comments above don't match)
common_hit=$(grep -vE '^[[:space:]]*#' "$ROOT_DIR/lib/common.sh" | grep -nE 'busy_timeout=[0-9]+;[[:space:]]*SELECT' || true)
if [ -n "$common_hit" ]; then
    bad "lib/common.sh re-introduced an inline 'PRAGMA busy_timeout=N; SELECT' (echoes the value): $common_hit"
else
    ok "lib/common.sh has no inline value-setting PRAGMA before a SELECT"
fi

statusline_hit=$(grep -vE '^[[:space:]]*#' "$ROOT_DIR/scripts/statusline-em.sh" | grep -nE 'busy_timeout' || true)
if [ -n "$statusline_hit" ]; then
    bad "scripts/statusline-em.sh re-introduced an inline PRAGMA busy_timeout (use -cmd \".timeout\"): $statusline_hit"
else
    ok "scripts/statusline-em.sh sets the timeout via the silent -cmd \".timeout\" dot-command"
fi

echo
echo "busy_timeout echo regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
