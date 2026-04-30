#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Database helpers (backward-compat shim)
# Sources all domain files. Callers: . "$LIB_DIR/db.sh"
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_LOADED:-}" ] && return 0
_EAGLE_DB_LOADED=1

_eagle_db_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$_eagle_db_dir/db-core.sh"
. "$_eagle_db_dir/db-sessions.sh"
. "$_eagle_db_dir/db-observations.sh"
. "$_eagle_db_dir/db-summaries.sh"
. "$_eagle_db_dir/db-mirrors.sh"
. "$_eagle_db_dir/db-features.sh"
. "$_eagle_db_dir/db-hints.sh"
. "$_eagle_db_dir/db-backfill.sh"
. "$_eagle_db_dir/db-guardrails.sh"
