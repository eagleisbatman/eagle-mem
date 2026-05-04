#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Config management
# eagle-mem config [init|show|set|test]
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$SCRIPT_DIR/style.sh"
. "$LIB_DIR/provider.sh"

eagle_header "Config"

subcommand="${1:-show}"
shift 2>/dev/null || true

show_help() {
    echo -e "  ${BOLD}eagle-mem config${RESET} — Provider and token-guard settings"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem config                  ${DIM}# show current config${RESET}"
    echo -e "    eagle-mem config ${CYAN}init${RESET}             ${DIM}# create config.toml${RESET}"
    echo -e "    eagle-mem config ${CYAN}set${RESET} section.key value"
    echo -e "    eagle-mem config ${CYAN}test${RESET}             ${DIM}# test curator provider${RESET}"
    echo ""
    echo -e "  ${BOLD}Examples:${RESET}"
    echo -e "    eagle-mem config set provider.type agent_cli"
    echo -e "    eagle-mem config set agent_cli.preferred current"
    echo -e "    eagle-mem config set orchestration.route opposite"
    echo -e "    eagle-mem config set orchestration.codex_worker_model gpt-5.5"
    echo -e "    eagle-mem config set orchestration.claude_worker_model claude-opus-4-7"
    echo -e "    eagle-mem config set updates.mode auto"
    echo -e "    eagle-mem config set updates.allow patch"
    echo -e "    eagle-mem config set token_guard.rtk enforce"
    echo -e "    eagle-mem config set token_guard.raw_bash block"
    echo ""
    exit 0
}

case "$subcommand" in
    --help|-h|help)
        show_help
        ;;

    init)
        eagle_config_init
        eagle_ok "Config created: $EAGLE_CONFIG_FILE"
        echo ""
        eagle_show_config
        ;;

    show|status)
        eagle_show_config
        ;;

    set)
        key="${1:-}"
        value="${2:-}"
        if [ -z "$key" ] || [ -z "$value" ]; then
            eagle_err "Usage: eagle-mem config set <section.key> <value>"
            eagle_info "Examples:"
            eagle_info "  eagle-mem config set provider.type ollama"
            eagle_info "  eagle-mem config set provider.type agent_cli"
            eagle_info "  eagle-mem config set agent_cli.preferred current"
            eagle_info "  eagle-mem config set orchestration.route opposite"
            eagle_info "  eagle-mem config set orchestration.codex_worker_effort xhigh"
            eagle_info "  eagle-mem config set orchestration.claude_worker_effort xhigh"
            eagle_info "  eagle-mem config set ollama.model mistral"
            eagle_info "  eagle-mem config set anthropic.model claude-haiku-4-5-20251001"
            eagle_info "  eagle-mem config set token_guard.rtk enforce"
            eagle_info "  eagle-mem config set token_guard.raw_bash block"
            exit 1
        fi
        section="${key%%.*}"
        config_key="${key#*.}"
        eagle_config_set "$section" "$config_key" "$value"
        eagle_ok "Set [$section] $config_key = $value"
        ;;

    test)
        provider=$(eagle_config_get "provider" "type" "none")
        if [ "$provider" = "none" ]; then
            eagle_err "No provider configured. Run: eagle-mem config init"
            exit 1
        fi

        eagle_info "Testing $provider provider..."
        result=$(eagle_llm_call "Respond with exactly: Eagle Mem provider test successful" "You are a test assistant. Follow instructions exactly." 50)
        if [ -n "$result" ]; then
            eagle_ok "Provider working"
            echo "  Response: $result"
        else
            eagle_err "Provider call failed. Check logs: $EAGLE_MEM_LOG"
            exit 1
        fi
        ;;

    *)
        eagle_err "Unknown config command: $subcommand"
        eagle_info "Usage: eagle-mem config [init|show|set|test]"
        exit 1
        ;;
esac
