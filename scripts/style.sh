#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — CLI styling helpers
# Source this in all scripts: . "$(dirname "$0")/style.sh"
# ═══════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

TICK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
ARROW="${CYAN}→${RESET}"
DOT="${DIM}·${RESET}"

eagle_header() {
    echo ""
    echo -e "  ${BOLD}Eagle Mem${RESET}  ${DIM}$1${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""
}

eagle_ok()   { echo -e "  ${TICK}  $1"; }
eagle_fail() { echo -e "  ${CROSS}  $1"; }
eagle_info() { echo -e "  ${ARROW}  $1"; }
eagle_warn() { echo -e "  ${YELLOW}!${RESET}  $1"; }
eagle_err()  { echo -e "  ${RED}✗${RESET}  $1" >&2; }
eagle_dim()  { echo -e "  ${DIM}$1${RESET}"; }

eagle_step() {
    echo -e "  ${CYAN}$1${RESET}  $2"
}

eagle_kv() {
    printf "  ${DIM}%-12s${RESET} %s\n" "$1" "$2"
}

eagle_footer() {
    echo ""
    echo -e "  ${GREEN}${BOLD}$1${RESET}"
    echo ""
}

eagle_art() {
    cat << 'ART'
        .~~~~-.
       /    ,__`)
      |      \o/|'-.
      |         /  ,\
      |        ('--./
      /         \
     /  ,  ,  ,  \
     `--'--'--'--'
ART
}

eagle_banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
    ███████╗░█████╗░░██████╗░██╗░░░░░███████╗  ███╗░░░███╗███████╗███╗░░░███╗
    ██╔════╝██╔══██╗██╔════╝░██║░░░░░██╔════╝  ████╗░████║██╔════╝████╗░████║
    █████╗░░███████║██║░░██╗░██║░░░░░█████╗░░  ██╔████╔██║█████╗░░██╔████╔██║
    ██╔══╝░░██╔══██║██║░░╚██╗██║░░░░░██╔══╝░░  ██║╚██╔╝██║██╔══╝░░██║╚██╔╝██║
    ███████╗██║░░██║╚██████╔╝███████╗███████╗  ██║░╚═╝░██║███████╗██║░╚═╝░██║
    ╚══════╝╚═╝░░╚═╝░╚═════╝░╚══════╝╚══════╝  ╚═╝░░░░░╚═╝╚══════╝╚═╝░░░░░╚═╝
BANNER
    echo -e "${RESET}"
}

eagle_is_tty() {
    [ -t 0 ] && [ -t 1 ]
}

eagle_confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if ! eagle_is_tty; then
        [ "$default" = "y" ] && return 0 || return 1
    fi

    local hint
    [ "$default" = "y" ] && hint="Y/n" || hint="y/N"

    echo -ne "  ${YELLOW}?${RESET}  ${prompt} [${hint}] "
    read -r -n 1 reply
    echo ""

    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
}
