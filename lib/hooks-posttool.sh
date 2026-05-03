#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — PostToolUse extracted responsibilities
# Source from hooks/post-tool-use.sh after common.sh + db.sh
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_HOOKS_POSTTOOL_LOADED:-}" ] && return 0
_EAGLE_HOOKS_POSTTOOL_LOADED=1

eagle_posttool_mirror_writes() {
    local tool_name="$1" fp="$2" session_id="$3" project="$4"
    local agent="${5:-$(eagle_agent_source)}"

    case "$tool_name" in
        Write|Edit|apply_patch)
            if [ -n "$fp" ]; then
                case "$fp" in
                    *..*) ;; # path traversal — skip
                    "$EAGLE_CLAUDE_PROJECTS_DIR"/*/memory/*.md)
                        local mem_base
                        mem_base=$(basename "$fp")
                        if [ "$mem_base" != "MEMORY.md" ] && [ -f "$fp" ]; then
                            eagle_capture_agent_memory "$fp" "$session_id" "$project" "$agent"
                        fi
                        ;;
                    "$EAGLE_CLAUDE_PLANS_DIR/"*.md)
                        if [ -f "$fp" ]; then
                            eagle_capture_agent_plan "$fp" "$session_id" "$project" "$agent"
                        fi
                        ;;
                esac
            fi
            ;;
    esac
}

eagle_posttool_mirror_tasks() {
    local tool_name="$1" session_id="$2" project="$3" input="$4"
    local agent="${5:-$(eagle_agent_source)}"

    case "$tool_name" in
        TaskCreate|TaskUpdate)
            if eagle_validate_session_id "$session_id"; then
                local task_dir="$EAGLE_CLAUDE_TASKS_DIR/$session_id"
                if [ -d "$task_dir" ]; then
                    local task_id
                    task_id=$(echo "$input" | jq -r '.tool_input.id // empty')
                    if [ -z "$task_id" ]; then
                        local newest
                        newest=$(ls -t "$task_dir"/*.json 2>/dev/null | head -1)
                        [ -n "$newest" ] && [ -f "$newest" ] && eagle_capture_agent_task "$newest" "$session_id" "$project" "$agent"
                    elif eagle_validate_session_id "$task_id"; then
                        local task_json="$task_dir/$task_id.json"
                        [ -f "$task_json" ] && eagle_capture_agent_task "$task_json" "$session_id" "$project" "$agent"
                    fi
                fi
            fi
            ;;
    esac
}

eagle_posttool_stale_hint() {
    local tool_name="$1" fp="$2" project="$3"

    case "$tool_name" in
        Write|Edit|apply_patch)
            if [ -n "$fp" ]; then
                local fname fname_stem
                fname=$(basename "$fp")
                fname_stem="${fname%.*}"
                case "$fp" in
                    "$HOME/.claude/"*) ;; # skip Claude config files
                    *)
                        if [ ${#fname_stem} -ge 3 ]; then
                            local fts_query
                            fts_query=$(eagle_fts_sanitize "$fname_stem")
                            if [ -n "$fts_query" ]; then
                                local stale_hit
                                stale_hit=$(eagle_search_stale_memories "$project" "$fts_query")
                                if [ -n "$stale_hit" ]; then
                                    local stale_msg="=== Eagle Mem: Memory Check ===
Memory '${stale_hit}' may reference '${fname}'. If your edit contradicts it, update the memory.
================"
                                    jq -nc --arg ctx "$stale_msg" '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}'
                                fi
                            fi
                        fi
                        ;;
                esac
            fi
            ;;
    esac
}

eagle_posttool_decision_surface() {
    local tool_name="$1" fp="$2" project="$3"

    case "$tool_name" in
        Read)
            if [ -n "$fp" ]; then
                local fname fname_stem read_context=""
                fname=$(basename "$fp")
                fname_stem="${fname%.*}"
                case "$fp" in
                    "$HOME/.claude/"*) ;; # skip Claude config files
                    *)
                        if [ ${#fname_stem} -ge 3 ]; then
                            local fts_query
                            fts_query=$(eagle_fts_sanitize "$fname_stem")
                            if [ -n "$fts_query" ]; then
                                local decision_hit
                                decision_hit=$(eagle_search_decisions_for_file "$project" "$fts_query")
                                if [ -n "$decision_hit" ]; then
                                    read_context+="=== Eagle Mem: Decision Recall ===
${fname}: ${decision_hit} — Do not revert without explicit user request.
================
"
                                fi
                            fi
                        fi

                        local feature_hit
                        feature_hit=$(eagle_find_features_for_file "$project" "$fp")
                        if [ -n "$feature_hit" ]; then
                            while IFS='|' read -r feat_name feat_desc feat_verified _role feat_deps feat_other_files feat_smoke; do
                                [ -z "$feat_name" ] && continue
                                read_context+="=== Eagle Mem: Feature Guardrail ===
'${fname}' is part of feature '${feat_name}'"
                                [ -n "$feat_desc" ] && read_context+=" ($feat_desc)"
                                read_context+="."
                                [ -n "$feat_verified" ] && read_context+=" Last verified: ${feat_verified}."
                                [ -n "$feat_deps" ] && read_context+=" Dependencies: ${feat_deps}."
                                [ -n "$feat_other_files" ] && read_context+=" Other files in pipeline: ${feat_other_files}."
                                [ -n "$feat_smoke" ] && read_context+=" Smoke tests: ${feat_smoke}."
                                read_context+=" Changes require re-testing after deploy.
================
"
                            done <<< "$feature_hit"
                        fi

                        if [ -n "$read_context" ]; then
                            jq -nc --arg ctx "$read_context" '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}'
                        fi
                        ;;
                esac
            fi
            ;;
    esac
}
