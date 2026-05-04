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
. "$LIB_DIR/updater.sh"

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

eagle_ensure_db

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
heuristic_summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project = '$p_esc' AND (decisions IS NULL OR decisions = '') AND (gotchas IS NULL OR gotchas = '');")
enriched_summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project = '$p_esc' AND (decisions IS NOT NULL AND decisions != '' OR gotchas IS NOT NULL AND gotchas != '');")

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
        eagle_ok "Enriched: ${enriched_summaries}/${total_summaries} (${enrich_pct}%) have decisions/gotchas"
        score=$((score + 25))
    elif [ "$enrich_pct" -ge 20 ]; then
        eagle_warn "Enriched: ${enriched_summaries}/${total_summaries} (${enrich_pct}%) — LLM extraction may need tuning"
        score=$((score + 12))
        issues+=("Low enrichment (${enrich_pct}%). Check LLM provider is responsive: eagle-mem config")
    elif [ "${enriched_summaries:-0}" -gt 0 ]; then
        eagle_fail "Enriched: ${enriched_summaries}/${total_summaries} (${enrich_pct}%)"
        score=$((score + 5))
        issues+=("${enrich_pct}% enrichment. Decisions/gotchas mostly missing.")
    else
        eagle_fail "Enriched: 0/${total_summaries} — no summaries have decisions/gotchas"
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
    if [ "$provider" = "agent_cli" ]; then
        model=$(_eagle_agent_cli_target)
    else
        model=$(eagle_config_get "$provider" "model" "default")
    fi
    eagle_ok "Provider: ${provider} (${model})"
    score=$((score + 15))
else
    eagle_fail "No LLM provider — curator and enrichment disabled"
    issues+=("Configure a provider: eagle-mem config init")
fi

# ─── Token guard visibility (informational) ────────────────

rtk_mode=$(eagle_config_get "token_guard" "rtk" "auto")
raw_bash_mode=$(eagle_config_get "token_guard" "raw_bash" "block")
rtk_bin=$(command -v rtk 2>/dev/null || true)
if [ -n "$rtk_bin" ]; then
    eagle_ok "Token guard: RTK $rtk_mode (${rtk_bin}), raw_bash=$raw_bash_mode"
elif [ "$rtk_mode" = "enforce" ]; then
    eagle_fail "Token guard: RTK enforce enabled, but rtk not found"
    issues+=("Install RTK or run: eagle-mem config set token_guard.rtk auto")
else
    eagle_dim "  Token guard: RTK not found (mode: $rtk_mode, raw_bash: $raw_bash_mode)"
fi

# ─── Orchestration visibility (informational) ───────────────

orch_route=$(eagle_config_get "orchestration" "route" "opposite")
orch_auto_worktree=$(eagle_config_get "orchestration" "auto_worktree" "true")
orch_worktree_root=$(eagle_config_get "orchestration" "worktree_root" "")
orch_codex_model=$(eagle_config_get "orchestration" "codex_worker_model" "gpt-5.5")
orch_codex_effort=$(eagle_config_get "orchestration" "codex_worker_effort" "xhigh")
orch_claude_model=$(eagle_config_get "orchestration" "claude_worker_model" "claude-opus-4-7")
orch_claude_effort=$(eagle_config_get "orchestration" "claude_worker_effort" "xhigh")
codex_bin=$(command -v codex 2>/dev/null || true)
claude_bin=$(command -v claude 2>/dev/null || true)

if [ -n "$codex_bin" ] && [ -n "$claude_bin" ]; then
    eagle_ok "Orchestration: route=$orch_route, worktrees=$orch_auto_worktree, Codex + Claude workers available"
elif [ -n "$codex_bin" ]; then
    eagle_warn "Orchestration: Codex available, Claude CLI missing"
    issues+=("Install or authenticate Claude Code CLI before spawning Claude worker lanes.")
elif [ -n "$claude_bin" ]; then
    eagle_warn "Orchestration: Claude available, Codex CLI missing"
    issues+=("Install or authenticate Codex CLI before spawning Codex worker lanes.")
else
    eagle_warn "Orchestration: worker CLIs not found"
    issues+=("Install/authenticate Codex and Claude Code CLIs before using eagle-mem orchestrate spawn.")
fi

eagle_dim "  Workers: codex=${orch_codex_model}/${orch_codex_effort}, claude-code=${orch_claude_model}/${orch_claude_effort}"
if [ -n "$orch_worktree_root" ]; then
    eagle_dim "  Worktree root: $orch_worktree_root"
fi

# ─── Auto-update visibility (informational) ────────────────

updates_mode=$(eagle_update_config_mode)
updates_allow=$(eagle_update_config_allow)
updates_channel=$(eagle_update_config_channel)
updates_interval=$(eagle_update_config_interval_hours)
updates_latest=$(eagle_update_latest_version 0 2>/dev/null || true)
updates_installed=$(eagle_update_installed_version)
updates_status="current"

if [ "$updates_mode" = "off" ]; then
    eagle_warn "Updates: disabled"
    issues+=("Auto-updates disabled. Re-enable bug-fix delivery: eagle-mem updates enable patch")
    updates_status="disabled"
elif [ -n "$updates_latest" ] && eagle_update_version_gt "$updates_latest" "$updates_installed"; then
    if eagle_update_allowed "$updates_installed" "$updates_latest" "$updates_allow"; then
        eagle_warn "Updates: v${updates_latest} available (mode=$updates_mode, allow=$updates_allow)"
        updates_status="available"
    else
        eagle_warn "Updates: v${updates_latest} available, outside $updates_allow range"
        updates_status="outside-range"
    fi
else
    eagle_ok "Updates: auto/${updates_allow} (${updates_channel}, every ${updates_interval}h)"
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
        --arg token_guard_rtk "$rtk_mode" \
        --arg token_guard_raw_bash "$raw_bash_mode" \
        --arg rtk_bin "${rtk_bin:-}" \
        --arg orchestration_route "$orch_route" \
        --arg orchestration_auto_worktree "$orch_auto_worktree" \
        --arg orchestration_worktree_root "$orch_worktree_root" \
        --arg codex_worker_model "$orch_codex_model" \
        --arg codex_worker_effort "$orch_codex_effort" \
        --arg claude_worker_model "$orch_claude_model" \
        --arg claude_worker_effort "$orch_claude_effort" \
        --arg codex_bin "${codex_bin:-}" \
        --arg claude_bin "${claude_bin:-}" \
        --arg updates_mode "$updates_mode" \
        --arg updates_allow "$updates_allow" \
        --arg updates_channel "$updates_channel" \
        --arg updates_interval "$updates_interval" \
        --arg updates_installed "$updates_installed" \
        --arg updates_latest "${updates_latest:-}" \
        --arg updates_status "$updates_status" \
        --argjson noise_pct "$noise_pct" \
        --arg last_curated "${last_curated:-never}" \
        '{project:$project, score:$score, max:$max_score, pct:$pct, grade:$grade,
          capture:{sessions:$total_sessions, summaries:$total_summaries, heuristic:$heuristic_summaries},
          enrichment:$enriched_summaries,
          features:$features, provider:$provider,
          token_guard:{rtk:$token_guard_rtk, raw_bash:$token_guard_raw_bash, rtk_bin:$rtk_bin},
          orchestration:{
            route:$orchestration_route,
            auto_worktree:$orchestration_auto_worktree,
            worktree_root:$orchestration_worktree_root,
            codex:{model:$codex_worker_model, effort:$codex_worker_effort, cli:$codex_bin},
            claude_code:{model:$claude_worker_model, effort:$claude_worker_effort, cli:$claude_bin}
          },
          updates:{
            mode:$updates_mode,
            allow:$updates_allow,
            channel:$updates_channel,
            interval_hours:$updates_interval,
            installed:$updates_installed,
            latest:$updates_latest,
            status:$updates_status
          },
          noise_pct:$noise_pct, last_curated:$last_curated}' >&3
fi
