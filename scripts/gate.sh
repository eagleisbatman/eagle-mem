#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Release gate (git-layer parity)
#
# The PreToolUse hook already blocks release-boundary commands for Claude and
# Codex. But a bare-shell `git push`, or a Grok session (which has no hook
# lifecycle), bypasses that gate entirely. This brings the SAME feature-
# verification gate to the git layer via an opt-in `pre-push` hook, so
# governance is not silently skippable regardless of which agent (or no agent)
# runs the push.
#
#   eagle-mem gate check            run the gate for the current repo (exit 1 if blocked)
#   eagle-mem gate install [--repo PATH] [--force]
#                                   install a repo-local .git/hooks/pre-push that runs `gate check`
#   eagle-mem gate uninstall [--repo PATH]
#                                   remove the Eagle Mem pre-push hook (only if it's ours)
#
# Bypass a single push: `git push --no-verify` or `EAGLE_MEM_DISABLE_HOOKS=1 git push`.
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"
. "$SCRIPT_DIR/style.sh"

HOOK_SENTINEL="# eagle-mem-managed-pre-push"

gate_check() {
    # Fail OPEN in any situation where blocking would be wrong: explicitly
    # disabled, no database yet, or not inside a recognized project. A git hook
    # must never wedge pushes just because Eagle Mem isn't set up here.
    [ "${EAGLE_MEM_DISABLE_HOOKS:-}" = "1" ] && exit 0
    [ -f "$EAGLE_MEM_DB" ] || exit 0

    local cwd project
    cwd="$(pwd)"
    project=$(eagle_project_from_cwd "$cwd")
    [ -z "$project" ] && exit 0

    local release_changed_files
    release_changed_files=$(eagle_changed_files_for_release "$cwd" 2>/dev/null || true)
    eagle_reconcile_current_feature_verifications "$project" "$cwd" "git-prepush" "git-push" \
        "Release boundary detected for current repository diff" "$release_changed_files" >/dev/null 2>&1 || true

    local pending_rows pending_count
    pending_rows=$(eagle_list_current_pending_feature_verifications "$project" "$cwd" "$release_changed_files" 8 2>/dev/null || true)
    pending_count=$(printf '%s\n' "$pending_rows" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    pending_count=${pending_count:-0}

    if [ "$pending_count" -gt 0 ] 2>/dev/null; then
        {
            echo ""
            echo "Eagle Mem blocked this push because ${pending_count} feature verification(s) are pending."
            echo ""
            echo "Resolve them, then push again:"
            echo "  eagle-mem feature verify <name> --notes \"what passed\""
            echo "  eagle-mem feature waive <id> --reason \"why this is safe\""
            echo ""
            echo "Pending checks:"
            while IFS='|' read -r pid pname pfile preason _ptrigger _pcreated psmoke pfingerprint; do
                [ -z "$pid" ] && continue
                local line="  #${pid} ${pname}"
                [ -n "$pfile" ] && line+=" (${pfile})"
                [ -n "$preason" ] && line+=" — ${preason}"
                [ -n "$psmoke" ] && line+=" | smoke: ${psmoke}"
                [ -n "$pfingerprint" ] && line+=" | diff: ${pfingerprint}"
                echo "$line"
            done <<< "$pending_rows"
            echo ""
            echo "Bypass once: git push --no-verify   (or EAGLE_MEM_DISABLE_HOOKS=1 git push)"
        } >&2
        exit 1
    fi
    exit 0
}

# Resolve the .git/hooks dir for a repo (handles worktrees and submodules).
gate_hooks_dir() {
    local repo="$1"
    ( cd "$repo" 2>/dev/null && git rev-parse --git-path hooks 2>/dev/null )
}

gate_install() {
    local repo="" force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo) repo="${2:-}"; shift 2 ;;
            --force|-f) force=1; shift ;;
            *) shift ;;
        esac
    done
    repo="${repo:-$(pwd)}"

    if ! ( cd "$repo" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ); then
        eagle_err "Not a git repository: $repo"
        exit 1
    fi

    local hooks_dir hook
    hooks_dir="$(gate_hooks_dir "$repo")"
    # git rev-parse --git-path returns a path relative to the repo; resolve it.
    case "$hooks_dir" in
        /*) ;;
        *) hooks_dir="$repo/$hooks_dir" ;;
    esac
    mkdir -p "$hooks_dir"
    hook="$hooks_dir/pre-push"

    if [ -f "$hook" ] && ! grep -qF "$HOOK_SENTINEL" "$hook" 2>/dev/null && [ "$force" -ne 1 ]; then
        eagle_err "A non-Eagle-Mem pre-push hook already exists: $hook"
        eagle_info "Re-run with --force to replace it, or add this line to your hook manually:"
        eagle_dim "  command -v eagle-mem >/dev/null 2>&1 && eagle-mem gate check"
        exit 1
    fi

    cat > "$hook" <<EOF
#!/usr/bin/env bash
$HOOK_SENTINEL
# Runs the Eagle Mem feature-verification gate before every push.
# Fail-open if eagle-mem is unavailable so pushes never wedge on a missing tool.
command -v eagle-mem >/dev/null 2>&1 || exit 0
exec eagle-mem gate check
EOF
    chmod +x "$hook"
    eagle_ok "Installed Eagle Mem pre-push gate: $hook"
    eagle_dim "Bypass once with: git push --no-verify"
}

gate_uninstall() {
    local repo="" ; repo="${1:-}"
    [ "$repo" = "--repo" ] && { repo="${2:-}"; }
    repo="${repo:-$(pwd)}"
    local hooks_dir hook
    hooks_dir="$(gate_hooks_dir "$repo")"
    case "$hooks_dir" in /*) ;; *) hooks_dir="$repo/$hooks_dir" ;; esac
    hook="$hooks_dir/pre-push"
    if [ -f "$hook" ] && grep -qF "$HOOK_SENTINEL" "$hook" 2>/dev/null; then
        rm -f "$hook"
        eagle_ok "Removed Eagle Mem pre-push gate: $hook"
    else
        eagle_info "No Eagle Mem pre-push gate found for: $repo"
    fi
}

subcommand="${1:-check}"
shift 2>/dev/null || true
case "$subcommand" in
    check)      gate_check ;;
    install)    gate_install "$@" ;;
    uninstall)  gate_uninstall "$@" ;;
    *)
        eagle_err "Unknown gate command: $subcommand"
        eagle_info "Usage: eagle-mem gate [check|install|uninstall]"
        exit 1
        ;;
esac
