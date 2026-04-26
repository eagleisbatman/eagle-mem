#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Database migration runner
# Idempotent: safe to run multiple times
# ═══════════════════════════════════════════════════════════
set -euo pipefail

EAGLE_MEM_DIR="${EAGLE_MEM_DIR:-$HOME/.eagle-mem}"
DB="$EAGLE_MEM_DIR/memory.db"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$EAGLE_MEM_DIR"

run_migration() {
    local name="$1"
    local file="$2"

    local already_applied
    already_applied=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _migrations WHERE name = '$name';" 2>/dev/null || echo "0")

    if [ "$already_applied" = "0" ]; then
        # Strip PRAGMAs from migration body (they can't run inside transactions
        # and are already set on every connection via lib/db.sh EAGLE_DB_SETUP)
        local body
        body=$(grep -v -E '^[[:space:]]*PRAGMA ' "$file")

        # Set connection PRAGMAs, then run migration body + tracking insert atomically
        # .bail on ensures sqlite3 stops on the first error instead of continuing
        { echo ".bail on"; echo "PRAGMA trusted_schema=ON;"; echo "PRAGMA foreign_keys=ON;"; echo "PRAGMA busy_timeout=5000;"; echo "BEGIN;"; echo "$body"; echo "INSERT INTO _migrations (name) VALUES ('$name');"; echo "COMMIT;"; } | sqlite3 "$DB"
        echo "  applied: $name"
    fi
}

# Ensure _migrations table exists (bootstrap)
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS _migrations (
    id         INTEGER PRIMARY KEY,
    name       TEXT    NOT NULL UNIQUE,
    applied_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);"

# Set PRAGMAs (these must be set on every connection)
sqlite3 "$DB" "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON;"

# ─── Migration 001: Initial schema (special name) ──────────
run_migration "001_initial_schema" "$SCRIPT_DIR/schema.sql"

# ─── Run numbered migrations (002+) via sorted glob ───────
for migration_file in "$SCRIPT_DIR"/[0-9][0-9][0-9]_*.sql; do
    [ ! -f "$migration_file" ] && continue
    migration_name=$(basename "$migration_file" .sql)
    run_migration "$migration_name" "$migration_file"
done

echo "  Eagle Mem database ready: $DB"
