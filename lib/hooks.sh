#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Hook registration helpers
# Shared by install.sh and update.sh
# ═══════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════

eagle_backup_file() {
    local file="$1"
    [ -f "$file" ] || return 0
    if [ -z "${_EAGLE_BACKUP_DONE:-}" ]; then
        local timestamp
        timestamp=$(date +%Y%m%d%H%M%S)
        cp "$file" "${file}.bak.${timestamp}" 2>/dev/null || true
        _EAGLE_BACKUP_DONE=1
    fi
}

eagle_clean_hook_entries() {
    local settings="$1"
    local event="$2"
    local command="$3"

    eagle_backup_file "$settings"

    local tmp
    tmp=$(mktemp)
    jq --arg cmd "$command" \
        ".hooks.${event} = ((.hooks.${event} // []) | map(select(.hooks | all(.command != \$cmd))))" \
        "$settings" > "$tmp" && mv "$tmp" "$settings"
}

# Add a permissions.allow rule to Claude settings.json so agent-issued capture
# commands (e.g. `eagle-mem session save`) run without a permission prompt.
# Idempotent and order-preserving: appends only when the rule is absent, and
# leaves existing permissions.deny/ask and allow entries untouched.
eagle_patch_permission_allow() {
    local settings="$1"
    local rule="$2"
    [ -f "$settings" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    if jq -e --arg r "$rule" '(.permissions.allow // []) | index($r) != null' "$settings" >/dev/null 2>&1; then
        return 0
    fi

    eagle_backup_file "$settings"
    local tmp
    tmp=$(mktemp)
    if jq --arg r "$rule" '
            .permissions = (.permissions // {})
            | .permissions.allow = ((.permissions.allow // []) + [$r])
        ' "$settings" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$settings"
    else
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

eagle_patch_hook() {
    local settings="$1"
    local event="$2"
    local matcher="$3"
    local command="$4"
    local description="${5:-}"

    eagle_backup_file "$settings"

    # Check both command AND matcher to avoid skipping entries with different matchers
    # (e.g. PreToolUse with "Bash" vs "Read" matcher using the same script)
    if [ -n "$matcher" ]; then
        if jq -e --arg m "$matcher" --arg c "$command" \
            ".hooks.${event}[]? | select(.matcher == \$m and (.hooks[]?.command == \$c))" \
            "$settings" &>/dev/null; then
            [ -n "$description" ] && eagle_ok "$description ${DIM}(already registered)${RESET}"
            return 0
        fi
    else
        if jq -e --arg c "$command" \
            ".hooks.${event}[]? | select(.matcher == null and (.hooks[]?.command == \$c))" \
            "$settings" &>/dev/null; then
            [ -n "$description" ] && eagle_ok "$description ${DIM}(already registered)${RESET}"
            return 0
        fi
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
    return 0
}
