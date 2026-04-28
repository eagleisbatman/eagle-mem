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
. "$LIB_DIR/hooks.sh"

SETTINGS="$EAGLE_SETTINGS"

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

# ─── Update files ──────────────────────────────────────────

mkdir -p "$EAGLE_MEM_DIR"/{hooks,lib,db}

cp "$PACKAGE_DIR"/hooks/*.sh "$EAGLE_MEM_DIR/hooks/"
cp "$PACKAGE_DIR"/lib/*.sh "$EAGLE_MEM_DIR/lib/"
cp "$PACKAGE_DIR"/db/*.sh "$EAGLE_MEM_DIR/db/"
cp "$PACKAGE_DIR"/db/*.sql "$EAGLE_MEM_DIR/db/"

chmod +x "$EAGLE_MEM_DIR"/hooks/*.sh
chmod +x "$EAGLE_MEM_DIR"/db/migrate.sh

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

if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    # Update PostToolUse matcher if it has the old value (pre-v1.3.0)
    if jq -e '.hooks.PostToolUse[]? | select(.matcher == "Read|Write|Edit|Bash")' "$SETTINGS" &>/dev/null; then
        _tmp=$(mktemp)
        jq '(.hooks.PostToolUse[] | select(.matcher == "Read|Write|Edit|Bash")).matcher = "Read|Write|Edit|Bash|TaskCreate|TaskUpdate"' "$SETTINGS" > "$_tmp" && mv "$_tmp" "$SETTINGS"
    fi

    eagle_patch_hook "$SETTINGS" "SessionStart" "" "$EAGLE_MEM_DIR/hooks/session-start.sh"
    eagle_patch_hook "$SETTINGS" "Stop" "" "$EAGLE_MEM_DIR/hooks/stop.sh"
    eagle_patch_hook "$SETTINGS" "PostToolUse" "Read|Write|Edit|Bash|TaskCreate|TaskUpdate" "$EAGLE_MEM_DIR/hooks/post-tool-use.sh"
    eagle_patch_hook "$SETTINGS" "SessionEnd" "" "$EAGLE_MEM_DIR/hooks/session-end.sh"
    eagle_patch_hook "$SETTINGS" "UserPromptSubmit" "" "$EAGLE_MEM_DIR/hooks/user-prompt-submit.sh"
    eagle_patch_hook "$SETTINGS" "PreToolUse" "Bash" "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh"

    eagle_ok "Hooks registered"
fi

# ─── Update skill symlinks ────────────────────────────────

if [ -d "$PACKAGE_DIR/skills" ]; then
    mkdir -p "$EAGLE_SKILLS_DIR"
    # Remove stale symlinks for deleted skills
    for existing in "$EAGLE_SKILLS_DIR"/eagle-mem-*/; do
        local_path="${existing%/}"
        [ ! -L "$local_path" ] && continue
        skill_name=$(basename "$local_path")
        if [ ! -d "$PACKAGE_DIR/skills/$skill_name" ]; then
            rm "$local_path"
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
    eagle_ok "Skills updated"
fi

# ─── Backfill project names ───────────────────────────────

backfilled=$(eagle_backfill_projects 2>/dev/null)
if [ "${backfilled:-0}" -gt 0 ]; then
    eagle_ok "Project names: $backfilled rows corrected"
else
    eagle_ok "Project names up to date"
fi

# ─── Save installed version ───────────────────────────────

version=$(jq -r .version "$PACKAGE_DIR/package.json" 2>/dev/null || echo "unknown")
echo "$version" > "$EAGLE_MEM_DIR/.version"

eagle_footer "Eagle Mem updated to v${version}."
