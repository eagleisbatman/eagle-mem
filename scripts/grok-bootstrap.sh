#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Grok Bootstrap
# Helps set up and verify Grok integration
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"
PACKAGE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"

eagle_banner
eagle_header "Grok Bootstrap"

if [ ! -d "$EAGLE_GROK_DIR" ]; then
    eagle_fail "~/.grok/ directory not found"
    echo ""
    eagle_info "Create it and re-run this command, or run 'eagle-mem install' first."
    exit 1
fi

eagle_ok "Grok environment detected ($EAGLE_GROK_DIR)"

# Check skills
skill_count=0
if [ -d "$EAGLE_GROK_SKILLS_DIR" ]; then
    skill_count=$(find "$EAGLE_GROK_SKILLS_DIR" -maxdepth 1 -name "eagle-mem-*" -type d 2>/dev/null | wc -l | tr -d ' ')
fi

if [ "$skill_count" -gt 0 ]; then
    eagle_ok "Grok skills installed ($skill_count eagle-mem-* skills)"
else
    eagle_warn "No eagle-mem skills found in $EAGLE_GROK_SKILLS_DIR"
    if [ -d "$PACKAGE_DIR/skills" ]; then
        echo ""
        if eagle_confirm "Link Eagle Mem skills into ~/.grok/skills/ now?"; then
            mkdir -p "$EAGLE_GROK_SKILLS_DIR"
            for skill_dir in "$PACKAGE_DIR"/skills/*/; do
                [ ! -d "$skill_dir" ] && continue
                skill_name=$(basename "$skill_dir")
                dst="$EAGLE_GROK_SKILLS_DIR/$skill_name"
                [ -L "$dst" ] && rm "$dst"
                ln -sf "$skill_dir" "$dst"
                eagle_ok "Linked: $skill_name"
            done
        fi
    else
        eagle_info "Run 'eagle-mem install' or 'eagle-mem update' to link them."
    fi
fi

echo ""
eagle_info "How to use Eagle Mem inside Grok:"
echo ""
eagle_dim "  • The six skills are available in the skill picker:"
eagle_dim "      eagle-mem-search, eagle-mem-overview, eagle-mem-tasks,"
eagle_dim "      eagle-mem-memories, eagle-mem-orchestrate, eagle-mem-feature"
echo ""
eagle_dim "  • From the command line (in this project):"
eagle_dim "      eagle-mem search \"auth bug\""
eagle_dim "      eagle-mem overview"
eagle_dim "      eagle-mem tasks"
echo ""
eagle_info "For long-running or multi-step work, use durable tasks:"
eagle_dim "  eagle-mem tasks add \"...\" --agent grok"
echo ""
eagle_ok "Grok bootstrap complete. You now have the same skills as Claude Code and Codex users."

echo ""