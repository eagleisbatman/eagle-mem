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
agent=$(eagle_agent_source_from_json "$input")
[ -z "$session_id" ] && exit 0
[ ! -f "$EAGLE_MEM_DB" ] && exit 0

cwd=$(echo "$input" | jq -r '.cwd // empty')
project=$(eagle_project_from_cwd "$cwd")
[ -z "$project" ] && exit 0

# Final sweep: re-capture all task files to catch status changes
# Claude Code may update task status without triggering PostToolUse
if eagle_validate_session_id "$session_id"; then
    task_dir="$EAGLE_CLAUDE_TASKS_DIR/$session_id"
    if [ -d "$task_dir" ]; then
        for task_file in "$task_dir"/*.json; do
            [ ! -f "$task_file" ] && continue
            eagle_capture_claude_task "$task_file" "$session_id" "$project" "$agent"
        done
        eagle_log "INFO" "SessionEnd: re-synced tasks from $task_dir"
    fi
fi

eagle_end_session "$session_id"
eagle_log "INFO" "SessionEnd: session=$session_id marked completed"

# Prune observations older than 90 days (keeps DB size bounded)
eagle_prune_observations 90 "$project"

exit 0
