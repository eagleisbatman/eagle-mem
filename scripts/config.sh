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

case "$subcommand" in
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
            eagle_info "  eagle-mem config set ollama.model mistral"
            eagle_info "  eagle-mem config set anthropic.model claude-haiku-4-5-20251001"
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
