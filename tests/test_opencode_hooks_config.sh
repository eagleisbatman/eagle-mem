#!/usr/bin/env bash
# Regression coverage for OpenCode plugin and skill registration helpers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-opencode-hooks.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR"

. "$ROOT_DIR/scripts/style.sh"
. "$ROOT_DIR/lib/common.sh"
. "$ROOT_DIR/lib/opencode-hooks.sh"

fail() {
    echo "opencode hooks config test failed: $*" >&2
    exit 1
}

first_skill=$(find "$ROOT_DIR/skills" -mindepth 1 -maxdepth 1 -type d -name "eagle-mem-*" | sort | head -n 1)
[ -n "$first_skill" ] || fail "no Eagle Mem skills found for OpenCode symlink test"
first_skill_name=$(basename "$first_skill")

mkdir -p "$EAGLE_OPENCODE_DIR"
eagle_opencode_detected || fail "OpenCode should be detected when config directory exists"

eagle_install_opencode_plugin "$ROOT_DIR" "0" >/dev/null
[ -f "$EAGLE_OPENCODE_PLUGIN" ] || fail "plugin was not installed"
grep -q "EAGLE_MEM_OPENCODE_PLUGIN" "$EAGLE_OPENCODE_PLUGIN" || fail "installed plugin is missing Eagle Mem ownership marker"
[ "$(eagle_opencode_plugin_state)" = "registered" ] || fail "plugin state should be registered"

eagle_install_opencode_plugin "$ROOT_DIR" "0" >/dev/null
[ "$(eagle_opencode_plugin_state)" = "registered" ] || fail "plugin reinstall should be idempotent"

eagle_install_opencode_skills "$ROOT_DIR" "0" >/dev/null
[ -L "$EAGLE_OPENCODE_SKILLS_DIR/$first_skill_name" ] || fail "OpenCode skill symlink was not created"
mkdir -p "$EAGLE_OPENCODE_SKILLS_DIR/eagle-mem-user-directory"

eagle_remove_opencode_plugin || fail "owned plugin should be removable"
[ ! -f "$EAGLE_OPENCODE_PLUGIN" ] || fail "owned plugin still exists after removal"

eagle_remove_opencode_skills >/dev/null || true
[ ! -e "$EAGLE_OPENCODE_SKILLS_DIR/$first_skill_name" ] || fail "OpenCode skill symlink still exists after removal"
[ -d "$EAGLE_OPENCODE_SKILLS_DIR/eagle-mem-user-directory" ] || fail "OpenCode skill removal deleted a real directory"

mkdir -p "$EAGLE_OPENCODE_PLUGINS_DIR"
printf '%s\n' "custom opencode plugin" > "$EAGLE_OPENCODE_PLUGIN"
if eagle_install_opencode_plugin "$ROOT_DIR" "0" >/dev/null 2>&1; then
    fail "custom OpenCode plugin should not be overwritten"
fi
grep -q "custom opencode plugin" "$EAGLE_OPENCODE_PLUGIN" || fail "custom plugin contents were overwritten"
[ "$(eagle_opencode_plugin_state)" = "custom" ] || fail "custom plugin state should be reported"

echo "opencode hooks config test passed"
