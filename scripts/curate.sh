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

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --full) FULL=1; shift ;;
        -p|--project) project="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$project" ]; then
    project=$(eagle_project_from_cwd "$(pwd)")
fi

p_esc=$(eagle_sql_escape "$project")

# Verify provider is configured
provider=$(eagle_config_get "provider" "type" "none")
if [ "$provider" = "none" ]; then
    eagle_err "No LLM provider configured. Run: eagle-mem config init"
    exit 1
fi
eagle_info "Provider: $provider ($(eagle_config_get "$provider" "model" "unknown"))"
eagle_info "Project: $project"
[ "$DRY_RUN" -eq 1 ] && eagle_info "Dry run — no changes will be made"
echo ""

# ─── 1. Analyze gotchas for promotion ─────────────────────

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

    gotcha_result=$(eagle_llm_call "$gotcha_prompt" "You analyze software development patterns. Be concise. Only output PROMOTE lines or NONE." 512)

    if [ -n "$gotcha_result" ] && ! echo "$gotcha_result" | grep -q "^NONE$"; then
        promoted=0
        while IFS= read -r line; do
            case "$line" in
                PROMOTE:*)
                    gotcha_text=$(echo "$line" | sed 's/^PROMOTE:[[:space:]]*//')
                    if [ "$DRY_RUN" -eq 1 ]; then
                        eagle_info "  Would promote: $gotcha_text"
                    else
                        eagle_log "INFO" "Curator: promoting gotcha: $gotcha_text"
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

    decision_result=$(eagle_llm_call "$decision_prompt" "You detect contradicting software decisions. Be precise." 512)

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

        cmd_result=$(eagle_llm_call "$cmd_prompt" "You optimize CLI output for AI assistants. Be conservative — only suggest rules for genuinely noisy commands." 512)

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

                            eagle_db "INSERT INTO command_rules (project, pattern, strategy, max_lines, reason)
                                VALUES ('$p_esc', '$pattern_esc', '$strategy', $ml_val, '$reason_esc')
                                ON CONFLICT(project, pattern) DO UPDATE SET
                                    strategy = excluded.strategy,
                                    max_lines = excluded.max_lines,
                                    reason = excluded.reason,
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

    feature_result=$(eagle_llm_call "$feature_prompt" "You identify software features from development session data. Be specific and evidence-based." 512)

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

    co_edit_count=0
    declare -A co_map

    while IFS='|' read -r f1 f2 co_sessions; do
        [ -z "$f1" ] || [ -z "$f2" ] && continue

        # Build comma-separated partner list per file (both directions)
        if [ -n "${co_map[$f1]+x}" ]; then
            co_map[$f1]="${co_map[$f1]},$f2"
        else
            co_map[$f1]="$f2"
        fi
        if [ -n "${co_map[$f2]+x}" ]; then
            co_map[$f2]="${co_map[$f2]},$f1"
        else
            co_map[$f2]="$f1"
        fi
        co_edit_count=$((co_edit_count + 1))
    done <<< "$co_edit_data"

    if [ "$DRY_RUN" -eq 1 ]; then
        for f in "${!co_map[@]}"; do
            eagle_info "    $(basename "$f") → ${co_map[$f]}"
        done
    else
        {
            echo "BEGIN;"
            echo "DELETE FROM file_hints WHERE project = '$(eagle_sql_escape "$project")' AND hint_type = 'co_edit';"
            for f in "${!co_map[@]}"; do
                local_f=$(eagle_sql_escape "$f")
                local_v=$(eagle_sql_escape "${co_map[$f]}")
                echo "INSERT INTO file_hints (project, hint_type, file_path, hint_value) VALUES ('$(eagle_sql_escape "$project")', 'co_edit', '$local_f', '$local_v') ON CONFLICT(project, hint_type, file_path) DO UPDATE SET hint_value = excluded.hint_value, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');"
            done
            echo "COMMIT;"
        } | eagle_db_pipe
        _proj_hash=$(printf '%s' "$project" | shasum | cut -c1-8)
        touch "$EAGLE_MEM_DIR/.co-edit-active.${_proj_hash}"
        eagle_log "INFO" "Curator: stored ${#co_map[@]} co-edit hints from $co_edit_count pairs"
    fi
    eagle_ok "$co_edit_count co-edit pairs found (${#co_map[@]} files)"
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
        [ -z "$hf_path" ] && continue
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

# ─── 7. Session compression (--full only) ─────────────────

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
