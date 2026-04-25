#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Uninstall
# Removes hooks from settings.json and optionally wipes data
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

. "$SCRIPTS_DIR/style.sh"

EAGLE_MEM_DIR="${EAGLE_MEM_DIR:-$HOME/.eagle-mem}"
SETTINGS="$HOME/.claude/settings.json"
SKILLS_DIR="$HOME/.claude/skills"

eagle_header "Uninstall"

# ─── Remove hooks from settings.json ──────────────────────

if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    for event in SessionStart Stop PostToolUse SessionEnd UserPromptSubmit; do
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

# ─── Remove skill symlinks ────────────────────────────────

if [ -d "$SKILLS_DIR" ]; then
    for skill in eagle-mem-search eagle-mem-tasks eagle-mem-overview; do
        target="$SKILLS_DIR/$skill"
        if [ -L "$target" ]; then
            rm "$target"
            eagle_ok "Skill removed: $skill"
        elif [ -d "$target" ]; then
            rm -rf "$target"
            eagle_ok "Skill removed: $skill"
        fi
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
