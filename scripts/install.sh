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

mkdir -p "$EAGLE_MEM_DIR"/{hooks,lib,db}

cp "$PACKAGE_DIR"/hooks/*.sh "$EAGLE_MEM_DIR/hooks/"
cp "$PACKAGE_DIR"/lib/*.sh "$EAGLE_MEM_DIR/lib/"
cp "$PACKAGE_DIR"/db/*.sh "$EAGLE_MEM_DIR/db/"
cp "$PACKAGE_DIR"/db/*.sql "$EAGLE_MEM_DIR/db/"

chmod +x "$EAGLE_MEM_DIR"/hooks/*.sh
chmod +x "$EAGLE_MEM_DIR"/db/migrate.sh

eagle_ok "Files copied to $EAGLE_MEM_DIR"

# ─── Run migrations ────────────────────────────────────────

"$EAGLE_MEM_DIR/db/migrate.sh" 2>/dev/null | grep -v -E '^(wal|5000|Eagle Mem database)$' > /dev/null
eagle_ok "Database ready"

# ─── Patch settings.json ───────────────────────────────────

if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi

patch_hook() {
    local event="$1"
    local matcher="$2"
    local command="$3"
    local description="$4"

    if jq -e ".hooks.${event}[]? | select(.hooks[]?.command == \"$command\")" "$SETTINGS" &>/dev/null; then
        eagle_ok "$description ${DIM}(already registered)${RESET}"
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
    eagle_ok "$description"
}

patch_hook "SessionStart" "" \
    "$EAGLE_MEM_DIR/hooks/session-start.sh" \
    "SessionStart hook"

patch_hook "Stop" "" \
    "$EAGLE_MEM_DIR/hooks/stop.sh" \
    "Stop hook"

patch_hook "PostToolUse" "Read|Write|Edit|Bash" \
    "$EAGLE_MEM_DIR/hooks/post-tool-use.sh" \
    "PostToolUse hook"

patch_hook "SessionEnd" "" \
    "$EAGLE_MEM_DIR/hooks/session-end.sh" \
    "SessionEnd hook"

patch_hook "UserPromptSubmit" "" \
    "$EAGLE_MEM_DIR/hooks/user-prompt-submit.sh" \
    "UserPromptSubmit hook"

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

# ─── Summary ───────────────────────────────────────────────

eagle_footer "Eagle Mem installed successfully."

eagle_kv "Database:" "$EAGLE_MEM_DIR/memory.db"
eagle_kv "Hooks:" "$EAGLE_MEM_DIR/hooks/"
eagle_kv "Settings:" "$SETTINGS"

echo ""
eagle_dim "Start a new Claude Code session — Eagle Mem will activate automatically."
echo ""
