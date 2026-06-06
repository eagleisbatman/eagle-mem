#!/usr/bin/env bash
# Trust surface regressions: corrupted DBs must be visible, not mistaken for
# empty memory state.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EAGLE_BIN="$ROOT_DIR/bin/eagle-mem"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-trust-surfaces.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    case "$haystack" in
        *"$needle"*) ;;
        *)
            echo "$message" >&2
            echo "Expected to find: $needle" >&2
            echo "Actual: $haystack" >&2
            exit 1
            ;;
    esac
}

assert_json() {
    local json="$1" filter="$2" message="$3"
    if ! printf '%s' "$json" | jq -e "$filter" >/dev/null; then
        echo "$message" >&2
        echo "$json" >&2
        exit 1
    fi
}

strip_ansi() {
    sed -E $'s/\x1b\\[[0-9;]*m//g'
}

repo="$tmp_dir/repo"
mkdir -p "$repo"

healthy_home="$tmp_dir/healthy"
mkdir -p "$healthy_home"
EAGLE_MEM_DIR="$healthy_home" "$ROOT_DIR/db/migrate.sh" >/dev/null

doctor_ok=$(EAGLE_MEM_DIR="$healthy_home" "$EAGLE_BIN" doctor --json)
assert_json "$doctor_ok" '.database.integrity.status == "ok"' "doctor should report healthy DB integrity"

compaction_ok=$(cd "$repo" && EAGLE_MEM_DIR="$healthy_home" "$EAGLE_BIN" compaction --json)
assert_json "$compaction_ok" '.status == "ok" and .database.integrity.status == "ok" and .readiness == "weak"' "compaction --json should emit structured healthy output"

stats_ok=$(cd "$repo" && EAGLE_MEM_DIR="$healthy_home" "$EAGLE_BIN" search --stats --json)
assert_json "$stats_ok" '.status == "ok" and .database.integrity.status == "ok" and (.sessions | type == "number")' "search --stats --json should emit structured healthy output"

statusline_ok=$(cd "$repo" && EAGLE_MEM_DIR="$healthy_home" "$EAGLE_BIN" statusline | strip_ansi)
assert_contains "$statusline_ok" "sessions" "healthy statusline should still show memory counts"

corrupt_home="$tmp_dir/corrupt"
mkdir -p "$corrupt_home"
printf 'not a sqlite database\n' > "$corrupt_home/memory.db"

doctor_bad=$(EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" doctor --json)
assert_json "$doctor_bad" '.overall == "Needs attention" and .database.integrity.status == "error"' "doctor should mark corrupted DB as needing attention"

set +e
health_bad=$(cd "$repo" && EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" health --json 2>/dev/null)
health_rc=$?
set -e
[ "$health_rc" -ne 0 ] || { echo "health --json should fail on corrupted DB" >&2; exit 1; }
assert_json "$health_bad" '.status == "error" and .error == "database_integrity" and .database.integrity.status == "error"' "health --json should emit a structured DB integrity error"

set +e
stats_bad=$(cd "$repo" && EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" search --stats --json 2>/dev/null)
stats_rc=$?
set -e
[ "$stats_rc" -ne 0 ] || { echo "search --stats --json should fail on corrupted DB" >&2; exit 1; }
assert_json "$stats_bad" '.status == "error" and .error == "database_integrity" and .database.integrity.status == "error"' "search --stats --json should emit a structured DB integrity error"

set +e
compaction_bad=$(cd "$repo" && EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" compaction --json 2>/dev/null)
compaction_rc=$?
set -e
[ "$compaction_rc" -ne 0 ] || { echo "compaction --json should fail on corrupted DB" >&2; exit 1; }
assert_json "$compaction_bad" '.status == "error" and .error == "database_integrity" and .database.integrity.status == "error"' "compaction --json should emit a structured DB integrity error"

set +e
tasks_bad=$(cd "$repo" && EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" tasks --json 2>/dev/null)
tasks_rc=$?
set -e
[ "$tasks_rc" -ne 0 ] || { echo "tasks --json should fail on corrupted DB" >&2; exit 1; }
assert_json "$tasks_bad" '.status == "error" and .error == "database_integrity" and .database.integrity.status == "error"' "tasks --json should emit a structured DB integrity error"

set +e
graph_bad=$(cd "$repo" && EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" graph 2>&1)
graph_rc=$?
set -e
[ "$graph_rc" -ne 0 ] || { echo "graph should fail on corrupted DB" >&2; exit 1; }
assert_contains "$graph_bad" "Database integrity check failed" "graph should explain corrupted DB instead of showing an empty graph"

set +e
inspect_bad=$(cd "$repo" && EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" inspect recall --json 2>/dev/null)
inspect_rc=$?
set -e
[ "$inspect_rc" -ne 0 ] || { echo "inspect recall --json should fail on corrupted DB" >&2; exit 1; }
assert_json "$inspect_bad" '.status == "error" and .error == "database_integrity" and .database.integrity.status == "error"' "inspect recall --json should emit a structured DB integrity error"

set +e
dashboard_bad=$(cd "$repo" && EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" dashboard --json 2>/dev/null)
dashboard_rc=$?
set -e
[ "$dashboard_rc" -ne 0 ] || { echo "dashboard --json should fail on corrupted DB" >&2; exit 1; }
assert_json "$dashboard_bad" '.status == "error" and .error == "database_integrity" and .database.integrity.status == "error"' "dashboard --json should emit a structured DB integrity error"

set +e
replay_bad=$(cd "$repo" && EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" replay --last --json 2>/dev/null)
replay_rc=$?
set -e
[ "$replay_rc" -ne 0 ] || { echo "replay --json should fail on corrupted DB" >&2; exit 1; }
assert_json "$replay_bad" '.status == "error" and .error == "database_integrity" and .database.integrity.status == "error"' "replay --json should emit a structured DB integrity error"

statusline_bad=$(cd "$repo" && EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" statusline | strip_ansi)
assert_contains "$statusline_bad" "DB error" "statusline should show DB error for corrupted memory state"

echo "trust surface regressions passed"
