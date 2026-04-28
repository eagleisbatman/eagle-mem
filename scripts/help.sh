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
echo -e "  ${DIM}Persistent memory for Claude Code${RESET}"
echo ""
echo -e "  ${BOLD}Commands:${RESET}"
echo -e "    ${CYAN}search${RESET}      Search past sessions, memories, and code"
echo -e "    ${CYAN}overview${RESET}    View or set project overview"
echo -e "    ${CYAN}scan${RESET}        Analyze codebase structure"
echo -e "    ${CYAN}index${RESET}       Index source files for FTS5 code search"
echo -e "    ${CYAN}memories${RESET}    View/sync mirrored Claude Code memories"
echo -e "    ${CYAN}tasks${RESET}       View mirrored Claude Code tasks"
echo -e "    ${CYAN}refresh${RESET}     Full project sync: scan (if needed) + index + memories"
echo -e "    ${CYAN}prune${RESET}       Remove old observations and orphaned chunks"
echo -e "    ${CYAN}config${RESET}      View or change LLM provider settings"
echo -e "    ${CYAN}curate${RESET}      Run the self-learning curator (LLM-powered analysis)"
echo -e "    ${CYAN}feature${RESET}     Manage feature graph (list/show/verify/add)"
echo -e "    ${CYAN}install${RESET}     First-time setup: hooks, database, skills"
echo -e "    ${CYAN}update${RESET}      Re-deploy hooks and run migrations"
echo -e "    ${CYAN}uninstall${RESET}   Remove hooks and optionally delete data"
echo ""
echo -e "  ${BOLD}Examples:${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem search \"auth bug\"  ${DIM}# keyword search${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem search --timeline  ${DIM}# recent sessions${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem refresh             ${DIM}# full project sync${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem overview           ${DIM}# view overview${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem prune --dry-run    ${DIM}# preview cleanup${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem install            ${DIM}# first-time setup${RESET}"
echo ""
echo -e "  ${BOLD}Skills${RESET} ${DIM}(inside Claude Code sessions):${RESET}"
echo -e "    ${CYAN}/eagle-mem-search${RESET}      Search memory and past sessions"
echo -e "    ${CYAN}/eagle-mem-overview${RESET}    Build or update project overview"
echo -e "    ${CYAN}/eagle-mem-scan${RESET}        Analyze codebase structure"
echo -e "    ${CYAN}/eagle-mem-index${RESET}       Index source files for code search"
echo -e "    ${CYAN}/eagle-mem-memories${RESET}    View/sync Claude Code memories"
echo -e "    ${CYAN}/eagle-mem-tasks${RESET}       TaskAware Compact Loop for multi-step work"
echo -e "    ${CYAN}/eagle-mem-prune${RESET}       Clean up stale data"
echo ""
echo -e "  ${DIM}https://github.com/eagleisbatman/eagle-mem${RESET}"
echo ""
