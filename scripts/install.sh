#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Install
# Sets up hooks, database, and skills for Claude Code
# ═══════════════════════════════════════════════════════════
set -euo pipefail

PACKAGE_DIR="${1:-.}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/hooks.sh"

SETTINGS="$EAGLE_SETTINGS"

eagle_banner
eagle_header "Install"

# ─── Detect platform ───────────────────────────────────────

detect_pkg_manager() {
    if command -v brew &>/dev/null; then
        echo "brew"
    elif command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo ""
    fi
}

install_package() {
    local pkg="$1"
    local mgr
    mgr=$(detect_pkg_manager)

    case "$mgr" in
        brew)   eagle_info "Running: brew install $pkg"; brew install "$pkg" ;;
        apt)    eagle_info "Running: sudo apt-get install -y $pkg"; sudo apt-get install -y "$pkg" ;;
        dnf)    eagle_info "Running: sudo dnf install -y $pkg"; sudo dnf install -y "$pkg" ;;
        pacman) eagle_info "Running: sudo pacman -S --noconfirm $pkg"; sudo pacman -S --noconfirm "$pkg" ;;
        *)
            eagle_fail "No package manager found. Install $pkg manually and re-run."
            exit 1
            ;;
    esac
}

# ─── Check prerequisites ───────────────────────────────────

echo -e "  ${BOLD}Checking prerequisites...${RESET}"
echo ""

prereqs_ok=true

# sqlite3
if command -v sqlite3 &>/dev/null; then
    sqlite_version=$(sqlite3 --version 2>/dev/null | awk '{print $1}')
    eagle_ok "sqlite3 ${DIM}($sqlite_version)${RESET}"
else
    eagle_fail "sqlite3 not found"
    if eagle_confirm "Install sqlite3?"; then
        install_package sqlite3
        if command -v sqlite3 &>/dev/null; then
            sqlite_version=$(sqlite3 --version 2>/dev/null | awk '{print $1}')
            eagle_ok "sqlite3 installed ${DIM}($sqlite_version)${RESET}"
        else
            eagle_fail "sqlite3 installation failed"
            prereqs_ok=false
        fi
    else
        prereqs_ok=false
    fi
fi

# FTS5 support
if command -v sqlite3 &>/dev/null; then
    if sqlite3 :memory: "SELECT sqlite_compileoption_used('ENABLE_FTS5');" 2>/dev/null | grep -q "1"; then
        eagle_ok "FTS5 support"
    else
        eagle_fail "SQLite was compiled without FTS5 support"
        eagle_dim "On macOS: brew install sqlite3 (system sqlite3 includes FTS5)"
        eagle_dim "On Linux: install libsqlite3-dev or rebuild with --enable-fts5"
        prereqs_ok=false
    fi
fi

# jq
if command -v jq &>/dev/null; then
    jq_version=$(jq --version 2>/dev/null | sed 's/jq-//')
    eagle_ok "jq ${DIM}($jq_version)${RESET}"
else
    eagle_fail "jq not found"
    if eagle_confirm "Install jq?"; then
        install_package jq
        if command -v jq &>/dev/null; then
            jq_version=$(jq --version 2>/dev/null | sed 's/jq-//')
            eagle_ok "jq installed ${DIM}($jq_version)${RESET}"
        else
            eagle_fail "jq installation failed"
            prereqs_ok=false
        fi
    else
        prereqs_ok=false
    fi
fi

# Claude Code
if [ -d "$HOME/.claude" ]; then
    eagle_ok "Claude Code ${DIM}(~/.claude/)${RESET}"
else
    eagle_fail "Claude Code not found (~/.claude/ does not exist)"
    echo ""
    eagle_dim "Install Claude Code first:"
    eagle_dim "  npm install -g @anthropic-ai/claude-code"
    eagle_dim "  https://docs.anthropic.com/en/docs/claude-code"
    echo ""
    exit 1
fi

if [ "$prereqs_ok" = false ]; then
    echo ""
    eagle_err "Prerequisites not met. Fix the issues above and re-run."
    exit 1
fi

echo ""

# ─── Copy files to ~/.eagle-mem/ ───────────────────────────

echo -e "  ${BOLD}Installing Eagle Mem...${RESET}"
echo ""

mkdir -p "$EAGLE_MEM_DIR"/{hooks,lib,db,scripts}

cp "$PACKAGE_DIR"/hooks/*.sh "$EAGLE_MEM_DIR/hooks/"
cp "$PACKAGE_DIR"/lib/*.sh "$EAGLE_MEM_DIR/lib/"
cp "$PACKAGE_DIR"/db/*.sh "$EAGLE_MEM_DIR/db/"
cp "$PACKAGE_DIR"/db/*.sql "$EAGLE_MEM_DIR/db/"
cp "$PACKAGE_DIR"/scripts/*.sh "$EAGLE_MEM_DIR/scripts/" 2>/dev/null

chmod +x "$EAGLE_MEM_DIR"/hooks/*.sh
chmod +x "$EAGLE_MEM_DIR"/db/migrate.sh
chmod +x "$EAGLE_MEM_DIR"/scripts/*.sh 2>/dev/null

eagle_ok "Files copied to $EAGLE_MEM_DIR"

# ─── Run migrations ────────────────────────────────────────

if ! "$EAGLE_MEM_DIR/db/migrate.sh" 2>/dev/null; then
    eagle_err "Database migration failed"
    exit 1
fi
eagle_ok "Database ready"

# ─── Patch settings.json ───────────────────────────────────

if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi

eagle_patch_hook "$SETTINGS" "SessionStart" "" \
    "$EAGLE_MEM_DIR/hooks/session-start.sh" \
    "SessionStart hook"

eagle_patch_hook "$SETTINGS" "Stop" "" \
    "$EAGLE_MEM_DIR/hooks/stop.sh" \
    "Stop hook"

eagle_patch_hook "$SETTINGS" "PostToolUse" "Read|Write|Edit|Bash|TaskCreate|TaskUpdate" \
    "$EAGLE_MEM_DIR/hooks/post-tool-use.sh" \
    "PostToolUse hook"

eagle_patch_hook "$SETTINGS" "SessionEnd" "" \
    "$EAGLE_MEM_DIR/hooks/session-end.sh" \
    "SessionEnd hook"

eagle_patch_hook "$SETTINGS" "UserPromptSubmit" "" \
    "$EAGLE_MEM_DIR/hooks/user-prompt-submit.sh" \
    "UserPromptSubmit hook"

eagle_patch_hook "$SETTINGS" "PreToolUse" "Bash" \
    "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh" \
    "PreToolUse hook (Bash)"

eagle_patch_hook "$SETTINGS" "PreToolUse" "Read" \
    "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh" \
    "PreToolUse hook (Read)"

eagle_patch_hook "$SETTINGS" "PreToolUse" "Edit" \
    "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh" \
    "PreToolUse hook (Edit)"

eagle_patch_hook "$SETTINGS" "PreToolUse" "Write" \
    "$EAGLE_MEM_DIR/hooks/pre-tool-use.sh" \
    "PreToolUse hook (Write)"

# ─── Install skills ────────────────────────────────────────

if [ -d "$PACKAGE_DIR/skills" ]; then
    mkdir -p "$EAGLE_SKILLS_DIR"
    for skill_dir in "$PACKAGE_DIR"/skills/*/; do
        [ ! -d "$skill_dir" ] && continue
        skill_name=$(basename "$skill_dir")
        dst="$EAGLE_SKILLS_DIR/$skill_name"
        [ -L "$dst" ] && rm "$dst"
        ln -sf "$skill_dir" "$dst"
        eagle_ok "Skill: $skill_name"
    done
fi

# ─── Statusline integration ───────────────────────────────

EM_STATUSLINE="$EAGLE_MEM_DIR/scripts/statusline-em.sh"
existing_sl=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)

if [ -z "$existing_sl" ]; then
    # No statusline configured — set up a minimal one that shows Eagle Mem
    wrapper="$EAGLE_MEM_DIR/scripts/statusline-wrapper.sh"
    cat > "$wrapper" << 'WRAPPER'
#!/usr/bin/env bash
input=$(cat)
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // ""' 2>/dev/null)
source "$HOME/.eagle-mem/scripts/statusline-em.sh"
eagle_mem_statusline "$project_dir"
WRAPPER
    chmod +x "$wrapper"
    tmp=$(mktemp)
    jq --arg cmd "sh $wrapper" '.statusLine = {"type": "command", "command": $cmd, "refreshInterval": 30}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    eagle_ok "Statusline ${DIM}(new — Eagle Mem indicator)${RESET}"
elif echo "$existing_sl" | grep -q "eagle-mem"; then
    eagle_ok "Statusline ${DIM}(already has Eagle Mem)${RESET}"
else
    # Existing statusline — check if it's a .sh file we can patch
    sl_file=$(echo "$existing_sl" | sed 's/^sh //')
    if [ -f "$sl_file" ] && ! grep -q "eagle-mem" "$sl_file"; then
        eagle_dim "  Statusline detected: $sl_file"
        eagle_dim "  To add Eagle Mem, add this snippet before your ASSEMBLE section:"
        echo ""
        eagle_dim "    # ── EAGLE MEM ──"
        eagle_dim "    em_section=\"\""
        eagle_dim "    em_db=\"\$HOME/.eagle-mem/memory.db\""
        eagle_dim "    if [ -f \"\$em_db\" ]; then"
        eagle_dim "      em_proj=\$(basename \"\$project_dir\" | sed \"s/'/''/g\")"
        eagle_dim "      em_cnt=\$(echo \".headers off"
        eagle_dim "    SELECT COUNT(*) FROM sessions WHERE project = '\${em_proj}';\" | sqlite3 \"\$em_db\" 2>/dev/null | tr -d '[:space:]')"
        eagle_dim "      em_mem=\$(echo \".headers off"
        eagle_dim "    SELECT COUNT(*) FROM claude_memories WHERE project = '\${em_proj}';\" | sqlite3 \"\$em_db\" 2>/dev/null | tr -d '[:space:]')"
        eagle_dim "      em_cnt=\${em_cnt:-0}; em_mem=\${em_mem:-0}"
        eagle_dim "      em_section=\$(printf \"%bEagle Mem%b %b%s%b ses %b%s%b mem\" \"\$CYAN\" \"\$R\" \"\$WHT\" \"\$em_cnt\" \"\$DIM\" \"\$WHT\" \"\$em_mem\" \"\$R\")"
        eagle_dim "    fi"
        echo ""
        eagle_ok "Statusline ${DIM}(manual patch needed — instructions above)${RESET}"
    else
        eagle_ok "Statusline ${DIM}(existing — cannot auto-patch; add Eagle Mem manually)${RESET}"
    fi
fi

# ─── Initialize config ────────────────────────────────────

. "$LIB_DIR/provider.sh"
if [ ! -f "$EAGLE_CONFIG_FILE" ]; then
    eagle_config_init
    eagle_ok "Config created ${DIM}(auto-detected provider)${RESET}"
else
    eagle_ok "Config ${DIM}(already exists)${RESET}"
fi

# ─── Save installed version ───────────────────────────────

version=$(jq -r .version "$PACKAGE_DIR/package.json" 2>/dev/null || echo "unknown")
echo "$version" > "$EAGLE_MEM_DIR/.version"

# ─── Summary ───────────────────────────────────────────────

eagle_footer "Eagle Mem installed successfully."

eagle_kv "Database:" "$EAGLE_MEM_DIR/memory.db"
eagle_kv "Hooks:" "$EAGLE_MEM_DIR/hooks/"
eagle_kv "Settings:" "$SETTINGS"

echo ""
eagle_dim "Start a new Claude Code session — Eagle Mem will activate automatically."
echo ""
