#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — PreToolUse hook
# Fires before Bash and Read tool calls
# 1. Surfaces feature verification checklists before git push
# 2. Truncates noisy commands via updatedInput (curator-learned rules)
# 3. Detects Read-after-Edit/Write (content already in context)
# 4. Nudges on repeated file reads (dedup tracker)
# ═══════════════════════════════════════════════════════════
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // empty')

case "$tool_name" in
    Bash|Read) ;;
    *) exit 0 ;;
esac

[ ! -f "$EAGLE_MEM_DB" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
project=$(eagle_project_from_cwd "$cwd")
[ -z "$project" ] && exit 0

context=""
updated_input=""

case "$tool_name" in
Bash)
    cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
    [ -z "$cmd" ] && exit 0

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

                        feature_hits=$(eagle_find_feature_for_push "$project" "$fname")

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

    base_cmd=$(echo "$cmd" | awk '{print $1}' | sed 's|.*/||')
    rule=$(eagle_get_command_rule "$project" "$base_cmd")

    if [ -n "$rule" ]; then
        IFS='|' read -r strategy max_lines reason <<< "$rule"
        case "$strategy" in
            truncate)
                if [ -n "$max_lines" ] && [ "$max_lines" -gt 0 ] 2>/dev/null; then
                    case "$cmd" in
                        *"&&"*|*"||"*|*";"*)
                            context+="Eagle Mem: '${base_cmd}' produces long output (${reason}). Consider: | head -${max_lines}"
                            ;;
                        *"| head"*|*"| tail"*|*"| wc"*|*"| grep"*|*">"*|*">>"*)
                            ;;
                        *)
                            updated_input=$(jq -nc --arg cmd "${cmd} | head -${max_lines}" '{"command":$cmd}')
                            context+="Eagle Mem: '${base_cmd}' output is typically long (${reason}). Piped through head -${max_lines}."
                            ;;
                    esac
                fi
                ;;
            summary)
                context+="Eagle Mem: '${base_cmd}' is typically noisy (${reason}). Consider piping through tail or checking exit code only."
                ;;
        esac
    fi
    ;;

Read)
    fp=$(echo "$input" | jq -r '.tool_input.file_path // empty')
    if [ -n "$fp" ] && [ -n "$session_id" ] && eagle_validate_session_id "$session_id"; then

        # ─── Read-after-modify detection ──────────────────────
        mod_file="$EAGLE_MEM_DIR/mod-tracker/${session_id}"
        if [ -f "$mod_file" ] && grep -qFx -- "$fp" "$mod_file" 2>/dev/null; then
            context+="Eagle Mem: '$(basename "$fp")' was just edited/written — the diff is already in context from the tool output. "
        fi

        # ─── Read dedup tracker (soft nudge) ──────────────────
        tracker_dir="$EAGLE_MEM_DIR/read-tracker"
        mkdir -p "$tracker_dir" 2>/dev/null
        tracker_file="$tracker_dir/${session_id}"
        echo "$fp" >> "$tracker_file"
        read_count=$(grep -cFx -- "$fp" "$tracker_file" 2>/dev/null)
        read_count=${read_count:-0}
        if [ "$read_count" -ge 3 ]; then
            context+="Eagle Mem: '$(basename "$fp")' has been read ${read_count} times this session. Its contents are likely already in context."
        fi
    fi
    ;;
esac

[ -z "$context" ] && [ -z "$updated_input" ] && exit 0

if [ -n "$updated_input" ]; then
    jq -nc --arg ctx "$context" --argjson ui "$updated_input" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":$ui,"additionalContext":$ctx}}'
else
    jq -nc --arg ctx "$context" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":$ctx}}'
fi

exit 0
