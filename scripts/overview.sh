#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Overview
# CLI wrapper for project overview management
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

# ─── Parse arguments ──────────────────────────────────────

action="${1:-show}"
shift 2>/dev/null || true

project=""
json_output=false
args=()

while [ $# -gt 0 ]; do
    case "$1" in
        --project|-p)   project="$2"; shift 2 ;;
        --json|-j)      json_output=true; shift ;;
        --help|-h)
            echo -e "  ${BOLD}eagle-mem overview${RESET} — Manage project overviews"
            echo ""
            echo -e "  ${BOLD}Usage:${RESET}"
            echo -e "    eagle-mem overview                    ${DIM}# show current overview${RESET}"
            echo -e "    eagle-mem overview ${CYAN}set${RESET} <text>         ${DIM}# set/update overview${RESET}"
            echo -e "    eagle-mem overview ${CYAN}delete${RESET}             ${DIM}# delete overview${RESET}"
            echo -e "    eagle-mem overview ${CYAN}list${RESET}               ${DIM}# list all overviews${RESET}"
            echo ""
            echo -e "  ${BOLD}Options:${RESET}"
            echo -e "    ${CYAN}-p, --project${RESET} <name>    Project name (default: current dir)"
            echo -e "    ${CYAN}-j, --json${RESET}              Output as JSON"
            echo ""
            echo -e "  ${BOLD}Tip:${RESET} Use ${CYAN}eagle-mem scan${RESET} to auto-generate an overview from code."
            echo ""
            exit 0
            ;;
        *)  args+=("$1"); shift ;;
    esac
done

[ -z "$project" ] && project=$(eagle_project_from_cwd "$(pwd)")
project_sql=$(eagle_sql_escape "$project")

# ─── Show overview ────────────────────────────────────────

overview_show() {
    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT project, content, updated_at FROM overviews WHERE project = '$project_sql';"
        return
    fi

    local content
    content=$(eagle_get_overview "$project")

    if [ -z "$content" ]; then
        eagle_dim "No overview for project '$project'"
        eagle_dim "Run 'eagle-mem scan' or 'eagle-mem overview set <text>' to create one"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Overview${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""
    echo -e "  $content"
    echo ""
}

# ─── Set overview ─────────────────────────────────────────

overview_set() {
    local content="${args[*]:-}"

    if [ -z "$content" ]; then
        eagle_err "Usage: eagle-mem overview set <text>"
        exit 1
    fi

    eagle_upsert_overview "$project" "$content"

    if [ "$json_output" = true ]; then
        printf '{"project":"%s","updated":true}\n' "$project"
        return
    fi

    eagle_ok "Overview saved for '$project'"
}

# ─── Delete overview ──────────────────────────────────────

overview_delete() {
    eagle_db "DELETE FROM overviews WHERE project = '$project_sql';"

    if [ "$json_output" = true ]; then
        printf '{"project":"%s","deleted":true}\n' "$project"
        return
    fi

    eagle_ok "Overview deleted for '$project'"
}

# ─── List all overviews ──────────────────────────────────

overview_list() {
    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT project, content, updated_at FROM overviews ORDER BY updated_at DESC;"
        return
    fi

    local results
    results=$(eagle_db "SELECT project, substr(content, 1, 80), updated_at FROM overviews ORDER BY updated_at DESC;")

    if [ -z "$results" ]; then
        eagle_dim "No overviews stored"
        return
    fi

    echo ""
    echo -e "  ${BOLD}All project overviews${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r proj snippet updated_at; do
        [ -z "$proj" ] && continue
        echo -e "  ${BOLD}$proj${RESET}  ${DIM}$updated_at${RESET}"
        echo -e "  ${DIM}$snippet...${RESET}"
        echo ""
    done <<< "$results"
}

# ─── Dispatch ─────────────────────────────────────────────

case "$action" in
    show|view)   overview_show ;;
    set|update)  overview_set ;;
    delete|rm)   overview_delete ;;
    list|ls)     overview_list ;;
    --help|-h)
        echo -e "  Run ${CYAN}eagle-mem overview --help${RESET} for usage"
        ;;
    *)
        eagle_err "Unknown action: $action"
        eagle_dim "  Run 'eagle-mem overview --help' for options"
        exit 1
        ;;
esac
