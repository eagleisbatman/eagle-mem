#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Update policy and auto-update CLI
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/provider.sh"
. "$LIB_DIR/updater.sh"

show_help() {
    echo -e "  ${BOLD}eagle-mem updates${RESET} — Manage automatic Eagle Mem updates"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem updates ${CYAN}status${RESET}"
    echo -e "    eagle-mem updates ${CYAN}check${RESET}"
    echo -e "    eagle-mem updates ${CYAN}apply${RESET} [--force] [--dry-run]"
    echo -e "    eagle-mem updates ${CYAN}enable${RESET} [auto|notify|patch|minor|major]"
    echo -e "    eagle-mem updates ${CYAN}disable${RESET}"
    echo ""
    echo -e "  ${DIM}Default: mode=auto, allow=patch. Patch bug fixes install in the${RESET}"
    echo -e "  ${DIM}background from SessionStart so stale bugs do not block agents.${RESET}"
    echo ""
}

updates_status() {
    eagle_update_ensure_defaults

    local installed latest latest_rc
    installed=$(eagle_update_installed_version)
    latest=$(eagle_update_latest_version 0 2>/dev/null) && latest_rc=0 || latest_rc=$?

    eagle_header "Updates"
    eagle_kv "Installed:" "v${installed:-unknown}"
    if [ "$latest_rc" -eq 0 ] && [ -n "$latest" ]; then
        eagle_kv "Latest:" "v$latest"
    else
        eagle_kv "Latest:" "unavailable"
    fi
    eagle_kv "Mode:" "$(eagle_update_config_mode)"
    eagle_kv "Allow:" "$(eagle_update_config_allow)"
    eagle_kv "Channel:" "$(eagle_update_config_channel)"
    eagle_kv "Interval:" "$(eagle_update_config_interval_hours)h"

    if [ -f "$EAGLE_UPDATE_STATE_FILE" ]; then
        status=$(jq -r '.status // "unknown"' "$EAGLE_UPDATE_STATE_FILE" 2>/dev/null || echo "unknown")
        at=$(jq -r '.updated_at // ""' "$EAGLE_UPDATE_STATE_FILE" 2>/dev/null || echo "")
        msg=$(jq -r '.message // ""' "$EAGLE_UPDATE_STATE_FILE" 2>/dev/null || echo "")
        eagle_kv "Last run:" "$status ${at:+($at)}"
        [ -n "$msg" ] && eagle_kv "Message:" "$msg"
    fi

    if [ -n "$latest" ] && eagle_update_version_gt "$latest" "$installed"; then
        if eagle_update_allowed "$installed" "$latest" "$(eagle_update_config_allow)"; then
            eagle_ok "Eligible update available"
        else
            eagle_warn "Update available but outside allowed range"
        fi
    else
        eagle_ok "Already current"
    fi
}

updates_check() {
    eagle_update_ensure_defaults
    installed=$(eagle_update_installed_version)
    latest=$(eagle_update_latest_version 1)
    if [ -z "$latest" ]; then
        eagle_err "Could not check npm for updates"
        exit 1
    fi

    if eagle_update_version_gt "$latest" "$installed"; then
        if eagle_update_allowed "$installed" "$latest" "$(eagle_update_config_allow)"; then
            eagle_ok "Update available: v$installed -> v$latest"
        else
            eagle_warn "Update available: v$installed -> v$latest (outside allowed range)"
        fi
    else
        eagle_ok "Already current: v$installed"
    fi
}

updates_apply() {
    eagle_update_ensure_defaults
    local dry_run=0 force=0 latest=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            --force) force=1; shift ;;
            --latest) latest="${2:-}"; shift 2 ;;
            --help|-h) show_help; exit 0 ;;
            *)
                eagle_err "Unknown apply option: $1"
                exit 1
                ;;
        esac
    done

    if output=$(eagle_update_apply_version "$latest" "$dry_run" "$force" 2>&1); then
        state=$(printf '%s' "$output" | awk -F'|' 'NR == 1 {print $1}')
        installed=$(printf '%s' "$output" | awk -F'|' 'NR == 1 {print $2}')
        latest=$(printf '%s' "$output" | awk -F'|' 'NR == 1 {print $3}')
        if [ "$state" = "current" ]; then
            eagle_ok "Already current: v$installed"
        elif [ "$dry_run" = "1" ]; then
            eagle_ok "Would update v$installed -> v$latest"
        else
            eagle_ok "Eagle Mem updated from v$installed to v$latest"
        fi
    else
        rc=$?
        if [ "$rc" -eq 2 ]; then
            eagle_warn "Update skipped: outside allowed range"
            eagle_info "Use --force for a manual override"
            exit 0
        fi
        if [ "$rc" -eq 3 ]; then
            eagle_warn "Update already running"
            exit 0
        fi
        eagle_err "Update failed"
        [ -n "$output" ] && eagle_dim "$output"
        exit 1
    fi
}

updates_enable() {
    eagle_update_ensure_defaults
    local value="${1:-auto}"
    case "$value" in
        auto|notify|off)
            eagle_config_set "updates" "mode" "$value"
            ;;
        patch|minor|major)
            eagle_config_set "updates" "mode" "auto"
            eagle_config_set "updates" "allow" "$value"
            ;;
        *)
            eagle_err "Use: eagle-mem updates enable [auto|notify|patch|minor|major]"
            exit 1
            ;;
    esac
    eagle_ok "Updates enabled: mode=$(eagle_update_config_mode), allow=$(eagle_update_config_allow)"
}

updates_disable() {
    eagle_update_ensure_defaults
    eagle_config_set "updates" "mode" "off"
    eagle_ok "Automatic update checks disabled"
}

command="${1:-status}"
shift 2>/dev/null || true

case "$command" in
    status) updates_status "$@" ;;
    check) updates_check "$@" ;;
    apply) updates_apply "$@" ;;
    auto) eagle_update_auto ;;
    enable) updates_enable "$@" ;;
    disable) updates_disable ;;
    help|--help|-h) show_help ;;
    *)
        eagle_err "Unknown updates command: $command"
        echo ""
        show_help
        exit 1
        ;;
esac
