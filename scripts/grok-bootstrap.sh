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
broken_links=0
if [ -d "$EAGLE_GROK_SKILLS_DIR" ]; then
    for link in "$EAGLE_GROK_SKILLS_DIR"/eagle-mem-*; do
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            broken_links=$((broken_links + 1))
        elif [ -d "$link" ]; then
            skill_count=$((skill_count + 1))
        fi
    done
fi

if [ "$broken_links" -gt 0 ]; then
    eagle_warn "Detected $broken_links broken or invalid Grok skill symlinks!"
fi

if [ "$skill_count" -gt 0 ] && [ "$broken_links" -eq 0 ]; then
    eagle_ok "Grok skills installed ($skill_count eagle-mem-* skills)"
else
    if [ "$broken_links" -gt 0 ]; then
        echo ""
        eagle_info "Repairing broken skill symlinks now..."
    fi
    if [ -d "$PACKAGE_DIR/skills" ]; then
        echo ""
        if eagle_confirm "Link/repair Eagle Mem skills into ~/.grok/skills/ now?"; then
            mkdir -p "$EAGLE_GROK_SKILLS_DIR"
            for skill_dir in "$PACKAGE_DIR"/skills/*/; do
                [ ! -d "$skill_dir" ] && continue
                skill_name=$(basename "$skill_dir")
                dst="$EAGLE_GROK_SKILLS_DIR/$skill_name"
                
                # Protect custom user folders with a timestamped backup
                if [ -d "$dst" ] && [ ! -L "$dst" ]; then
                    backup_dst="${dst}.bak.$(date +%Y%m%d%H%M%S)"
                    eagle_warn "Custom directory found at $dst. Backing up to $(basename "$backup_dst")..."
                    mv "$dst" "$backup_dst"
                fi
                
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