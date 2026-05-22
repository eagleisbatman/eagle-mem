#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Compaction Survival Status
# Shows how well the project is protected against context loss
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

eagle_banner
eagle_header "Compaction Survival"

project=$(eagle_project_from_cwd "$(pwd)")
project_sql=$(eagle_sql_escape "$project")

# --- Metrics ---
enriched=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project='$project_sql' AND (learned != '' OR decisions != '' OR gotchas != '')" 2>/dev/null || echo 0)
total_summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project='$project_sql'" 2>/dev/null || echo 0)
active_tasks=$(eagle_db "SELECT COUNT(*) FROM agent_tasks WHERE project='$project_sql' AND status IN ('pending','in_progress')" 2>/dev/null || echo 0)
stale_tasks=$(eagle_db "SELECT COUNT(*) FROM agent_tasks WHERE project='$project_sql' AND status='in_progress' AND updated_at < datetime('now','-7 days')" 2>/dev/null || echo 0)
last_capture=$(eagle_db "SELECT MAX(updated_at) FROM agent_tasks WHERE project='$project_sql'" 2>/dev/null || echo "never")

echo ""
echo -e "  Project: ${BOLD}$project${RESET}"
echo ""

echo -e "  ${BOLD}Context Survival Metrics${RESET}"
echo -e "  ─────────────────────────────────────"
echo -e "  Enriched summaries:     ${GREEN}$enriched${RESET} / $total_summaries"
echo -e "  Active durable tasks:   ${CYAN}$active_tasks${RESET}"
echo -e "  Stale in_progress tasks:${RED}$stale_tasks${RESET}"
echo -e "  Last durable update:    $last_capture"

echo ""
if [ "$stale_tasks" -gt 0 ]; then
    eagle_warn "Stale tasks detected — run 'eagle-mem tasks stale' and clean them up"
else
    eagle_ok "No long-stale tasks"
fi

# Orchestration lanes (for cross-agent long-running work survival)
active_lanes=$(eagle_db "SELECT COUNT(*) FROM orchestration_lanes WHERE project='$project_sql' AND status NOT IN ('completed', 'cancelled')" 2>/dev/null || echo 0)
echo -e "  Active orchestration lanes: ${CYAN}$active_lanes${RESET}"
if [ "$active_lanes" -gt 0 ]; then
    eagle_info "Long-running work is tracked in durable lanes — use 'eagle-mem orchestrate' to manage"
fi

if [ "$enriched" -ge 3 ] && [ "$active_tasks" -gt 0 ]; then
    eagle_ok "Compaction Survival: Strong — future sessions will have good context"
elif [ "$enriched" -ge 1 ]; then
    eagle_info "Compaction Survival: Moderate — add more durable tasks and summaries"
else
    eagle_warn "Compaction Survival: Weak — start using durable tasks and <eagle-summary> blocks"
fi

echo ""
eagle_dim "Run this anytime to check how safe the project is from /compact amnesia."
echo ""