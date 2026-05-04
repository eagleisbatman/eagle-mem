#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — PreToolUse hook
# Fires before Bash, Read, Edit, Write tool calls
# 1. Surfaces feature verification checklists before git push
# 2. Truncates noisy commands via updatedInput (curator-learned rules)
# 3. Detects Read-after-Edit/Write (content already in context)
# 4. Nudges on repeated file reads (dedup tracker)
# 5. Co-edit nudge on Edit/Write (curator-learned pairs)
# 6. Stuck loop detection (repeated edits to same file)
# ═══════════════════════════════════════════════════════════
set +e
[ "${EAGLE_MEM_DISABLE_HOOKS:-}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // empty')
agent=$(eagle_agent_source_from_json "$input")

case "$tool_name" in
    Read|Edit|Write|apply_patch) ;;
    *) eagle_is_shell_tool "$tool_name" || exit 0 ;;
esac

[ ! -f "$EAGLE_MEM_DB" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
project=$(eagle_project_from_cwd "$cwd")
[ -z "$project" ] && exit 0

context=""
updated_input=""

case "$tool_name" in
Bash|exec_command|shell_command|unified_exec)
    cmd=$(eagle_tool_command_from_json "$input")
    [ -z "$cmd" ] && exit 0

    # ─── Enforced feature verification on release boundaries ───

    release_changed_files=""
    if eagle_is_release_boundary_command "$cmd"; then
        if [ -n "$cwd" ] && [ -d "$cwd" ]; then
            release_changed_files=$(eagle_changed_files_for_release "$cwd")
            eagle_reconcile_current_feature_verifications "$project" "$cwd" "$session_id" "$tool_name" "Release boundary detected for current repository diff" "$release_changed_files" >/dev/null
        fi

        pending_rows=$(eagle_list_current_pending_feature_verifications "$project" "$cwd" "$release_changed_files" 8 2>/dev/null)
        pending_count=$(printf '%s\n' "$pending_rows" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
        pending_count=${pending_count:-0}
        if [ "$pending_count" -gt 0 ] 2>/dev/null; then
            block_reason="Eagle Mem blocked this release boundary because ${pending_count} feature verification(s) are pending.

Run the affected smoke tests, then resolve them with:
  eagle-mem feature verify <name> --notes \"what passed\"

For intentional exceptions:
  eagle-mem feature waive <id> --reason \"why this is safe\"

Pending checks:"
            while IFS='|' read -r pid pname pfile preason _ptrigger _pcreated psmoke pfingerprint; do
                [ -z "$pid" ] && continue
                block_reason+="
  #${pid} ${pname}"
                [ -n "$pfile" ] && block_reason+=" (${pfile})"
                [ -n "$preason" ] && block_reason+=" — ${preason}"
                [ -n "$psmoke" ] && block_reason+=" | smoke: ${psmoke}"
                [ -n "$pfingerprint" ] && block_reason+=" | diff: ${pfingerprint}"
            done <<< "$pending_rows"

            jq -nc --arg reason "$block_reason" '{
                "decision":"block",
                "reason":$reason,
                "hookSpecificOutput":{
                    "hookEventName":"PreToolUse",
                    "permissionDecision":"deny",
                    "permissionDecisionReason":$reason
                }
            }'
            exit 0
        fi
    fi

    # ─── RTK command rewrite / enforcement ─────────────────

    rtk_mode=$(eagle_token_guard_rtk_mode)
    raw_bash_mode=$(eagle_token_guard_raw_bash_mode)
    rtk_cmd=$(eagle_rtk_rewrite_command "$cmd")
    if [ -n "$rtk_cmd" ]; then
        if [ "$agent" = "codex" ] && [ "$raw_bash_mode" != "allow" ] && ! eagle_raw_bash_unlock_active; then
            reason="Eagle Mem token guard blocked raw shell output.

Use RTK so large output is compact before it enters context:
  $rtk_cmd

Temporary escape hatch for one-off raw output:
  touch $EAGLE_RAW_BASH_UNLOCK"
            jq -nc --arg reason "$reason" '{
                "decision":"block",
                "reason":$reason,
                "hookSpecificOutput":{
                    "hookEventName":"PreToolUse",
                    "permissionDecision":"deny",
                    "permissionDecisionReason":$reason
                }
            }'
            exit 0
        fi

        if ! eagle_raw_bash_unlock_active; then
            updated_input=$(echo "$input" | jq --arg cmd "$rtk_cmd" '.tool_input + {"command":$cmd}')
            context+="Eagle Mem token guard: rewrote raw shell command through RTK to reduce context load: ${rtk_cmd}. "
        fi
    elif [ "$rtk_mode" = "enforce" ] && ! command -v rtk >/dev/null 2>&1 && eagle_raw_output_command_needs_guard "$cmd" && ! eagle_raw_bash_unlock_active; then
        reason="Eagle Mem token guard is set to enforce, but RTK is not installed or not on PATH.

This command can dump raw output into agent context:
  $cmd

Install RTK or disable enforcement:
  eagle-mem config set token_guard.rtk auto

Temporary escape hatch:
  touch $EAGLE_RAW_BASH_UNLOCK"
        jq -nc --arg reason "$reason" '{
            "decision":"block",
            "reason":$reason,
            "hookSpecificOutput":{
                "hookEventName":"PreToolUse",
                "permissionDecision":"deny",
                "permissionDecisionReason":$reason
            }
        }'
        exit 0
    fi

    # ─── Feature verification context for non-blocked pushes ───

    case "$cmd" in
        *"git push"*|*"gh pr create"*)
            has_features=$(eagle_count_active_features "$project")
            if [ "${has_features:-0}" -gt 0 ]; then
                    changed_files="$release_changed_files"
                    if [ -z "$changed_files" ] && [ -n "$cwd" ] && [ -d "$cwd" ]; then
                        changed_files=$(eagle_changed_files_for_release "$cwd")
                    fi

                if [ -n "$changed_files" ]; then
                    seen_features=""
                    while IFS= read -r changed_file; do
                        [ -z "$changed_file" ] && continue
                        norm_file=$(eagle_project_file_path "$cwd" "$changed_file")
                        fname=$(basename "$norm_file")

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
                        context="=== Eagle Mem: Feature Guardrail ===
This push affects the following features. After deploy, verify each works and run 'eagle-mem feature verify <name>'.
${context}================"
                    fi
                fi
            fi
            ;;
    esac

    # ─── Command output filtering (learned rules) ─────────────

    if [ -z "$updated_input" ]; then
    base_cmd=$(echo "$cmd" | awk '{print $1}' | sed 's|.*/||')
    rule=$(eagle_get_command_rule "$project" "$base_cmd" "$cmd")

    if [ -n "$rule" ]; then
        IFS='|' read -r strategy max_lines reason <<< "$rule"
        case "$strategy" in
            truncate)
                if [ -n "$max_lines" ] && [ "$max_lines" -gt 0 ] 2>/dev/null; then
                    case "$cmd" in
                        *"&&"*|*"||"*|*";"*)
                            context+="Eagle Mem command rule: '${base_cmd}' produces long output (${reason}). Consider: | head -${max_lines}"
                            ;;
                        *"| head"*|*"| tail"*|*"| wc"*|*"| grep"*|*">"*|*">>"*)
                            ;;
                        *)
                            updated_input=$(echo "$input" | jq --arg cmd "${cmd} | head -${max_lines}" '.tool_input + {"command":$cmd}')
                            context+="Eagle Mem command rule: '${base_cmd}' output is typically long (${reason}). Piped through head -${max_lines}."
                            ;;
                    esac
                fi
                ;;
            summary)
                context+="Eagle Mem command rule: '${base_cmd}' is typically noisy (${reason}). Consider piping through tail or checking exit code only."
                ;;
        esac
    fi
    fi
    ;;

Edit|Write|apply_patch)
    target_files=$(echo "$input" | jq -r '.tool_input.file_path // empty')
    if [ "$tool_name" = "apply_patch" ]; then
        patch_cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
        target_files=$(printf '%s\n' "$patch_cmd" | eagle_extract_apply_patch_files | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++')
    fi
    if [ -n "$target_files" ]; then
        while IFS= read -r fp; do
            [ -z "$fp" ] && continue
        # ─── Guardrail + decision/gotcha surfacing ────────
        fname=$(basename "$fp")
        fname_stem="${fname%.*}"
        case "$fp" in
            "$HOME/.claude/"*) ;;
            *)
                # Guardrails use GLOB on full filename — no stem length minimum needed.
                # FTS decision/gotcha lookups need a meaningful stem (>= 3 chars).
                if [ ${#fname_stem} -ge 3 ]; then
                    fts_query=$(eagle_fts_sanitize "$fname_stem")
                    fts_query=${fts_query:-"$fname_stem"}
                    edit_ctx=$(eagle_get_edit_context "$project" "$fname" "$fts_query" 2>/dev/null)
                else
                    # Short stem (e.g. db.sh) — only fetch guardrails, skip FTS queries
                    edit_ctx=$(eagle_get_guardrails_for_file "$project" "$fname" 2>/dev/null)
                    if [ -n "$edit_ctx" ]; then
                        # Prefix with GR: to match batched output format; strip empty lines
                        edit_ctx=$(echo "$edit_ctx" | grep -v '^$' | sed 's/^/GR:/')
                    fi
                fi
                if [ -n "$edit_ctx" ]; then
                    gr_block=""
                    while IFS= read -r ctx_line; do
                        case "$ctx_line" in
                            GR:*)  gr_block+="  - ${ctx_line#GR:}"$'\n' ;;
                            DEC:*) context+="=== Eagle Mem: Decision Recall ==="$'\n'"${fname}: ${ctx_line#DEC:} — Do not revert without asking."$'\n'"================"$'\n' ;;
                            GOT:*) context+="=== Eagle Mem: Gotcha Recall ==="$'\n'"${fname}: ${ctx_line#GOT:}"$'\n'"================"$'\n' ;;
                        esac
                    done <<< "$edit_ctx"
                    if [ -n "$gr_block" ]; then
                        context+="=== Eagle Mem: Guardrail ==="$'\n'"${fname}:"$'\n'"${gr_block}================"$'\n'
                    fi
                fi
                ;;
        esac

        # ─── Stuck loop detection ─────────────────────────
        if [ -n "$session_id" ] && eagle_validate_session_id "$session_id"; then
            edit_tracker="$EAGLE_MEM_DIR/edit-tracker/${session_id}"
            if [ -f "$edit_tracker" ]; then
                edit_count=$(grep -cFx -- "$fp" "$edit_tracker" 2>/dev/null)
                edit_count=${edit_count:-0}
                if [ "$edit_count" -ge 8 ]; then
                    context+="Eagle Mem warning: '$(basename "$fp")' has been edited ${edit_count} times this session. You may be stuck — consider stepping back to rethink your approach before making more changes. "
                elif [ "$edit_count" -ge 5 ]; then
                    context+="Eagle Mem warning: '$(basename "$fp")' has been edited ${edit_count} times this session. If the changes aren't converging, consider a different approach. "
                fi
            fi
        fi

        # ─── Co-edit nudge (skip SQLite call if no co-edit hints exist) ──
        _proj_hash=$(printf '%s' "$project" | shasum | cut -c1-8)
        co_edit_marker="$EAGLE_MEM_DIR/.co-edit-active.${_proj_hash}"
        co_edits=""
        if [ -f "$co_edit_marker" ]; then
            co_edits=$(eagle_get_co_edits "$project" "$fp")
        fi
        if [ -n "$co_edits" ]; then
            partners=""
            IFS=',' read -ra co_arr <<< "$co_edits"
            for co_file in "${co_arr[@]}"; do
                [ -n "$co_file" ] && partners+="$(basename "$co_file"), "
            done
            partners=${partners%, }
            context+="Eagle Mem recall: when you change '$(basename "$fp")' you usually also touch: $partners"
        fi
        done <<< "$target_files"
    fi
    ;;

Read)
    fp=$(echo "$input" | jq -r '.tool_input.file_path // empty')
    if [ -n "$fp" ] && [ -n "$session_id" ] && eagle_validate_session_id "$session_id"; then

        # ─── Read-after-modify detection ──────────────────────
        mod_file="$EAGLE_MEM_DIR/mod-tracker/${session_id}"
        if [ -f "$mod_file" ] && grep -qFx -- "$fp" "$mod_file" 2>/dev/null; then
            context+="Eagle Mem recall: '$(basename "$fp")' was just edited/written — the diff is already in context from the tool output. "
        fi

        # ─── Read dedup tracker (soft nudge) ──────────────────
        tracker_dir="$EAGLE_MEM_DIR/read-tracker"
        mkdir -p "$tracker_dir" 2>/dev/null
        tracker_file="$tracker_dir/${session_id}"
        echo "$fp" >> "$tracker_file"
        read_count=$(grep -cFx -- "$fp" "$tracker_file" 2>/dev/null)
        read_count=${read_count:-0}
        if [ "$read_count" -ge 3 ]; then
            context+="Eagle Mem recall: '$(basename "$fp")' has been read ${read_count} times this session. Its contents are likely already in context."
        fi
    fi
    ;;
esac

[ -z "$context" ] && [ -z "$updated_input" ] && exit 0

if [ "$agent" = "codex" ]; then
    # Codex PreToolUse currently supports deny decisions, but not advisory
    # additionalContext or updatedInput. Deny paths above already returned JSON;
    # non-blocking reminders are delivered through SessionStart/UserPromptSubmit.
    exit 0
fi

if [ -n "$updated_input" ]; then
    jq -nc --arg ctx "$context" --argjson ui "$updated_input" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":$ui,"additionalContext":$ctx}}'
else
    jq -nc --arg ctx "$context" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":$ctx}}'
fi

exit 0
