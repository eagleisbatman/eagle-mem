#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Database migration runner
# Idempotent: safe to run multiple times
# ═══════════════════════════════════════════════════════════
set -euo pipefail

EAGLE_MEM_DIR="${EAGLE_MEM_DIR:-$HOME/.eagle-mem}"
DB="$EAGLE_MEM_DIR/memory.db"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

COMMON_SH="$SCRIPT_DIR/../lib/common.sh"
if [ -f "$COMMON_SH" ]; then
    . "$COMMON_SH"
    eagle_require_sqlite_fts5 || exit 1
    SQLITE_BIN=$(eagle_sqlite_path)
else
    SQLITE_BIN=$(command -v sqlite3 2>/dev/null || true)
    if [ -z "$SQLITE_BIN" ] || ! "$SQLITE_BIN" :memory: "CREATE VIRTUAL TABLE eagle_mem_fts5_probe USING fts5(value);" >/dev/null 2>&1; then
        echo "Eagle Mem requires SQLite FTS5, but the active sqlite3 does not support it." >&2
        [ -n "$SQLITE_BIN" ] && echo "Detected sqlite3: $SQLITE_BIN" >&2
        echo "Fix PATH so an FTS5-capable sqlite3 is first, then re-run the command." >&2
        exit 1
    fi
fi

# Restrict permissions: DB and config contain session data and may contain
# residual secrets despite redaction. Owner-only access (700 dir, 600 files).
umask 077
mkdir -p "$EAGLE_MEM_DIR"

run_migration() {
    local name="$1"
    local file="$2"

    # The guard query MUST set busy_timeout: without it a momentary SQLITE_BUSY
    # (a hook touching the DB mid-update) makes sqlite3 exit non-zero, the `|| echo 0`
    # fail-open then re-runs an already-applied migration and the body explodes with
    # "duplicate column" / UNIQUE-constraint errors. busy_timeout makes the guard wait
    # for the lock instead of guessing. tail -n1 drops the PRAGMA echo line.
    local already_applied
    already_applied=$("$SQLITE_BIN" "$DB" "PRAGMA busy_timeout=5000; SELECT COUNT(*) FROM _migrations WHERE name = '$name';" 2>/dev/null | tail -n1)
    [ -z "$already_applied" ] && already_applied="0"

    if [ "$already_applied" = "0" ]; then
        # Strip PRAGMAs from migration body (they can't run inside transactions
        # and are already set on every connection via lib/db.sh EAGLE_DB_SETUP).
        #
        # FUTURE-MIGRATION FOOTGUN: EVERY line matching `^\s*PRAGMA ` is removed
        # from the body before it runs inside the BEGIN/COMMIT below. A migration
        # that genuinely needs a persistent/connection PRAGMA (e.g. a one-shot
        # `PRAGMA user_version=N;` or a `PRAGMA foreign_key_check;` validation)
        # will have that line SILENTLY DROPPED — it will appear to succeed while
        # doing nothing. Do not rely on PRAGMA statements inside a migration file;
        # set connection PRAGMAs in EAGLE_DB_SETUP, and run any standalone schema
        # PRAGMA as a separate `"$SQLITE_BIN" "$DB" "PRAGMA ...;"` call outside
        # run_migration. This stripping behavior is intentional — do not remove it.
        local body
        body=$(grep -v -E '^[[:space:]]*PRAGMA ' "$file")

        # Set connection PRAGMAs, then run migration body + tracking insert atomically
        # .bail on ensures sqlite3 stops on the first error instead of continuing
        {
            echo ".bail on"
            echo ".output /dev/null"
            echo "PRAGMA trusted_schema=ON;"
            echo "PRAGMA foreign_keys=ON;"
            echo "PRAGMA busy_timeout=5000;"
            echo ".output stdout"
            echo "BEGIN;"
            echo "$body"
            echo "INSERT INTO _migrations (name) VALUES ('$name');"
            echo "COMMIT;"
        } | "$SQLITE_BIN" "$DB"
        echo "  applied: $name"
    fi
}

# Ensure _migrations table exists (bootstrap)
"$SQLITE_BIN" "$DB" "CREATE TABLE IF NOT EXISTS _migrations (
    id         INTEGER PRIMARY KEY,
    name       TEXT    NOT NULL UNIQUE,
    applied_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);"

# Set PRAGMAs (these must be set on every connection)
"$SQLITE_BIN" "$DB" "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON;" >/dev/null

# ─── Migration 001: Initial schema (special name) ──────────
run_migration "001_initial_schema" "$SCRIPT_DIR/schema.sql"

# ─── Run numbered migrations (002+) via sorted glob ───────
for migration_file in "$SCRIPT_DIR"/[0-9][0-9][0-9]_*.sql; do
    [ ! -f "$migration_file" ] && continue
    migration_name=$(basename "$migration_file" .sql)
    run_migration "$migration_name" "$migration_file"
done

echo "  Eagle Mem database ready: $DB"
