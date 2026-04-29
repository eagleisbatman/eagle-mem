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
EAGLE_CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
EAGLE_CLAUDE_PLANS_DIR="$HOME/.claude/plans"
EAGLE_CLAUDE_TASKS_DIR="$HOME/.claude/tasks"

eagle_log() {
    local level="$1"
    shift
    # Ensure log file is owner-only (may contain debug data)
    if [ ! -f "$EAGLE_MEM_LOG" ]; then
        touch "$EAGLE_MEM_LOG" 2>/dev/null && chmod 600 "$EAGLE_MEM_LOG" 2>/dev/null
    fi
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$level] $*" >> "$EAGLE_MEM_LOG" 2>/dev/null || true
}

eagle_project_from_cwd() {
    local cwd="${1:-$(pwd)}"
    local resolved="$cwd"

    # Normalize macOS /private prefixes
    case "$resolved" in /private/tmp*) resolved="/tmp${resolved#/private/tmp}" ;; esac
    case "$resolved" in /private/var/*) resolved="/var${resolved#/private/var}" ;; esac

    # Skip ephemeral directories — return empty so hooks early-exit
    case "$resolved" in
        /tmp|/tmp/*|/var/tmp|/var/tmp/*) echo ""; return ;;
        /var/folders|/var/folders/*) echo ""; return ;;
        "$HOME/Downloads"|"$HOME/Downloads/"*) echo ""; return ;;
        "$HOME/Desktop"|"$HOME/Desktop/"*) echo ""; return ;;
    esac

    local git_root
    git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$git_root" ]; then
        basename "$git_root"
    else
        local name
        name=$(basename "$cwd")
        # Reject single-character project names (likely temp dir fragments)
        if [ ${#name} -le 1 ]; then
            echo ""; return
        fi
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

# Escape SQL LIKE wildcards (% and _) so literal filenames match exactly.
# Apply AFTER eagle_sql_escape, since this only handles LIKE metacharacters.
eagle_like_escape() {
    printf '%s' "$1" | sed 's/%/\\%/g; s/_/\\_/g'
}

# Validate a session ID is safe for use in file paths (no traversal).
# Claude Code session IDs are UUIDs or hex strings — reject anything else.
eagle_validate_session_id() {
    local sid="$1"
    # Length cap: Claude Code IDs are UUIDs/hex (36-64 chars). Reject oversized input.
    [ ${#sid} -gt 128 ] && return 1
    [[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]]
}

eagle_read_stdin() {
    local input=""
    if [ ! -t 0 ]; then
        input=$(cat)
    fi
    echo "$input"
}

# Redact secrets from text before storage.
# Covers: Bearer tokens, API keys, passwords, secrets, tokens,
# Stripe/AWS/GitHub/Anthropic/OpenAI key patterns, named env vars.
eagle_redact() {
    sed -E \
        -e 's/(Bearer )[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(api[_-]?key[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(password[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(secret[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(token[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(Authorization: )[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(client_secret[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(private_key[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(access_token[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/sk_live_[A-Za-z0-9]+/[REDACTED]/g' \
        -e 's/sk_test_[A-Za-z0-9]+/[REDACTED]/g' \
        -e 's/whsec_[A-Za-z0-9]+/[REDACTED]/g' \
        -e 's/AKIA[A-Z0-9]{16}/[REDACTED]/g' \
        -e 's/ghp_[A-Za-z0-9]{36}/[REDACTED]/g' \
        -e 's/gho_[A-Za-z0-9]{36}/[REDACTED]/g' \
        -e 's/glpat-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
        -e 's/sk-ant-[A-Za-z0-9_-]+/[REDACTED]/g' \
        -e 's/sk-[A-Za-z0-9]{20,}/[REDACTED]/g' \
        -e 's/AIza[0-9A-Za-z_-]{35}/[REDACTED]/g' \
        -e 's/xox[abps]-[A-Za-z0-9-]+/[REDACTED]/g' \
        -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[REDACTED_JWT]/g' \
        -e 's|(https?://[^/:]+:)[^@]+(@)|\1[REDACTED]\2|g' \
        -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY]/g' \
        -e 's/(ANTHROPIC_API_KEY[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/g' \
        -e 's/(OPENAI_API_KEY[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/g' \
        -e 's/(GOOGLE_API_KEY[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/g' \
        -e 's/(SLACK_TOKEN[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/g' \
        -e 's/(DATABASE_URL[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/g'
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

eagle_patch_claude_md() {
    local claude_md="$HOME/.claude/CLAUDE.md"
    local marker="## Eagle Mem — Persistent Memory"

    if [ -f "$claude_md" ] && grep -qF "$marker" "$claude_md" 2>/dev/null; then
        return 1
    fi

    mkdir -p "$HOME/.claude"

    cat >> "$claude_md" << 'EAGLE_MD'

---

## Eagle Mem — Persistent Memory

Eagle Mem hooks are active in every project. SessionStart injects context (overview, recent sessions, memories, tasks, core files). Stop captures session summaries. PostToolUse mirrors memories/plans/tasks.

**Rule:** Before your final response in every session, emit an `<eagle-summary>` block so the Stop hook can capture a rich summary instead of just heuristics.

```
<eagle-summary>
request: [what user asked] | completed: [what shipped] | learned: [non-obvious discoveries]
next_steps: [concrete actions] | decisions: [choice — why] | gotchas: [what surprised]
key_files: [path — role] | files_read: [...] | files_modified: [...]
</eagle-summary>
```

**Why:** Without this block, summaries degrade to "(auto-captured)" with no decisions, gotchas, or learned context. Rich summaries are what make future sessions useful.

**How to apply:**
- Emit `<eagle-summary>` before your final text response, every session
- When Eagle Mem injects context at SessionStart, attribute it: "Eagle Mem recalls:"
- Do not revert decisions surfaced by PostToolUse without asking the user
- Never put raw secrets in the summary — Eagle Mem redacts but defense in depth
- If you contradict a loaded memory, update the memory file
EAGLE_MD
}
