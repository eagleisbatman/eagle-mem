#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — SessionEnd hook
# Fires when the Claude Code session ends
# Marks the session as completed
# ═══════════════════════════════════════════════════════════
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
[ -z "$session_id" ] && exit 0
[ ! -f "$EAGLE_MEM_DB" ] && exit 0

eagle_end_session "$session_id"
eagle_log "INFO" "SessionEnd: session=$session_id marked completed"

exit 0
