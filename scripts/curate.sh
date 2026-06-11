#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Curator
# Self-learning engine that analyzes sessions and generates:
# 1. Promoted gotchas → persistent memories
# 2. Superseded decision detection
# 3. Command compression rules
# 4. Feature auto-discovery
# 5. Co-edit pattern detection
# 6. Hot file detection
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$SCRIPT_DIR/style.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/provider.sh"

eagle_header "Curator"

DRY_RUN=0
FULL=0
project=""

show_help() {
    cat <<EOF
Usage: eagle-mem curate [options]

Options:
  -h, --help           Show this help message and exit
  --dry-run            Analyze gotchas, decisions, features, and memories without saving to db
  --full               Run full session compression and historical curation (slower)
  -p, --project <dir>  Target project directory (defaults to auto-detected cwd)
EOF
}

parse_consolidations_json() {
    local result="$1"
    printf '%s' "$result" | jq -Rrs -c '
        def text_trim: gsub("^\\s+|\\s+$"; "");
        def parse_payload:
            gsub("\r"; "")
            | gsub("^\\s*```json\\s*\\n"; "")
            | gsub("^\\s*```\\s*\\n"; "")
            | gsub("\\n\\s*```\\s*$"; "")
            | text_trim
            | if . == "" or . == "NONE" or . == "none" or . == "null" then []
              else
                  try fromjson catch (
                      ([match("(?s)(\\{.*\\}|\\[.*\\])")? | .string][0] // "[]") | fromjson
                  )
              end;
        def trim: gsub("^\\s+|\\s+$"; "");
        def names:
            if type == "array" then map(tostring | trim) | map(select(length > 0))
            elif type == "string" then split(",") | map(trim) | map(select(length > 0))
            else []
            end;
        def root:
            if type == "array" then .
            elif type == "object" then (.consolidations // .items // .instructions // [])
            else []
            end;
        parse_payload
        | root
        | map({
            source_names: ((.source_names // .sourceNames // .source_memories // .sourceMemories // .original_names // .originalNames // .originals // .names) | names),
            new_name: ((.new_name // .newName // .name // .title // "") | tostring | trim),
            description: ((.description // "") | tostring),
            value: ((.value // .content // .compiled_truth // .compiledTruth // "") | tostring)
        })
        | map(select((.source_names | length) > 0 and (.new_name | length) > 0))
    ' 2>/dev/null
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        --full) FULL=1; shift ;;
        -p|--project) project="$2"; shift 2 ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run with -h or --help for usage details." >&2
            exit 1
            ;;
    esac
done

if [ -z "$project" ]; then
    project=$(eagle_project_from_cwd "$(pwd)")
fi

p_esc=$(eagle_sql_escape "$project")

cleanup_curate() {
    local rc=$?
    eagle_run_finish "$rc" "$LINENO"
}
eagle_run_start "curate" "$project" "$(pwd)"
trap cleanup_curate EXIT

# Verify provider is configured
provider=$(eagle_config_get "provider" "type" "none")
if [ "$provider" = "none" ]; then
    eagle_err "No LLM provider configured. Run: eagle-mem config init"
    exit 1
fi
eagle_info "Provider: $(eagle_llm_provider_label)"
eagle_info "Project: $project"
[ "$DRY_RUN" -eq 1 ] && eagle_info "Dry run — no changes will be made"
echo ""

# ─── 1. Analyze gotchas for promotion ─────────────────────

eagle_run_step "promote_gotchas"
eagle_info "Analyzing gotchas for promotion..."

recent_gotchas=$(eagle_db "SELECT gotchas, created_at
    FROM summaries
    WHERE project = '$p_esc'
    AND gotchas IS NOT NULL AND gotchas != ''
    ORDER BY created_at DESC
    LIMIT 20;")

if [ -n "$recent_gotchas" ]; then
    gotcha_prompt="Analyze these gotchas from recent development sessions on project '$project'. Identify any that appear multiple times or are important enough to become permanent project knowledge.

GOTCHAS:
$recent_gotchas

For each gotcha worth promoting, output EXACTLY this format (one per line):
PROMOTE: <one-line gotcha summary>

Only promote gotchas that are:
1. Repeated across multiple sessions (same mistake happening again)
2. Non-obvious and likely to be forgotten
3. Specific enough to be actionable

If none qualify, output: NONE"

    gotcha_result=$(eagle_llm_call "$gotcha_prompt" "You analyze software development patterns. Be concise. Only output PROMOTE lines or NONE." 512 || true)

    if [ -n "$gotcha_result" ] && ! echo "$gotcha_result" | grep -q "^NONE$"; then
        promoted=0
        while IFS= read -r line; do
            case "$line" in
                PROMOTE:*)
                    gotcha_text=$(echo "$line" | sed 's/^PROMOTE:[[:space:]]*//')
                    if [ "$DRY_RUN" -eq 1 ]; then
                        eagle_info "  Would promote: $gotcha_text"
                    else
                        eagle_add_guardrail "$project" "$gotcha_text" "" "promoted"
                        eagle_log "INFO" "Curator: promoted gotcha to guardrail: $gotcha_text"
                    fi
                    promoted=$((promoted + 1))
                    ;;
            esac
        done <<< "$gotcha_result"
        eagle_ok "Found $promoted gotchas to promote"
    else
        eagle_ok "No gotchas need promotion"
    fi
else
    eagle_dim "  No gotchas to analyze"
fi

# ─── 2. Detect superseded decisions ───────────���───────────

eagle_info "Checking for superseded decisions..."

recent_decisions=$(eagle_db "SELECT decisions, key_files, created_at
    FROM summaries
    WHERE project = '$p_esc'
    AND decisions IS NOT NULL AND decisions != ''
    ORDER BY created_at DESC
    LIMIT 20;")

if [ -n "$recent_decisions" ]; then
    decision_prompt="Analyze these decisions from recent sessions on project '$project'. Identify any that CONTRADICT or SUPERSEDE earlier decisions (e.g., session 5 decided to use approach A, but session 8 switched to approach B).

DECISIONS (newest first):
$recent_decisions

For each superseded decision, output EXACTLY:
SUPERSEDED: <old decision> → <new decision> | file: <affected file if known>

If none are superseded, output: NONE"

    decision_result=$(eagle_llm_call "$decision_prompt" "You detect contradicting software decisions. Be precise." 512 || true)

    if [ -n "$decision_result" ] && ! echo "$decision_result" | grep -q "^NONE$"; then
        superseded=0
        while IFS= read -r line; do
            case "$line" in
                SUPERSEDED:*)
                    if [ "$DRY_RUN" -eq 1 ]; then
                        eagle_info "  $line"
                    else
                        eagle_log "INFO" "Curator: $line"
                    fi
                    superseded=$((superseded + 1))
                    ;;
            esac
        done <<< "$decision_result"
        eagle_ok "Found $superseded superseded decisions"
    else
        eagle_ok "No superseded decisions found"
    fi
else
    eagle_dim "  No decisions to analyze"
fi

# ─── 3. Generate command compression rules ────────────────

eagle_info "Analyzing command patterns..."

command_stats=$(eagle_db "SELECT command_category,
    COUNT(*) as count,
    AVG(output_bytes) as avg_bytes,
    MAX(output_bytes) as max_bytes,
    AVG(output_lines) as avg_lines
    FROM observations
    WHERE project = '$p_esc'
    AND tool_name = 'Bash'
    AND command_category IS NOT NULL
    AND output_bytes IS NOT NULL
    AND output_bytes > 0
    GROUP BY command_category
    HAVING count > 5
    ORDER BY avg_bytes DESC
    LIMIT 10;")

if [ -n "$command_stats" ]; then
    # Get noisy commands grouped by base command (first 2 words) to catch variants
    # e.g. "git diff", "git diff HEAD~1", "git -C /path diff" all group under "git diff"
    noisy_commands=$(eagle_db "SELECT
        CASE
            WHEN tool_input_summary LIKE 'Bash: cd %' THEN 'cd ... && ' || SUBSTR(tool_input_summary, INSTR(tool_input_summary, '&& ') + 3, 40)
            ELSE SUBSTR(tool_input_summary, 7, 40)
        END as base_cmd,
        COUNT(*) as count,
        CAST(AVG(output_bytes) AS INTEGER) as avg_bytes,
        CAST(MAX(output_bytes) AS INTEGER) as max_bytes,
        CAST(AVG(output_lines) AS INTEGER) as avg_lines
        FROM observations
        WHERE project = '$p_esc'
        AND tool_name = 'Bash'
        AND output_bytes > 2000
        GROUP BY base_cmd
        HAVING count >= 2
        ORDER BY avg_bytes DESC
        LIMIT 15;")

    if [ -n "$noisy_commands" ]; then
        cmd_prompt="Analyze these frequently-run command patterns and their output sizes for project '$project'. Suggest compression rules for commands that produce consistently large output (>2KB average).

COMMAND PATTERNS (base_command | times_run | avg_bytes | max_bytes | avg_lines):
$noisy_commands

For each command that deserves a compression rule, output EXACTLY:
RULE: <pattern> | <strategy: summary or truncate> | <max_lines or -> | <reason>

Where:
- pattern: the base command to match (e.g., 'npm', 'git log', 'pnpm test')
- strategy: 'summary' (only show result) or 'truncate' (keep first N lines)
- max_lines: for truncate strategy, how many lines to keep; '-' for summary
- reason: one-line explanation

If no rules needed, output: NONE"

        cmd_result=$(eagle_llm_call "$cmd_prompt" "You optimize CLI output for AI assistants. Be conservative — only suggest rules for genuinely noisy commands." 512 || true)

        if [ -n "$cmd_result" ] && ! echo "$cmd_result" | grep -q "^NONE$"; then
            rules_count=0
            while IFS= read -r line; do
                case "$line" in
                    RULE:*)
                        rule_data=$(echo "$line" | sed 's/^RULE:[[:space:]]*//')
                        IFS='|' read -r pattern strategy max_lines reason <<< "$rule_data"
                        pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        strategy=$(echo "$strategy" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        max_lines=$(echo "$max_lines" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        reason=$(echo "$reason" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

                        # Guard: skip malformed lines missing required fields
                        if [ -z "$pattern" ] || [ -z "$strategy" ]; then
                            eagle_log "WARN" "Curator: skipping malformed RULE line: $line"
                            continue
                        fi
                        case "$strategy" in summary|truncate) ;; *)
                            eagle_log "WARN" "Curator: skipping RULE with invalid strategy '$strategy'"
                            continue
                        ;; esac
                        # Guard: reject dangerous LLM-generated patterns that match everything
                        # Require at least 2 literal characters (not just wildcards)
                        _literal_chars=$(printf '%s' "$pattern" | sed 's/[%_]//g')
                        if [ ${#_literal_chars} -lt 2 ]; then
                            eagle_log "WARN" "Curator: skipping overly broad pattern '$pattern' (needs >=2 literal chars)"
                            continue
                        fi

                        [ "$max_lines" = "-" ] && max_lines=""

                        if [ "$DRY_RUN" -eq 1 ]; then
                            eagle_info "  Rule: $pattern → $strategy ($reason)"
                        else
                            pattern_esc=$(eagle_sql_escape "$pattern")
                            reason_esc=$(eagle_sql_escape "$reason")
                            ml_val="${max_lines:-NULL}"
                            [ "$ml_val" != "NULL" ] && ml_val=$(eagle_sql_int "$ml_val")

                            # Tag provenance: these rules are LLM-derived. They can be
                            # excluded from enforcement via token_guard.trust_learned_rules=false.
                            eagle_db "INSERT INTO command_rules (project, pattern, strategy, max_lines, reason, source)
                                VALUES ('$p_esc', '$pattern_esc', '$strategy', $ml_val, '$reason_esc', 'curator')
                                ON CONFLICT(project, pattern) DO UPDATE SET
                                    strategy = excluded.strategy,
                                    max_lines = excluded.max_lines,
                                    reason = excluded.reason,
                                    source = 'curator',
                                    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"
                            eagle_log "INFO" "Curator: added command rule: $pattern → $strategy"
                        fi
                        rules_count=$((rules_count + 1))
                        ;;
                esac
            done <<< "$cmd_result"
            eagle_ok "$rules_count command rules generated"
        else
            eagle_ok "No command rules needed"
        fi
    else
        eagle_dim "  Not enough command data yet"
    fi
else
    eagle_dim "  No command metrics collected yet (need more sessions)"
fi

# ─── 4. Feature auto-discovery ────────────────────────────

eagle_info "Discovering features from session data..."

feature_data=$(eagle_db "SELECT s.request, s.key_files, s.decisions, s.completed
    FROM summaries s
    WHERE s.project = '$p_esc'
    AND (s.key_files IS NOT NULL AND s.key_files != ''
         OR s.decisions IS NOT NULL AND s.decisions != '')
    ORDER BY s.created_at DESC
    LIMIT 15;")

existing_features=$(eagle_db "SELECT name FROM features WHERE project = '$p_esc' AND status = 'active';")

if [ -n "$feature_data" ]; then
    feature_prompt="Analyze these session summaries from project '$project' and identify distinct FEATURES (user-facing capabilities, not implementation details).

SESSION DATA (request | key_files | decisions | completed):
$feature_data

EXISTING FEATURES (already tracked):
${existing_features:-none}

For each NEW feature discovered (not already in existing list), output EXACTLY:
FEATURE: <name> | <one-line description> | <comma-separated key files>

Rules:
- Feature names should be short, kebab-case (e.g., 'title-generation', 'auth-middleware')
- Only discover features with clear file evidence (at least 2 related files)
- Don't re-discover existing features
- If no new features found, output: NONE"

    feature_result=$(eagle_llm_call "$feature_prompt" "You identify software features from development session data. Be specific and evidence-based." 512 || true)

    if [ -n "$feature_result" ] && ! echo "$feature_result" | grep -q "^NONE$"; then
        features_count=0
        while IFS= read -r line; do
            case "$line" in
                FEATURE:*)
                    feat_data=$(echo "$line" | sed 's/^FEATURE:[[:space:]]*//')
                    IFS='|' read -r fname fdesc ffiles <<< "$feat_data"
                    fname=$(echo "$fname" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    fdesc=$(echo "$fdesc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    ffiles=$(echo "$ffiles" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

                    # Guard: skip malformed lines missing required name
                    if [ -z "$fname" ]; then
                        eagle_log "WARN" "Curator: skipping malformed FEATURE line: $line"
                        continue
                    fi

                    if [ "$DRY_RUN" -eq 1 ]; then
                        eagle_info "  Feature: $fname — $fdesc"
                        eagle_info "    Files: $ffiles"
                    else
                        eagle_upsert_feature "$project" "$fname" "$fdesc"
                        fid=$(eagle_get_feature_id "$project" "$fname")
                        if [ -n "$fid" ] && [ -n "$ffiles" ]; then
                            IFS=',' read -ra file_arr <<< "$ffiles"
                            for f in "${file_arr[@]}"; do
                                f=$(echo "$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                                [ -n "$f" ] && eagle_add_feature_file "$fid" "$f" ""
                            done
                        fi
                        eagle_log "INFO" "Curator: discovered feature: $fname"
                    fi
                    features_count=$((features_count + 1))
                    ;;
            esac
        done <<< "$feature_result"
        eagle_ok "$features_count features discovered"
    else
        eagle_ok "No new features discovered"
    fi
else
    eagle_dim "  Not enough session data for feature discovery"
fi

# ─── 5. Co-edit pattern detection (pure SQL) ─────────────

eagle_info "Analyzing co-edit patterns..."

# Need 3+ sessions with edits — with fewer, every pair trivially co-occurs
edit_sessions=$(eagle_db "SELECT COUNT(DISTINCT session_id) FROM observations
    WHERE project = '$p_esc' AND tool_name IN ('Edit', 'Write');")

co_edit_data=""
if [ "${edit_sessions:-0}" -ge 3 ]; then
    co_edit_data=$(eagle_db "WITH edits AS (
        SELECT session_id,
            CASE tool_name
                WHEN 'Edit' THEN SUBSTR(tool_input_summary, 6)
                WHEN 'Write' THEN SUBSTR(tool_input_summary, 7)
            END as file_path
        FROM observations
        WHERE project = '$p_esc'
        AND tool_name IN ('Edit', 'Write')
        AND tool_input_summary IS NOT NULL
    ),
    file_stats AS (
        SELECT file_path, COUNT(DISTINCT session_id) as edit_sessions
        FROM edits GROUP BY file_path
    ),
    -- Filter files edited in >85% of all edit sessions (like .env — changes with everything)
    noisy_files AS (
        SELECT file_path FROM file_stats
        WHERE CAST(edit_sessions AS REAL) / $edit_sessions > 0.85
    )
    SELECT e1.file_path as f1, e2.file_path as f2,
        COUNT(DISTINCT e1.session_id) as co_sessions
    FROM edits e1
    JOIN edits e2 ON e1.session_id = e2.session_id AND e1.file_path < e2.file_path
    WHERE e1.file_path NOT IN (SELECT file_path FROM noisy_files)
    AND e2.file_path NOT IN (SELECT file_path FROM noisy_files)
    GROUP BY f1, f2
    HAVING co_sessions >= 2
    ORDER BY co_sessions DESC
    LIMIT 30;")
fi

if [ -n "$co_edit_data" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        eagle_info "  Co-edit pairs found:"
    fi

    # Use awk for associative map (Bash 3.2 compatible)
    co_map_output=$(printf '%s\n' "$co_edit_data" | awk -F'|' '
        $1 && $2 {
            m[$1] = (m[$1] ? m[$1] "," : "") $2
            m[$2] = (m[$2] ? m[$2] "," : "") $1
            n++
        }
        END {
            for (f in m) print f "|" m[f]
            print "__co_edit_count__|" n "|" length(m) > "/dev/stderr"
        }
    ' 2>&1 1>/dev/null)
    # stderr has the count line, stdout has the map lines — reverse:
    co_map_output=$(printf '%s\n' "$co_edit_data" | awk -F'|' '
        $1 && $2 {
            m[$1] = (m[$1] ? m[$1] "," : "") $2
            m[$2] = (m[$2] ? m[$2] "," : "") $1
            n++
        }
        END {
            for (f in m) print f "|" m[f]
            printf "%s\n", "__META__|" n "|" length(m) > "/dev/stderr"
        }
    ' 2>/tmp/eagle_co_edit_meta)
    co_edit_count=$(awk -F'|' '{print $2}' /tmp/eagle_co_edit_meta)
    co_map_file_count=$(awk -F'|' '{print $3}' /tmp/eagle_co_edit_meta)
    rm -f /tmp/eagle_co_edit_meta

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "$co_map_output" | while IFS='|' read -r f partners; do
            if [ -z "$f" ]; then continue; fi
            eagle_info "    $(basename "$f") → $partners"
        done
    else
        {
            echo "BEGIN;"
            echo "DELETE FROM file_hints WHERE project = '$(eagle_sql_escape "$project")' AND hint_type = 'co_edit';"
            printf '%s\n' "$co_map_output" | while IFS='|' read -r f partners; do
                if [ -z "$f" ]; then continue; fi
                local_f=$(eagle_sql_escape "$f")
                local_v=$(eagle_sql_escape "$partners")
                echo "INSERT INTO file_hints (project, hint_type, file_path, hint_value) VALUES ('$(eagle_sql_escape "$project")', 'co_edit', '$local_f', '$local_v') ON CONFLICT(project, hint_type, file_path) DO UPDATE SET hint_value = excluded.hint_value, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"
            done
            echo "COMMIT;"
        } | eagle_db_pipe
        _proj_hash=$(printf '%s' "$project" | shasum | cut -c1-8)
        touch "$EAGLE_MEM_DIR/.co-edit-active.${_proj_hash}"
        eagle_log "INFO" "Curator: stored $co_map_file_count co-edit hints from $co_edit_count pairs"
    fi
    eagle_ok "$co_edit_count co-edit pairs found ($co_map_file_count files)"
else
    if [ "$DRY_RUN" -eq 0 ]; then
        eagle_delete_file_hints "$project" "co_edit"
        _proj_hash=$(printf '%s' "$project" | shasum | cut -c1-8)
        rm -f "$EAGLE_MEM_DIR/.co-edit-active.${_proj_hash}"
    fi
    eagle_dim "  Not enough edit data for co-edit detection (need 3+ sessions, have ${edit_sessions:-0})"
fi

# ─── 6. Hot file detection (pure SQL) ────────────────────

eagle_info "Detecting hot files..."

total_sessions=$(eagle_db "SELECT COUNT(DISTINCT session_id) FROM observations
    WHERE project = '$p_esc' AND tool_name = 'Read';")

hot_file_data=""
if [ "${total_sessions:-0}" -ge 3 ]; then
    hot_file_data=$(eagle_db "WITH read_stats AS (
        SELECT
            SUBSTR(tool_input_summary, 6) as file_path,
            COUNT(*) as total_reads,
            COUNT(DISTINCT session_id) as sessions_read
        FROM observations
        WHERE project = '$p_esc'
        AND tool_name = 'Read'
        AND tool_input_summary IS NOT NULL
        GROUP BY file_path
    )
    SELECT file_path, total_reads, sessions_read,
        CAST(total_reads * 1.0 / sessions_read AS INTEGER) as reads_per_session
    FROM read_stats
    WHERE (CAST(sessions_read AS REAL) / $total_sessions > 0.5
           OR total_reads * 1.0 / sessions_read >= 10)
    AND total_reads >= 5
    ORDER BY reads_per_session DESC
    LIMIT 15;")
fi

if [ -n "$hot_file_data" ]; then
    hot_files=""
    hot_count=0

    while IFS='|' read -r hf_path hf_reads hf_sessions hf_rps; do
        if [ -z "$hf_path" ]; then continue; fi
        if [ -n "$hot_files" ]; then
            hot_files+=","
        fi
        hot_files+="$hf_path"
        hot_count=$((hot_count + 1))

        if [ "$DRY_RUN" -eq 1 ]; then
            eagle_info "    $(basename "$hf_path") — ${hf_rps} reads/session, ${hf_sessions}/${total_sessions} sessions"
        fi
    done <<< "$hot_file_data"

    if [ "$DRY_RUN" -eq 0 ] && [ -n "$hot_files" ]; then
        {
            echo "BEGIN;"
            echo "DELETE FROM file_hints WHERE project = '$(eagle_sql_escape "$project")' AND hint_type = 'hot_file';"
            echo "INSERT INTO file_hints (project, hint_type, file_path, hint_value) VALUES ('$(eagle_sql_escape "$project")', 'hot_file', '', '$(eagle_sql_escape "$hot_files")') ON CONFLICT(project, hint_type, file_path) DO UPDATE SET hint_value = excluded.hint_value, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"
            echo "COMMIT;"
        } | eagle_db_pipe
        eagle_log "INFO" "Curator: stored $hot_count hot files"
    fi
    eagle_ok "$hot_count hot files detected"
else
    if [ "$DRY_RUN" -eq 0 ]; then
        eagle_delete_file_hints "$project" "hot_file"
    fi
    eagle_dim "  Not enough session data for hot file detection (need 3+ sessions, have ${total_sessions:-0})"
fi

# ─── 7. Knowledge Graph Wiring & Dream Cycle (Consolidation) ───

eagle_info "Executing Dream Cycle (Knowledge Graph & Memory Consolidation)..."

# 7.1 Wire co-edit edges in the graph
if [ -n "$co_edit_data" ]; then
    co_wire_count=0
    while IFS='|' read -r f1 f2 co_sessions; do
        if [ -z "$f1" ] || [ -z "$f2" ]; then continue; fi
        f1_id=$(eagle_graph_get_node_id "$project" "file" "$f1")
        f2_id=$(eagle_graph_get_node_id "$project" "file" "$f2")
        if [ -n "$f1_id" ] && [ -n "$f2_id" ]; then
            if [ "$DRY_RUN" -eq 0 ]; then
                eagle_graph_add_edge "$project" "$f1_id" "$f2_id" "co_edited" "$co_sessions"
            fi
            co_wire_count=$((co_wire_count + 1))
        fi
    done <<< "$co_edit_data"
    if [ "$DRY_RUN" -eq 1 ]; then
        eagle_info "Would wire $co_wire_count co-edited file edges"
    else
        eagle_ok "Wired $co_wire_count co-edited file edges"
    fi
fi

# 7.2 Wire session nodes and access edges
recent_sessions=$(eagle_db "SELECT id FROM sessions WHERE project = '$p_esc' ORDER BY started_at DESC LIMIT 15;")
if [ -n "$recent_sessions" ]; then
    session_wire_count=$(printf '%s\n' "$recent_sessions" | awk 'NF {count++} END {print count + 0}')
    if [ "$DRY_RUN" -eq 0 ]; then
        session_wire_count=$(eagle_graph_wire_recent_session_edges "$project" 15)
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        eagle_info "Would wire $session_wire_count recent session nodes and edges"
    else
        eagle_ok "Wired $session_wire_count recent session nodes and edges"
    fi
fi

# 7.3 Offline Memory Consolidation (Compiled Truth vs Evidence)
active_memory_rows=$(eagle_db_json "SELECT memory_name, memory_type, description, content FROM agent_memories WHERE project = '$p_esc';" || {
    eagle_log "WARN" "Unable to read active agent memories for consolidation"
    echo "[]"
})
active_memory_count=$(printf '%s' "$active_memory_rows" | jq 'length' 2>/dev/null || echo 0)
if [ "$active_memory_count" -gt 0 ]; then
    wired_memory_count=0
    memory_node_index=0
    while [ "$memory_node_index" -lt "$active_memory_count" ]; do
        mname=$(printf '%s' "$active_memory_rows" | jq -r ".[$memory_node_index].memory_name // empty")
        mcontent=$(printf '%s' "$active_memory_rows" | jq -r ".[$memory_node_index].content // empty")
        memory_node_index=$((memory_node_index + 1))
        [ -n "$mname" ] || continue
        if [ "$DRY_RUN" -eq 0 ]; then
            eagle_graph_add_node "$project" "memory" "$mname" "$mcontent" ""
        fi
        wired_memory_count=$((wired_memory_count + 1))
    done
    if [ "$DRY_RUN" -eq 1 ]; then
        eagle_info "Would wire $wired_memory_count agent memory graph nodes"
    else
        eagle_ok "Wired $wired_memory_count agent memory graph nodes"
    fi

    memory_prompt_json=$(printf '%s' "$active_memory_rows" | jq -c '[.[] | {
        memory_name: .memory_name,
        memory_type: .memory_type,
        description: .description,
        content: .content
    }]')

    if [ "$DRY_RUN" -eq 1 ]; then
        eagle_info "Would analyze $wired_memory_count agent memories for consolidation"
    else
        consolidation_prompt="Analyze these mirrored agent memories for project '$project'. Identify memories that are redundant, overlap in scope, or describe the same subsystem/gotcha/concept.

INPUT_MEMORIES_JSON:
$memory_prompt_json

For any memories that should be consolidated, merge them into a single Compiled Truth summary.
The consolidated memory value MUST be formatted exactly as:
--- Compiled Truth ---
<A structured, clear, up-to-date summary of the topic, gotten by merging the duplicate/overlapping memories. Keep it extremely precise.>

--- Evidence Trail ---
- <Original memory title 1>: <brief original description or timestamp>
- <Original memory title 2>: <brief original description or timestamp>

Return strict JSON only, with this schema:
{
  \"consolidations\": [
    {
      \"source_names\": [\"<exact source memory_name>\", \"<exact source memory_name>\"],
      \"new_name\": \"<new consolidated memory name>\",
      \"description\": \"<new description>\",
      \"value\": \"<the merged compiled truth + evidence content>\"
    }
  ]
}

If no memories need consolidation, return {\"consolidations\":[]}."

        consolidation_result=$(eagle_llm_call "$consolidation_prompt" "You consolidate software development memories into a single compiled truth. Return strict JSON only." 1024 || true)
        if ! parsed_consolidations=$(parse_consolidations_json "$consolidation_result"); then
            eagle_log "WARN" "Unable to parse memory consolidation provider response"
            parsed_consolidations="[]"
        fi

        consolidation_count=$(printf '%s' "$parsed_consolidations" | jq 'length' 2>/dev/null || echo 0)
        if [ "$consolidation_count" -gt 0 ]; then
            cons_count=0
            consolidation_index=0
            while [ "$consolidation_index" -lt "$consolidation_count" ]; do
                consolidation_item=$(printf '%s' "$parsed_consolidations" | jq -c ".[$consolidation_index]")
                consolidation_index=$((consolidation_index + 1))
                new_name=$(printf '%s' "$consolidation_item" | jq -r '.new_name // empty')
                val_part=$(printf '%s' "$consolidation_item" | jq -r '.value // empty')
                [ -n "$new_name" ] || continue

                eagle_graph_add_node "$project" "memory" "$new_name" "$val_part" ""
                new_node_id=$(eagle_graph_get_node_id "$project" "memory" "$new_name")

                old_count=$(printf '%s' "$consolidation_item" | jq '.source_names | length' 2>/dev/null || echo 0)
                old_index=0
                while [ "$old_index" -lt "$old_count" ]; do
                    old_n=$(printf '%s' "$consolidation_item" | jq -r ".source_names[$old_index] // empty")
                    old_index=$((old_index + 1))
                    [ -n "$old_n" ] || continue
                    old_node_id=$(eagle_graph_get_node_id "$project" "memory" "$old_n")
                    if [ -n "$old_node_id" ] && [ -n "$new_node_id" ]; then
                        eagle_graph_add_edge "$project" "$new_node_id" "$old_node_id" "supersedes" 1.0
                    else
                        eagle_log "WARN" "Unable to wire supersedes edge: source='$old_n' consolidated='$new_name'"
                    fi
                done
                cons_count=$((cons_count + 1))
            done
            eagle_ok "Consolidated $cons_count sets of overlapping agent memories"
        else
            eagle_ok "Agent memories are fully consolidated and up to date"
        fi
    fi
else
    eagle_dim "  No active agent memories to consolidate"
fi

# ─── 8. Session compression (--full only) ─────────────────

if [ "$FULL" -eq 1 ]; then
    eagle_info "Compressing old sessions..."

    old_count=$(eagle_db "SELECT COUNT(*) FROM summaries
        WHERE project = '$p_esc'
        AND created_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days');")

    if [ "${old_count:-0}" -gt 10 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            eagle_info "  Would analyze $old_count old sessions for compression"
        else
            eagle_info "  $old_count sessions older than 30 days (compression not yet implemented)"
        fi
    else
        eagle_dim "  Not enough old sessions to compress"
    fi
fi

# ──��� Summary ──────────────────────────────────────────────

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    eagle_footer "Dry run complete. Run without --dry-run to apply changes."
else
    eagle_meta_set "last_curated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$project"
    eagle_footer "Curation complete for '$project'."
fi
