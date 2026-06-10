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
    echo -e "    ${CYAN}--completed${RESET} <text>     What was accomplished (alias: --summary)"
    echo -e "    ${CYAN}--request${RESET} <text>       User request that caused the work"
    echo -e "    ${CYAN}--investigated${RESET} <text>  What was explored or analyzed"
    echo -e "    ${CYAN}--learned${RESET} <text>       Non-obvious discoveries"
    echo -e "    ${CYAN}--decisions${RESET} <text>     Decisions and why"
    echo -e "    ${CYAN}--gotchas${RESET} <text>       Surprises or pitfalls"
    echo -e "    ${CYAN}--next-steps${RESET} <text>    Follow-up work"
    echo -e "    ${CYAN}--key-files${RESET} <text>     Important files (path — role)"
    echo -e "    ${CYAN}--files-read${RESET} <list>    Comma-separated files read"
    echo -e "    ${CYAN}--files-modified${RESET} <list> Comma-separated files modified"
    echo -e "    ${CYAN}--affected-features${RESET} <text>  Features touched (need re-verify)"
    echo -e "    ${CYAN}--verified-features${RESET} <text>  Features verified this session"
    echo -e "    ${CYAN}--regression-risks${RESET} <text>   Known risks introduced"
    echo -e "    ${CYAN}--notes${RESET} <text>         Extra notes"
    echo -e "    ${CYAN}--session-id${RESET} <id>      Live session id (merges into the active row;"
    echo -e "                              omit for a standalone manual save)"
    echo -e "    ${CYAN}-p, --project${RESET} <name>   Project name (default: current git root)"
    echo -e "    ${CYAN}--agent${RESET} <name>         Source: claude-code, codex, antigravity, opencode, grok"
    echo -e "    ${CYAN}--cwd${RESET} <path>           Working directory for project detection"
    echo -e "    ${CYAN}--json${RESET}                 Output JSON"
    echo ""
    echo -e "  ${DIM}Agents use this to capture a clean, branded session summary without printing${RESET}"
    echo -e "  ${DIM}raw blocks. Pass --session-id <id> to merge into the live session row. Stop${RESET}"
    echo -e "  ${DIM}hooks still capture automatically as a safety net when no save is made.${RESET}"
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

# Comma-separated list → JSON array (matches hooks/stop.sh storage shape).
# Safe under set -e: empty input yields [] without a failing pipeline.
# Slurp the whole value (-s) so embedded newlines split into items rather than
# emitting one JSON array per line (which would corrupt the stored column).
csv_to_json_array() {
    local raw="${1:-}"
    [ -z "$raw" ] && { echo '[]'; return 0; }
    printf '%s' "$raw" | jq -Rsc 'split("[,\n]"; "") | map(gsub("^\\s+|\\s+$";"")) | map(select(. != ""))'
}

# Count items in a field separated by ';' or newlines (for the capture banner).
count_items() {
    local text="${1:-}"
    [ -z "$text" ] && { echo 0; return 0; }
    printf '%s' "$text" | awk 'BEGIN{RS="[;\n]"} {gsub(/^[ \t]+|[ \t]+$/,""); if($0!="") n++} END{print n+0}'
}

save_session() {
    local summary=""
    local request=""
    local investigated=""
    local learned=""
    local decisions=""
    local gotchas=""
    local next_steps=""
    local key_files=""
    local files_read_raw=""
    local files_modified_raw=""
    local affected_features=""
    local verified_features=""
    local regression_risks=""
    local notes=""
    local project=""
    local cwd
    cwd="$(pwd)"
    local agent=""
    local cli_session_id=""
    local json_output=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --summary|--completed)
                require_value "$1" "${2:-}"
                summary="$2"
                shift 2
                ;;
            --summary-stdin)
                # Read the summary from stdin so it is not visible in `ps`.
                summary="$(cat)"
                shift
                ;;
            --request)
                require_value "$1" "${2:-}"
                request="$2"
                shift 2
                ;;
            --investigated)
                require_value "$1" "${2:-}"
                investigated="$2"
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
            --files-read)
                require_value "$1" "${2:-}"
                files_read_raw="$2"
                shift 2
                ;;
            --files-modified)
                require_value "$1" "${2:-}"
                files_modified_raw="$2"
                shift 2
                ;;
            --affected-features)
                require_value "$1" "${2:-}"
                affected_features="$2"
                shift 2
                ;;
            --verified-features)
                require_value "$1" "${2:-}"
                verified_features="$2"
                shift 2
                ;;
            --regression-risks)
                require_value "$1" "${2:-}"
                regression_risks="$2"
                shift 2
                ;;
            --notes)
                require_value "$1" "${2:-}"
                notes="$2"
                shift 2
                ;;
            --session-id)
                require_value "$1" "${2:-}"
                cli_session_id="$2"
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

    if [ -z "$summary" ] && [ -z "$learned" ] && [ -z "$decisions" ] && [ -z "$gotchas" ] \
        && [ -z "$next_steps" ] && [ -z "$key_files" ] && [ -z "$investigated" ] \
        && [ -z "$files_read_raw" ] && [ -z "$files_modified_raw" ] \
        && [ -z "$affected_features" ] && [ -z "$verified_features" ] && [ -z "$regression_risks" ]; then
        eagle_err "Nothing to save. Pass --completed/--summary (or another field)."
        exit 1
    fi

    if [ -n "$cli_session_id" ] && ! eagle_validate_session_id "$cli_session_id"; then
        eagle_err "Invalid --session-id (allowed: letters, digits, '_', '-', max 128 chars)."
        exit 1
    fi

    # For a live session, prefer its recorded project so a save issued from a
    # subdirectory (whose cwd derives a different key) does not trigger an
    # unintended project rekey of the active session.
    if [ -z "$project" ] && [ -n "$cli_session_id" ] && [ -f "${EAGLE_MEM_DB:-}" ]; then
        project=$(eagle_db "SELECT project FROM sessions WHERE id='$(eagle_sql_escape "$cli_session_id")' LIMIT 1;" 2>/dev/null || true)
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
            antigravity*|google-antigravity*|google_antigravity*) agent="antigravity" ;;
            opencode) agent="opencode" ;;
            grok|grok-cli) agent="grok" ;;
            *)
                eagle_err "--agent must be codex, claude-code, antigravity, opencode, or grok"
                exit 1
                ;;
        esac
    fi

    # Default request only for manual (non-session-id) saves; for a live
    # session leave it empty so the Stop hook's real request is preserved.
    if [ -z "$request" ] && [ -z "$cli_session_id" ]; then
        request="Manual session save"
    fi

    local files_read files_modified
    files_read=$(csv_to_json_array "$files_read_raw")
    files_modified=$(csv_to_json_array "$files_modified_raw")

    summary=$(printf '%s' "$summary" | eagle_redact)
    request=$(printf '%s' "$request" | eagle_redact)
    investigated=$(printf '%s' "$investigated" | eagle_redact)
    learned=$(printf '%s' "$learned" | eagle_redact)
    decisions=$(printf '%s' "$decisions" | eagle_redact)
    gotchas=$(printf '%s' "$gotchas" | eagle_redact)
    next_steps=$(printf '%s' "$next_steps" | eagle_redact)
    key_files=$(printf '%s' "$key_files" | eagle_redact)
    notes=$(printf '%s' "$notes" | eagle_redact)
    affected_features=$(printf '%s' "$affected_features" | eagle_redact)
    verified_features=$(printf '%s' "$verified_features" | eagle_redact)
    regression_risks=$(printf '%s' "$regression_risks" | eagle_redact)

    # Fold feature-tracking fields into notes (same shape as hooks/stop.sh)
    local regression_notes=""
    [ -n "$affected_features" ] && regression_notes+="affected_features: $affected_features"
    if [ -n "$verified_features" ]; then
        [ -n "$regression_notes" ] && regression_notes+="; "
        regression_notes+="verified_features: $verified_features"
    fi
    if [ -n "$regression_risks" ]; then
        [ -n "$regression_notes" ] && regression_notes+="; "
        regression_notes+="regression_risks: $regression_risks"
    fi
    if [ -n "$regression_notes" ]; then
        if [ -n "$notes" ]; then
            notes="${notes}; ${regression_notes}"
        else
            notes="$regression_notes"
        fi
    fi

    eagle_ensure_db

    local session_id end_after_save=1
    if [ -n "$cli_session_id" ]; then
        # Live session: ensure the row exists and stays active. Empty source/cwd
        # preserve whatever SessionStart already recorded; do NOT end the session.
        session_id="$cli_session_id"
        end_after_save=0
        eagle_upsert_session "$session_id" "$project" "" "" "" "$agent"
    else
        local stamp
        stamp=$(date -u +%Y%m%dT%H%M%SZ)
        session_id="manual-${stamp}-$$-${RANDOM:-0}"
        eagle_upsert_session "$session_id" "$project" "$cwd" "" "manual" "$agent"
    fi

    # capture_source=agent: agent-authored capture is authoritative and must not
    # be clobbered by later Stop-hook heuristics or background enrichment.
    eagle_insert_summary "$session_id" "$project" "$request" "$investigated" "$learned" "$summary" "$next_steps" "$files_read" "$files_modified" "$notes" "$decisions" "$gotchas" "$key_files" "$agent" "agent"

    [ "$end_after_save" = "1" ] && eagle_end_session "$session_id"

    local n_dec n_got dec_word got_word
    n_dec=$(count_items "$decisions")
    n_got=$(count_items "$gotchas")
    [ "$n_dec" = "1" ] && dec_word="decision" || dec_word="decisions"
    [ "$n_got" = "1" ] && got_word="gotcha" || got_word="gotchas"

    if [ "$json_output" = true ]; then
        printf '{'
        printf '"session_id":%s,' "$(json_string "$session_id")"
        printf '"project":%s,' "$(json_string "$project")"
        printf '"agent":%s,' "$(json_string "$agent")"
        printf '"decisions":%s,' "$n_dec"
        printf '"gotchas":%s,' "$n_got"
        printf '"summary":%s' "$(json_string "$summary")"
        printf '}\n'
    else
        printf '  %bEagle Mem%b | Session captured — %s %s, %s %s\n' \
            "$CYAN" "$RESET" "$n_dec" "$dec_word" "$n_got" "$got_word"
        eagle_kv "Project:" "$project"
        eagle_kv "Source:" "$(eagle_agent_label "$agent")"
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
