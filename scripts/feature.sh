#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Feature management
# eagle-mem feature [list|show|verify|pending|waive|add]
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$SCRIPT_DIR/style.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db
eagle_header "Features"

project=$(eagle_project_from_cwd "$(pwd)")
subcommand="${1:-list}"
shift 2>/dev/null || true
raw_output=false

case "$subcommand" in
    list|ls)
        results=$(eagle_list_features "$project")
        if [ -z "$results" ]; then
            eagle_dim "No features tracked for '$project'"
            eagle_dim "Run 'eagle-mem curate' to auto-discover features"
            exit 0
        fi

        while IFS='|' read -r name desc status verified dep_count file_count test_count; do
            [ -z "$name" ] && continue
            verified_label=""
            if [ -n "$verified" ]; then
                verified_label=" ${DIM}(verified: ${verified})${RESET}"
            else
                verified_label=" ${DIM}(never verified)${RESET}"
            fi
            echo -e "  ${CYAN}${name}${RESET}${verified_label}"
            [ -n "$desc" ] && echo -e "    ${desc}"
            echo -e "    ${DIM}${file_count} files, ${dep_count} deps, ${test_count} smoke tests${RESET}"
        done <<< "$results"
        ;;

    show)
        name="${1:-}"
        [ -z "$name" ] && { eagle_err "Usage: eagle-mem feature show <name>"; exit 1; }
        eagle_show_feature "$project" "$name"
        ;;

    verify)
        name="${1:-}"
        [ -z "$name" ] && { eagle_err "Usage: eagle-mem feature verify <name> [--notes <text>]"; exit 1; }
        shift
        notes=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --notes) notes="$2"; shift 2 ;;
                *) notes="$1"; shift ;;
            esac
        done
        fid=$(eagle_get_feature_id "$project" "$name")
        if [ -z "$fid" ]; then
            eagle_err "Feature not found: $name"
            exit 1
        fi
        eagle_verify_feature "$project" "$name" "$notes"
        resolved=$(eagle_resolve_pending_feature_verifications "$project" "$name" "verified" "$notes" | tail -1)
        eagle_ok "Feature '$name' marked as verified"
        if [ "${resolved:-0}" -gt 0 ] 2>/dev/null; then
            eagle_info "Resolved pending verification records: $resolved"
        fi
        ;;

    pending)
        limit=50
        while [ $# -gt 0 ]; do
            case "$1" in
                --raw|--debug) raw_output=true; shift ;;
                --limit|-n) limit="$2"; shift 2 ;;
                --project|-p) project="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        limit=$(eagle_sql_int "$limit")
        [ "$limit" -eq 0 ] && limit=50
        results=$(eagle_list_pending_feature_verifications "$project" 50)
        if [ -z "$results" ]; then
            eagle_ok "No pending feature verifications for '$project'"
            exit 0
        fi

        pending_count=$(printf '%s\n' "$results" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
        echo -e "  ${BOLD}Pending verification${RESET} ${DIM}($project)${RESET}"
        echo -e "  ${DIM}${pending_count} check(s) must be verified or waived before release-boundary commands.${RESET}"
        echo ""

        shown=0
        while IFS='|' read -r id feat file reason trigger created smoke fingerprint; do
            [ -z "$id" ] && continue
            [ "$shown" -ge "$limit" ] && break
            shown=$((shown + 1))
            echo -e "  ${BOLD}${shown}. ${feat}${RESET} ${DIM}#${id}${RESET}"
            [ -n "$file" ] && echo -e "     ${DIM}File:${RESET} $file"
            [ -n "$reason" ] && echo -e "     ${DIM}Why:${RESET} $reason"
            [ -n "$smoke" ] && echo -e "     ${CYAN}Smoke:${RESET} $smoke"
            if [ "$raw_output" = true ]; then
                [ -n "$trigger" ] && echo -e "     ${DIM}Trigger:${RESET} $trigger"
                [ -n "$fingerprint" ] && echo -e "     ${DIM}Diff:${RESET} $fingerprint"
                [ -n "$created" ] && echo -e "     ${DIM}Created:${RESET} $created"
            fi
            echo ""
        done <<< "$results"
        if [ "$pending_count" -gt "$shown" ] 2>/dev/null; then
            eagle_dim "$((pending_count - shown)) more pending; run with --limit $pending_count to show all."
            echo ""
        fi
        eagle_info "Verify after testing: eagle-mem feature verify <name> --notes \"what passed\""
        eagle_info "Waive intentionally: eagle-mem feature waive <id> --reason \"why safe\""
        if [ "$raw_output" = false ]; then
            eagle_dim "Run with --raw to show trigger, diff fingerprint, and created timestamp."
        fi
        ;;

    waive)
        id="${1:-}"
        [ -z "$id" ] && { eagle_err "Usage: eagle-mem feature waive <id> --reason <text>"; exit 1; }
        case "$id" in
            *[!0-9]*)
                eagle_err "Invalid ID: '$id' (must be numeric)"
                exit 1
                ;;
        esac
        shift
        reason=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --reason|--notes)
                    if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                        eagle_err "$1 requires a value"
                        exit 1
                    fi
                    reason="$2"
                    shift 2
                    ;;
                *) reason="$1"; shift ;;
            esac
        done
        [ -z "$reason" ] && { eagle_err "Usage: eagle-mem feature waive <id> --reason <text>"; exit 1; }
        waived=$(eagle_waive_pending_feature_verification "$project" "$id" "$reason" | tail -1)
        if [ "${waived:-0}" -gt 0 ] 2>/dev/null; then
            eagle_ok "Pending verification #$id waived"
        else
            eagle_err "No pending verification found with ID $id"
            exit 1
        fi
        ;;

    add)
        name="${1:-}"
        [ -z "$name" ] && { eagle_err "Usage: eagle-mem feature add <name> [--desc <text>] [--file <path>] [--requires <target:name>] [--smoke <command>]"; exit 1; }
        shift
        desc=""
        files=()
        deps=()
        smokes=()

        while [ $# -gt 0 ]; do
            case "$1" in
                --desc|-d) desc="$2"; shift 2 ;;
                --file|-f) files+=("$2"); shift 2 ;;
                --requires|-r) deps+=("$2"); shift 2 ;;
                --smoke|-s) smokes+=("$2"); shift 2 ;;
                *) shift ;;
            esac
        done

        eagle_upsert_feature "$project" "$name" "$desc"
        fid=$(eagle_get_feature_id "$project" "$name")

        for f in "${files[@]+"${files[@]}"}"; do
            eagle_add_feature_file "$fid" "$f" ""
        done

        for d in "${deps[@]+"${deps[@]}"}"; do
            target="${d%%:*}"
            dep_name="${d#*:}"
            eagle_add_feature_dependency "$fid" "env_var" "$target" "$dep_name" ""
        done

        for s in "${smokes[@]+"${smokes[@]}"}"; do
            eagle_add_feature_smoke_test "$fid" "$s" ""
        done

        eagle_ok "Feature '$name' created"
        ;;

    *)
        eagle_err "Unknown feature command: $subcommand"
        eagle_info "Usage: eagle-mem feature [list|show|verify|pending|waive|add]"
        exit 1
        ;;
esac
