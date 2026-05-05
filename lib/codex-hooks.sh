#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Codex hook registration helpers
# Shared by install.sh, update.sh, and uninstall.sh
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_CODEX_HOOKS_LOADED:-}" ] && return 0
_EAGLE_CODEX_HOOKS_LOADED=1

eagle_enable_codex_hooks() {
    local config="$EAGLE_CODEX_CONFIG"
    mkdir -p "$(dirname "$config")"

    if [ ! -f "$config" ]; then
        cat > "$config" << 'TOML'
[features]
codex_hooks = true
TOML
        chmod 600 "$config" 2>/dev/null || true
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    awk '
        BEGIN { in_features=0; saw_features=0; saw_flag=0; inserted=0 }
        /^[[:space:]]*\[features\][[:space:]]*$/ {
            saw_features=1
            in_features=1
            print
            next
        }
        /^[[:space:]]*\[/ && in_features {
            if (!saw_flag && !inserted) {
                print "codex_hooks = true"
                inserted=1
            }
            in_features=0
        }
        in_features && /^[[:space:]]*codex_hooks[[:space:]]*=/ {
            print "codex_hooks = true"
            saw_flag=1
            next
        }
        { print }
        END {
            if (in_features && !saw_flag && !inserted) {
                print "codex_hooks = true"
                inserted=1
            }
            if (!saw_features) {
                print ""
                print "[features]"
                print "codex_hooks = true"
            }
        }
    ' "$config" > "$tmp" && mv "$tmp" "$config"
    chmod 600 "$config" 2>/dev/null || true
}

eagle_patch_codex_hook() {
    local hooks_file="$1"
    local event="$2"
    local matcher="$3"
    local command="$4"
    local description="${5:-}"
    local status_message="${6:-}"
    local timeout="${7:-}"
    local script_path="$command"
    script_path="${script_path#EAGLE_AGENT_SOURCE=codex bash \"}"
    script_path="${script_path#bash \"}"
    script_path="${script_path%\"}"

    mkdir -p "$(dirname "$hooks_file")"
    if [ ! -f "$hooks_file" ]; then
        printf '{"hooks":{}}\n' > "$hooks_file"
        chmod 600 "$hooks_file" 2>/dev/null || true
    fi

    local match_query
    if [ -n "$matcher" ]; then
        match_query='.hooks[$event][]? | select(.matcher == $matcher and (.hooks[]?.command == $command))'
    else
        match_query='.hooks[$event][]? | select((.matcher == null or .matcher == "") and (.hooks[]?.command == $command))'
    fi
    if jq -e --arg event "$event" --arg matcher "$matcher" --arg command "$command" "$match_query" "$hooks_file" &>/dev/null; then
        [ -n "$description" ] && eagle_ok "$description ${DIM}(already registered)${RESET}"
        return 0
    fi

    if jq -e --arg event "$event" --arg matcher "$matcher" --arg script "$script_path" '
        .hooks[$event][]?
        | select((($matcher == "" and (.matcher == null or .matcher == "")) or .matcher == $matcher)
                 and any(.hooks[]?; (.command // "") | contains($script)))
    ' "$hooks_file" &>/dev/null; then
        local tmp_existing
        tmp_existing=$(mktemp)
        jq --arg event "$event" --arg matcher "$matcher" --arg script "$script_path" --arg command "$command" '
            .hooks[$event] |= map(
                if ((($matcher == "" and (.matcher == null or .matcher == "")) or .matcher == $matcher)
                    and any(.hooks[]?; (.command // "") | contains($script)))
                then .hooks |= map(if ((.command // "") | contains($script)) then .command = $command else . end)
                else .
                end
            )
        ' "$hooks_file" > "$tmp_existing" && mv "$tmp_existing" "$hooks_file"
        [ -n "$description" ] && eagle_ok "$description ${DIM}(updated)${RESET}"
        return 0
    fi

    local entry
    entry=$(jq -nc \
        --arg m "$matcher" \
        --arg c "$command" \
        --arg s "$status_message" \
        --arg timeout "$timeout" '
        {
            hooks: [
                {
                    type: "command",
                    command: $c
                }
                + (if $s == "" then {} else {statusMessage: $s} end)
                + (if $timeout == "" then {} else {timeout: ($timeout | tonumber)} end)
            ]
        }
        + (if $m == "" then {} else {matcher: $m} end)')

    local tmp
    tmp=$(mktemp)
    jq --argjson entry "$entry" ".hooks.${event} = ((.hooks.${event} // []) + [\$entry])" "$hooks_file" > "$tmp" && mv "$tmp" "$hooks_file"
    chmod 600 "$hooks_file" 2>/dev/null || true
    [ -n "$description" ] && eagle_ok "$description"
}

eagle_register_codex_hooks() {
    eagle_enable_codex_hooks

    eagle_patch_codex_hook "$EAGLE_CODEX_HOOKS" "SessionStart" "startup|resume|clear" \
        "EAGLE_AGENT_SOURCE=codex bash \"$EAGLE_MEM_DIR/hooks/session-start.sh\"" \
        "Codex SessionStart hook" \
        "Loading Eagle Mem recall" \
        "30"

    eagle_patch_codex_hook "$EAGLE_CODEX_HOOKS" "UserPromptSubmit" "" \
        "EAGLE_AGENT_SOURCE=codex bash \"$EAGLE_MEM_DIR/hooks/user-prompt-submit.sh\"" \
        "Codex UserPromptSubmit hook" \
        "Searching Eagle Mem" \
        "30"

    eagle_patch_codex_hook "$EAGLE_CODEX_HOOKS" "PreToolUse" "^(Bash|exec_command|shell_command|unified_exec|apply_patch|Edit|Write)$" \
        "EAGLE_AGENT_SOURCE=codex bash \"$EAGLE_MEM_DIR/hooks/pre-tool-use.sh\"" \
        "Codex PreToolUse hook" \
        "Checking Eagle Mem guardrails" \
        "30"

    eagle_patch_codex_hook "$EAGLE_CODEX_HOOKS" "PostToolUse" "^(Bash|exec_command|shell_command|unified_exec|apply_patch|Edit|Write)$" \
        "EAGLE_AGENT_SOURCE=codex bash \"$EAGLE_MEM_DIR/hooks/post-tool-use.sh\"" \
        "Codex PostToolUse hook" \
        "Recording Eagle Mem observation" \
        "30"

    eagle_patch_codex_hook "$EAGLE_CODEX_HOOKS" "Stop" "" \
        "EAGLE_AGENT_SOURCE=codex bash \"$EAGLE_MEM_DIR/hooks/stop.sh\"" \
        "Codex Stop hook" \
        "Saving Eagle Mem summary" \
        "60"
}

eagle_remove_codex_hooks() {
    local hooks_file="$EAGLE_CODEX_HOOKS"
    [ -f "$hooks_file" ] || return 1
    command -v jq &>/dev/null || return 1

    local tmp
    tmp=$(mktemp)
    jq '
        def without_eagle_mem_handlers:
            .hooks = ((.hooks // [])
                | map(select(((.command // "") | contains(".eagle-mem/hooks/")) | not)));

        if .hooks then
            .hooks |= with_entries(
                .value = [
                    .value[]?
                    | without_eagle_mem_handlers
                    | select((.hooks // []) | length > 0)
                ]
                | select(.value != [])
            )
        else . end
        | if .hooks == {} then del(.hooks) else . end
    ' "$hooks_file" > "$tmp" && mv "$tmp" "$hooks_file"
    chmod 600 "$hooks_file" 2>/dev/null || true
}
