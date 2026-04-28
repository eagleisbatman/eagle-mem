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

if [ -z "$session_id" ] || [ -z "$tool_name" ]; then exit 0; fi

# Only track relevant tools
case "$tool_name" in
    Read|Write|Edit|Bash|TaskCreate|TaskUpdate) ;;
    *) exit 0 ;;
esac

[ ! -f "$EAGLE_MEM_DB" ] && exit 0

project=$(eagle_project_from_cwd "$cwd")

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

        # Output metrics
        tool_output=$(echo "$input" | jq -r '.tool_result.stdout // empty' 2>/dev/null)
        if [ -n "$tool_output" ]; then
            output_bytes=${#tool_output}
            output_lines=$(echo "$tool_output" | wc -l | tr -d ' ')
        fi

        # Command category extraction
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

# ─── Claude memory + plan mirror ─────────────────────────
# Intercept writes to Claude Code's auto-memory and plan files
case "$tool_name" in
    Write|Edit)
        if [ -n "$fp" ]; then
            # Reject path traversal: bash case `*` matches `/`, so
            # patterns like projects/*/memory/*.md would match paths
            # containing /../ segments. Block any path with `..` first.
            case "$fp" in
                *..*) ;; # path traversal — skip
                "$HOME/.claude/projects"/*/memory/*.md)
                    mem_base=$(basename "$fp")
                    if [ "$mem_base" != "MEMORY.md" ] && [ -f "$fp" ]; then
                        eagle_capture_claude_memory "$fp" "$session_id" "$project"
                    fi
                    ;;
                "$HOME/.claude/plans/"*.md)
                    if [ -f "$fp" ]; then
                        eagle_capture_claude_plan "$fp" "$session_id" "$project"
                    fi
                    ;;
            esac
        fi
        ;;
esac

# ─── Claude task mirror ─────────────────────────────────
# Intercept TaskCreate/TaskUpdate and capture the resulting JSON files
case "$tool_name" in
    TaskCreate|TaskUpdate)
        if eagle_validate_session_id "$session_id"; then
            task_dir="$HOME/.claude/tasks/$session_id"
            if [ -d "$task_dir" ]; then
                task_id=$(echo "$input" | jq -r '.tool_input.id // empty')
                if [ -z "$task_id" ]; then
                    newest=$(ls -t "$task_dir"/*.json 2>/dev/null | head -1)
                    [ -n "$newest" ] && [ -f "$newest" ] && eagle_capture_claude_task "$newest" "$session_id" "$project"
                elif eagle_validate_session_id "$task_id"; then
                    task_json="$task_dir/$task_id.json"
                    [ -f "$task_json" ] && eagle_capture_claude_task "$task_json" "$session_id" "$project"
                fi
            fi
        fi
        ;;
esac

# ─── Stale memory hint ──────────────────────────────────
# After editing a project file, FTS5-search memories for the filename.
# If a memory mentions this file, remind Claude to check for staleness.
case "$tool_name" in
    Write|Edit)
        if [ -n "$fp" ]; then
            fname=$(basename "$fp")
            fname_stem="${fname%.*}"
            case "$fp" in
                "$HOME/.claude/"*) ;; # skip Claude config files
                *)
                    if [ ${#fname_stem} -ge 3 ]; then
                        fts_query=$(eagle_fts_sanitize "$fname_stem")
                        if [ -n "$fts_query" ]; then
                            fts_esc=$(eagle_sql_escape "$fts_query")
                            p_esc=$(eagle_sql_escape "$project")
                            stale_hit=$(eagle_db "SELECT m.memory_name
                                FROM claude_memories m
                                JOIN claude_memories_fts f ON f.rowid = m.id
                                WHERE claude_memories_fts MATCH '$fts_esc'
                                AND m.project = '$p_esc'
                                LIMIT 1;")
                            if [ -n "$stale_hit" ]; then
                                stale_msg="Eagle Mem: Memory '${stale_hit}' may reference '${fname}'. If your edit contradicts it, update the memory."
                                jq -nc --arg ctx "$stale_msg" '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}'
                            fi
                        fi
                    fi
                    ;;
            esac
        fi
        ;;
esac

# ─── Decision + feature surfacing on Read ──────────────────
# When Claude reads a file, surface past decisions and feature pipeline context.
case "$tool_name" in
    Read)
        if [ -n "$fp" ]; then
            fname=$(basename "$fp")
            fname_stem="${fname%.*}"
            read_context=""
            case "$fp" in
                "$HOME/.claude/"*) ;; # skip Claude config files
                *)
                    p_esc=$(eagle_sql_escape "$project")

                    # Decision history from summaries
                    if [ ${#fname_stem} -ge 3 ]; then
                        fts_query=$(eagle_fts_sanitize "$fname_stem")
                        if [ -n "$fts_query" ]; then
                            fts_esc=$(eagle_sql_escape "$fts_query")
                            decision_hit=$(eagle_db "SELECT s.decisions
                                FROM summaries s
                                JOIN summaries_fts f ON f.rowid = s.id
                                WHERE summaries_fts MATCH '$fts_esc'
                                AND s.project = '$p_esc'
                                AND s.decisions IS NOT NULL
                                AND s.decisions != ''
                                ORDER BY s.created_at DESC
                                LIMIT 1;")
                            if [ -n "$decision_hit" ]; then
                                read_context+="Eagle Mem decision history for '${fname}': ${decision_hit} — Do not revert without explicit user request. "
                            fi
                        fi
                    fi

                    # Feature pipeline context
                    feature_hit=$(eagle_find_features_for_file "$project" "$fp")
                    if [ -n "$feature_hit" ]; then
                        while IFS='|' read -r feat_name feat_desc feat_verified _role feat_deps feat_other_files feat_smoke; do
                            [ -z "$feat_name" ] && continue
                            read_context+="Eagle Mem: '${fname}' is part of feature '${feat_name}'"
                            [ -n "$feat_desc" ] && read_context+=" ($feat_desc)"
                            read_context+="."
                            if [ -n "$feat_verified" ]; then
                                read_context+=" Last verified: ${feat_verified}."
                            fi
                            if [ -n "$feat_deps" ]; then
                                read_context+=" Dependencies: ${feat_deps}."
                            fi
                            if [ -n "$feat_other_files" ]; then
                                read_context+=" Other files in pipeline: ${feat_other_files}."
                            fi
                            if [ -n "$feat_smoke" ]; then
                                read_context+=" Smoke tests: ${feat_smoke}."
                            fi
                            read_context+=" Changes require re-testing after deploy. "
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

eagle_insert_observation "$session_id" "$project" "$tool_name" "$tool_summary" "$files_read" "$files_modified" "$output_bytes" "$output_lines" "$command_category"

exit 0
