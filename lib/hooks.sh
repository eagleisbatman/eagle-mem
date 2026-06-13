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

# Register (idempotently) the full Claude Code hook set into a settings.json.
# Single source of truth for the event→matcher→script mapping so install.sh and
# update.sh can never drift (the historical bug class). Requires $EAGLE_MEM_DIR.
#   $1 = settings.json path
#   $2 = "verbose" to print a "✓ <Event> hook" line per registration (installer);
#        omitted/anything else = quiet (updater prints its own summary line).
eagle_register_claude_hooks() {
    local settings="$1"
    local V=""
    [ "${2:-}" = "verbose" ] && V=1

    # Clean old registrations before re-registering (handles matcher changes across versions).
    eagle_clean_hook_entries "$settings" "Stop" "$EAGLE_MEM_DIR/hooks/stop.sh"
    eagle_clean_hook_entries "$settings" "PostToolUse" "$EAGLE_MEM_DIR/hooks/post-tool-use.sh"
    eagle_clean_hook_entries "$settings" "PreToolUse" "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh"
    eagle_clean_hook_entries "$settings" "PreCompact" "$EAGLE_MEM_DIR/hooks/pre-compact.sh"

    # ${V:+label} expands to the label only in verbose mode; otherwise to "",
    # which makes eagle_patch_hook silent (it only prints when given a description).
    eagle_patch_hook "$settings" "SessionStart" "" "$EAGLE_MEM_DIR/hooks/session-start.sh" "${V:+SessionStart hook}"
    eagle_patch_hook "$settings" "Stop" "" "bash \"$EAGLE_MEM_DIR/hooks/stop.sh\"" "${V:+Stop hook}"
    eagle_patch_hook "$settings" "PostToolUse" "Read|Write|Edit|Bash|TaskUpdate" "$EAGLE_MEM_DIR/hooks/post-tool-use.sh" "${V:+PostToolUse hook}"
    eagle_patch_hook "$settings" "TaskCreated" "" "$EAGLE_MEM_DIR/hooks/post-tool-use.sh" "${V:+TaskCreated hook}"
    eagle_patch_hook "$settings" "TaskCompleted" "" "$EAGLE_MEM_DIR/hooks/post-tool-use.sh" "${V:+TaskCompleted hook}"
    eagle_patch_hook "$settings" "SessionEnd" "" "$EAGLE_MEM_DIR/hooks/session-end.sh" "${V:+SessionEnd hook}"
    eagle_patch_hook "$settings" "UserPromptSubmit" "" "$EAGLE_MEM_DIR/hooks/user-prompt-submit.sh" "${V:+UserPromptSubmit hook}"
    eagle_patch_hook "$settings" "PreToolUse" "Bash|Read|Edit|Write" "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh" "${V:+PreToolUse hook}"
    # PreCompact's matcher is the trigger itself ("manual" | "auto"); register both
    # so auto-compaction — the gap users actually hit — also captures before the
    # window collapses. The hook reads `trigger` from stdin for telemetry.
    eagle_patch_hook "$settings" "PreCompact" "manual" "$EAGLE_MEM_DIR/hooks/pre-compact.sh" "${V:+PreCompact hook (manual)}"
    eagle_patch_hook "$settings" "PreCompact" "auto" "$EAGLE_MEM_DIR/hooks/pre-compact.sh" "${V:+PreCompact hook (auto)}"

    # Allow agent-issued session capture to run without a permission prompt.
    if eagle_patch_permission_allow "$settings" "Bash(eagle-mem session save:*)"; then
        [ -n "$V" ] && eagle_ok "Capture permission ${DIM}(eagle-mem session save)${RESET}"
    fi
    # Explicit success: the trailing conditional above evaluates false in quiet
    # mode (V empty), which would otherwise make this function return 1 and abort
    # a `set -e` caller (update.sh) right after a fully successful registration.
    return 0
}
