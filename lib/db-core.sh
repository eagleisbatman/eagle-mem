#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Database primitives
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_CORE_LOADED:-}" ] && return 0
_EAGLE_DB_CORE_LOADED=1

EAGLE_DB_SETUP=".headers off
.output /dev/null
PRAGMA busy_timeout=10000;
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;
PRAGMA trusted_schema=ON;
.output stdout"

# eagle_db — CONTRACT: continue-on-error (NO `.bail on`). When passed
# multi-statement SQL, sqlite3 runs every statement even if an earlier one
# errors. Many callers depend on this best-effort behavior (e.g. probing for a
# table then querying it, or fire-and-forget multi-table writes). The return
# code reflects sqlite3's exit status (non-zero if the LAST statement failed),
# and any stderr is mirrored to the log. If you need fail-fast atomicity across
# statements, use eagle_db_strict (or eagle_db_pipe, which also sets `.bail on`).
eagle_db() {
    local _eagle_sqlite_bin
    _eagle_sqlite_bin=$(eagle_sqlite_path)
    [ -n "$_eagle_sqlite_bin" ] || return 1
    local _eagle_db_err
    _eagle_db_err=$(mktemp 2>/dev/null || echo "/tmp/_eagle_db_err.$$")
    local _eagle_db_out
    _eagle_db_out=$({ echo "$EAGLE_DB_SETUP"; echo "$*"; } | "$_eagle_sqlite_bin" "$EAGLE_MEM_DB" 2>"$_eagle_db_err")
    local _eagle_db_rc=$?
    if [ -s "$_eagle_db_err" ]; then
        cat "$_eagle_db_err" >> "$EAGLE_MEM_LOG" 2>/dev/null
    fi
    rm -f "$_eagle_db_err" 2>/dev/null
    [ -n "$_eagle_db_out" ] && printf '%s\n' "$_eagle_db_out"
    return $_eagle_db_rc
}

# eagle_db_strict — same as eagle_db but with `.bail on`, so a multi-statement
# script aborts on the FIRST error instead of continuing. Use for fail-fast
# transactions (BEGIN/.../COMMIT) where a mid-script error must not commit a
# partially-applied result. Single-statement callers can use either function.
eagle_db_strict() {
    local _eagle_sqlite_bin
    _eagle_sqlite_bin=$(eagle_sqlite_path)
    [ -n "$_eagle_sqlite_bin" ] || return 1
    local _eagle_db_err
    _eagle_db_err=$(mktemp 2>/dev/null || echo "/tmp/_eagle_db_strict_err.$$")
    local _eagle_db_out
    _eagle_db_out=$({ echo "$EAGLE_DB_SETUP"; echo ".bail on"; echo "$*"; } | "$_eagle_sqlite_bin" "$EAGLE_MEM_DB" 2>"$_eagle_db_err")
    local _eagle_db_rc=$?
    if [ -s "$_eagle_db_err" ]; then
        cat "$_eagle_db_err" >> "$EAGLE_MEM_LOG" 2>/dev/null
    fi
    rm -f "$_eagle_db_err" 2>/dev/null
    [ -n "$_eagle_db_out" ] && printf '%s\n' "$_eagle_db_out"
    return $_eagle_db_rc
}

eagle_db_pipe() {
    local _eagle_sqlite_bin
    _eagle_sqlite_bin=$(eagle_sqlite_path)
    [ -n "$_eagle_sqlite_bin" ] || return 1
    local _eagle_db_err
    _eagle_db_err=$(mktemp 2>/dev/null || echo "/tmp/_eagle_db_pipe_err.$$")
    local _eagle_db_out
    _eagle_db_out=$({ echo "$EAGLE_DB_SETUP"; echo ".bail on"; cat; } | "$_eagle_sqlite_bin" "$EAGLE_MEM_DB" 2>"$_eagle_db_err")
    local _eagle_db_rc=$?
    if [ -s "$_eagle_db_err" ]; then
        cat "$_eagle_db_err" >> "$EAGLE_MEM_LOG" 2>/dev/null
    fi
    rm -f "$_eagle_db_err" 2>/dev/null
    [ -n "$_eagle_db_out" ] && printf '%s\n' "$_eagle_db_out"
    return $_eagle_db_rc
}

eagle_db_json() {
    local _eagle_sqlite_bin
    _eagle_sqlite_bin=$(eagle_sqlite_path)
    [ -n "$_eagle_sqlite_bin" ] || return 1
    local _eagle_db_err
    _eagle_db_err=$(mktemp 2>/dev/null || echo "/tmp/_eagle_db_json_err.$$")
    local _eagle_db_out
    _eagle_db_out=$({ echo "$EAGLE_DB_SETUP"; echo ".mode json"; echo "$*"; } | "$_eagle_sqlite_bin" "$EAGLE_MEM_DB" 2>"$_eagle_db_err")
    local _eagle_db_rc=$?
    if [ -s "$_eagle_db_err" ]; then
        cat "$_eagle_db_err" >> "$EAGLE_MEM_LOG" 2>/dev/null
    fi
    rm -f "$_eagle_db_err" 2>/dev/null
    [ -n "$_eagle_db_out" ] && printf '%s\n' "$_eagle_db_out"
    return $_eagle_db_rc
}

eagle_ensure_db() {
    eagle_require_sqlite_fts5 || return 1

    if [ ! -f "$EAGLE_MEM_DB" ]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../db" && pwd)"
        "$script_dir/migrate.sh"
    fi
}
