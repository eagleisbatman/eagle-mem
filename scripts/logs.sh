#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Command Run Logs
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"

cmd="${1:-list}"
[ $# -gt 0 ] && shift || true

show_help() {
    cat <<EOF
Usage: eagle-mem logs [list|tail|show|prune] [run-id-or-filename]

Commands:
  list                    Show recent command-scoped run logs
  tail [id|filename]      Tail a run log, or the latest run log when omitted
  show <id|filename>      Print a run log
  prune [--days N] [--keep N]
                          Delete old run logs (defaults: 14 days, latest 50)
EOF
}

# Canonicalize an absolute path, resolving symlinks and '..'. Prefers realpath,
# falls back to python3, then to a best-effort directory canonicalization.
canonicalize_path() {
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$p" 2>/dev/null && return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null && return 0
    fi
    local dir base
    dir=$(dirname "$p")
    base=$(basename "$p")
    dir=$(cd -P "$dir" 2>/dev/null && pwd) || return 1
    printf '%s/%s\n' "$dir" "$base"
}

# Verify that $1 (a canonical path) is contained within $2 (a canonical dir).
path_within() {
    local path="$1" root="$2"
    case "$path" in
        "$root"/*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_log_path() {
    local ref="${1:-}"
    local runs_root="${EAGLE_RUNS_DIR%/}" rel_ref
    local canon_root resolved canon_resolved
    canon_root=$(canonicalize_path "$runs_root" 2>/dev/null) || canon_root="$runs_root"

    emit_if_contained() {
        local candidate="$1"
        [ -L "$candidate" ] && return 1
        [ -f "$candidate" ] || return 1
        local canon
        canon=$(canonicalize_path "$candidate" 2>/dev/null) || return 1
        path_within "$canon" "$canon_root" || return 1
        printf '%s\n' "$candidate"
        return 0
    }

    if [ -z "$ref" ]; then
        ls -t "$runs_root"/*.log 2>/dev/null | while IFS= read -r candidate; do
            emit_if_contained "$candidate" && break
        done
        return 0
    fi

    case "$ref" in
        *$'\n'*|*..*) return 1 ;;
        /*)
            rel_ref="${ref#"$runs_root"/}"
            [ "$rel_ref" != "$ref" ] || return 1
            case "$rel_ref" in ""|*/*) return 1 ;; esac
            emit_if_contained "$runs_root/$rel_ref" && return 0
            return 1
            ;;
        */*) return 1 ;;
    esac

    emit_if_contained "$runs_root/$ref" && return 0
    emit_if_contained "$runs_root/$ref.log" && return 0
    return 1
}

run_log_count() {
    [ -d "$EAGLE_RUNS_DIR" ] || {
        printf '0\n'
        return 0
    }
    find "$EAGLE_RUNS_DIR" -type f -name '*.log' -print 2>/dev/null | wc -l | tr -d ' '
}

case "$cmd" in
    -h|--help|help)
        show_help
        ;;
    list)
        eagle_header "Run Logs"
        if ! ls "$EAGLE_RUNS_DIR"/*.log >/dev/null 2>&1; then
            eagle_info "No run logs found yet"
            eagle_dim "Run eagle-mem scan, index, or curate to create command-scoped logs."
            exit 0
        fi
        ls -t "$EAGLE_RUNS_DIR"/*.log 2>/dev/null | head -20 | while IFS= read -r log_path; do
            [ -L "$log_path" ] && continue
            first_line=$(sed -n '1p' "$log_path" 2>/dev/null)
            run_id=$(basename "$log_path" .log)
            printf '  %s  %s\n' "$run_id" "$first_line"
        done
        ;;
    tail)
        log_path=$(resolve_log_path "${1:-}") || {
            eagle_err "Run log not found"
            exit 1
        }
        tail -n "${EAGLE_LOG_TAIL_LINES:-80}" "$log_path"
        ;;
    show)
        log_path=$(resolve_log_path "${1:-}") || {
            eagle_err "Run log not found"
            exit 1
        }
        cat "$log_path"
        ;;
    prune)
        days="${EAGLE_RUN_LOG_RETENTION_DAYS:-14}"
        keep="${EAGLE_RUN_LOG_MAX_COUNT:-50}"
        while [ $# -gt 0 ]; do
            case "$1" in
                --days)
                    days="${2:-}"
                    shift 2
                    ;;
                --keep)
                    keep="${2:-}"
                    shift 2
                    ;;
                *)
                    eagle_err "Unknown prune option: $1"
                    show_help
                    exit 1
                    ;;
            esac
        done
        case "$days" in ""|*[!0-9]*)
            eagle_err "Invalid --days value: $days"
            exit 1
            ;;
        esac
        case "$keep" in ""|*[!0-9]*)
            eagle_err "Invalid --keep value: $keep"
            exit 1
            ;;
        esac
        before=$(run_log_count)
        eagle_run_prune_logs "$days" "$keep"
        after=$(run_log_count)
        eagle_ok "Pruned run logs: before=$before after=$after days=$days keep=$keep"
        ;;
    *)
        eagle_err "Unknown logs command: $cmd"
        show_help
        exit 1
        ;;
esac
