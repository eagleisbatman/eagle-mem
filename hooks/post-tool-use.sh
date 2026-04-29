#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — PostToolUse hook
# Fires after every tool use
# Captures observations + dispatches to extracted responsibilities
# ═══════════════════════════════════════════════════════════
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/hooks-posttool.sh"

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
tool_name=$(echo "$input" | jq -r '.tool_name // empty')

if [ -z "$session_id" ] || [ -z "$tool_name" ]; then exit 0; fi

# Only track relevant tools
case "$tool_name" in
    Read|Write|Edit|Bash|TaskCreate|TaskUpdate) ;;
    *) exit 0 ;;
esac

[ ! -f "$EAGLE_MEM_DB" ] && exit 0

project=$(eagle_project_from_cwd "$cwd")
[ -z "$project" ] && exit 0

# Ensure session row exists before inserting observations (FK constraint).
# PostToolUse can race SessionStart — the session row might not exist yet.
eagle_upsert_session "$session_id" "$project" "$cwd" "" ""

# ─── Extract observation data from tool call ──────────────

fp=""
files_read="[]"
files_modified="[]"
tool_summary=""
output_bytes=""
output_lines=""
command_category=""

case "$tool_name" in
    Read)
        fp=$(echo "$input" | jq -r '.tool_input.file_path // empty')
        [ -n "$fp" ] && files_read=$(printf '%s' "$fp" | jq -Rsc '[.]')
        tool_summary="Read $fp"
        ;;
    Write)
        fp=$(echo "$input" | jq -r '.tool_input.file_path // empty')
        [ -n "$fp" ] && files_modified=$(printf '%s' "$fp" | jq -Rsc '[.]')
        tool_summary="Write $fp"
        ;;
    Edit)
        fp=$(echo "$input" | jq -r '.tool_input.file_path // empty')
        [ -n "$fp" ] && files_modified=$(printf '%s' "$fp" | jq -Rsc '[.]')
        tool_summary="Edit $fp"
        ;;
    Bash)
        cmd=$(echo "$input" | jq -r '.tool_input.command // empty' | cut -c1-200)
        cmd=$(echo "$cmd" | eagle_redact)
        tool_summary="Bash: $cmd"

        tool_output=$(echo "$input" | jq -r '.tool_response.stdout // empty' 2>/dev/null)
        if [ -n "$tool_output" ]; then
            output_bytes=${#tool_output}
            output_lines=$(echo "$tool_output" | wc -l | tr -d ' ')
        fi

        first_word=$(echo "$cmd" | awk '{print $1}' | sed 's|.*/||')
        case "$first_word" in
            git|gh) command_category="git" ;;
            npm|npx|pnpm|yarn|bun) command_category="js" ;;
            pip|pip3|python|python3|uv) command_category="python" ;;
            cargo|rustc) command_category="rust" ;;
            go) command_category="go" ;;
            docker|docker-compose|podman) command_category="docker" ;;
            kubectl|helm|k9s) command_category="k8s" ;;
            aws|gcloud|az) command_category="cloud" ;;
            make|cmake|ninja) command_category="build" ;;
            grep|find|ls|cat|head|tail|wc|sort|sed|awk) command_category="files" ;;
            curl|wget|http) command_category="http" ;;
            *test*|jest|pytest|vitest|mocha) command_category="test" ;;
            *lint*|eslint|ruff|golangci-lint) command_category="lint" ;;
            *) command_category="other" ;;
        esac
        ;;
    TaskCreate|TaskUpdate)
        task_subject=$(echo "$input" | jq -r '.tool_input.subject // empty')
        tool_summary="$tool_name: $task_subject"
        ;;
esac

# ─── Track recent Edit/Write targets for Read-after-modify detection ──

if [ -n "$fp" ] && [ -n "$session_id" ] && eagle_validate_session_id "$session_id"; then
    case "$tool_name" in
        Edit|Write)
            mod_dir="$EAGLE_MEM_DIR/mod-tracker"
            mkdir -p "$mod_dir" 2>/dev/null
            mod_file="$mod_dir/${session_id}"
            echo "$fp" >> "$mod_file"
            # Keep only last 3 entries — use per-process tmp to avoid
            # race when parallel PostToolUse hooks fire on same session
            if [ -f "$mod_file" ]; then
                _mod_tmp=$(mktemp "${mod_file}.XXXXXX" 2>/dev/null) || _mod_tmp="${mod_file}.$$"
                tail -3 "$mod_file" > "$_mod_tmp" && mv "$_mod_tmp" "$mod_file" || rm -f "$_mod_tmp"
            fi
            ;;
    esac
fi

# ─── Dispatch to extracted responsibilities ───────────────

eagle_posttool_mirror_writes "$tool_name" "$fp" "$session_id" "$project"
eagle_posttool_mirror_tasks "$tool_name" "$session_id" "$project" "$input"
eagle_posttool_stale_hint "$tool_name" "$fp" "$project"
eagle_posttool_decision_surface "$tool_name" "$fp" "$project"

# ─── Record observation ──────────────────────────────────

if ! eagle_insert_observation "$session_id" "$project" "$tool_name" "$tool_summary" "$files_read" "$files_modified" "$output_bytes" "$output_lines" "$command_category"; then
    eagle_log "ERROR" "PostToolUse: observation insert failed for session=$session_id tool=$tool_name"
fi

exit 0
