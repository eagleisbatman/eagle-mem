#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Prune
# Removes old observations and orphaned code chunks
# to keep the database lean
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

# ─── Help ────────────────────────────────────────────────

show_help() {
    echo -e "  ${BOLD}eagle-mem prune${RESET} — Clean up old data"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem prune                     ${DIM}# prune observations > 90 days${RESET}"
    echo -e "    eagle-mem prune ${CYAN}--days 30${RESET}           ${DIM}# prune observations > 30 days${RESET}"
    echo -e "    eagle-mem prune ${CYAN}--dry-run${RESET}           ${DIM}# show what would be pruned${RESET}"
    echo ""
    echo -e "  ${BOLD}What gets pruned:${RESET}"
    echo -e "    ${DOT} Observations older than --days (default: 90)"
    echo -e "    ${DOT} Code chunks for files that no longer exist"
    echo ""
    echo -e "  ${BOLD}What is preserved:${RESET}"
    echo -e "    ${DOT} All sessions and summaries (your session history)"
    echo -e "    ${DOT} All tasks"
    echo -e "    ${DOT} Project overviews"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    ${CYAN}-d, --days${RESET} <N>        Age threshold (default: 90)"
    echo -e "    ${CYAN}-p, --project${RESET} <name>  Only prune for this project"
    echo -e "    ${CYAN}-n, --dry-run${RESET}         Show counts without deleting"
    echo ""
    exit 0
}

# ─── Parse arguments ──────────────────────────────────────

days=90
project=""
dry_run=false

while [ $# -gt 0 ]; do
    case "$1" in
        --days|-d)      days="$2"; shift 2 ;;
        --project|-p)   project="$2"; shift 2 ;;
        --dry-run|-n)   dry_run=true; shift ;;
        --help|-h)  show_help ;;
        *)
            eagle_err "Unknown option: $1"
            exit 1
            ;;
    esac
done

if ! [[ "$days" =~ ^[0-9]+$ ]]; then
    eagle_err "Days must be a number, got: $days"
    exit 1
fi

eagle_header "Prune"

# ─── Count before ────────────────────────────────────────

total_obs=$(eagle_db "SELECT COUNT(*) FROM observations;")
total_chunks=$(eagle_db "SELECT COUNT(*) FROM code_chunks;")
eagle_info "Database: ${total_obs:-0} observations, ${total_chunks:-0} chunks"
echo ""

# ─── Old observations ───────────────────────────────────

obs_project_filter=""
if [ -n "$project" ]; then
    obs_project_filter="AND session_id IN (SELECT id FROM sessions WHERE project = '$(eagle_sql_escape "$project")')"
fi

old_obs_count=$(eagle_db "SELECT COUNT(*) FROM observations WHERE created_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-$days days') $obs_project_filter;")

if [ "${old_obs_count:-0}" -gt 0 ]; then
    if [ "$dry_run" = true ]; then
        eagle_dim "Would prune $old_obs_count observations older than $days days"
    else
        eagle_prune_observations "$days" "$project"
        eagle_ok "Pruned $old_obs_count observations older than $days days"
    fi
else
    eagle_ok "No observations older than $days days"
fi

# ─── Orphaned code chunks ───────────────────────────────

if [ -n "$project" ]; then
    projects="$project"
else
    projects=$(eagle_db "SELECT DISTINCT project FROM code_chunks;")
fi

orphan_total=0
if [ -n "$projects" ]; then
    while IFS= read -r proj; do
        [ -z "$proj" ] && continue

        # Try to find the project directory
        proj_cwd=$(eagle_db "SELECT cwd FROM sessions WHERE project = '$(eagle_sql_escape "$proj")' ORDER BY started_at DESC LIMIT 1;")

        if [ -n "$proj_cwd" ] && [ -d "$proj_cwd" ]; then
            if [ "$dry_run" = true ]; then
                # Count files that no longer exist
                orphans=0
                paths=$(eagle_db "SELECT DISTINCT file_path FROM code_chunks WHERE project = '$(eagle_sql_escape "$proj")';")
                while IFS= read -r fpath; do
                    [ -z "$fpath" ] && continue
                    [ ! -f "$proj_cwd/$fpath" ] && orphans=$((orphans + 1))
                done <<< "$paths"
                if [ "$orphans" -gt 0 ]; then
                    eagle_dim "Would prune $orphans orphaned files from '$proj'"
                    orphan_total=$((orphan_total + orphans))
                fi
            else
                removed=$(eagle_prune_orphan_chunks "$proj" "$proj_cwd")
                if [ "${removed:-0}" -gt 0 ]; then
                    eagle_ok "Pruned $removed orphaned files from '$proj'"
                    orphan_total=$((orphan_total + removed))
                fi
            fi
        fi
    done <<< "$projects"
fi

if [ "$orphan_total" -eq 0 ]; then
    eagle_ok "No orphaned code chunks found"
fi

# ─── Summary ────────────────────────────────────────────

new_obs=$(eagle_db "SELECT COUNT(*) FROM observations;")
new_chunks=$(eagle_db "SELECT COUNT(*) FROM code_chunks;")

echo ""
if [ "$dry_run" = true ]; then
    eagle_footer "Dry run complete (no changes made)."
else
    eagle_footer "Prune complete."
fi

eagle_kv "Observations:" "${new_obs:-0} (was ${total_obs:-0})"
eagle_kv "Code chunks:" "${new_chunks:-0} (was ${total_chunks:-0})"
eagle_kv "Database:" "$EAGLE_MEM_DB"
echo ""
