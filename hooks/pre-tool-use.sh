#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — PreToolUse hook
# Fires before every tool use
# Surfaces feature verification checklists before git push
# ═══════════════════════════════════════════════════════════
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // empty')
[ "$tool_name" != "Bash" ] && exit 0

[ ! -f "$EAGLE_MEM_DB" ] && exit 0

cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

# Only intercept git push and gh pr create
case "$cmd" in
    *"git push"*|*"gh pr create"*) ;;
    *) exit 0 ;;
esac

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
project=$(eagle_project_from_cwd "$cwd")

p_esc=$(eagle_sql_escape "$project")
has_features=$(eagle_db "SELECT COUNT(*) FROM features WHERE project = '$p_esc' AND status = 'active';")
[ "${has_features:-0}" -eq 0 ] && exit 0

# Get changed files from git diff
changed_files=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    changed_files=$(git -C "$cwd" diff --name-only HEAD 2>/dev/null)
    [ -z "$changed_files" ] && changed_files=$(git -C "$cwd" diff --cached --name-only 2>/dev/null)
fi
[ -z "$changed_files" ] && exit 0

# Check each changed file against feature_files
context=""
seen_features=""
while IFS= read -r changed_file; do
    [ -z "$changed_file" ] && continue
    fname=$(basename "$changed_file")
    fname_esc=$(eagle_sql_escape "$fname")

    feature_hits=$(eagle_db "SELECT DISTINCT f.name,
        (SELECT GROUP_CONCAT(fst.command, '; ')
         FROM feature_smoke_tests fst WHERE fst.feature_id = f.id) as smoke,
        (SELECT GROUP_CONCAT(fd.target || ':' || fd.name, ', ')
         FROM feature_dependencies fd WHERE fd.feature_id = f.id) as deps,
        f.last_verified_at
        FROM features f
        JOIN feature_files ff ON ff.feature_id = f.id
        WHERE f.project = '$p_esc'
        AND f.status = 'active'
        AND (ff.file_path LIKE '%$fname_esc' OR ff.file_path LIKE '%$fname_esc%');")

    while IFS='|' read -r feat_name feat_smoke feat_deps feat_verified; do
        [ -z "$feat_name" ] && continue
        # Deduplicate features
        case "$seen_features" in
            *"|$feat_name|"*) continue ;;
        esac
        seen_features+="|$feat_name|"

        context+="  - $feat_name"
        [ -n "$feat_smoke" ] && context+=" | smoke: $feat_smoke"
        [ -n "$feat_deps" ] && context+=" | deps: $feat_deps"
        if [ -n "$feat_verified" ]; then
            context+=" | last verified: $feat_verified"
        else
            context+=" | never verified"
        fi
        context+=$'\n'
    done <<< "$feature_hits"
done <<< "$changed_files"

[ -z "$context" ] && exit 0

push_msg="Eagle Mem: This push affects the following features. After deploy, verify each works and run 'eagle-mem feature verify <name>' to record confirmation.
${context}IMPORTANT: Do not push without informing the user which features need re-testing."

jq -nc --arg ctx "$push_msg" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":$ctx}}'

exit 0
