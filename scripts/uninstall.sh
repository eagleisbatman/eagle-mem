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
dry_run=false

for arg in "$@"; do
    case "$arg" in
        --dry-run|--check)
            dry_run=true
            ;;
        --help|-h)
            echo "Usage: eagle-mem uninstall [--dry-run]"
            exit 0
            ;;
    esac
done

eagle_header "Uninstall"
eagle_uninstall_change_plan

if [ "$dry_run" = true ]; then
    eagle_footer "Dry run complete. No files changed."
    exit 0
fi

# ─── Remove hooks from settings.json ──────────────────────

if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    settings_backup=$(eagle_backup_user_file "$SETTINGS" 2>/dev/null || true)
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
    [ -n "${settings_backup:-}" ] && eagle_dim "  Backup: $settings_backup"
else
    eagle_warn "Could not patch settings.json (jq not found or file missing)"
fi

codex_hooks_backup=""
if [ -f "$EAGLE_CODEX_HOOKS" ]; then
    codex_hooks_backup=$(eagle_backup_user_file "$EAGLE_CODEX_HOOKS" 2>/dev/null || true)
fi
if eagle_remove_codex_hooks; then
    eagle_ok "Hooks removed from Codex hooks.json"
    [ -n "$codex_hooks_backup" ] && eagle_dim "  Backup: $codex_hooks_backup"
else
    eagle_warn "Could not patch Codex hooks.json (jq not found or file missing)"
fi

# ─── Remove instruction blocks and statusline integration ───

claude_md="$HOME/.claude/CLAUDE.md"
if [ -f "$claude_md" ] && grep -qF "## Eagle Mem — Persistent Memory" "$claude_md" 2>/dev/null; then
    claude_md_backup=$(eagle_backup_user_file "$claude_md" 2>/dev/null || true)
    if eagle_remove_marked_markdown_section "$claude_md"; then
        eagle_ok "Eagle Mem block removed from Claude CLAUDE.md"
        [ -n "${claude_md_backup:-}" ] && eagle_dim "  Backup: $claude_md_backup"
    else
        eagle_warn "Could not remove Eagle Mem block from Claude CLAUDE.md"
    fi
else
    eagle_info "Claude CLAUDE.md block not present"
fi

if [ -f "$EAGLE_CODEX_AGENTS_MD" ] && grep -qF "## Eagle Mem — Persistent Memory" "$EAGLE_CODEX_AGENTS_MD" 2>/dev/null; then
    codex_agents_backup=$(eagle_backup_user_file "$EAGLE_CODEX_AGENTS_MD" 2>/dev/null || true)
    if eagle_remove_marked_markdown_section "$EAGLE_CODEX_AGENTS_MD"; then
        eagle_ok "Eagle Mem block removed from Codex AGENTS.md"
        [ -n "${codex_agents_backup:-}" ] && eagle_dim "  Backup: $codex_agents_backup"
    else
        eagle_warn "Could not remove Eagle Mem block from Codex AGENTS.md"
    fi
else
    eagle_info "Codex AGENTS.md block not present"
fi

if eagle_remove_statusline_integration "$SETTINGS"; then
    eagle_ok "Eagle Mem statusline integration removed"
else
    eagle_info "Statusline integration not present or not auto-removable"
fi

# ─── Remove skill symlinks ────────────────────────────────

if [ -d "$EAGLE_SKILLS_DIR" ]; then
    for target in "$EAGLE_SKILLS_DIR"/eagle-mem-*; do
        [ -L "$target" ] || [ -d "$target" ] || continue
        rm -rf "$target"
        eagle_ok "Skill removed: $(basename "$target")"
    done
fi

if [ -d "$EAGLE_CODEX_SKILLS_DIR" ]; then
    for target in "$EAGLE_CODEX_SKILLS_DIR"/eagle-mem-*; do
        [ -L "$target" ] || [ -d "$target" ] || continue
        rm -rf "$target"
        eagle_ok "Codex skill removed: $(basename "$target")"
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
