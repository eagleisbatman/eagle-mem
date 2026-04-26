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

migration_output=$("$EAGLE_MEM_DIR/db/migrate.sh" 2>/dev/null | grep -v -E '^(wal|5000)$')
if echo "$migration_output" | grep -q "applied:"; then
    echo "$migration_output" | grep "applied:" | while read -r line; do
        eagle_ok "Migration: ${line#*applied: }"
    done
else
    eagle_ok "Database up to date"
fi

# ─── Re-register hooks (idempotent) ───────────────────────

if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    patch_hook() {
        local event="$1"
        local matcher="$2"
        local command="$3"

        if jq -e ".hooks.${event}[]? | select(.hooks[]?.command == \"$command\")" "$SETTINGS" &>/dev/null; then
            return
        fi

        local entry
        if [ -n "$matcher" ]; then
            entry="{\"matcher\": \"$matcher\", \"hooks\": [{\"type\": \"command\", \"command\": \"$command\"}]}"
        else
            entry="{\"hooks\": [{\"type\": \"command\", \"command\": \"$command\"}]}"
        fi

        local tmp
        tmp=$(mktemp)
        jq --argjson entry "$entry" ".hooks.${event} = ((.hooks.${event} // []) + [\$entry])" "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    }

    patch_hook "SessionStart" "" "$EAGLE_MEM_DIR/hooks/session-start.sh"
    patch_hook "Stop" "" "$EAGLE_MEM_DIR/hooks/stop.sh"
    patch_hook "PostToolUse" "Read|Write|Edit|Bash" "$EAGLE_MEM_DIR/hooks/post-tool-use.sh"
    patch_hook "SessionEnd" "" "$EAGLE_MEM_DIR/hooks/session-end.sh"
    patch_hook "UserPromptSubmit" "" "$EAGLE_MEM_DIR/hooks/user-prompt-submit.sh"

    eagle_ok "Hooks registered"
fi

# ─── Update skill symlinks ────────────────────────────────

if [ -d "$PACKAGE_DIR/skills" ]; then
    mkdir -p "$EAGLE_SKILLS_DIR"
    for skill_dir in "$PACKAGE_DIR"/skills/*/; do
        [ ! -d "$skill_dir" ] && continue
        skill_name=$(basename "$skill_dir")
        dst="$EAGLE_SKILLS_DIR/$skill_name"
        [ -L "$dst" ] && rm "$dst"
        ln -sf "$skill_dir" "$dst"
    done
    eagle_ok "Skills updated"
fi

# ─── Summary ───────────────────────────────────────────────

version=$(node -e "console.log(require('$PACKAGE_DIR/package.json').version)" 2>/dev/null || echo "unknown")
eagle_footer "Eagle Mem updated to v${version}."
