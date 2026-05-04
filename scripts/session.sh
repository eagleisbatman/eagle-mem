#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Manual session capture
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

show_help() {
    echo -e "  ${BOLD}eagle-mem session${RESET} — Save or inspect session records"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem session ${CYAN}save --summary <text>${RESET}"
    echo -e "    eagle-mem session ${CYAN}save <text>${RESET}"
    echo ""
    echo -e "  ${BOLD}Options for save:${RESET}"
    echo -e "    ${CYAN}--summary${RESET} <text>       Summary to store"
    echo -e "    ${CYAN}--request${RESET} <text>       User request that caused the work"
    echo -e "    ${CYAN}--learned${RESET} <text>       Non-obvious discoveries"
    echo -e "    ${CYAN}--decisions${RESET} <text>     Decisions and why"
    echo -e "    ${CYAN}--gotchas${RESET} <text>       Surprises or pitfalls"
    echo -e "    ${CYAN}--next-steps${RESET} <text>    Follow-up work"
    echo -e "    ${CYAN}--key-files${RESET} <text>     Important files"
    echo -e "    ${CYAN}--notes${RESET} <text>         Extra notes"
    echo -e "    ${CYAN}-p, --project${RESET} <name>   Project name (default: current git root)"
    echo -e "    ${CYAN}--agent${RESET} <name>         Source agent: codex or claude-code"
    echo -e "    ${CYAN}--cwd${RESET} <path>           Working directory for project detection"
    echo -e "    ${CYAN}--json${RESET}                 Output JSON"
    echo ""
    echo -e "  ${DIM}This command is mainly for agent fallbacks. Normal sessions are captured${RESET}"
    echo -e "  ${DIM}automatically by hooks when Claude Code or Codex stops a turn.${RESET}"
    echo ""
}

require_value() {
    local flag="$1"
    if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        eagle_err "$flag requires a value"
        exit 1
    fi
}

json_string() {
    jq -Rn --arg v "${1:-}" '$v'
}

save_session() {
    local summary=""
    local request="Manual session save"
    local learned=""
    local decisions=""
    local gotchas=""
    local next_steps=""
    local key_files=""
    local notes=""
    local project=""
    local cwd
    cwd="$(pwd)"
    local agent=""
    local json_output=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --summary)
                require_value "$1" "${2:-}"
                summary="$2"
                shift 2
                ;;
            --request)
                require_value "$1" "${2:-}"
                request="$2"
                shift 2
                ;;
            --learned)
                require_value "$1" "${2:-}"
                learned="$2"
                shift 2
                ;;
            --decisions)
                require_value "$1" "${2:-}"
                decisions="$2"
                shift 2
                ;;
            --gotchas)
                require_value "$1" "${2:-}"
                gotchas="$2"
                shift 2
                ;;
            --next-steps)
                require_value "$1" "${2:-}"
                next_steps="$2"
                shift 2
                ;;
            --key-files)
                require_value "$1" "${2:-}"
                key_files="$2"
                shift 2
                ;;
            --notes)
                require_value "$1" "${2:-}"
                notes="$2"
                shift 2
                ;;
            --project|-p)
                require_value "$1" "${2:-}"
                project="$2"
                shift 2
                ;;
            --cwd)
                require_value "$1" "${2:-}"
                cwd="$2"
                shift 2
                ;;
            --agent)
                require_value "$1" "${2:-}"
                agent="$2"
                shift 2
                ;;
            --json|-j)
                json_output=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --)
                shift
                if [ $# -gt 0 ]; then
                    summary="${summary}${summary:+ }$*"
                    shift $#
                fi
                ;;
            -*)
                eagle_err "Unknown option for session save: $1"
                exit 1
                ;;
            *)
                summary="${summary}${summary:+ }$1"
                shift
                ;;
        esac
    done

    if [ -z "$summary" ]; then
        eagle_err "Nothing to save. Pass --summary <text>."
        exit 1
    fi

    [ -z "$project" ] && project=$(eagle_project_from_cwd "$cwd")
    if [ -z "$project" ]; then
        eagle_err "Could not determine project. Re-run with --project <name>."
        exit 1
    fi

    if [ -z "$agent" ]; then
        agent=$(eagle_agent_source)
    else
        case "$agent" in
            codex|openai-codex) agent="codex" ;;
            claude|claude-code|cloud-code) agent="claude-code" ;;
            *)
                eagle_err "--agent must be codex or claude-code"
                exit 1
                ;;
        esac
    fi

    summary=$(printf '%s' "$summary" | eagle_redact)
    request=$(printf '%s' "$request" | eagle_redact)
    learned=$(printf '%s' "$learned" | eagle_redact)
    decisions=$(printf '%s' "$decisions" | eagle_redact)
    gotchas=$(printf '%s' "$gotchas" | eagle_redact)
    next_steps=$(printf '%s' "$next_steps" | eagle_redact)
    key_files=$(printf '%s' "$key_files" | eagle_redact)
    notes=$(printf '%s' "$notes" | eagle_redact)

    eagle_ensure_db

    local stamp session_id
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    session_id="manual-${stamp}-$$-${RANDOM:-0}"

    eagle_upsert_session "$session_id" "$project" "$cwd" "" "manual" "$agent"
    eagle_insert_summary "$session_id" "$project" "$request" "" "$learned" "$summary" "$next_steps" "[]" "[]" "$notes" "$decisions" "$gotchas" "$key_files" "$agent"
    eagle_end_session "$session_id"

    if [ "$json_output" = true ]; then
        printf '{'
        printf '"session_id":%s,' "$(json_string "$session_id")"
        printf '"project":%s,' "$(json_string "$project")"
        printf '"agent":%s,' "$(json_string "$agent")"
        printf '"summary":%s' "$(json_string "$summary")"
        printf '}\n'
    else
        eagle_ok "Session summary saved"
        eagle_kv "Project:" "$project"
        eagle_kv "Source:" "$(eagle_agent_label "$agent")"
        eagle_kv "Session:" "$session_id"
    fi
}

command="${1:-help}"
shift 2>/dev/null || true

case "$command" in
    save) save_session "$@" ;;
    help|--help|-h) show_help ;;
    *)
        eagle_err "Unknown session command: $command"
        echo ""
        show_help
        exit 1
        ;;
esac
