#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Hook registration helpers
# Shared by install.sh and update.sh
# ═══════════════════════════════════════════════════════════

eagle_clean_hook_entries() {
    local settings="$1"
    local event="$2"
    local command="$3"

    local tmp
    tmp=$(mktemp)
    jq --arg cmd "$command" \
        ".hooks.${event} = ((.hooks.${event} // []) | map(select(.hooks | all(.command != \$cmd))))" \
        "$settings" > "$tmp" && mv "$tmp" "$settings"
}

eagle_patch_hook() {
    local settings="$1"
    local event="$2"
    local matcher="$3"
    local command="$4"
    local description="${5:-}"

    # Check both command AND matcher to avoid skipping entries with different matchers
    # (e.g. PreToolUse with "Bash" vs "Read" matcher using the same script)
    local match_query
    if [ -n "$matcher" ]; then
        match_query=".hooks.${event}[]? | select(.matcher == \"$matcher\" and (.hooks[]?.command == \"$command\"))"
    else
        match_query=".hooks.${event}[]? | select(.matcher == null and (.hooks[]?.command == \"$command\"))"
    fi
    if jq -e "$match_query" "$settings" &>/dev/null; then
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
