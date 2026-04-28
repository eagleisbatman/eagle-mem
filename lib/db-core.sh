#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Database primitives
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_CORE_LOADED:-}" ] && return 0
_EAGLE_DB_CORE_LOADED=1

EAGLE_DB_SETUP=".headers off
.output /dev/null
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;
PRAGMA trusted_schema=ON;
.output stdout"

eagle_db() {
    local _eagle_db_err
    _eagle_db_err=$(mktemp 2>/dev/null || echo "/tmp/_eagle_db_err.$$")
    local _eagle_db_out
    _eagle_db_out=$({ echo "$EAGLE_DB_SETUP"; echo "$*"; } | sqlite3 "$EAGLE_MEM_DB" 2>"$_eagle_db_err")
    local _eagle_db_rc=$?
    if [ -s "$_eagle_db_err" ]; then
        cat "$_eagle_db_err" >> "$EAGLE_MEM_LOG" 2>/dev/null
    fi
    rm -f "$_eagle_db_err" 2>/dev/null
    [ -n "$_eagle_db_out" ] && printf '%s\n' "$_eagle_db_out"
    return $_eagle_db_rc
}

eagle_db_pipe() {
    local _eagle_db_err
    _eagle_db_err=$(mktemp 2>/dev/null || echo "/tmp/_eagle_db_pipe_err.$$")
    local _eagle_db_out
    _eagle_db_out=$({ echo "$EAGLE_DB_SETUP"; echo ".bail on"; cat; } | sqlite3 "$EAGLE_MEM_DB" 2>"$_eagle_db_err")
    local _eagle_db_rc=$?
    if [ -s "$_eagle_db_err" ]; then
        cat "$_eagle_db_err" >> "$EAGLE_MEM_LOG" 2>/dev/null
    fi
    rm -f "$_eagle_db_err" 2>/dev/null
    [ -n "$_eagle_db_out" ] && printf '%s\n' "$_eagle_db_out"
    return $_eagle_db_rc
}

eagle_db_json() {
    local _eagle_db_err
    _eagle_db_err=$(mktemp 2>/dev/null || echo "/tmp/_eagle_db_json_err.$$")
    local _eagle_db_out
    _eagle_db_out=$({ echo "$EAGLE_DB_SETUP"; echo ".mode json"; echo "$*"; } | sqlite3 "$EAGLE_MEM_DB" 2>"$_eagle_db_err")
    local _eagle_db_rc=$?
    if [ -s "$_eagle_db_err" ]; then
        cat "$_eagle_db_err" >> "$EAGLE_MEM_LOG" 2>/dev/null
    fi
    rm -f "$_eagle_db_err" 2>/dev/null
    [ -n "$_eagle_db_out" ] && printf '%s\n' "$_eagle_db_out"
    return $_eagle_db_rc
}

eagle_ensure_db() {
    if [ ! -f "$EAGLE_MEM_DB" ]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../db" && pwd)"
        "$script_dir/migrate.sh"
    fi
}
