#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Uninstall
# Removes hooks from settings.json and optionally wipes data
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/codex-hooks.sh"

SETTINGS="$EAGLE_SETTINGS"

eagle_header "Uninstall"

# ─── Remove hooks from settings.json ──────────────────────

if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    for event in SessionStart Stop PostToolUse PreToolUse SessionEnd UserPromptSubmit; do
        if jq -e ".hooks.${event}" "$SETTINGS" &>/dev/null; then
            tmp=$(mktemp)
            jq ".hooks.${event} = [.hooks.${event}[]? | select(any(.hooks[]?; .command | contains(\"eagle-mem\")) | not)]" "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
            tmp=$(mktemp)
            jq "if .hooks.${event} == [] then del(.hooks.${event}) else . end" "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
        fi
    done
    tmp=$(mktemp)
    jq 'if .hooks == {} then del(.hooks) else . end' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    eagle_ok "Hooks removed from settings.json"
else
    eagle_warn "Could not patch settings.json (jq not found or file missing)"
fi

if eagle_remove_codex_hooks; then
    eagle_ok "Hooks removed from Codex hooks.json"
else
    eagle_warn "Could not patch Codex hooks.json (jq not found or file missing)"
fi

# ─── Remove skill symlinks ────────────────────────────────

if [ -d "$EAGLE_SKILLS_DIR" ]; then
    for target in "$EAGLE_SKILLS_DIR"/eagle-mem-*; do
        [ -L "$target" ] || [ -d "$target" ] || continue
        rm -rf "$target"
        eagle_ok "Skill removed: $(basename "$target")"
    done
fi

# ─── Optionally wipe data ─────────────────────────────────

if [ -d "$EAGLE_MEM_DIR" ]; then
    echo ""
    if eagle_confirm "Delete Eagle Mem data? (${DIM}$EAGLE_MEM_DIR${RESET})"; then
        rm -rf "$EAGLE_MEM_DIR"
        eagle_ok "Data deleted"
    else
        eagle_info "Data preserved at $EAGLE_MEM_DIR"
    fi
fi

eagle_footer "Eagle Mem uninstalled."
