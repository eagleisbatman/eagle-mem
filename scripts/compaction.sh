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

json_output=false
project=""

while [ $# -gt 0 ]; do
    case "$1" in
        --json|-j) json_output=true; shift ;;
        --project|-p) project="$2"; shift 2 ;;
        --help|-h)
            echo -e "  ${BOLD}eagle-mem compaction${RESET} — Compaction Survival status"
            echo ""
            echo -e "  ${BOLD}Usage:${RESET}"
            echo -e "    eagle-mem compaction"
            echo -e "    eagle-mem compaction --json"
            echo -e "    eagle-mem compaction --project <project>"
            exit 0
            ;;
        *) shift ;;
    esac
done

compaction_fail() {
    local error_code="$1"
    local message="$2"
    local db_status="${3:-unknown}"
    local db_detail="${4:-}"

    if [ "$json_output" = true ]; then
        jq -nc \
            --arg status "error" \
            --arg command "compaction" \
            --arg error "$error_code" \
            --arg message "$message" \
            --arg project "${project:-}" \
            --arg db_status "$db_status" \
            --arg db_detail "$db_detail" \
            '{status:$status, command:$command, error:$error, message:$message,
              project:$project, database:{integrity:{status:$db_status, detail:$db_detail}}}'
    else
        eagle_fail "$message"
        [ -n "$db_detail" ] && eagle_dim "  $db_detail"
    fi
    exit 1
}

if [ -z "$project" ]; then
    project=$(eagle_project_from_cwd "$(pwd)")
fi
project_sql=$(eagle_sql_escape "$project")

if ! eagle_ensure_db; then
    compaction_fail "database_unavailable" "Database is unavailable; SQLite/FTS5 setup failed." "unavailable" "eagle_ensure_db failed"
fi

db_integrity_check=$(eagle_db_integrity_status "$EAGLE_MEM_DB" 2>/dev/null || true)
db_integrity_status="${db_integrity_check%%|*}"
db_integrity_detail="${db_integrity_check#*|}"
[ -n "$db_integrity_status" ] || db_integrity_status="unknown"
[ -n "$db_integrity_detail" ] || db_integrity_detail="not checked"
if [ "$db_integrity_status" != "ok" ]; then
    compaction_fail "database_integrity" "Database integrity check failed; compaction state is unavailable." "$db_integrity_status" "$db_integrity_detail"
fi

# --- Metrics ---
enriched=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project='$project_sql' AND (learned != '' OR decisions != '' OR gotchas != '')" 2>/dev/null || echo 0)
total_summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project='$project_sql'" 2>/dev/null || echo 0)
active_tasks=$(eagle_db "SELECT COUNT(*) FROM agent_tasks WHERE project='$project_sql' AND status IN ('pending','in_progress')" 2>/dev/null || echo 0)
stale_tasks=$(eagle_db "SELECT COUNT(*) FROM agent_tasks WHERE project='$project_sql' AND status='in_progress' AND updated_at < datetime('now','-7 days')" 2>/dev/null || echo 0)
durable_memories=$(eagle_db "SELECT COUNT(*) FROM agent_memories WHERE project='$project_sql'" 2>/dev/null || echo 0)
active_features=$(eagle_db "SELECT COUNT(*) FROM features WHERE project='$project_sql' AND status='active'" 2>/dev/null || echo 0)
recall_events=$(eagle_db "SELECT COUNT(*) FROM recall_events WHERE project='$project_sql'" 2>/dev/null || echo 0)
semantic_graph_nodes=$(eagle_db "SELECT COUNT(*) FROM graph_nodes WHERE project='$project_sql' AND node_type IN ('feature','memory','task','session','decision')" 2>/dev/null || echo 0)
last_capture=$(eagle_db "SELECT MAX(updated_at) FROM agent_tasks WHERE project='$project_sql'" 2>/dev/null || echo "never")
active_lanes=$(eagle_db "SELECT COUNT(*) FROM orchestration_lanes WHERE project='$project_sql' AND status NOT IN ('completed', 'cancelled')" 2>/dev/null || echo 0)

readiness="weak"
if [ "$enriched" -ge 3 ] && [ "$active_tasks" -gt 0 ]; then
    readiness="strong"
elif [ "$enriched" -ge 1 ]; then
    readiness="moderate"
fi

if [ "$json_output" = true ]; then
    jq -nc \
        --arg status "ok" \
        --arg project "$project" \
        --arg db_integrity_status "$db_integrity_status" \
        --arg db_integrity_detail "$db_integrity_detail" \
        --argjson enriched "${enriched:-0}" \
        --argjson total_summaries "${total_summaries:-0}" \
        --argjson active_tasks "${active_tasks:-0}" \
        --argjson stale_tasks "${stale_tasks:-0}" \
        --argjson durable_memories "${durable_memories:-0}" \
        --argjson active_features "${active_features:-0}" \
        --argjson recall_events "${recall_events:-0}" \
        --argjson semantic_graph_nodes "${semantic_graph_nodes:-0}" \
        --arg last_capture "${last_capture:-never}" \
        --argjson active_lanes "${active_lanes:-0}" \
        --arg readiness "$readiness" \
        '{status:$status, project:$project,
          database:{integrity:{status:$db_integrity_status, detail:$db_integrity_detail}},
          metrics:{enriched_summaries:$enriched, total_summaries:$total_summaries,
                   active_tasks:$active_tasks, stale_tasks:$stale_tasks,
                   durable_memories:$durable_memories, active_features:$active_features,
                   recall_events:$recall_events, semantic_graph_nodes:$semantic_graph_nodes,
                   last_durable_update:$last_capture, active_orchestration_lanes:$active_lanes},
          readiness:$readiness}'
    exit 0
fi

eagle_banner
eagle_header "Compaction Survival"

echo ""
echo -e "  Project: ${BOLD}$project${RESET}"
echo ""

echo -e "  ${BOLD}Context Survival Metrics${RESET}"
echo -e "  ─────────────────────────────────────"
echo -e "  Enriched summaries:     ${GREEN}$enriched${RESET} / $total_summaries"
echo -e "  Active durable tasks:   ${CYAN}$active_tasks${RESET}"
echo -e "  Durable memories:       ${CYAN}$durable_memories${RESET}"
echo -e "  Active features:        ${CYAN}$active_features${RESET}"
echo -e "  Recall events:          ${CYAN}$recall_events${RESET}"
echo -e "  Semantic graph nodes:   ${CYAN}$semantic_graph_nodes${RESET}"
echo -e "  Stale in_progress tasks:${RED}$stale_tasks${RESET}"
echo -e "  Last durable update:    $last_capture"

echo ""
if [ "$stale_tasks" -gt 0 ]; then
    eagle_warn "Stale tasks detected — run 'eagle-mem tasks stale' and clean them up"
else
    eagle_ok "No long-stale tasks"
fi

# Orchestration lanes (for cross-agent long-running work survival)
echo -e "  Active orchestration lanes: ${CYAN}$active_lanes${RESET}"
if [ "$active_lanes" -gt 0 ]; then
    eagle_info "Long-running work is tracked in durable lanes — use 'eagle-mem orchestrate' to manage"
fi

if [ "$readiness" = "strong" ]; then
    eagle_ok "Compaction Survival: Strong — future sessions will have good context"
elif [ "$readiness" = "moderate" ]; then
    eagle_info "Compaction Survival: Moderate — add more durable tasks and summaries"
else
    eagle_warn "Compaction Survival: Weak — start using durable tasks and <eagle-summary> blocks"
fi

echo ""
eagle_dim "Run this anytime to check how safe the project is from /compact amnesia."
echo ""
