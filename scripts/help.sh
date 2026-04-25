#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Help
# ═══════════════════════════════════════════════════════════

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

. "$SCRIPTS_DIR/style.sh"

version=$(node -e "console.log(require('$PACKAGE_DIR/package.json').version)" 2>/dev/null || echo "unknown")

eagle_banner

echo -e "  ${BOLD}Eagle Mem${RESET} ${DIM}v${version}${RESET}"
echo -e "  ${DIM}Lightweight persistent memory for Claude Code${RESET}"
echo ""
echo -e "  ${BOLD}Usage:${RESET}"
echo -e "    eagle-mem ${CYAN}<command>${RESET}"
echo ""
echo -e "  ${BOLD}Commands:${RESET}"
echo -e "    ${CYAN}install${RESET}     Set up hooks, database, and skills"
echo -e "    ${CYAN}uninstall${RESET}   Remove hooks and optionally delete data"
echo -e "    ${CYAN}update${RESET}      Re-deploy hooks and run new migrations"
echo -e "    ${CYAN}scan${RESET}        Analyze a project and generate an overview"
echo -e "    ${CYAN}index${RESET}       Index source files for code-level search"
echo -e "    ${CYAN}help${RESET}        Show this help message"
echo -e "    ${CYAN}version${RESET}     Show version number"
echo ""
echo -e "  ${BOLD}Examples:${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem install       ${DIM}# First-time setup${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem update        ${DIM}# After npm update${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem scan .         ${DIM}# Scan current project${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem index .        ${DIM}# Index source files${RESET}"
echo -e "    ${DIM}\$${RESET} eagle-mem uninstall     ${DIM}# Clean removal${RESET}"
echo ""
echo -e "  ${BOLD}What it does:${RESET}"
echo -e "    ${DOT} Saves session summaries to a shared SQLite database"
echo -e "    ${DOT} Injects relevant memory at session start"
echo -e "    ${DOT} Searches past sessions when you ask related questions"
echo -e "    ${DOT} Tracks file operations across sessions"
echo -e "    ${DOT} Provides task management for complex multi-step work"
echo ""
echo -e "  ${BOLD}Skills${RESET} ${DIM}(available inside Claude Code):${RESET}"
echo -e "    ${CYAN}/eagle-mem-search${RESET}    Search past sessions and observations"
echo -e "    ${CYAN}/eagle-mem-tasks${RESET}     Break work into tracked subtasks"
echo -e "    ${CYAN}/eagle-mem-overview${RESET}  Generate a persistent project summary"
echo ""
echo -e "  ${DIM}https://github.com/eagleisbatman/eagle-mem${RESET}"
echo ""
