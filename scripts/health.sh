#!/usr/bin/env bash
# ════════��══════════��═══════════════════════════════════════
# Eagle Mem — Health Check
# Diagnoses how well the self-learning pipeline is working
# ════════���══════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$SCRIPT_DIR/style.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/provider.sh"

project=""
JSON_OUT=0

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project) project="$2"; shift 2 ;;
        -j|--json) JSON_OUT=1; shift ;;
        *) shift ;;
    esac
done

if [ "$JSON_OUT" -eq 1 ]; then
    exec 3>&1 1>&2
fi

eagle_header "Health Check"

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

# ─��─ 1. Summary capture rate (25 pts) ───────────────────

max_score=$((max_score + 25))

total_sessions=$(eagle_db "SELECT COUNT(*) FROM sessions WHERE project = '$p_esc';")
total_summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project = '$p_esc';")
heuristic_summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project = '$p_esc' AND completed = '(auto-captured)';")
enriched_summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project = '$p_esc' AND (decisions IS NOT NULL AND decisions != '' OR gotchas IS NOT NULL AND gotchas != '' OR key_files IS NOT NULL AND key_files != '');")

if [ "${total_sessions:-0}" -eq 0 ]; then
    capture_pct=0
else
    capture_pct=$((total_summaries * 100 / total_sessions))
fi

model_summaries=$((total_summaries - heuristic_summaries))

if [ "${total_summaries:-0}" -gt 0 ]; then
    if [ "$capture_pct" -ge 50 ]; then
        eagle_ok "Capture: ${total_summaries}/${total_sessions} sessions (${capture_pct}%) — ${model_summaries} from model, ${heuristic_summaries} heuristic"
        score=$((score + 25))
    elif [ "$capture_pct" -ge 20 ]; then
        eagle_warn "Capture: ${total_summaries}/${total_sessions} sessions (${capture_pct}%) — ${heuristic_summaries} heuristic"
        score=$((score + 15))
    else
        eagle_fail "Capture: ${total_summaries}/${total_sessions} sessions (${capture_pct}%)"
        score=$((score + 5))
    fi
else
    eagle_dim "  No summaries yet"
fi

# ─── 2. Enrichment rate (25 pts) ────────────────────────

max_score=$((max_score + 25))

if [ "${total_summaries:-0}" -eq 0 ]; then
    enrich_pct=0
else
    enrich_pct=$((enriched_summaries * 100 / total_summaries))
fi

if [ "${total_summaries:-0}" -gt 0 ]; then
    if [ "$enrich_pct" -ge 50 ]; then
        eagle_ok "Enriched: ${enriched_summaries}/${total_summaries} (${enrich_pct}%) have decisions/gotchas/key_files"
        score=$((score + 25))
    elif [ "$enrich_pct" -ge 20 ]; then
        eagle_warn "Enriched: ${enriched_summaries}/${total_summaries} (${enrich_pct}%) — LLM extraction may need tuning"
        score=$((score + 12))
        issues+=("Low enrichment (${enrich_pct}%). Check LLM provider is responsive: eagle-mem config")
    elif [ "${enriched_summaries:-0}" -gt 0 ]; then
        eagle_fail "Enriched: ${enriched_summaries}/${total_summaries} (${enrich_pct}%)"
        score=$((score + 5))
        issues+=("${enrich_pct}% enrichment. Decisions/gotchas/key_files mostly missing.")
    else
        eagle_fail "Enriched: 0/${total_summaries} — no summaries have decisions/gotchas/key_files"
        issues+=("Zero enrichment. Check provider config: eagle-mem config")
    fi
else
    eagle_dim "  No summaries to enrich"
fi

# ─── 3. Feature discovery (15 pts) ─────────────────────

max_score=$((max_score + 15))

feature_count=$(eagle_db "SELECT COUNT(*) FROM features WHERE project = '$p_esc' AND status = 'active';")

if [ "${feature_count:-0}" -ge 3 ]; then
    eagle_ok "Features: ${feature_count} tracked"
    score=$((score + 15))
elif [ "${feature_count:-0}" -ge 1 ]; then
    eagle_warn "Features: ${feature_count} — curator needs more sessions"
    score=$((score + 8))
else
    eagle_fail "Features: 0 — run: eagle-mem curate"
    issues+=("No features discovered. Run: eagle-mem curate")
fi

# ─── 4. Provider configured (15 pts) ───────────────────

max_score=$((max_score + 15))

provider=$(eagle_config_get "provider" "type" "none")
if [ "$provider" != "none" ]; then
    model=$(eagle_config_get "$provider" "model" "default")
    eagle_ok "Provider: ${provider} (${model})"
    score=$((score + 15))
else
    eagle_fail "No LLM provider — curator and enrichment disabled"
    issues+=("Configure a provider: eagle-mem config init")
fi

# ─── 5. Data quality (10 pts) ──────────────────────────

max_score=$((max_score + 10))

# Count noise: ephemeral projects + single-char project names
noise_sessions=$(eagle_db "SELECT COUNT(*) FROM sessions WHERE project IN ('tmp', 'private', '', 'T') OR LENGTH(project) <= 1;")
all_sessions=$(eagle_db "SELECT COUNT(*) FROM sessions;")

if [ "${all_sessions:-0}" -eq 0 ]; then
    noise_pct=0
else
    noise_pct=$((noise_sessions * 100 / all_sessions))
fi

if [ "$noise_pct" -le 5 ]; then
    eagle_ok "Data quality: ${noise_pct}% noise (${noise_sessions} ephemeral sessions)"
    score=$((score + 10))
elif [ "$noise_pct" -le 20 ]; then
    eagle_warn "Data quality: ${noise_pct}% noise (${noise_sessions}/${all_sessions})"
    score=$((score + 5))
    issues+=("${noise_pct}% noise. Skiplist prevents new pollution; prune old: eagle-mem prune")
else
    eagle_fail "Data quality: ${noise_pct}% noise (${noise_sessions}/${all_sessions})"
    issues+=("Heavy noise. Run: eagle-mem prune to clean ephemeral data.")
fi

# ─── 6. Curator activity (10 pts) ──────────────────────

max_score=$((max_score + 10))

curator_schedule=$(eagle_config_get "curator" "schedule" "manual")
last_curated=$(eagle_db "SELECT value FROM eagle_meta WHERE key = 'last_curated_at' AND project = '$p_esc' LIMIT 1;" 2>/dev/null || echo "")

if [ -n "$last_curated" ]; then
    eagle_ok "Curator: last run ${last_curated} (schedule: ${curator_schedule})"
    score=$((score + 10))
elif [ "$curator_schedule" = "auto" ]; then
    eagle_warn "Curator: auto-scheduled, hasn't run yet (triggers on session start)"
    score=$((score + 5))
    issues+=("Auto-curate configured but hasn't fired. Needs ${_min_sessions:-5}+ sessions since last run.")
else
    eagle_fail "Curator: never run (schedule: ${curator_schedule})"
    issues+=("Run: eagle-mem curate --dry-run")
fi

# ─── Score ───────���────────────────────────────────────────

echo ""
echo -e "  ${DIM}────���────────────────────────────────${RESET}"

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
        --argjson total_sessions "${total_sessions:-0}" \
        --argjson total_summaries "${total_summaries:-0}" \
        --argjson heuristic_summaries "${heuristic_summaries:-0}" \
        --argjson enriched_summaries "${enriched_summaries:-0}" \
        --argjson features "${feature_count:-0}" \
        --arg provider "$provider" \
        --argjson noise_pct "$noise_pct" \
        --arg last_curated "${last_curated:-never}" \
        '{project:$project, score:$score, max:$max_score, pct:$pct, grade:$grade,
          capture:{sessions:$total_sessions, summaries:$total_summaries, heuristic:$heuristic_summaries},
          enrichment:$enriched_summaries,
          features:$features, provider:$provider,
          noise_pct:$noise_pct, last_curated:$last_curated}' >&3
fi
