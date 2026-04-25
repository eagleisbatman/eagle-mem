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
        sqlite3 "$DB" < "$file"
        sqlite3 "$DB" "INSERT INTO _migrations (name) VALUES ('$name');"
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

# ─── Migration 001: Initial schema ─────────────────────────
run_migration "001_initial_schema" "$SCRIPT_DIR/schema.sql"

# ─── Migration 002: Project overviews ──────────────────────
run_migration "002_overviews" "$SCRIPT_DIR/002_overviews.sql"

# ─── Migration 003: Code chunks ───────────────────────────
run_migration "003_code_chunks" "$SCRIPT_DIR/003_code_chunks.sql"

echo "  Eagle Mem database ready: $DB"
