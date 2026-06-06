#!/usr/bin/env bash
# Codex hook enablement should use the current canonical features.hooks flag
# while cleaning up the older codex_hooks alias when encountered.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-codex-hooks-config.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
export EAGLE_CODEX_DIR="$HOME/.codex"
export EAGLE_CODEX_CONFIG="$EAGLE_CODEX_DIR/config.toml"
export EAGLE_CODEX_HOOKS="$EAGLE_CODEX_DIR/hooks.json"

mkdir -p "$HOME" "$EAGLE_MEM_DIR" "$EAGLE_CODEX_DIR"

. "$ROOT_DIR/lib/common.sh"
. "$ROOT_DIR/lib/codex-hooks.sh"

fail() {
    echo "codex hooks config regression failed: $*" >&2
    exit 1
}

assert_has_hooks_true() {
    grep -q '^hooks = true$' "$EAGLE_CODEX_CONFIG" || fail "missing canonical hooks = true"
}

assert_no_legacy_write() {
    if grep -q '^codex_hooks[[:space:]]*=' "$EAGLE_CODEX_CONFIG"; then
        fail "deprecated codex_hooks key was left in generated config"
    fi
}

rm -f "$EAGLE_CODEX_CONFIG"
eagle_enable_codex_hooks
assert_has_hooks_true
assert_no_legacy_write

cat > "$EAGLE_CODEX_CONFIG" <<'TOML'
[other]
name = "preserve-me"

[features]
codex_hooks = false
memories = true

[sandbox]
mode = "workspace-write"
TOML

eagle_enable_codex_hooks
assert_has_hooks_true
assert_no_legacy_write
grep -q '^memories = true$' "$EAGLE_CODEX_CONFIG" || fail "features table values were not preserved"
grep -q '^name = "preserve-me"$' "$EAGLE_CODEX_CONFIG" || fail "other config sections were not preserved"
grep -q '^mode = "workspace-write"$' "$EAGLE_CODEX_CONFIG" || fail "later config sections were not preserved"

cat > "$EAGLE_CODEX_CONFIG" <<'TOML'
[features]
hooks = false
TOML

eagle_enable_codex_hooks
assert_has_hooks_true
assert_no_legacy_write
hook_lines=$(grep -c '^hooks = true$' "$EAGLE_CODEX_CONFIG")
[ "$hook_lines" -eq 1 ] || fail "expected one hooks = true line, found $hook_lines"

echo "codex hooks config regressions passed"

