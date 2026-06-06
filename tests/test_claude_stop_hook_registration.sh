#!/usr/bin/env bash
# Regression coverage for Claude Stop hook registration.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-claude-stop.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR/hooks"

. "$ROOT_DIR/scripts/style.sh"
. "$ROOT_DIR/lib/common.sh"
. "$ROOT_DIR/lib/hooks.sh"

settings="$tmp_dir/settings.json"
old_stop="$EAGLE_MEM_DIR/hooks/stop.sh"
new_stop="bash \"$EAGLE_MEM_DIR/hooks/stop.sh\""

fail() {
    echo "claude stop hook registration test failed: $*" >&2
    exit 1
}

cat > "$settings" <<JSON
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$old_stop"
          }
        ]
      }
    ]
  }
}
JSON

eagle_clean_hook_entries "$settings" "Stop" "$old_stop"
eagle_patch_hook "$settings" "Stop" "" "$new_stop" >/dev/null

jq -e --arg cmd "$old_stop" 'all(.hooks.Stop[]?.hooks[]?; .command != $cmd)' "$settings" >/dev/null \
    || fail "path-only Stop hook registration remained"

jq -e --arg cmd "$new_stop" '.hooks.Stop[]? | select(.matcher == null and (.hooks[]?.command == $cmd))' "$settings" >/dev/null \
    || fail "bash-wrapped Stop hook registration missing"

eagle_patch_hook "$settings" "Stop" "" "$new_stop" >/dev/null
count=$(jq --arg cmd "$new_stop" '[.hooks.Stop[]?.hooks[]? | select(.command == $cmd)] | length' "$settings")
[ "$count" -eq 1 ] || fail "bash-wrapped Stop hook registration duplicated: $count"

echo "claude stop hook registration test passed"
