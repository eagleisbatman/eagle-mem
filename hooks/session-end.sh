#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — SessionEnd hook
# Fires when the Claude Code session ends
# Marks the session as completed + triggers auto-curate
# ═══════════════════════════════════════════════════════════
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/provider.sh"

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
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
            eagle_capture_claude_task "$task_file" "$session_id" "$project"
        done
        eagle_log "INFO" "SessionEnd: re-synced tasks from $task_dir"
    fi
fi

eagle_end_session "$session_id"
eagle_log "INFO" "SessionEnd: session=$session_id marked completed"

# Prune observations older than 90 days (keeps DB size bounded)
eagle_prune_observations 90 "$project"

# ─── Auto-curate trigger ─────────────────────────────────
curator_schedule=$(eagle_config_get "curator" "schedule" "manual")
if [ "$curator_schedule" = "auto" ]; then
    provider=$(eagle_config_get "provider" "type" "none")
    if [ "$provider" != "none" ]; then
        min_sessions=$(eagle_config_get "curator" "min_sessions" "5")
        min_sessions=$(eagle_sql_int "$min_sessions")

        last_curated=$(eagle_meta_get "last_curated_at" "$project")
        since="${last_curated:-1970-01-01T00:00:00Z}"

        sessions_since=$(eagle_count_sessions_since "$project" "$since")
        if [ "${sessions_since:-0}" -ge "$min_sessions" ]; then
            eagle_log "INFO" "SessionEnd: auto-curate triggered (${sessions_since} sessions since last curate)"
            nohup bash "$SCRIPTS_DIR/curate.sh" -p "$project" >> "$EAGLE_MEM_LOG" 2>&1 &
        fi
    fi
fi

exit 0
