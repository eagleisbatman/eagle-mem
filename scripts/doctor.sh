#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Doctor
# Read-only trust and install footprint checks.
# ═══════════════════════════════════════════════════════════
set -euo pipefail

PACKAGE_DIR="${1:-.}"
shift 2>/dev/null || true

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"

mode="install-footprint"
json_output=false

while [ $# -gt 0 ]; do
    case "$1" in
        --json|-j) json_output=true; shift ;;
        --help|-h)
            echo -e "  ${BOLD}eagle-mem doctor${RESET} — Trust and install diagnostics"
            echo ""
            echo -e "  ${BOLD}Usage:${RESET}"
            echo -e "    eagle-mem doctor"
            echo -e "    eagle-mem doctor install-footprint"
            echo ""
            echo -e "  ${BOLD}Options:${RESET}"
            echo -e "    ${CYAN}-j, --json${RESET}  Output structured JSON"
            exit 0
            ;;
        install-footprint|footprint)
            mode="$1"
            shift
            ;;
        *) shift ;;
    esac
done

case "$mode" in
    install-footprint|footprint|"") ;;
    *)
        eagle_err "Unknown doctor check: $mode"
        eagle_dim "Run: eagle-mem doctor --help"
        exit 1
        ;;
esac

package_version=$(jq -r .version "$PACKAGE_DIR/package.json" 2>/dev/null || echo "unknown")
installed_version=$(tr -d '[:space:]' < "$EAGLE_MEM_DIR/.version" 2>/dev/null || true)
[ -z "$installed_version" ] && installed_version="not installed"

sqlite_bin=$(eagle_sqlite_path)
sqlite_version=$(eagle_sqlite_version)
sqlite_fts5=false
if eagle_sqlite_supports_fts5; then
    sqlite_fts5=true
fi

runtime_exists=false
db_exists=false
[ -d "$EAGLE_MEM_DIR" ] && runtime_exists=true
[ -f "$EAGLE_MEM_DB" ] && db_exists=true

doctor_compare_group() {
    local group="$1"
    local checked=0 missing=0 drift=0
    local src dst
    for src in "$PACKAGE_DIR/$group"/*; do
        [ -f "$src" ] || continue
        case "$group" in
            db) ;;
            *)
                case "$src" in
                    *.sh|*/eagle-mem) ;;
                    *) continue ;;
                esac
                ;;
        esac
        checked=$((checked + 1))
        dst="$EAGLE_MEM_DIR/$group/$(basename "$src")"
        if [ ! -f "$dst" ]; then
            missing=$((missing + 1))
        elif ! cmp -s "$src" "$dst"; then
            drift=$((drift + 1))
        fi
    done
    printf '%s|%s|%s\n' "$checked" "$missing" "$drift"
}

hooks_cmp=$(doctor_compare_group hooks)
lib_cmp=$(doctor_compare_group lib)
db_cmp=$(doctor_compare_group db)
scripts_cmp=$(doctor_compare_group scripts)
manifest_path=$(eagle_runtime_manifest_path)
manifest_check=$(eagle_runtime_manifest_check)
manifest_status="${manifest_check%%|*}"
manifest_checked=$(printf '%s' "$manifest_check" | cut -d'|' -f2)
manifest_missing=$(printf '%s' "$manifest_check" | cut -d'|' -f3)
manifest_drift=$(printf '%s' "$manifest_check" | cut -d'|' -f4)
manifest_version=$(eagle_runtime_manifest_field '.package.version' 2>/dev/null || true)
manifest_action=$(eagle_runtime_manifest_field '.action' 2>/dev/null || true)
manifest_generated_at=$(eagle_runtime_manifest_field '.generated_at' 2>/dev/null || true)
manifest_package_dir=$(eagle_runtime_manifest_field '.package.dir' 2>/dev/null || true)

sum_missing=0
sum_drift=0
for row in "$hooks_cmp" "$lib_cmp" "$db_cmp" "$scripts_cmp"; do
    IFS='|' read -r _checked missing drift <<< "$row"
    sum_missing=$((sum_missing + missing))
    sum_drift=$((sum_drift + drift))
done

claude_hooks="not found"
if [ -f "$EAGLE_SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    if jq -e '.. | objects | .command? // empty | select(test("eagle-mem|\\.eagle-mem"))' "$EAGLE_SETTINGS" >/dev/null 2>&1; then
        claude_hooks="registered"
    else
        claude_hooks="not registered"
    fi
fi

codex_hooks="not found"
if [ -f "$EAGLE_CODEX_HOOKS" ] && command -v jq >/dev/null 2>&1; then
    if jq -e '.. | objects | .command? // empty | select(test("eagle-mem|\\.eagle-mem"))' "$EAGLE_CODEX_HOOKS" >/dev/null 2>&1; then
        codex_hooks="registered"
    else
        codex_hooks="not registered"
    fi
fi

statusline_state="not configured"
statusline_command=""
if [ -f "$EAGLE_SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    statusline_command=$(jq -r '.statusLine.command // .statusline.command // empty' "$EAGLE_SETTINGS" 2>/dev/null)
    if [ -n "$statusline_command" ]; then
        if printf '%s' "$statusline_command" | grep -qE 'eagle-mem|\.eagle-mem'; then
            statusline_state="registered"
        else
            sl_file=$(eagle_statusline_script_from_command "$statusline_command" 2>/dev/null || true)
            if [ -n "$sl_file" ] && grep -qE 'eagle_mem_statusline|\.eagle-mem/scripts/statusline-em' "$sl_file" 2>/dev/null; then
                statusline_state="registered"
            else
                statusline_state="custom"
            fi
        fi
    fi
fi

overall="Healthy"
if [ "$runtime_exists" != true ] || [ "$db_exists" != true ]; then
    overall="Not installed"
elif [ "$sqlite_fts5" != true ] || [ "$sum_missing" -gt 0 ] || [ "$sum_drift" -gt 0 ] || [ "$manifest_status" != "ok" ]; then
    overall="Needs attention"
fi

if [ "$json_output" = true ]; then
    jq -nc \
        --arg overall "$overall" \
        --arg package_dir "$PACKAGE_DIR" \
        --arg runtime_dir "$EAGLE_MEM_DIR" \
        --arg db "$EAGLE_MEM_DB" \
        --arg package_version "$package_version" \
        --arg installed_version "$installed_version" \
        --arg sqlite_bin "${sqlite_bin:-}" \
        --arg sqlite_version "${sqlite_version:-}" \
        --argjson sqlite_fts5 "$sqlite_fts5" \
        --arg claude_hooks "$claude_hooks" \
        --arg codex_hooks "$codex_hooks" \
        --arg statusline "$statusline_state" \
        --arg hooks_cmp "$hooks_cmp" \
        --arg lib_cmp "$lib_cmp" \
        --arg db_cmp "$db_cmp" \
        --arg scripts_cmp "$scripts_cmp" \
        --arg manifest_path "$manifest_path" \
        --arg manifest_status "$manifest_status" \
        --argjson manifest_checked "${manifest_checked:-0}" \
        --argjson manifest_missing "${manifest_missing:-0}" \
        --argjson manifest_drift "${manifest_drift:-0}" \
        --arg manifest_version "${manifest_version:-}" \
        --arg manifest_action "${manifest_action:-}" \
        --arg manifest_generated_at "${manifest_generated_at:-}" \
        --arg manifest_package_dir "${manifest_package_dir:-}" \
        '{overall:$overall, package_dir:$package_dir, runtime_dir:$runtime_dir, db:$db,
          versions:{package:$package_version, installed:$installed_version},
          sqlite:{path:$sqlite_bin, version:$sqlite_version, fts5:$sqlite_fts5},
          hooks:{claude:$claude_hooks, codex:$codex_hooks, statusline:$statusline},
          runtime_drift:{hooks:$hooks_cmp, lib:$lib_cmp, db:$db_cmp, scripts:$scripts_cmp},
          manifest:{path:$manifest_path, status:$manifest_status, checked:$manifest_checked,
                    missing:$manifest_missing, drift:$manifest_drift, version:$manifest_version,
                    action:$manifest_action, generated_at:$manifest_generated_at,
                    package_dir:$manifest_package_dir}}'
    exit 0
fi

eagle_header "Doctor"
echo -e "  ${BOLD}Overall:${RESET} $overall"
echo ""
echo -e "  ${BOLD}Install footprint${RESET}"
eagle_kv "Package:" "$PACKAGE_DIR"
eagle_kv "Runtime:" "$EAGLE_MEM_DIR"
eagle_kv "Database:" "$EAGLE_MEM_DB"
eagle_kv "Version:" "package $package_version, installed $installed_version"
echo ""

echo -e "  ${BOLD}SQLite${RESET}"
if [ -n "$sqlite_bin" ]; then
    eagle_kv "Binary:" "$sqlite_bin"
    eagle_kv "Version:" "${sqlite_version:-unknown}"
    if [ "$sqlite_fts5" = true ]; then
        eagle_ok "FTS5 available"
    else
        eagle_fail "FTS5 unavailable"
    fi
else
    eagle_fail "SQLite not found"
fi
echo ""

echo -e "  ${BOLD}Hooks${RESET}"
eagle_kv "Claude Code:" "$claude_hooks"
eagle_kv "Codex:" "$codex_hooks"
eagle_kv "Statusline:" "$statusline_state"
echo ""

echo -e "  ${BOLD}Install manifest${RESET}"
eagle_kv "Path:" "$manifest_path"
if [ "$manifest_status" = "ok" ]; then
    eagle_ok "${manifest_checked:-0} files match manifest"
else
    eagle_warn "status=$manifest_status, checked=${manifest_checked:-0}, missing=${manifest_missing:-0}, drift=${manifest_drift:-0}"
fi
[ -n "$manifest_version" ] && eagle_kv "Version:" "$manifest_version"
[ -n "$manifest_action" ] && eagle_kv "Action:" "$manifest_action"
[ -n "$manifest_generated_at" ] && eagle_kv "Generated:" "$manifest_generated_at"
echo ""

echo -e "  ${BOLD}Runtime drift${RESET}"
for label_row in "hooks:$hooks_cmp" "lib:$lib_cmp" "db:$db_cmp" "scripts:$scripts_cmp"; do
    label="${label_row%%:*}"
    row="${label_row#*:}"
    IFS='|' read -r checked missing drift <<< "$row"
    if [ "$missing" -eq 0 ] && [ "$drift" -eq 0 ] 2>/dev/null; then
        eagle_ok "$label: $checked checked, no drift"
    else
        eagle_warn "$label: $checked checked, $missing missing, $drift drifted"
    fi
done
echo ""

echo -e "  ${BOLD}Next${RESET}"
if [ "$overall" = "Healthy" ]; then
    eagle_ok "Installed runtime matches this package."
else
    [ "$runtime_exists" != true ] && eagle_info "Run: eagle-mem install"
    [ "$manifest_status" != "ok" ] && eagle_info "Run: eagle-mem update to refresh the install manifest."
    [ "$sum_missing" -gt 0 ] || [ "$sum_drift" -gt 0 ] && eagle_info "Run: eagle-mem update"
    [ "$sqlite_fts5" != true ] && eagle_info "Set EAGLE_SQLITE_BIN to an FTS5-capable sqlite3."
fi
echo ""
