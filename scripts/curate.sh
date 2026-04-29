#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Curator
# Self-learning engine that analyzes sessions and generates:
# 1. Promoted gotchas → persistent memories
# 2. Superseded decision detection
# 3. Command compression rules
# 4. Feature auto-discovery
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
    # Get specific noisy commands
    noisy_commands=$(eagle_db "SELECT tool_input_summary,
        COUNT(*) as count,
        CAST(AVG(output_bytes) AS INTEGER) as avg_bytes,
        CAST(AVG(output_lines) AS INTEGER) as avg_lines
        FROM observations
        WHERE project = '$p_esc'
        AND tool_name = 'Bash'
        AND output_bytes > 1000
        GROUP BY tool_input_summary
        HAVING count >= 3
        ORDER BY avg_bytes DESC
        LIMIT 15;")

    if [ -n "$noisy_commands" ]; then
        cmd_prompt="Analyze these frequently-run commands and their output sizes for project '$project'. Suggest compression rules for commands that produce consistently large output.

COMMAND STATS (command | times_run | avg_output_bytes | avg_output_lines):
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

# ─── 5. Session compression (--full only) ─────────────────

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
