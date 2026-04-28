#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — PreToolUse hook
# Fires before every Bash tool use
# 1. Surfaces feature verification checklists before git push
# 2. Applies learned command filtering rules (RTK-style adaptive)
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

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
project=$(eagle_project_from_cwd "$cwd")
[ -z "$project" ] && exit 0

context=""

# ─── Feature verification on git push ─────────────────────

case "$cmd" in
    *"git push"*|*"gh pr create"*)
        has_features=$(eagle_count_active_features "$project")
        if [ "${has_features:-0}" -gt 0 ]; then
            changed_files=""
            if [ -n "$cwd" ] && [ -d "$cwd" ]; then
                changed_files=$(git -C "$cwd" diff --name-only HEAD 2>/dev/null)
                [ -z "$changed_files" ] && changed_files=$(git -C "$cwd" diff --cached --name-only 2>/dev/null)
            fi

            if [ -n "$changed_files" ]; then
                seen_features=""
                while IFS= read -r changed_file; do
                    [ -z "$changed_file" ] && continue
                    fname=$(basename "$changed_file")
                    fname_esc=$(eagle_sql_escape "$fname")

                    feature_hits=$(eagle_find_feature_for_push "$project" "$fname_esc")

                    while IFS='|' read -r feat_name feat_smoke feat_deps feat_verified; do
                        [ -z "$feat_name" ] && continue
                        case "$seen_features" in *"|$feat_name|"*) continue ;; esac
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

                if [ -n "$context" ]; then
                    context="Eagle Mem: This push affects the following features. After deploy, verify each works and run 'eagle-mem feature verify <name>'.
${context}"
                fi
            fi
        fi
        ;;
esac

# ─── Command output filtering (learned rules) ─────────────

# Extract the base command for rule matching
base_cmd=$(echo "$cmd" | awk '{print $1}' | sed 's|.*/||')

rule=$(eagle_get_command_rule "$project" "$base_cmd")

if [ -n "$rule" ]; then
    IFS='|' read -r strategy max_lines reason <<< "$rule"
    case "$strategy" in
        summary)
            context+="Eagle Mem command hint: '${base_cmd}' output is typically noisy (${reason}). Consider piping through 'tail -5' or checking exit code only."
            ;;
        truncate)
            if [ -n "$max_lines" ] && [ "$max_lines" -gt 0 ] 2>/dev/null; then
                context+="Eagle Mem command hint: '${base_cmd}' produces long output (${reason}). Consider: ${cmd} | head -${max_lines}"
            fi
            ;;
    esac
fi

[ -z "$context" ] && exit 0

jq -nc --arg ctx "$context" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":$ctx}}'

exit 0
