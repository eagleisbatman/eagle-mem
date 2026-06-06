#!/usr/bin/env bash
# Repair command regressions: DB errors need an actionable and safe recovery path.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EAGLE_BIN="$ROOT_DIR/bin/eagle-mem"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-repair.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

assert_json() {
    local json="$1" filter="$2" message="$3"
    if ! printf '%s' "$json" | jq -e "$filter" >/dev/null; then
        echo "$message" >&2
        echo "$json" >&2
        exit 1
    fi
}

healthy_home="$tmp_dir/healthy"
mkdir -p "$healthy_home"
EAGLE_MEM_DIR="$healthy_home" "$ROOT_DIR/db/migrate.sh" >/dev/null

healthy_json=$(EAGLE_MEM_DIR="$healthy_home" "$EAGLE_BIN" repair --json)
assert_json "$healthy_json" '.status == "ok" and .database.integrity.status == "ok"' "repair should no-op on a healthy DB"

corrupt_home="$tmp_dir/corrupt"
mkdir -p "$corrupt_home"
printf 'not a sqlite database\n' > "$corrupt_home/memory.db"
before_hash=$(shasum -a 256 "$corrupt_home/memory.db" | awk '{print $1}')

dry_json=$(EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" repair --dry-run --json)
assert_json "$dry_json" '.status == "needs_repair" and .database.integrity.status == "error"' "repair dry-run should produce an actionable repair plan"
after_dry_hash=$(shasum -a 256 "$corrupt_home/memory.db" | awk '{print $1}')
[ "$before_hash" = "$after_dry_hash" ] || {
    echo "repair --dry-run must not modify the DB" >&2
    exit 1
}

set +e
yes_json=$(EAGLE_MEM_DIR="$corrupt_home" "$EAGLE_BIN" repair --yes --json 2>/dev/null)
yes_rc=$?
set -e
[ "$yes_rc" -ne 0 ] || {
    echo "repair --yes should not replace unrecoverable garbage with an empty DB" >&2
    echo "$yes_json" >&2
    exit 1
}
assert_json "$yes_json" '.status == "error" and (.message | test("left untouched")) and .backup_path != ""' "repair --yes should back up and keep unrecoverable DB untouched"

after_yes_hash=$(shasum -a 256 "$corrupt_home/memory.db" | awk '{print $1}')
[ "$before_hash" = "$after_yes_hash" ] || {
    echo "unrecoverable repair should leave original DB bytes untouched" >&2
    exit 1
}

backup_count=$(find "$corrupt_home/backups" -type f -name 'memory-*.db' 2>/dev/null | wc -l | tr -d ' ')
[ "$backup_count" -ge 1 ] || {
    echo "repair --yes should create a backup before recovery attempts" >&2
    exit 1
}

echo "repair regressions passed"
