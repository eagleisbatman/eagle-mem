#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    case "$haystack" in
        *"$needle"*) ;;
        *)
            echo "$message" >&2
            echo "Expected to find: $needle" >&2
            echo "Actual: $haystack" >&2
            exit 1
            ;;
    esac
}

# Provider fallback: a failed preferred Codex CLI should fall through to Claude.
provider_home="$tmp_dir/provider-home"
fake_bin="$tmp_dir/bin"
mkdir -p "$provider_home" "$fake_bin"
cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
exit 42
SH
cat > "$fake_bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'claude fallback ok\n'
SH
chmod +x "$fake_bin/codex" "$fake_bin/claude"
cat > "$provider_home/config.toml" <<'TOML'
[provider]
type = "agent_cli"
fallback = "auto"

[agent_cli]
preferred = "codex"
codex_model = ""
claude_model = ""
TOML
provider_result=$(EAGLE_MEM_DIR="$provider_home" PATH="$fake_bin:$PATH" bash -c "
    . '$ROOT_DIR/lib/common.sh'
    . '$ROOT_DIR/lib/provider.sh'
    eagle_llm_call 'say ok' 'system' 20
")
assert_contains "$provider_result" "claude fallback ok" "agent_cli fallback did not use Claude after Codex failed"
cat > "$provider_home/config.toml" <<'TOML'
[provider]
type = "agent_cli"
fallback = "auto"

[agent_cli]
preferred = "grok"
codex_model = ""
claude_model = ""
TOML
EAGLE_MEM_DIR="$provider_home" PATH="$fake_bin:$PATH" bash -c "
    . '$ROOT_DIR/lib/common.sh'
    . '$ROOT_DIR/lib/provider.sh'
    _eagle_agent_cli_target_chain >/dev/null
"
grep -q "agent_cli unsupported preferred target: grok" "$provider_home/eagle-mem.log" || {
    echo "unsupported agent_cli target should be logged" >&2
    exit 1
}

# PreToolUse parsing + read scoring: repeated large read after modification should emit scored context.
hook_home="$tmp_dir/hook-home"
repo="$tmp_dir/repo"
mkdir -p "$hook_home/mod-tracker" "$repo"
touch "$hook_home/memory.db"
large_file="$repo/large.txt"
dd if=/dev/zero bs=1024 count=600 2>/dev/null | tr '\0' 'x' > "$large_file"
session_id="session_reliability_123"
printf '%s\n' "$large_file" > "$hook_home/mod-tracker/$session_id"
read_input=$(jq -nc --arg fp "$large_file" --arg sid "$session_id" --arg cwd "$repo" \
    '{tool_name:"Read",session_id:$sid,cwd:$cwd,tool_input:{file_path:$fp}}')
EAGLE_MEM_DIR="$hook_home" EAGLE_MEM_PROJECT="project-read" bash "$ROOT_DIR/hooks/pre-tool-use.sh" <<< "$read_input" >/dev/null
EAGLE_MEM_DIR="$hook_home" EAGLE_MEM_PROJECT="project-read" bash "$ROOT_DIR/hooks/pre-tool-use.sh" <<< "$read_input" >/dev/null
read_output=$(EAGLE_MEM_DIR="$hook_home" EAGLE_MEM_PROJECT="project-read" bash "$ROOT_DIR/hooks/pre-tool-use.sh" <<< "$read_input")
assert_contains "$read_output" "Eagle Mem read score" "Read guard did not emit scored duplicate-read context"
grep -q 'mod_file}.lock' "$ROOT_DIR/hooks/post-tool-use.sh" || {
    echo "post-tool-use modification tracker should use a lock directory" >&2
    exit 1
}
if grep -q '>> "$mod_file"' "$ROOT_DIR/hooks/post-tool-use.sh"; then
    echo "post-tool-use modification tracker should not append to mod_file outside the lock" >&2
    exit 1
fi

# Auto-scan state race: failed background scan must clear the freshness marker.
state_home="$tmp_dir/state-home"
auto_scripts="$tmp_dir/auto-scripts"
auto_repo="$tmp_dir/auto-repo"
mkdir -p "$state_home" "$auto_scripts" "$auto_repo"
cat > "$auto_scripts/scan.sh" <<'SH'
#!/usr/bin/env bash
exit 9
SH
cat > "$auto_scripts/index.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
EAGLE_MEM_DIR="$state_home" EAGLE_MEM_LOG="$state_home/eagle-mem.log" bash -c "
    . '$ROOT_DIR/lib/common.sh'
    . '$ROOT_DIR/lib/hooks-sessionstart.sh'
    eagle_get_overview() { return 0; }
    eagle_db() { printf '0\n'; }
    eagle_sessionstart_auto_provision 'project-auto-fail' '$auto_repo' '$auto_scripts'
    scan_state=\$(_eagle_state_file scan 'project-auto-fail')
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        grep -q 'auto-scan failed' '$state_home/eagle-mem.log' 2>/dev/null && break
        sleep 0.2
    done
    [ ! -f \"\$scan_state\" ]
"

# Command-scoped logs: scan should create an inspectable run log and logs list should show it.
log_home="$tmp_dir/log-home"
log_repo="$tmp_dir/log-repo"
mkdir -p "$log_home" "$log_repo"
printf '# demo\n' > "$log_repo/README.md"
EAGLE_MEM_DIR="$log_home" bash "$ROOT_DIR/scripts/scan.sh" "$log_repo" >/dev/null
log_list=$(EAGLE_MEM_DIR="$log_home" bash "$ROOT_DIR/bin/eagle-mem" logs list)
assert_contains "$log_list" "command=scan" "logs list did not show the scan command run"
run_path=$(ls -t "$log_home/runs"/*.log 2>/dev/null | sed -n '1p')
run_id=$(basename "$run_path" .log)
run_show=$(EAGLE_MEM_DIR="$log_home" bash "$ROOT_DIR/bin/eagle-mem" logs show "$run_id")
assert_contains "$run_show" "run_start" "logs show by run id did not print the run log"
if EAGLE_MEM_DIR="$log_home" bash "$ROOT_DIR/bin/eagle-mem" logs show /etc/hosts >/dev/null 2>&1; then
    echo "logs show should reject absolute paths outside the run log directory" >&2
    exit 1
fi
if EAGLE_MEM_DIR="$log_home" bash "$ROOT_DIR/bin/eagle-mem" logs tail ../memory.db >/dev/null 2>&1; then
    echo "logs tail should reject traversal outside the run log directory" >&2
    exit 1
fi
mkdir -p "$log_home/runs/nested"
printf '[nested] [INFO] nested run\n' > "$log_home/runs/nested/nested.log"
if EAGLE_MEM_DIR="$log_home" bash "$ROOT_DIR/bin/eagle-mem" logs show "$log_home/runs/nested/nested.log" >/dev/null 2>&1; then
    echo "logs show should reject nested absolute paths inside the run log directory" >&2
    exit 1
fi
ln -s /etc/hosts "$log_home/runs/symlink.log"
if EAGLE_MEM_DIR="$log_home" bash "$ROOT_DIR/bin/eagle-mem" logs show symlink >/dev/null 2>&1; then
    echo "logs show should reject symlinked run logs" >&2
    exit 1
fi
list_with_symlink=$(EAGLE_MEM_DIR="$log_home" bash "$ROOT_DIR/bin/eagle-mem" logs list)
case "$list_with_symlink" in
    *symlink*)
        echo "logs list should skip symlinked run logs" >&2
        exit 1
        ;;
esac
printf '[old] [INFO] old run\n' > "$log_home/runs/20000101T000000Z-scan-1.log"
printf '[old] [INFO] old run\n' > "$log_home/runs/20000101T000001Z-scan-2.log"
EAGLE_MEM_DIR="$log_home" bash "$ROOT_DIR/bin/eagle-mem" logs prune --days 0 --keep 1 >/dev/null
remaining_logs=$(find "$log_home/runs" -type f -name '*.log' -print | wc -l | tr -d ' ')
if [ "$remaining_logs" != "1" ]; then
    echo "logs prune --keep 1 should leave exactly one run log" >&2
    exit 1
fi

mirror_home="$tmp_dir/mirror-home"
mkdir -p "$mirror_home"
EAGLE_MEM_DIR="$mirror_home" EAGLE_MEM_LOG="$mirror_home/eagle-mem.log" bash -c "
    . '$ROOT_DIR/lib/common.sh'
    eagle_run_start 'mirror-test' 'project-mirror' '$tmp_dir'
    eagle_log 'WARN' 'mirrored run log detail'
    eagle_run_finish 0 0
" >/dev/null
mirror_log=$(ls "$mirror_home/runs"/*.log | sed -n '1p')
grep -q "mirrored run log detail" "$mirror_log" || {
    echo "eagle_log messages should be mirrored into active run logs" >&2
    exit 1
}

post_home="$tmp_dir/post-home"
post_repo="$tmp_dir/post-repo"
mkdir -p "$post_home" "$post_repo"
EAGLE_MEM_DIR="$post_home" "$ROOT_DIR/db/migrate.sh" >/dev/null
post_session="session_posttool_123"
patch_cmd=$'*** Begin Patch\n*** Update File: alpha.txt\n@@\n-old\n+new\n*** Update File: beta.txt\n@@\n-old\n+new\n*** Update File: old-name.txt\n*** Move to: gamma.txt\n@@\n-old\n+new\n*** End Patch'
post_input=$(jq -nc --arg sid "$post_session" --arg cwd "$post_repo" --arg cmd "$patch_cmd" \
    '{tool_name:"apply_patch",session_id:$sid,cwd:$cwd,tool_input:{command:$cmd},tool_response:{}}')
EAGLE_MEM_DIR="$post_home" EAGLE_MEM_PROJECT="project-post" bash "$ROOT_DIR/hooks/post-tool-use.sh" <<< "$post_input"
mod_contents=$(cat "$post_home/mod-tracker/$post_session")
assert_contains "$mod_contents" "beta.txt" "multi-file apply_patch should track later modified files"
assert_contains "$mod_contents" "gamma.txt" "apply_patch move destinations should be tracked"

echo "reliability guard regressions passed"
