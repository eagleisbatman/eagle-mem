#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Shared constants and helpers
# Source this file: . "$(dirname "$0")/../lib/common.sh"
# ═══════════════════════════════════════════════════════════

EAGLE_MEM_DIR="${EAGLE_MEM_DIR:-$HOME/.eagle-mem}"
EAGLE_MEM_DB="$EAGLE_MEM_DIR/memory.db"
EAGLE_MEM_LOG="$EAGLE_MEM_DIR/eagle-mem.log"
EAGLE_SETTINGS="${EAGLE_SETTINGS:-$HOME/.claude/settings.json}"
EAGLE_SKILLS_DIR="$HOME/.claude/skills"

eagle_log() {
    local level="$1"
    shift
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$level] $*" >> "$EAGLE_MEM_LOG" 2>/dev/null || true
}

eagle_project_from_cwd() {
    local cwd="${1:-$(pwd)}"
    local git_root
    git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$git_root" ]; then
        basename "$git_root"
    else
        basename "$cwd"
    fi
}

eagle_sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

eagle_sql_int() {
    case "$1" in
        ''|*[!0-9]*) echo "0" ;;
        *) printf '%s' "$1" ;;
    esac
}

eagle_fts_sanitize() {
    printf '%s' "$1" | sed 's/[*"(){}^~:]/  /g' | sed 's/  */ /g; s/^ //; s/ $//'
}

# Validate a session ID is safe for use in file paths (no traversal).
# Claude Code session IDs are UUIDs or hex strings — reject anything else.
eagle_validate_session_id() {
    local sid="$1"
    [[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]]
}

eagle_read_stdin() {
    local input=""
    if [ ! -t 0 ]; then
        input=$(cat)
    fi
    echo "$input"
}

# Collect project files into a destination file.
# Uses git ls-files when available, falls back to find with common exclusions.
# Usage: eagle_collect_files <target_dir> <output_file>
eagle_collect_files() {
    local target_dir="$1"
    local output_file="$2"

    if git -C "$target_dir" rev-parse --is-inside-work-tree &>/dev/null; then
        git -C "$target_dir" ls-files --cached --others --exclude-standard > "$output_file"
    else
        (cd "$target_dir" && find . -type f \
            -not -path '*/node_modules/*' \
            -not -path '*/.git/*' \
            -not -path '*/dist/*' \
            -not -path '*/build/*' \
            -not -path '*/.next/*' \
            -not -path '*/target/*' \
            -not -path '*/vendor/*' \
            -not -path '*/__pycache__/*' \
            -not -path '*/.venv/*' \
            -not -path '*/venv/*' \
            -not -path '*/.egg-info/*' \
            -not -name '*.pyc' \
            -not -name '*.lock' \
            -not -name 'package-lock.json' \
            -not -name 'yarn.lock' \
            -not -name 'pnpm-lock.yaml' \
            | sed 's|^\./||') > "$output_file"
    fi
}
