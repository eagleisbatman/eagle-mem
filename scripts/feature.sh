#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Feature management
# eagle-mem feature [list|show|verify|add]
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
        eagle_verify_feature "$project" "$name" "$notes"
        eagle_ok "Feature '$name' marked as verified"
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
        eagle_info "Usage: eagle-mem feature [list|show|verify|add]"
        exit 1
        ;;
esac
