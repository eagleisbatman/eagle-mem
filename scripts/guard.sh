#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Guardrails management
# eagle-mem guard [add|list|remove]
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"
. "$SCRIPT_DIR/style.sh"

eagle_ensure_db

project=$(eagle_project_from_cwd "$(pwd)")
if [ -z "$project" ]; then
    eagle_err "Not in a recognized project directory"
    exit 1
fi

eagle_header "Guardrails"

subcommand="${1:-list}"
shift 2>/dev/null || true

case "$subcommand" in
    add)
        rule="${1:-}"
        if [ -z "$rule" ]; then
            eagle_err "Usage: eagle-mem guard add \"rule text\" [--file pattern]"
            eagle_info "Examples:"
            eagle_info "  eagle-mem guard add \"PRAGMA busy_timeout must precede synchronous\" --file \"db-core.sh\""
            eagle_info "  eagle-mem guard add \"Never manually copy files to ~/.eagle-mem\""
            eagle_info "  eagle-mem guard add \"Always validate session IDs\" --file \"*.sh\""
            exit 1
        fi
        shift

        file_pattern=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --file|-f)
                    if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                        eagle_err "--file requires a pattern argument"
                        exit 1
                    fi
                    file_pattern="$2"
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done

        eagle_add_guardrail "$project" "$rule" "$file_pattern" "manual"
        eagle_ok "Guardrail added for project: $project"
        if [ -n "$file_pattern" ]; then
            eagle_info "File pattern: $file_pattern"
        else
            eagle_info "Scope: project-wide"
        fi
        eagle_dim "Rule: $rule"
        ;;

    list|ls)
        results=$(eagle_list_guardrails "$project")
        if [ -z "$results" ]; then
            eagle_info "No guardrails for project: $project"
            eagle_dim "Add one: eagle-mem guard add \"rule\" [--file pattern]"
            exit 0
        fi

        echo -e "  ${BOLD}ID   File Pattern         Rule                                     Source   Active${RESET}"
        echo -e "  ${DIM}──── ──────────────────── ──────────────────────────────────────── ──────── ──────${RESET}"

        while IFS='|' read -r id pat rule source active _created; do
            [ -z "$id" ] && continue
            pat="${pat:-(all)}"
            rule_display="${rule:0:40}"
            [ ${#rule} -gt 40 ] && rule_display="${rule_display}..."
            if [ "$active" = "1" ]; then
                active_display="${GREEN}yes${RESET}"
            else
                active_display="${DIM}no${RESET}"
            fi
            printf "  %-4s %-20s %-40s %-8s %b\n" "$id" "$pat" "$rule_display" "$source" "$active_display"
        done <<< "$results"
        echo ""
        ;;

    remove|rm|delete)
        id="${1:-}"
        if [ -z "$id" ]; then
            eagle_err "Usage: eagle-mem guard remove <id>"
            exit 1
        fi
        case "$id" in
            *[!0-9]*)
                eagle_err "Invalid ID: '$id' (must be numeric)"
                exit 1
                ;;
        esac
        eagle_remove_guardrail "$id"
        eagle_ok "Guardrail #$id removed"
        ;;

    sync)
        eagle_info "Syncing rules from CLAUDE.md files..."

        # Collect rules first, then delete+insert in a single transaction
        # to prevent data loss if interrupted mid-sync
        sync_sql=""
        synced=0
        p_esc=$(eagle_sql_escape "$project")

        for claude_md in "$HOME/.claude/CLAUDE.md" ".claude/CLAUDE.md" "CLAUDE.md"; do
            [ ! -f "$claude_md" ] && continue
            eagle_dim "  Reading: $claude_md"

            # Extract lines that look like imperative rules
            while IFS= read -r line; do
                # Strip markdown formatting
                clean=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*[-*>]*[[:space:]]*//' | sed 's/\*\*//g' | sed 's/`//g')
                [ -z "$clean" ] && continue
                # Skip headings, short lines, and non-rule content
                [ ${#clean} -lt 15 ] && continue
                case "$clean" in \#*) continue ;; esac

                # Cap rule length
                [ ${#clean} -gt 2048 ] && clean="${clean:0:2048}"
                rule_esc=$(eagle_sql_escape "$clean")
                sync_sql+="INSERT OR IGNORE INTO guardrails (project, file_pattern, rule, source) VALUES ('$p_esc', '', '$rule_esc', 'claude-md');"$'\n'
                synced=$((synced + 1))
            done < <(grep -iE '^[[:space:]]*[-*>]*[[:space:]]*(never |always |do not |don'\''t |must |rule:|important:)' "$claude_md" 2>/dev/null)
        done

        # Atomic: always delete stale + insert new in one transaction
        # Even when synced=0, DELETE must run to clear removed rules
        eagle_db_pipe <<SQL
BEGIN;
DELETE FROM guardrails WHERE project = '$p_esc' AND source = 'claude-md';
$sync_sql
COMMIT;
SQL
        if [ "$synced" -gt 0 ]; then
            eagle_ok "$synced rules synced from CLAUDE.md"
        else
            eagle_info "No imperative rules found in CLAUDE.md files (stale rules cleared)"
        fi
        ;;

    *)
        eagle_err "Unknown guard command: $subcommand"
        eagle_info "Usage: eagle-mem guard [add|list|remove|sync]"
        exit 1
        ;;
esac
