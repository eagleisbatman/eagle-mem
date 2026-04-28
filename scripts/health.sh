#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Health Check
# Diagnoses how well the self-learning pipeline is working
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$SCRIPT_DIR/style.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/provider.sh"

eagle_header "Health Check"

project=""
JSON_OUT=0

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project) project="$2"; shift 2 ;;
        -j|--json) JSON_OUT=1; shift ;;
        *) shift ;;
    esac
done

if [ -z "$project" ]; then
    project=$(eagle_project_from_cwd "$(pwd)")
fi

if [ -z "$project" ]; then
    eagle_err "Cannot determine project (ephemeral directory). Use -p <project>."
    exit 1
fi

p_esc=$(eagle_sql_escape "$project")

eagle_info "Project: ${BOLD}$project${RESET}"
echo ""

score=0
max_score=0
issues=()

# ─── 1. Summary enrichment rate ──────────────────────────

max_score=$((max_score + 30))

total_summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project = '$p_esc';")
enriched_summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project = '$p_esc' AND (decisions IS NOT NULL AND decisions != '' OR gotchas IS NOT NULL AND gotchas != '' OR key_files IS NOT NULL AND key_files != '');")

if [ "${total_summaries:-0}" -eq 0 ]; then
    enrich_pct=0
else
    enrich_pct=$((enriched_summaries * 100 / total_summaries))
fi

if [ "$enrich_pct" -ge 50 ]; then
    eagle_ok "Enriched summaries: ${enriched_summaries}/${total_summaries} (${enrich_pct}%)"
    score=$((score + 30))
elif [ "$enrich_pct" -ge 20 ]; then
    eagle_warn "Enriched summaries: ${enriched_summaries}/${total_summaries} (${enrich_pct}%) — aim for 50%+"
    score=$((score + 15))
    issues+=("Low enrichment rate (${enrich_pct}%). Eagle-summary blocks aren't being emitted reliably.")
elif [ "${total_summaries:-0}" -gt 0 ]; then
    eagle_fail "Enriched summaries: ${enriched_summaries}/${total_summaries} (${enrich_pct}%) — self-learning not working"
    issues+=("Critical: ${enrich_pct}% enrichment. Decisions/gotchas/key_files are not being captured.")
else
    eagle_dim "  No summaries yet"
fi

# ─── 2. Feature discovery ────────────────────────────────

max_score=$((max_score + 20))

feature_count=$(eagle_db "SELECT COUNT(*) FROM features WHERE project = '$p_esc' AND status = 'active';")
feature_file_count=$(eagle_db "SELECT COUNT(*) FROM feature_files ff JOIN features f ON ff.feature_id = f.id WHERE f.project = '$p_esc' AND f.status = 'active';")

if [ "${feature_count:-0}" -ge 3 ]; then
    eagle_ok "Features tracked: ${feature_count} (${feature_file_count} files mapped)"
    score=$((score + 20))
elif [ "${feature_count:-0}" -ge 1 ]; then
    eagle_warn "Features tracked: ${feature_count} — curator needs more sessions"
    score=$((score + 10))
    issues+=("Only ${feature_count} features discovered. Run curator more often.")
else
    eagle_fail "Features tracked: 0 — feature graph is empty"
    issues+=("No features discovered. Run: eagle-mem curate")
fi

# ─── 3. Command intelligence ─────────────────────────────

max_score=$((max_score + 15))

rule_count=$(eagle_db "SELECT COUNT(*) FROM command_rules WHERE (project = '$p_esc' OR project IS NULL) AND enabled = 1;")
obs_with_metrics=$(eagle_db "SELECT COUNT(*) FROM observations WHERE project = '$p_esc' AND tool_name = 'Bash' AND output_bytes IS NOT NULL AND output_bytes > 0;")

if [ "${rule_count:-0}" -ge 2 ]; then
    eagle_ok "Command rules: ${rule_count} active (${obs_with_metrics} observations with metrics)"
    score=$((score + 15))
elif [ "${rule_count:-0}" -ge 1 ]; then
    eagle_warn "Command rules: ${rule_count} — learning in progress"
    score=$((score + 8))
elif [ "${obs_with_metrics:-0}" -gt 20 ]; then
    eagle_fail "Command rules: 0 (but ${obs_with_metrics} observations available — run curator)"
    issues+=("Command metrics collected but no rules generated yet.")
else
    eagle_dim "  Command metrics: ${obs_with_metrics} observations (need more data)"
    score=$((score + 5))
fi

# ─── 4. Provider configured ──────────────────────────────

max_score=$((max_score + 15))

provider=$(eagle_config_get "provider" "type" "none")
if [ "$provider" != "none" ]; then
    model=$(eagle_config_get "$provider" "model" "default")
    eagle_ok "LLM provider: ${provider} (${model})"
    score=$((score + 15))
else
    eagle_fail "No LLM provider — curator and enrichment extraction disabled"
    issues+=("Configure a provider: eagle-mem config init")
fi

# ─── 5. Project data quality ─────────────────────────────

max_score=$((max_score + 10))

tmp_sessions=$(eagle_db "SELECT COUNT(*) FROM sessions WHERE project IN ('tmp', 'private', '');")
total_sessions=$(eagle_db "SELECT COUNT(*) FROM sessions;")

if [ "${total_sessions:-0}" -eq 0 ]; then
    noise_pct=0
else
    noise_pct=$((tmp_sessions * 100 / total_sessions))
fi

if [ "$noise_pct" -le 5 ]; then
    eagle_ok "Data quality: ${tmp_sessions} ephemeral sessions (${noise_pct}% noise)"
    score=$((score + 10))
elif [ "$noise_pct" -le 20 ]; then
    eagle_warn "Data quality: ${tmp_sessions} ephemeral sessions (${noise_pct}% noise)"
    score=$((score + 5))
    issues+=("${noise_pct}% of sessions from ephemeral dirs. Skiplist should prevent new ones.")
else
    eagle_fail "Data quality: ${noise_pct}% noise — ${tmp_sessions}/${total_sessions} sessions from ephemeral dirs"
    issues+=("Heavy ephemeral pollution. Update Eagle Mem to get skiplist protection.")
fi

# ─── 6. Curator activity ─────────────────────────────────

max_score=$((max_score + 10))

curator_schedule=$(eagle_config_get "curator" "schedule" "manual")
last_curated=$(eagle_db "SELECT value FROM eagle_meta WHERE key = 'last_curated_at' AND (project = '$p_esc' OR project IS NULL) ORDER BY CASE WHEN project IS NOT NULL THEN 0 ELSE 1 END LIMIT 1;" 2>/dev/null || echo "")

if [ -n "$last_curated" ]; then
    eagle_ok "Curator: last run ${last_curated} (schedule: ${curator_schedule})"
    score=$((score + 10))
elif [ "$curator_schedule" = "auto" ]; then
    eagle_warn "Curator: auto-scheduled but hasn't run yet"
    score=$((score + 5))
    issues+=("Auto-curate is configured but hasn't run. It triggers at session end.")
else
    eagle_fail "Curator: never run (schedule: ${curator_schedule})"
    issues+=("Curator has never run. Try: eagle-mem curate --dry-run")
fi

# ─── Score ────────────────────────────────────────────────

echo ""
echo -e "  ${DIM}─────────────────────────────────────${RESET}"

pct=$((score * 100 / max_score))
if [ "$pct" -ge 80 ]; then
    color="$GREEN"
    grade="Healthy"
elif [ "$pct" -ge 50 ]; then
    color="$YELLOW"
    grade="Needs attention"
else
    color="$RED"
    grade="Unhealthy"
fi

echo -e "  ${BOLD}Score: ${color}${score}/${max_score} (${pct}%)${RESET}  ${color}${grade}${RESET}"

if [ ${#issues[@]} -gt 0 ]; then
    echo ""
    echo -e "  ${BOLD}Issues:${RESET}"
    for issue in "${issues[@]}"; do
        echo -e "    ${YELLOW}!${RESET} $issue"
    done
fi

eagle_footer "Health check complete."

if [ "$JSON_OUT" -eq 1 ]; then
    jq -nc \
        --arg project "$project" \
        --argjson score "$score" \
        --argjson max_score "$max_score" \
        --argjson pct "$pct" \
        --arg grade "$grade" \
        --argjson total_summaries "${total_summaries:-0}" \
        --argjson enriched_summaries "${enriched_summaries:-0}" \
        --argjson features "${feature_count:-0}" \
        --argjson command_rules "${rule_count:-0}" \
        --arg provider "$provider" \
        --argjson noise_pct "$noise_pct" \
        '{project:$project, score:$score, max:$max_score, pct:$pct, grade:$grade,
          enrichment:{total:$total_summaries, enriched:$enriched_summaries},
          features:$features, command_rules:$command_rules,
          provider:$provider, noise_pct:$noise_pct}'
fi
