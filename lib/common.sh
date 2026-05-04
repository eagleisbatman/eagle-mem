#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Shared constants and helpers
# Source this file: . "$(dirname "$0")/../lib/common.sh"
# ═══════════════════════════════════════════════════════════

EAGLE_MEM_DIR="${EAGLE_MEM_DIR:-$HOME/.eagle-mem}"
EAGLE_MEM_DB="$EAGLE_MEM_DIR/memory.db"
EAGLE_MEM_LOG="$EAGLE_MEM_DIR/eagle-mem.log"
EAGLE_SETTINGS="${EAGLE_SETTINGS:-$HOME/.claude/settings.json}"
EAGLE_SKILLS_DIR="${EAGLE_SKILLS_DIR:-$HOME/.claude/skills}"
EAGLE_CLAUDE_PROJECTS_DIR="${EAGLE_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
EAGLE_CLAUDE_PLANS_DIR="${EAGLE_CLAUDE_PLANS_DIR:-$HOME/.claude/plans}"
EAGLE_CLAUDE_TASKS_DIR="${EAGLE_CLAUDE_TASKS_DIR:-$HOME/.claude/tasks}"
EAGLE_CODEX_DIR="${EAGLE_CODEX_DIR:-$HOME/.codex}"
EAGLE_CODEX_CONFIG="${EAGLE_CODEX_CONFIG:-$EAGLE_CODEX_DIR/config.toml}"
EAGLE_CODEX_HOOKS="${EAGLE_CODEX_HOOKS:-$EAGLE_CODEX_DIR/hooks.json}"
EAGLE_CODEX_AGENTS_MD="${EAGLE_CODEX_AGENTS_MD:-$EAGLE_CODEX_DIR/AGENTS.md}"
EAGLE_CODEX_SKILLS_DIR="${EAGLE_CODEX_SKILLS_DIR:-$EAGLE_CODEX_DIR/skills}"
EAGLE_CODEX_MEMORIES_DIR="${EAGLE_CODEX_MEMORIES_DIR:-$EAGLE_CODEX_DIR/memories}"
EAGLE_RAW_BASH_UNLOCK="${EAGLE_RAW_BASH_UNLOCK:-/tmp/eagle-mem-raw-bash-unlock}"

eagle_sqlite_path() {
    command -v sqlite3 2>/dev/null || true
}

eagle_sqlite_version() {
    sqlite3 --version 2>/dev/null | awk '{print $1}'
}

eagle_sqlite_supports_fts5() {
    command -v sqlite3 >/dev/null 2>&1 || return 1
    sqlite3 :memory: "CREATE VIRTUAL TABLE eagle_mem_fts5_probe USING fts5(value);" >/dev/null 2>&1
}

eagle_print_sqlite_fts5_error() {
    local sqlite_path sqlite_version probe_error
    sqlite_path=$(eagle_sqlite_path)
    sqlite_version=$(eagle_sqlite_version)
    probe_error=$(sqlite3 :memory: "CREATE VIRTUAL TABLE eagle_mem_fts5_probe USING fts5(value);" 2>&1 >/dev/null || true)

    printf '%s\n' "Eagle Mem requires SQLite FTS5, but the active sqlite3 does not support it." >&2
    if [ -n "$sqlite_path" ]; then
        printf '%s\n' "Detected sqlite3: $sqlite_path" >&2
    else
        printf '%s\n' "Detected sqlite3: not found on PATH" >&2
    fi
    [ -n "$sqlite_version" ] && printf '%s\n' "SQLite version: $sqlite_version" >&2
    [ -n "$probe_error" ] && printf '%s\n' "SQLite error: $probe_error" >&2
    printf '%s\n' "Fix: put an FTS5-capable sqlite3 earlier in PATH, then re-run the command." >&2
    printf '%s\n' "macOS: check 'command -v sqlite3'; /usr/bin/sqlite3 usually has FTS5. If Android SDK platform-tools is first, move it later in PATH." >&2
    printf '%s\n' "Homebrew: install sqlite and prepend its bin directory, for example: export PATH=\"/opt/homebrew/opt/sqlite/bin:\$PATH\"" >&2
    printf '%s\n' "Linux: install a sqlite3 package compiled with ENABLE_FTS5." >&2
}

eagle_require_sqlite_fts5() {
    if eagle_sqlite_supports_fts5; then
        return 0
    fi
    eagle_print_sqlite_fts5_error
    return 1
}

eagle_log() {
    local level="$1"
    shift
    # Ensure log file is owner-only (may contain debug data)
    if [ ! -f "$EAGLE_MEM_LOG" ]; then
        touch "$EAGLE_MEM_LOG" 2>/dev/null && chmod 600 "$EAGLE_MEM_LOG" 2>/dev/null
    fi
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$level] $*" >> "$EAGLE_MEM_LOG" 2>/dev/null || true
}

eagle_normalize_project_path() {
    local path="${1:-$(pwd)}"

    # Normalize macOS /private prefixes.
    case "$path" in /private/tmp*) path="/tmp${path#/private/tmp}" ;; esac
    case "$path" in /private/var/*) path="/var${path#/private/var}" ;; esac

    printf '%s\n' "$path"
}

eagle_is_ephemeral_project_path() {
    local path="${1:-}"

    case "$path" in
        /tmp|/tmp/*|/var/tmp|/var/tmp/*) return 0 ;;
        /var/folders|/var/folders/*) return 0 ;;
        "$HOME/Downloads"|"$HOME/Downloads/"*) return 0 ;;
        "$HOME/Desktop"|"$HOME/Desktop/"*) return 0 ;;
    esac

    return 1
}

eagle_project_key_from_target_dir() {
    local target_dir="${1:-}"
    [ -z "$target_dir" ] && return 1

    local name
    name=$(basename "$target_dir")
    if [ ${#name} -le 1 ]; then
        echo ""
        return 0
    fi

    if [[ "$target_dir" == "$HOME/"* ]]; then
        echo "${target_dir#$HOME/}"
    elif [ "$target_dir" = "$HOME" ]; then
        echo "$name"
    else
        echo "${target_dir#/}"
    fi
}

eagle_project_key_for_worktree_path() {
    local resolved="${1:-}"

    case "$resolved" in
        "$HOME"/*/.eagle-worktrees/*)
            local worktree_parent worktree_tail worktree_repo worktree_project
            worktree_parent="${resolved%%/.eagle-worktrees/*}"
            worktree_tail="${resolved#"$worktree_parent/.eagle-worktrees/"}"
            worktree_repo="${worktree_tail%%/*}"
            worktree_project="$worktree_parent/$worktree_repo"
            if [ -n "$worktree_repo" ] && [ -d "$worktree_project" ]; then
                eagle_project_key_from_target_dir "$worktree_project"
                return 0
            fi
            ;;
    esac

    return 1
}

eagle_project_from_path_no_git() {
    if [ -n "${EAGLE_MEM_PROJECT:-}" ]; then
        echo "$EAGLE_MEM_PROJECT"
        return
    fi

    local path="${1:-$(pwd)}"
    local resolved
    resolved=$(eagle_normalize_project_path "$path")

    if eagle_is_ephemeral_project_path "$resolved"; then
        echo ""
        return
    fi

    local worktree_project
    if worktree_project=$(eagle_project_key_for_worktree_path "$resolved"); then
        echo "$worktree_project"
        return
    fi

    eagle_project_key_from_target_dir "$resolved"
}

eagle_project_from_cwd() {
    if [ -n "${EAGLE_MEM_PROJECT:-}" ]; then
        echo "$EAGLE_MEM_PROJECT"
        return
    fi

    local cwd="${1:-$(pwd)}"
    local resolved
    resolved=$(eagle_normalize_project_path "$cwd")

    # Skip ephemeral directories — return empty so hooks early-exit.
    if eagle_is_ephemeral_project_path "$resolved"; then
        echo ""
        return
    fi

    # Eagle Mem worker lanes run in sibling git worktrees under
    # <parent>/.eagle-worktrees/<repo>/<lane>. Keep their observations attached
    # to the real project, not to the disposable worktree path.
    local worktree_project
    if worktree_project=$(eagle_project_key_for_worktree_path "$resolved"); then
        echo "$worktree_project"
        return
    fi

    local target_dir
    local git_root
    git_root=$(git -C "$resolved" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$git_root" ]; then
        target_dir="$git_root"
    else
        target_dir="$resolved"
    fi

    eagle_project_key_from_target_dir "$target_dir"
}

eagle_path_is_same_or_child() {
    local parent child
    parent=$(eagle_normalize_project_path "${1:-}")
    child=$(eagle_normalize_project_path "${2:-}")

    [ -z "$parent" ] || [ -z "$child" ] && return 1
    [ "$child" = "$parent" ] && return 0
    case "$child" in "$parent"/*) return 0 ;; esac
    return 1
}

eagle_transcript_first_cwd() {
    local transcript_path="${1:-}"
    [ -f "$transcript_path" ] || return 1

    local sample
    sample=$(dd if="$transcript_path" bs=65536 count=4 2>/dev/null)
    [ -n "$sample" ] || return 1

    printf '%s\n' "$sample" | sed -nE '/"cwd"[[:space:]]*:/ {
        s/.*"cwd"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/
        p
        q
    }'
}

eagle_project_from_claude_project_dir() {
    local project_dir="${1:-}"
    project_dir="${project_dir%/}"
    [ -d "$project_dir" ] || return 1

    local jsonl cwd project
    for jsonl in "$project_dir"/*.jsonl; do
        [ -f "$jsonl" ] || continue
        cwd=$(eagle_transcript_first_cwd "$jsonl")
        [ -z "$cwd" ] && continue
        project=$(eagle_project_from_path_no_git "$cwd")
        [ -n "$project" ] && { printf '%s\n' "$project"; return 0; }
    done

    return 1
}

eagle_project_from_claude_transcript() {
    local transcript_path="${1:-}"
    local cwd="${2:-}"

    case "$transcript_path" in
        "$EAGLE_CLAUDE_PROJECTS_DIR"/*/*.jsonl) ;;
        *) return 1 ;;
    esac

    local transcript_cwd project
    transcript_cwd=$(eagle_transcript_first_cwd "$transcript_path")
    [ -n "$transcript_cwd" ] || return 1

    if [ -n "$cwd" ] && ! eagle_path_is_same_or_child "$transcript_cwd" "$cwd"; then
        return 1
    fi

    project=$(eagle_project_from_path_no_git "$transcript_cwd")
    [ -n "$project" ] || return 1
    printf '%s\n' "$project"
}

eagle_project_from_hook_input() {
    local input="${1:-}"

    if [ -n "${EAGLE_MEM_PROJECT:-}" ]; then
        echo "$EAGLE_MEM_PROJECT"
        return
    fi

    local cwd transcript_path project
    cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
    transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

    if project=$(eagle_project_from_claude_transcript "$transcript_path" "$cwd"); then
        printf '%s\n' "$project"
        return
    fi

    eagle_project_from_cwd "$cwd"
}

eagle_project_file_path() {
    local cwd="${1:-$(pwd)}"
    local file_path="${2:-}"

    [ -z "$file_path" ] && return 0

    case "$file_path" in
        ./*) file_path="${file_path#./}" ;;
    esac

    case "$file_path" in
        /*)
            local git_root
            git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
            if [ -n "$git_root" ]; then
                case "$file_path" in
                    "$git_root"/*)
                        printf '%s\n' "${file_path#$git_root/}"
                        return 0
                        ;;
                esac
            fi
            case "$file_path" in
                "$cwd"/*)
                    printf '%s\n' "${file_path#$cwd/}"
                    return 0
                    ;;
            esac
            ;;
    esac

    printf '%s\n' "$file_path"
}

eagle_extract_apply_patch_files() {
    sed -n -E 's/^\*\*\* (Add|Update|Delete) File: //p'
}

eagle_agent_source() {
    local agent="${EAGLE_AGENT_SOURCE:-${EAGLE_AGENT:-}}"
    case "$agent" in
        codex|openai-codex) echo "codex" ;;
        claude|claude-code|cloud-code) echo "claude-code" ;;
        *)
            if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_CI:-}" ] || [ -n "${CODEX_MANAGED_BY_NPM:-}" ]; then
                echo "codex"
            else
                echo "claude-code"
            fi
            ;;
    esac
}

eagle_agent_source_from_json() {
    local input="${1:-}"
    local configured="${EAGLE_AGENT_SOURCE:-${EAGLE_AGENT:-}}"
    if [ -n "$configured" ]; then
        eagle_agent_source
        return
    fi

    local transcript_path turn_id tool_name
    transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
    turn_id=$(printf '%s' "$input" | jq -r '.turn_id // empty' 2>/dev/null)
    tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)

    case "$transcript_path" in
        "$HOME/.codex/"*|*/.codex/*) echo "codex"; return ;;
        "$HOME/.claude/"*|*/.claude/*) echo "claude-code"; return ;;
    esac
    [ -n "$turn_id" ] && { echo "codex"; return; }
    [ "$tool_name" = "apply_patch" ] && { echo "codex"; return; }

    echo "claude-code"
}

eagle_agent_label() {
    case "${1:-$(eagle_agent_source)}" in
        codex) echo "Codex" ;;
        *) echo "Claude Code" ;;
    esac
}

eagle_trim_text() {
    local text="${1:-}"
    local max="${2:-240}"

    text=$(printf '%s' "$text" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
    if [ "${#text}" -gt "$max" ] 2>/dev/null; then
        if [ "$max" -gt 3 ] 2>/dev/null; then
            printf '%s...' "${text:0:$((max - 3))}"
        else
            printf '%s' "${text:0:$max}"
        fi
    else
        printf '%s' "$text"
    fi
}

eagle_is_shell_tool() {
    case "${1:-}" in
        Bash|exec_command|shell_command|unified_exec) return 0 ;;
        *) return 1 ;;
    esac
}

eagle_tool_command_from_json() {
    local input="${1:-}"
    printf '%s' "$input" | jq -r '
        .tool_input.command
        // .tool_input.cmd
        // .tool_input.shell_command
        // .tool_input.command_line
        // .tool_input.cmdline
        // (if (.tool_input.argv? | type) == "array" then (.tool_input.argv | join(" ")) else empty end)
        // empty
    ' 2>/dev/null
}

eagle_emit_context_for_agent() {
    local agent="${1:-$(eagle_agent_source)}"
    local hook_event="${2:-}"
    local context="${3:-}"

    [ -z "$context" ] && return 0

    if [ "$agent" = "codex" ]; then
        jq -cn \
            --arg event "$hook_event" \
            --arg context "$context" \
            '{
                hookSpecificOutput: {
                    hookEventName: $event,
                    additionalContext: $context
                }
            }'
        return 0
    fi

    printf '%s\n' "$context"
}

eagle_config_get_light() {
    local section="$1"
    local key="$2"
    local default="${3:-}"
    local cfg="${EAGLE_CONFIG_FILE:-$EAGLE_MEM_DIR/config.toml}"

    if [ ! -f "$cfg" ]; then
        echo "$default"
        return
    fi

    local value
    value=$(awk -v section="$section" -v key="$key" '
        /^[[:space:]]*\[/ {
            gsub(/[\[\][:space:]]/, "")
            current = $0
        }
        current == section && /^[[:space:]]*[^#\[]/ {
            split($0, parts, "=")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[1])
            if (parts[1] == key) {
                val = substr($0, index($0, "=") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                gsub(/^["'"'"']|["'"'"']$/, "", val)
                print val
                exit
            }
        }
    ' "$cfg")

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

eagle_token_guard_rtk_mode() {
    if declare -F eagle_config_get >/dev/null 2>&1; then
        eagle_config_get "token_guard" "rtk" "auto"
    else
        eagle_config_get_light "token_guard" "rtk" "auto"
    fi
}

eagle_token_guard_raw_bash_mode() {
    if declare -F eagle_config_get >/dev/null 2>&1; then
        eagle_config_get "token_guard" "raw_bash" "block"
    else
        eagle_config_get_light "token_guard" "raw_bash" "block"
    fi
}

eagle_raw_output_command_needs_guard() {
    local cmd="$1"
    local first
    first=$(printf '%s\n' "$cmd" | awk 'NR == 1 {print $1}' | sed 's|.*/||')

    case "$first" in
        cat|head|tail|find|grep|rg|wc) return 0 ;;
    esac

    if printf '%s\n' "$cmd" \
        | tr '\n' ';' \
        | sed -E 's/(&&|[|][|]|;)/\
/g' \
        | awk '
            {
                for (i = 1; i <= NF; i++) {
                    token = $i
                    sub(/^.*\//, "", token)
                    if (token ~ /^(cat|head|tail|find|grep|rg|wc)$/) found = 1
                }
            }
            END { exit(found ? 0 : 1) }
        '
    then
        return 0
    fi

    if printf '%s\n' "$cmd" \
        | tr '\n' ';' \
        | sed -E 's/(&&|[|][|]|;)/\
/g' \
        | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i !~ /(^|\/)git$/) continue
                    j = i + 1
                    while (j <= NF && $j ~ /^-/) {
                        opt = $j
                        j++
                        if (opt == "-C" || opt == "-c" ||
                            opt == "--git-dir" || opt == "--work-tree" ||
                            opt == "--namespace" || opt == "--exec-path" ||
                            opt == "--config-env" || opt == "--super-prefix") {
                            j++
                        }
                    }
                    if ($j ~ /^(diff|show|log|blame|grep)$/) found = 1
                }
            }
            END { exit(found ? 0 : 1) }
        '
    then
        return 0
    fi

    if printf '%s\n' "$cmd" | grep -qE '\|\s*(head|tail|grep|rg|wc)\b'; then
        return 0
    fi

    return 1
}

eagle_rtk_rewrite_command() {
    local cmd="$1"
    [ "$(eagle_token_guard_rtk_mode)" = "off" ] && return 1
    command -v rtk >/dev/null 2>&1 || return 1

    case "$cmd" in
        ""|rtk\ *|*" rtk "*|*"eagle-mem "*|*"git push"*|*"gh pr create"*|*"npm publish"*|*"pnpm publish"*|*"yarn npm publish"*|*"bun publish"*)
            return 1
            ;;
    esac

    local rewritten
    rewritten=$(rtk rewrite "$cmd" 2>/dev/null | head -1)
    [ -z "$rewritten" ] && return 1
    [ "$rewritten" = "$cmd" ] && return 1
    printf '%s\n' "$rewritten"
}

eagle_raw_bash_unlock_active() {
    [ -f "$EAGLE_RAW_BASH_UNLOCK" ] || return 1
    local now mtime age
    now=$(date +%s)
    mtime=$(stat -f %m "$EAGLE_RAW_BASH_UNLOCK" 2>/dev/null || stat -c %Y "$EAGLE_RAW_BASH_UNLOCK" 2>/dev/null || echo 0)
    age=$((now - mtime))
    [ "$age" -lt 600 ]
}

eagle_sha256_stream() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        sha256sum | awk '{print $1}'
    fi
}

eagle_is_release_boundary_command() {
    local cmd="$1"

    if printf '%s\n' "$cmd" \
        | tr '\n' ';' \
        | sed -E 's/(&&|[|][|]|;)/\
/g' \
        | awk '
            function has_dry_run_flag(line) {
                return line ~ /(^|[[:space:]])--dry-run([[:space:]]|$|=([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss])([[:space:]]|$))/
            }
            function is_eagle_feature_command(line) {
                return line ~ /(^|[[:space:]])([^[:space:]]*\/)?eagle-mem[[:space:]]+feature[[:space:]]+(verify|waive|pending|list)([[:space:]]|$)/
            }
            is_eagle_feature_command($0) { next }
            /(^|[[:space:]])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)/ ||
            /(^|[[:space:]])npm[[:space:]]+publish([[:space:]]|$)/ ||
            /(^|[[:space:]])pnpm[[:space:]]+publish([[:space:]]|$)/ ||
            /(^|[[:space:]])yarn[[:space:]]+npm[[:space:]]+publish([[:space:]]|$)/ ||
            /(^|[[:space:]])bun[[:space:]]+publish([[:space:]]|$)/ {
                if (!has_dry_run_flag($0)) found = 1
            }
            END { exit(found ? 0 : 1) }
        '
    then
        return 0
    fi

    if printf '%s\n' "$cmd" \
        | tr '\n' ';' \
        | sed -E 's/(&&|[|][|]|;)/\
/g' \
        | awk '
            function has_dry_run_flag(line) {
                return line ~ /(^|[[:space:]])--dry-run([[:space:]]|$|=([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss])([[:space:]]|$))/
            }
            function is_eagle_feature_command(line) {
                return line ~ /(^|[[:space:]])([^[:space:]]*\/)?eagle-mem[[:space:]]+feature[[:space:]]+(verify|waive|pending|list)([[:space:]]|$)/
            }
            is_eagle_feature_command($0) { next }
            /(^|[[:space:]])git[[:space:]]+push([[:space:]]|$)/ {
                if (!has_dry_run_flag($0)) found = 1
            }
            END { exit(found ? 0 : 1) }
        '
    then
        return 0
    fi

    return 1
}

eagle_changed_files_for_release() {
    local cwd="${1:-$(pwd)}"
    [ -d "$cwd" ] || return 0

    {
        git -C "$cwd" diff --name-only HEAD 2>/dev/null
        git -C "$cwd" diff --cached --name-only 2>/dev/null
        local default_branch
        default_branch=$(git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
        if [ -n "$default_branch" ] && git -C "$cwd" rev-parse --verify "origin/$default_branch" >/dev/null 2>&1; then
            git -C "$cwd" diff --name-only "origin/$default_branch...HEAD" 2>/dev/null
        fi
        if git -C "$cwd" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
            git -C "$cwd" diff --name-only '@{upstream}...HEAD' 2>/dev/null
        fi
        if ! git -C "$cwd" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
            if ! git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD >/dev/null 2>&1; then
                if git -C "$cwd" rev-parse --verify HEAD~1 >/dev/null 2>&1; then
                    git -C "$cwd" diff --name-only HEAD~1..HEAD 2>/dev/null
                fi
            fi
        fi
    } | sed '/^[[:space:]]*$/d' | sort -u
}

eagle_change_fingerprint_for_file() {
    local cwd="${1:-$(pwd)}"
    local file_path="${2:-}"
    [ -z "$file_path" ] && return 0
    [ -d "$cwd" ] || return 0

    local git_root
    git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    [ -z "$git_root" ] && return 0

    local rel_path="$file_path"
    case "$rel_path" in
        ./*) rel_path="${rel_path#./}" ;;
        /*)
            case "$rel_path" in
                "$git_root"/*) rel_path="${rel_path#$git_root/}" ;;
                "$cwd"/*) rel_path="${rel_path#$cwd/}" ;;
            esac
            ;;
    esac

    local base_ref=""
    local default_branch
    default_branch=$(git -C "$git_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
    if [ -n "$default_branch" ] && git -C "$git_root" rev-parse --verify "origin/$default_branch" >/dev/null 2>&1; then
        base_ref=$(git -C "$git_root" merge-base HEAD "origin/$default_branch" 2>/dev/null)
    fi

    if [ -z "$base_ref" ] && git -C "$git_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
        base_ref=$(git -C "$git_root" merge-base HEAD '@{upstream}' 2>/dev/null)
    fi

    if [ -z "$base_ref" ]; then
        if ! git -C "$git_root" diff --quiet HEAD -- "$rel_path" 2>/dev/null \
            || ! git -C "$git_root" diff --cached --quiet HEAD -- "$rel_path" 2>/dev/null \
            || git -C "$git_root" ls-files --others --exclude-standard -- "$rel_path" 2>/dev/null | grep -qxF "$rel_path"
        then
            base_ref="HEAD"
        elif git -C "$git_root" rev-parse --verify HEAD~1 >/dev/null 2>&1; then
            base_ref="HEAD~1"
        else
            base_ref="HEAD"
        fi
    fi

    local base_blob="missing"
    if [ -n "$base_ref" ] && git -C "$git_root" cat-file -e "$base_ref:$rel_path" 2>/dev/null; then
        base_blob=$(git -C "$git_root" rev-parse "$base_ref:$rel_path" 2>/dev/null)
    fi

    local final_blob="missing"
    if [ -f "$git_root/$rel_path" ]; then
        final_blob=$(git -C "$git_root" hash-object -- "$rel_path" 2>/dev/null)
    elif git -C "$git_root" cat-file -e "HEAD:$rel_path" 2>/dev/null; then
        final_blob=$(git -C "$git_root" rev-parse "HEAD:$rel_path" 2>/dev/null)
    fi

    printf 'file:%s\nbase:%s\nfinal:%s\n' "$rel_path" "$base_blob" "$final_blob" | eagle_sha256_stream
}

eagle_sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

eagle_sql_int() {
    case "$1" in
        ''|*[!0-9]*) echo "0" ;;
        *) printf '%s' "$1" ;;
    esac
}

eagle_fts_sanitize() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9_]/ /g' | sed 's/  */ /g; s/^ //; s/ $//'
}

# Escape SQL LIKE wildcards (% and _) so literal filenames match exactly.
# Apply AFTER eagle_sql_escape, since this only handles LIKE metacharacters.
eagle_like_escape() {
    printf '%s' "$1" | sed 's/%/\\%/g; s/_/\\_/g'
}

# Validate a session ID is safe for use in file paths (no traversal).
# Claude Code session IDs are UUIDs or hex strings — reject anything else.
eagle_validate_session_id() {
    local sid="$1"
    # Length cap: Claude Code IDs are UUIDs/hex (36-64 chars). Reject oversized input.
    [ ${#sid} -gt 128 ] && return 1
    [[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]]
}

eagle_read_stdin() {
    local input=""
    if [ ! -t 0 ]; then
        input=$(cat)
    fi
    echo "$input"
}

# Redact secrets from text before storage.
# Covers: Bearer tokens, API keys, passwords, secrets, tokens,
# Stripe/AWS/GitHub/Anthropic/OpenAI key patterns, named env vars.
eagle_redact() {
    sed -E \
        -e 's/(Bearer )[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(api[_-]?key[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(password[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(secret[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(token[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(Authorization: )[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(client_secret[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(private_key[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/(access_token[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/gi' \
        -e 's/sk_live_[A-Za-z0-9]+/[REDACTED]/g' \
        -e 's/sk_test_[A-Za-z0-9]+/[REDACTED]/g' \
        -e 's/whsec_[A-Za-z0-9]+/[REDACTED]/g' \
        -e 's/AKIA[A-Z0-9]{16}/[REDACTED]/g' \
        -e 's/ghp_[A-Za-z0-9]{36}/[REDACTED]/g' \
        -e 's/gho_[A-Za-z0-9]{36}/[REDACTED]/g' \
        -e 's/glpat-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
        -e 's/sk-ant-[A-Za-z0-9_-]+/[REDACTED]/g' \
        -e 's/sk-[A-Za-z0-9]{20,}/[REDACTED]/g' \
        -e 's/AIza[0-9A-Za-z_-]{35}/[REDACTED]/g' \
        -e 's/xox[abps]-[A-Za-z0-9-]+/[REDACTED]/g' \
        -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[REDACTED_JWT]/g' \
        -e 's|(https?://[^/:]+:)[^@]+(@)|\1[REDACTED]\2|g' \
        -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY]/g' \
        -e 's/(ANTHROPIC_API_KEY[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/g' \
        -e 's/(OPENAI_API_KEY[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/g' \
        -e 's/(GOOGLE_API_KEY[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/g' \
        -e 's/(SLACK_TOKEN[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/g' \
        -e 's/(DATABASE_URL[= :])[^[:space:],;"'"'"']*/\1[REDACTED]/g'
}

# Collect project files into a destination file.
# Uses git ls-files when available, falls back to find with common exclusions.
# Usage: eagle_collect_files <target_dir> <output_file>
eagle_collect_files() {
    local target_dir="$1"
    local output_file="$2"

    if git -C "$target_dir" rev-parse --is-inside-work-tree &>/dev/null; then
        git -C "$target_dir" ls-files --cached --others --exclude-standard > "$output_file"
    else
        (cd "$target_dir" && find . -type f \
            -not -path '*/node_modules/*' \
            -not -path '*/.git/*' \
            -not -path '*/dist/*' \
            -not -path '*/build/*' \
            -not -path '*/.next/*' \
            -not -path '*/target/*' \
            -not -path '*/vendor/*' \
            -not -path '*/__pycache__/*' \
            -not -path '*/.venv/*' \
            -not -path '*/venv/*' \
            -not -path '*/.egg-info/*' \
            -not -name '*.pyc' \
            -not -name '*.lock' \
            -not -name 'package-lock.json' \
            -not -name 'yarn.lock' \
            -not -name 'pnpm-lock.yaml' \
            | sed 's|^\./||') > "$output_file"
    fi
}

_eagle_claude_md_section() {
    cat << 'EAGLE_MD'

---

## Eagle Mem — Persistent Memory

Eagle Mem hooks are active in every project. SessionStart injects context (overview, recent sessions, memories, tasks, orchestration lanes, core files). Stop captures session summaries. PostToolUse mirrors memories/plans/tasks.

**Rule:** Before your final response in every session, emit an `<eagle-summary>` block so the Stop hook can capture a rich summary instead of just heuristics.

```
<eagle-summary>
request: [what user asked]
completed: [what shipped]
learned: [non-obvious discoveries]
decisions: [choice — why]
gotchas: [what surprised]
next_steps: [concrete actions]
key_files: [path — role]
files_read: [path, ...]
files_modified: [path, ...]
affected_features: [feature, ...]
verified_features: [feature, ...]
regression_risks: [risk, ...]
</eagle-summary>
```

**Why:** Without this block, summaries degrade to "(auto-captured)" with no decisions, gotchas, or learned context. Rich summaries are what make future sessions useful.

**How to apply:**
- Emit `<eagle-summary>` before your final text response, every session
- When Eagle Mem injects context at SessionStart, attribute it: "Eagle Mem recalls:"
- Do not revert decisions surfaced by PostToolUse without asking the user
- If Eagle Mem reports pending feature verification, verify or waive it before push/PR/publish
- For broad multi-agent work, YOU run `eagle-mem orchestrate`; do not ask the user to run these commands
- Never put raw secrets in the summary — Eagle Mem redacts but defense in depth
- If you contradict a loaded memory, update the memory file
EAGLE_MD
}

eagle_patch_claude_md() {
    local claude_md="$HOME/.claude/CLAUDE.md"
    local marker="## Eagle Mem — Persistent Memory"

    mkdir -p "$HOME/.claude"

    if [ -f "$claude_md" ] && grep -qF "$marker" "$claude_md" 2>/dev/null; then
        # Check if section has outdated pipe-separated format
        if grep -qF 'request: \[what user asked\] | completed:' "$claude_md" 2>/dev/null; then
            # Replace the outdated section: remove old, append new
            local tmp_md
            tmp_md=$(mktemp)
            awk -v marker="$marker" '
                $0 ~ marker { skip=1; next }
                skip && /^---$/ && !seen_end { seen_end=1; next }
                skip && /^## / { skip=0 }
                !skip { print }
            ' "$claude_md" > "$tmp_md"
            mv "$tmp_md" "$claude_md"
            _eagle_claude_md_section >> "$claude_md"
            return 0
        fi
        if ! grep -qF 'eagle-mem orchestrate' "$claude_md" 2>/dev/null; then
            local tmp_md
            tmp_md=$(mktemp)
            awk '
                { print }
                /pending feature verification/ {
                    print "- For broad multi-agent work, YOU run `eagle-mem orchestrate`; do not ask the user to run these commands"
                }
            ' "$claude_md" > "$tmp_md" && mv "$tmp_md" "$claude_md"
            return 0
        fi
        return 1
    fi

    _eagle_claude_md_section >> "$claude_md"
}

_eagle_codex_agents_section() {
    cat << 'EAGLE_AGENTS'

---

## Eagle Mem — Persistent Memory

Eagle Mem hooks are active for Codex in this project. SessionStart and UserPromptSubmit inject project recall from the shared Eagle Mem database at `~/.eagle-mem/memory.db`. PostToolUse records observations and marks affected features for verification.

**User-visible output rule:** Keep Codex final answers clean. Do not print Eagle Mem summary capture blocks, XML, JSON hook payloads, or internal templates to the user unless the user explicitly asks for raw Eagle Mem internals. The Stop hook captures Codex summaries from the transcript automatically.

**How to apply:**
- Attribute recalled context as "Eagle Mem recalls:" when it is injected
- Use the Eagle Mem skills when relevant: `eagle-mem-search`, `eagle-mem-overview`, `eagle-mem-memories`, `eagle-mem-tasks`, and `eagle-mem-orchestrate`
- For broad multi-agent work, YOU run `eagle-mem orchestrate`; do not ask the user to run these commands
- Codex does not currently expose a persistent custom statusline like Claude Code; if the user asks for Eagle Mem status, run `eagle-mem statusline`
- For important decisions, preferences, gotchas, or durable project facts, include them briefly in normal prose. Eagle Mem will extract them from the transcript.
- Do not revert Eagle Mem-surfaced decisions without asking the user
- If Eagle Mem reports pending feature verification, verify or waive it before push/PR/publish
- Never put raw secrets in summaries
EAGLE_AGENTS
}

eagle_patch_codex_agents_md() {
    local agents_md="$EAGLE_CODEX_AGENTS_MD"
    local marker="## Eagle Mem — Persistent Memory"

    mkdir -p "$(dirname "$agents_md")"

    if [ -f "$agents_md" ] && grep -qF "$marker" "$agents_md" 2>/dev/null; then
        if grep -qF 'emit an `<eagle-summary>` block' "$agents_md" 2>/dev/null \
            || grep -qF 'emit an <eagle-summary> block' "$agents_md" 2>/dev/null \
            || grep -qF 'explicitly include them in the `<eagle-summary>` block' "$agents_md" 2>/dev/null \
            || grep -qF 'explicitly include them in the <eagle-summary> block' "$agents_md" 2>/dev/null \
            || ! grep -qF 'Keep Codex final answers clean' "$agents_md" 2>/dev/null \
            || ! grep -qF 'eagle-mem statusline' "$agents_md" 2>/dev/null; then
            local tmp_md
            tmp_md=$(mktemp)
            awk -v marker="$marker" '
                $0 ~ marker { skip=1; next }
                skip && /^---$/ { skip=0; next }
                skip && /^## / { skip=0 }
                !skip { print }
            ' "$agents_md" > "$tmp_md"
            mv "$tmp_md" "$agents_md"
            _eagle_codex_agents_section >> "$agents_md"
            return 0
        fi
        if ! grep -qF 'eagle-mem orchestrate' "$agents_md" 2>/dev/null; then
            local tmp_md
            tmp_md=$(mktemp)
            awk '
                { print }
                /eagle-mem-tasks/ {
                    print "- Use the `eagle-mem-orchestrate` skill for broad multi-agent work. YOU run `eagle-mem orchestrate`; do not ask the user to run these commands"
                }
            ' "$agents_md" > "$tmp_md" && mv "$tmp_md" "$agents_md"
            return 0
        fi
        return 1
    fi

    _eagle_codex_agents_section >> "$agents_md"
}
