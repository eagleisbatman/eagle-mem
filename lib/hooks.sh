#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Hook registration helpers
# Shared by install.sh and update.sh
# ═══════════════════════════════════════════════════════════

eagle_patch_hook() {
    local settings="$1"
    local event="$2"
    local matcher="$3"
    local command="$4"
    local description="${5:-}"

    if jq -e ".hooks.${event}[]? | select(.hooks[]?.command == \"$command\")" "$settings" &>/dev/null; then
        [ -n "$description" ] && eagle_ok "$description ${DIM}(already registered)${RESET}"
        return 0
    fi

    local entry
    if [ -n "$matcher" ]; then
        entry=$(jq -nc --arg m "$matcher" --arg c "$command" '{matcher: $m, hooks: [{type: "command", command: $c}]}')
    else
        entry=$(jq -nc --arg c "$command" '{hooks: [{type: "command", command: $c}]}')
    fi

    local tmp
    tmp=$(mktemp)
    jq --argjson entry "$entry" ".hooks.${event} = ((.hooks.${event} // []) + [\$entry])" "$settings" > "$tmp" && mv "$tmp" "$settings"
    [ -n "$description" ] && eagle_ok "$description"
}
