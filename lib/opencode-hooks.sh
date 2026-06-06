#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — OpenCode plugin registration helpers
# Shared by install.sh, update.sh, uninstall.sh, and doctor.sh
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_OPENCODE_HOOKS_LOADED:-}" ] && return 0
_EAGLE_OPENCODE_HOOKS_LOADED=1

eagle_opencode_detected() {
    [ -d "$EAGLE_OPENCODE_DIR" ] && return 0
    command -v opencode >/dev/null 2>&1
}

eagle_opencode_plugin_source() {
    local package_dir="${1:-.}"
    printf '%s\n' "$package_dir/integrations/opencode_eagle_mem_plugin.js"
}

eagle_install_opencode_plugin() {
    local package_dir="${1:-.}" dry_run="${2:-0}"
    local src
    src=$(eagle_opencode_plugin_source "$package_dir")

    [ -f "$src" ] || {
        eagle_warn "OpenCode plugin source missing: $src"
        return 1
    }

    if [ "$dry_run" = "1" ]; then
        eagle_info "Would install OpenCode plugin: $EAGLE_OPENCODE_PLUGIN"
        return 0
    fi

    mkdir -p "$EAGLE_OPENCODE_PLUGINS_DIR"
    if [ -f "$EAGLE_OPENCODE_PLUGIN" ] && ! grep -q "EAGLE_MEM_OPENCODE_PLUGIN" "$EAGLE_OPENCODE_PLUGIN" 2>/dev/null; then
        eagle_warn "OpenCode plugin path already exists and is not Eagle Mem-owned: $EAGLE_OPENCODE_PLUGIN"
        return 1
    fi
    cp "$src" "$EAGLE_OPENCODE_PLUGIN"
    chmod 600 "$EAGLE_OPENCODE_PLUGIN" 2>/dev/null || true
    eagle_ok "OpenCode plugin ${DIM}(global local plugin)${RESET}"
}

eagle_install_opencode_skills() {
    local package_dir="${1:-.}" dry_run="${2:-0}"
    [ -d "$package_dir/skills" ] || return 0

    if [ "$dry_run" = "1" ]; then
        eagle_info "Would symlink OpenCode skills to: $EAGLE_OPENCODE_SKILLS_DIR"
        return 0
    fi

    mkdir -p "$EAGLE_OPENCODE_SKILLS_DIR"
    find "$EAGLE_OPENCODE_SKILLS_DIR" -maxdepth 1 -name "eagle-mem-*" -type l 2>/dev/null | while read -r existing; do
        skill_name=$(basename "$existing")
        if [ ! -d "$package_dir/skills/$skill_name" ]; then
            rm "$existing"
            eagle_ok "Removed stale OpenCode skill: $skill_name"
        fi
    done
    for skill_dir in "$package_dir"/skills/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name=$(basename "$skill_dir")
        dst="$EAGLE_OPENCODE_SKILLS_DIR/$skill_name"
        [ -L "$dst" ] && rm "$dst"
        ln -sf "$skill_dir" "$dst"
    done
    eagle_ok "OpenCode skills updated"
}

eagle_remove_opencode_plugin() {
    [ -f "$EAGLE_OPENCODE_PLUGIN" ] || return 1

    if grep -q "EAGLE_MEM_OPENCODE_PLUGIN" "$EAGLE_OPENCODE_PLUGIN" 2>/dev/null; then
        rm -f "$EAGLE_OPENCODE_PLUGIN"
        return 0
    fi

    return 1
}

eagle_remove_opencode_skills() {
    [ -d "$EAGLE_OPENCODE_SKILLS_DIR" ] || return 1

    local removed=1
    for target in "$EAGLE_OPENCODE_SKILLS_DIR"/eagle-mem-*; do
        [ -L "$target" ] || continue
        rm -rf "$target"
        eagle_ok "OpenCode skill removed: $(basename "$target")"
        removed=0
    done
    return "$removed"
}

eagle_opencode_plugin_state() {
    if ! eagle_opencode_detected; then
        printf '%s\n' "not found"
    elif [ -f "$EAGLE_OPENCODE_PLUGIN" ] && grep -q "EAGLE_MEM_OPENCODE_PLUGIN" "$EAGLE_OPENCODE_PLUGIN" 2>/dev/null; then
        printf '%s\n' "registered"
    elif [ -f "$EAGLE_OPENCODE_PLUGIN" ]; then
        printf '%s\n' "custom"
    else
        printf '%s\n' "not registered"
    fi
}
