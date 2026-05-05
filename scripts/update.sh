#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Update
# Re-deploys hooks/lib/db files and runs pending migrations
# ═══════════════════════════════════════════════════════════
set -euo pipefail

PACKAGE_DIR="${1:-.}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/provider.sh"
. "$LIB_DIR/updater.sh"
. "$LIB_DIR/hooks.sh"
. "$LIB_DIR/codex-hooks.sh"

SETTINGS="$EAGLE_SETTINGS"
claude_found=false
codex_found=false

eagle_header "Update"

# ─── Verify existing installation ──────────────────────────

if [ ! -d "$EAGLE_MEM_DIR" ]; then
    eagle_fail "Eagle Mem is not installed ($EAGLE_MEM_DIR not found)"
    eagle_info "Run ${BOLD}eagle-mem install${RESET} first"
    exit 1
fi

if [ ! -f "$EAGLE_MEM_DIR/memory.db" ]; then
    eagle_warn "Database not found — will be created"
fi

[ -d "$HOME/.claude" ] && claude_found=true
if [ -d "$EAGLE_CODEX_DIR" ] || command -v codex &>/dev/null; then
    codex_found=true
fi

# ─── Update files ──────────────────────────────────────────

mkdir -p "$EAGLE_MEM_DIR"/{hooks,lib,db,scripts}

cp "$PACKAGE_DIR"/hooks/*.sh "$EAGLE_MEM_DIR/hooks/"
cp "$PACKAGE_DIR"/lib/*.sh "$EAGLE_MEM_DIR/lib/"
cp "$PACKAGE_DIR"/db/*.sh "$EAGLE_MEM_DIR/db/"
cp "$PACKAGE_DIR"/db/*.sql "$EAGLE_MEM_DIR/db/"
cp "$PACKAGE_DIR"/scripts/*.sh "$EAGLE_MEM_DIR/scripts/" 2>/dev/null

chmod +x "$EAGLE_MEM_DIR"/hooks/*.sh
chmod +x "$EAGLE_MEM_DIR"/db/migrate.sh
chmod +x "$EAGLE_MEM_DIR"/scripts/*.sh 2>/dev/null

eagle_ok "Files updated"

# ─── Run pending migrations ────────────────────────────────

migration_output=$("$EAGLE_MEM_DIR/db/migrate.sh" 2>&1) || {
    eagle_err "Database migration failed"
    eagle_err "$migration_output"
    exit 1
}
if echo "$migration_output" | grep -q "applied:"; then
    echo "$migration_output" | grep "applied:" | while read -r line; do
        eagle_ok "Migration: ${line#*applied: }"
    done
else
    eagle_ok "Database up to date"
fi

# ─── Re-register hooks (idempotent) ───────────────────────

if [ "$claude_found" = true ] && [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    # Update PostToolUse matcher if it has the old value (pre-v1.3.0)
    if jq -e '.hooks.PostToolUse[]? | select(.matcher == "Read|Write|Edit|Bash")' "$SETTINGS" &>/dev/null; then
        _tmp=$(mktemp)
        jq '(.hooks.PostToolUse[] | select(.matcher == "Read|Write|Edit|Bash")).matcher = "Read|Write|Edit|Bash|TaskCreate|TaskUpdate"' "$SETTINGS" > "$_tmp" && mv "$_tmp" "$SETTINGS"
    fi

    eagle_patch_hook "$SETTINGS" "SessionStart" "" "$EAGLE_MEM_DIR/hooks/session-start.sh"
    eagle_patch_hook "$SETTINGS" "Stop" "" "$EAGLE_MEM_DIR/hooks/stop.sh"
    eagle_patch_hook "$SETTINGS" "PostToolUse" "Read|Write|Edit|Bash|TaskCreate|TaskUpdate" "$EAGLE_MEM_DIR/hooks/post-tool-use.sh"
    eagle_patch_hook "$SETTINGS" "TaskCreated" "" "$EAGLE_MEM_DIR/hooks/post-tool-use.sh"
    eagle_patch_hook "$SETTINGS" "TaskCompleted" "" "$EAGLE_MEM_DIR/hooks/post-tool-use.sh"
    eagle_patch_hook "$SETTINGS" "SessionEnd" "" "$EAGLE_MEM_DIR/hooks/session-end.sh"
    eagle_patch_hook "$SETTINGS" "UserPromptSubmit" "" "$EAGLE_MEM_DIR/hooks/user-prompt-submit.sh"
    eagle_patch_hook "$SETTINGS" "PreToolUse" "Bash" "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh"
    eagle_patch_hook "$SETTINGS" "PreToolUse" "Read" "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh"
    eagle_patch_hook "$SETTINGS" "PreToolUse" "Edit" "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh"
    eagle_patch_hook "$SETTINGS" "PreToolUse" "Write" "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh"

    eagle_ok "Hooks registered"
fi

if [ "$codex_found" = true ] && command -v jq &>/dev/null; then
    eagle_register_codex_hooks
    eagle_ok "Codex hooks registered"
elif [ "$codex_found" = false ]; then
    eagle_info "Codex hooks skipped ${DIM}(Codex not detected)${RESET}"
fi

# ─── Update skill symlinks ────────────────────────────────

if [ "$claude_found" = true ] && [ -d "$PACKAGE_DIR/skills" ]; then
    mkdir -p "$EAGLE_SKILLS_DIR"
    # Remove stale symlinks for deleted skills (find catches broken symlinks; glob doesn't)
    find "$EAGLE_SKILLS_DIR" -maxdepth 1 -name "eagle-mem-*" -type l 2>/dev/null | while read -r existing; do
        skill_name=$(basename "$existing")
        if [ ! -d "$PACKAGE_DIR/skills/$skill_name" ]; then
            rm "$existing"
            eagle_ok "Removed stale skill: $skill_name"
        fi
    done
    for skill_dir in "$PACKAGE_DIR"/skills/*/; do
        [ ! -d "$skill_dir" ] && continue
        skill_name=$(basename "$skill_dir")
        dst="$EAGLE_SKILLS_DIR/$skill_name"
        [ -L "$dst" ] && rm "$dst"
        ln -sf "$skill_dir" "$dst"
    done
    eagle_ok "Claude skills updated"
fi

if [ "$codex_found" = true ] && [ -d "$PACKAGE_DIR/skills" ]; then
    mkdir -p "$EAGLE_CODEX_SKILLS_DIR"
    find "$EAGLE_CODEX_SKILLS_DIR" -maxdepth 1 -name "eagle-mem-*" -type l 2>/dev/null | while read -r existing; do
        skill_name=$(basename "$existing")
        if [ ! -d "$PACKAGE_DIR/skills/$skill_name" ]; then
            rm "$existing"
            eagle_ok "Removed stale Codex skill: $skill_name"
        fi
    done
    for skill_dir in "$PACKAGE_DIR"/skills/*/; do
        [ ! -d "$skill_dir" ] && continue
        skill_name=$(basename "$skill_dir")
        dst="$EAGLE_CODEX_SKILLS_DIR/$skill_name"
        [ -L "$dst" ] && rm "$dst"
        ln -sf "$skill_dir" "$dst"
    done
    eagle_ok "Codex skills updated"
fi

# ─── Refresh generated Claude statusline wrapper ───────────

statusline_wrapper="$EAGLE_MEM_DIR/scripts/statusline-wrapper.sh"
if [ -f "$statusline_wrapper" ]; then
    cat > "$statusline_wrapper" << 'WRAPPER'
#!/usr/bin/env bash
input=$(cat)
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // ""' 2>/dev/null)
session_id=$(echo "$input" | jq -r '.session_id // .session.id // ""' 2>/dev/null)
source "$HOME/.eagle-mem/scripts/statusline-em.sh"
eagle_mem_statusline "$project_dir" "$session_id" "$input"
WRAPPER
    chmod +x "$statusline_wrapper"
    eagle_ok "Statusline wrapper updated"
fi

if [ "$claude_found" = true ] && [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    existing_sl=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)
    existing_sl_file=$(eagle_statusline_script_from_command "$existing_sl" 2>/dev/null || true)
    if eagle_patch_statusline_script "$existing_sl_file"; then
        eagle_ok "Statusline custom Eagle Mem block patched"
    elif [ -n "$existing_sl_file" ] && [ -f "$existing_sl_file" ] && grep -q "eagle-mem" "$existing_sl_file" && ! eagle_statusline_script_uses_input "$existing_sl_file"; then
        eagle_warn "Statusline custom Eagle Mem block needs manual input-aware update"
    fi
fi

# ─── Backfill project names ───────────────────────────────

backfilled=$(eagle_backfill_projects 2>/dev/null)
if [ "${backfilled:-0}" -gt 0 ]; then
    eagle_ok "Project names: $backfilled rows corrected"
else
    eagle_ok "Project names up to date"
fi

# ─── Ensure auto-update defaults exist ─────────────────────

eagle_update_ensure_defaults
eagle_ok "Auto-updates ${DIM}(mode=$(eagle_update_config_mode), allow=$(eagle_update_config_allow))${RESET}"

# ─── Patch CLAUDE.md with Eagle Mem instructions ─────────

if [ "$claude_found" = true ]; then
    if eagle_patch_claude_md; then
        eagle_ok "CLAUDE.md updated ${DIM}(eagle-summary instructions added)${RESET}"
    else
        eagle_ok "CLAUDE.md up to date"
    fi
fi

if [ "$codex_found" = true ]; then
    if eagle_patch_codex_agents_md; then
        eagle_ok "AGENTS.md updated ${DIM}(Codex clean-output memory instructions updated)${RESET}"
    else
        eagle_ok "AGENTS.md up to date"
    fi
fi

# ─── Save installed version ───────────────────────────────

version=$(jq -r .version "$PACKAGE_DIR/package.json" 2>/dev/null || echo "unknown")
echo "$version" > "$EAGLE_MEM_DIR/.version"
echo "$version" > "$EAGLE_MEM_DIR/.latest-version"

eagle_footer "Eagle Mem updated to v${version}."
