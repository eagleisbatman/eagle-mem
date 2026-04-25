#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — PostToolUse hook
# Fires after every tool use
# Captures file read/write operations as lightweight observations
# ═══════════════════════════════════════════════════════════
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
tool_name=$(echo "$input" | jq -r '.tool_name // empty')

[ -z "$session_id" ] || [ -z "$tool_name" ] && exit 0

# Only track file-related tools
case "$tool_name" in
    Read|Write|Edit|Bash) ;;
    *) exit 0 ;;
esac

[ ! -f "$EAGLE_MEM_DB" ] && exit 0

project=$(eagle_project_from_cwd "$cwd")

files_read="[]"
files_modified="[]"
tool_summary=""

case "$tool_name" in
    Read)
        fp=$(echo "$input" | jq -r '.tool_input.file_path // empty')
        [ -n "$fp" ] && files_read="[\"$fp\"]"
        tool_summary="Read $fp"
        ;;
    Write)
        fp=$(echo "$input" | jq -r '.tool_input.file_path // empty')
        [ -n "$fp" ] && files_modified="[\"$fp\"]"
        tool_summary="Write $fp"
        ;;
    Edit)
        fp=$(echo "$input" | jq -r '.tool_input.file_path // empty')
        [ -n "$fp" ] && files_modified="[\"$fp\"]"
        tool_summary="Edit $fp"
        ;;
    Bash)
        cmd=$(echo "$input" | jq -r '.tool_input.command // empty' | cut -c1-200)
        # Redact common secret patterns before storing
        cmd=$(echo "$cmd" | sed -E \
            -e 's/(Bearer )[^ ]*/\1[REDACTED]/gi' \
            -e 's/(api[_-]?key[= :])[^ ]*/\1[REDACTED]/gi' \
            -e 's/(password[= :])[^ ]*/\1[REDACTED]/gi' \
            -e 's/(secret[= :])[^ ]*/\1[REDACTED]/gi' \
            -e 's/(token[= :])[^ ]*/\1[REDACTED]/gi' \
            -e 's/(Authorization: )[^ ]*/\1[REDACTED]/gi')
        tool_summary="Bash: $cmd"
        ;;
esac

# Deduplicate: skip if exact same observation within last 5 seconds
dup_count=$(eagle_observation_exists "$session_id" "$tool_name" "$tool_summary")
if [ "$dup_count" != "0" ]; then
    exit 0
fi

eagle_insert_observation "$session_id" "$project" "$tool_name" "$tool_summary" "$files_read" "$files_modified"

exit 0
