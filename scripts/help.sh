#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Help
# ═══════════════════════════════════════════════════════════

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

. "$SCRIPTS_DIR/style.sh"

version=$(jq -r .version "$PACKAGE_DIR/package.json" 2>/dev/null || echo "unknown")

eagle_banner

echo -e "  ${BOLD}Eagle Mem${RESET} ${DIM}v${version}${RESET}"
echo -e "  ${DIM}Context that survives /compact for Claude Code and Codex${RESET}"
echo ""
echo -e "  ${BOLD}Commands:${RESET}"
echo -e "    ${CYAN}install${RESET}     First-time setup: hooks, database, skills"
echo -e "    ${CYAN}update${RESET}      Re-deploy hooks and run migrations"
echo -e "    ${CYAN}uninstall${RESET}   Remove hooks and optionally delete data"
echo -e "    ${CYAN}search${RESET}      Search past sessions, memories, and code"
echo -e "    ${CYAN}health${RESET}      Diagnose pipeline health and background automation"
echo -e "    ${CYAN}config${RESET}      View or change LLM provider settings"
echo -e "    ${CYAN}guard${RESET}       Manage regression guardrails for files"
echo -e "    ${CYAN}overview${RESET}    Build or view project overview"
echo -e "    ${CYAN}memories${RESET}    View/sync agent memories"
echo -e "    ${CYAN}tasks${RESET}       View mirrored tasks"
echo -e "    ${CYAN}curate${RESET}      Run curator (co-edits, hot files, guardrails)"
echo -e "    ${CYAN}feature${RESET}     Track, verify, and unblock features"
echo -e "    ${CYAN}prune${RESET}       Clean old sessions and stale data"
echo ""
echo -e "  ${BOLD}Search modes:${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem search \"auth bug\"    ${DIM}# keyword search${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem search --timeline     ${DIM}# recent sessions${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem search --overview     ${DIM}# project overview${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem search --memories     ${DIM}# mirrored memories${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem search --tasks        ${DIM}# in-flight tasks${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem search --files        ${DIM}# hot files${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem search --stats        ${DIM}# project stats${RESET}"
echo ""
echo -e "  ${BOLD}Anti-regression:${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem feature pending       ${DIM}# pending release blockers${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem feature verify NAME   ${DIM}# verify current diff after testing${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem feature waive ID      ${DIM}# intentional exception${RESET}"
echo ""
echo -e "  ${BOLD}Skills${RESET} ${DIM}(inside Claude Code and Codex sessions):${RESET}"
echo -e "    ${CYAN}eagle-mem-search${RESET}       Search memory and past sessions"
echo -e "    ${CYAN}eagle-mem-overview${RESET}     Build or update project overview"
echo -e "    ${CYAN}eagle-mem-memories${RESET}     View/sync agent memories"
echo -e "    ${CYAN}eagle-mem-tasks${RESET}        TaskAware Compact Loop for multi-step work"
echo ""
echo -e "  ${DIM}Everything else is automatic — scan, index, prune, and${RESET}"
echo -e "  ${DIM}curator all run in the background via hooks.${RESET}"
echo ""
echo -e "  ${DIM}https://github.com/eagleisbatman/eagle-mem${RESET}"
echo ""
