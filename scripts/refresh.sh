#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Refresh
# Full project sync: scan (if needed) + index + memories sync
# One command to bring everything up to date
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

TARGET_DIR="${1:-.}"
if [ ! -d "$TARGET_DIR" ]; then
    eagle_err "Directory not found: $TARGET_DIR"
    exit 1
fi
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
PROJECT=$(eagle_project_from_cwd "$TARGET_DIR")

eagle_header "Refresh"
eagle_info "Syncing ${BOLD}$PROJECT${RESET} at $TARGET_DIR"
echo ""

failed=0
STEP_LOG=$(mktemp)
trap 'rm -f "$STEP_LOG"' EXIT

run_step() {
    local label="$1"; shift
    if "$@" > "$STEP_LOG" 2>&1; then
        tail -5 "$STEP_LOG"
        eagle_ok "$label complete"
    else
        cat "$STEP_LOG"
        eagle_warn "$label had issues (non-fatal)"
        failed=$((failed + 1))
    fi
}

# ─── 1. Structural scan (scan.sh guards against overwriting manual overviews) ──
eagle_info "Step 1/4: Scanning codebase structure..."
run_step "Scan" bash "$SCRIPTS_DIR/scan.sh" "$TARGET_DIR"
echo ""

# ─── 2. Code indexing ────────────────────────────────────
eagle_info "Step 2/4: Indexing source files..."
run_step "Index" bash "$SCRIPTS_DIR/index.sh" "$TARGET_DIR"
echo ""

# ─── 3. Memory sync ─────────────────────────────────────
eagle_info "Step 3/4: Syncing Claude Code memories, plans, and tasks..."
run_step "Memory sync" bash "$SCRIPTS_DIR/memories.sh" sync
echo ""

# ─── 4. Stats ────────────────────────────────────────────
eagle_info "Step 4/4: Verifying..."

project_sql=$(eagle_sql_escape "$PROJECT")
sessions=$(eagle_db "SELECT COUNT(*) FROM sessions WHERE project = '$project_sql';")
summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project = '$project_sql';")
chunks=$(eagle_db "SELECT COUNT(*) FROM code_chunks WHERE project = '$project_sql';")
memories=$(eagle_db "SELECT COUNT(*) FROM claude_memories WHERE project = '$project_sql';")
tasks=$(eagle_db "SELECT COUNT(*) FROM claude_tasks WHERE project = '$project_sql';")

echo ""
eagle_kv "Sessions:" "${sessions:-0}"
eagle_kv "Summaries:" "${summaries:-0}"
eagle_kv "Code chunks:" "${chunks:-0}"
eagle_kv "Memories:" "${memories:-0}"
eagle_kv "Tasks:" "${tasks:-0}"

if [ "$failed" -eq 0 ]; then
    eagle_footer "Refresh complete. Run /eagle-mem-overview inside Claude Code for a rich project briefing."
else
    eagle_footer "Refresh complete with $failed warning(s)."
fi
