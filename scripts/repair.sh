#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Database Repair
# Safe recovery workflow for malformed SQLite memory databases.
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"
PACKAGE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"

json_output=false
dry_run=true
assume_yes=false
backup_dir=""

show_help() {
    echo -e "  ${BOLD}eagle-mem repair${RESET} — Diagnose and recover a malformed memory database"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem repair                 ${DIM}# preview repair plan${RESET}"
    echo -e "    eagle-mem repair ${CYAN}--dry-run${RESET}       ${DIM}# preview repair plan${RESET}"
    echo -e "    eagle-mem repair ${CYAN}--yes${RESET}           ${DIM}# backup, recover, verify, replace${RESET}"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    ${CYAN}--backup-dir${RESET} <path>  Backup directory (default: ~/.eagle-mem/backups)"
    echo -e "    ${CYAN}-j, --json${RESET}           Output structured JSON"
    echo ""
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=true; shift ;;
        --yes|-y) assume_yes=true; dry_run=false; shift ;;
        --backup-dir) backup_dir="$2"; shift 2 ;;
        --json|-j) json_output=true; shift ;;
        --help|-h) show_help ;;
        *)
            eagle_err "Unknown option: $1"
            exit 1
            ;;
    esac
done

[ -n "$backup_dir" ] || backup_dir="$EAGLE_MEM_DIR/backups"

repair_json() {
    local status="$1" message="$2" db_status="$3" db_detail="$4" backup_path="${5:-}" recovered_path="${6:-}"
    jq -nc \
        --arg status "$status" \
        --arg command "repair" \
        --arg message "$message" \
        --arg db "$EAGLE_MEM_DB" \
        --arg backup_dir "$backup_dir" \
        --arg backup_path "$backup_path" \
        --arg recovered_path "$recovered_path" \
        --arg db_status "$db_status" \
        --arg db_detail "$db_detail" \
        '{status:$status, command:$command, message:$message, db:$db,
          backup_dir:$backup_dir, backup_path:$backup_path, recovered_path:$recovered_path,
          database:{integrity:{status:$db_status, detail:$db_detail}}}'
}

repair_emit() {
    local status="$1" message="$2" db_status="$3" db_detail="$4" backup_path="${5:-}" recovered_path="${6:-}"
    if [ "$json_output" = true ]; then
        repair_json "$status" "$message" "$db_status" "$db_detail" "$backup_path" "$recovered_path"
    else
        case "$status" in
            ok) eagle_ok "$message" ;;
            repaired) eagle_ok "$message" ;;
            needs_repair) eagle_warn "$message" ;;
            *) eagle_fail "$message" ;;
        esac
        eagle_kv "Database:" "$EAGLE_MEM_DB"
        eagle_kv "Integrity:" "$db_status"
        [ -n "$db_detail" ] && eagle_dim "  $db_detail"
        [ -n "$backup_path" ] && eagle_kv "Backup:" "$backup_path"
        [ -n "$recovered_path" ] && eagle_kv "Recovered:" "$recovered_path"
    fi
}

sqlite_bin=$(eagle_sqlite_path)
if [ -z "$sqlite_bin" ]; then
    repair_emit "error" "SQLite with FTS5 is unavailable." "unavailable" "sqlite3 with FTS5 not found"
    exit 1
fi

if [ ! -f "$EAGLE_MEM_DB" ]; then
    repair_emit "error" "Memory database file is missing." "missing" "database file not found"
    exit 1
fi

integrity_check=$(eagle_db_integrity_status "$EAGLE_MEM_DB" 2>/dev/null || true)
integrity_status="${integrity_check%%|*}"
integrity_detail="${integrity_check#*|}"
[ -n "$integrity_status" ] || integrity_status="unknown"
[ -n "$integrity_detail" ] || integrity_detail="not checked"

if [ "$integrity_status" = "ok" ]; then
    repair_emit "ok" "Database integrity is already ok; no repair needed." "$integrity_status" "$integrity_detail"
    exit 0
fi

if [ "$dry_run" = true ] || [ "$assume_yes" != true ]; then
    repair_emit "needs_repair" "Database needs repair. Re-run with --yes to backup, recover, verify, and replace." "$integrity_status" "$integrity_detail"
    exit 0
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$backup_dir"
backup_path="$backup_dir/memory-$timestamp.db"
recover_dir=$(mktemp -d "$EAGLE_MEM_DIR/.repair.XXXXXX")
recover_sql="$recover_dir/recover.sql"
recovered_path="$recover_dir/memory.db"
cleanup_repair() {
    rm -rf "$recover_dir" 2>/dev/null || true
}
trap cleanup_repair EXIT

cp "$EAGLE_MEM_DB" "$backup_path"
chmod 600 "$backup_path" 2>/dev/null || true
for suffix in -wal -shm; do
    if [ -f "$EAGLE_MEM_DB$suffix" ]; then
        cp "$EAGLE_MEM_DB$suffix" "$backup_path$suffix"
        chmod 600 "$backup_path$suffix" 2>/dev/null || true
    fi
done

set +e
recover_output=$("$sqlite_bin" "$EAGLE_MEM_DB" ".recover" 2>&1 > "$recover_sql")
recover_rc=$?
set -e
if [ "$recover_rc" -ne 0 ] || [ ! -s "$recover_sql" ]; then
    repair_emit "error" "SQLite recovery failed; original database was left untouched." "$integrity_status" "${recover_output:-recover output was empty}" "$backup_path"
    exit 1
fi

if ! "$sqlite_bin" "$recovered_path" < "$recover_sql" >/dev/null 2>"$recover_dir/import.err"; then
    import_error=$(tr '\n' ' ' < "$recover_dir/import.err" | sed 's/[[:space:]][[:space:]]*/ /g')
    repair_emit "error" "Recovered SQL could not be imported; original database was left untouched." "$integrity_status" "$import_error" "$backup_path"
    exit 1
fi

core_tables=$("$sqlite_bin" "$recovered_path" "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('sessions','observations','summaries','agent_memories','agent_tasks');" 2>/dev/null || printf '0')
if [ "${core_tables:-0}" -eq 0 ] 2>/dev/null; then
    repair_emit "error" "Recovered SQL did not contain Eagle Mem core tables; original database was left untouched." "$integrity_status" "no recoverable Eagle Mem tables found" "$backup_path"
    exit 1
fi

candidate_home="$recover_dir/home"
mkdir -p "$candidate_home"
mv "$recovered_path" "$candidate_home/memory.db"
if ! EAGLE_MEM_DIR="$candidate_home" "$PACKAGE_DIR/db/migrate.sh" >/dev/null 2>"$recover_dir/migrate.err"; then
    migrate_error=$(tr '\n' ' ' < "$recover_dir/migrate.err" | sed 's/[[:space:]][[:space:]]*/ /g')
    repair_emit "error" "Recovered database migrations failed; original database was left untouched." "$integrity_status" "$migrate_error" "$backup_path"
    exit 1
fi
recovered_path="$candidate_home/memory.db"

post_check=$(eagle_db_integrity_status "$recovered_path" 2>/dev/null || true)
post_status="${post_check%%|*}"
post_detail="${post_check#*|}"
if [ "$post_status" != "ok" ]; then
    repair_emit "error" "Recovered database failed integrity check; original database was left untouched." "$post_status" "$post_detail" "$backup_path" "$recovered_path"
    exit 1
fi

cp "$recovered_path" "$EAGLE_MEM_DB"
chmod 600 "$EAGLE_MEM_DB" 2>/dev/null || true
rm -f "$EAGLE_MEM_DB-wal" "$EAGLE_MEM_DB-shm" 2>/dev/null || true

final_check=$(eagle_db_integrity_status "$EAGLE_MEM_DB" 2>/dev/null || true)
final_status="${final_check%%|*}"
final_detail="${final_check#*|}"
if [ "$final_status" != "ok" ]; then
    cp "$backup_path" "$EAGLE_MEM_DB"
    chmod 600 "$EAGLE_MEM_DB" 2>/dev/null || true
    repair_emit "error" "Replacement failed integrity check; backup was restored." "$final_status" "$final_detail" "$backup_path"
    exit 1
fi

repair_emit "repaired" "Database repaired successfully." "$final_status" "$final_detail" "$backup_path" "$EAGLE_MEM_DB"
