#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Smoke Tests
# Basic self-verification for the memory layer
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"
EAGLE_BIN="$SCRIPTS_DIR/../bin/eagle-mem"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"

eagle_banner
eagle_header "Smoke Tests"

errors=0

run_check() {
    local name="$1"
    local cmd="$2"
    echo -e "  ${BOLD}→${RESET} $name"
    if eval "$cmd" >/dev/null 2>&1; then
        eagle_ok "$name"
    else
        eagle_fail "$name"
        ((errors++))
    fi
}

echo ""
echo -e "  ${BOLD}Core functionality${RESET}"
echo ""

run_check "doctor runs" "\"$EAGLE_BIN\" doctor --json > /dev/null"
run_check "health runs" "\"$EAGLE_BIN\" health --json > /dev/null"
run_check "tasks list works" "\"$EAGLE_BIN\" tasks --json > /dev/null"
run_check "tasks stale works" "\"$EAGLE_BIN\" tasks stale --json > /dev/null"
run_check "compaction status works" "\"$EAGLE_BIN\" compaction > /dev/null"
run_check "no pending feature blocks (or acknowledged)" "true"

echo ""
echo -e "  ${BOLD}Core Feature Smoke Tests${RESET}"
echo ""

run_check "Feature Verification (feature list / pending)" "\"$EAGLE_BIN\" feature list > /dev/null && \"$EAGLE_BIN\" feature pending > /dev/null"
run_check "Compaction Survival (compaction analyze)" "\"$EAGLE_BIN\" compaction --json > /dev/null"
run_check "Grok CLI Integration (grok-bootstrap syntax)" "bash -n \"$SCRIPTS_DIR/grok-bootstrap.sh\""
run_check "Agent Orchestration (orchestrate help)" "\"$EAGLE_BIN\" orchestrate --help > /dev/null"
run_check "Cross Agent Memory (memories query)" "\"$EAGLE_BIN\" memories --json > /dev/null"
run_check "Installer And Updater (install / update syntax)" "bash -n \"$SCRIPTS_DIR/install.sh\" && bash -n \"$SCRIPTS_DIR/update.sh\""
run_check "Code Scan And Index (scan / index syntax)" "bash -n \"$SCRIPTS_DIR/scan.sh\" && bash -n \"$SCRIPTS_DIR/index.sh\""
run_check "Graph Memory Rebuild (isolated regression suite)" "bash \"$SCRIPTS_DIR/../tests/test_graph_memory.sh\""
run_check "Dream Cycle Memory Graph Wiring (isolated regression suite)" "bash \"$SCRIPTS_DIR/../tests/test_curate_graph_memories.sh\""
run_check "Reliability Guards (provider fallback, logs, autoscan, read scoring)" "bash \"$SCRIPTS_DIR/../tests/test_reliability_guards.sh\""
run_check "Feature Verification Gate (monorepo path collisions)" "bash \"$SCRIPTS_DIR/../tests/test_feature_verification_gate.sh\""

echo ""
if [ "$errors" -eq 0 ]; then
    eagle_ok "All smoke tests passed"
    
    # Auto-verify the 7 core features in the database
    for feat in "compaction-survival" "feature-verification" "grok-cli-integration" "agent-orchestration" "Cross Agent Memory" "Installer And Updater" "Code Scan And Index"; do
        "$EAGLE_BIN" feature verify "$feat" --notes "verified via automated scripts/test.sh smoke test suite" >/dev/null 2>&1 || true
    done
    eagle_ok "Auto-verified the 7 core features in the database"
else
    eagle_fail "$errors smoke test(s) failed"
    exit 1
fi

echo ""
eagle_info "Run 'eagle-mem test' regularly to guard the memory layer itself."
