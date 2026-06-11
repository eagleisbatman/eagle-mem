#!/usr/bin/env bash
# Curator command-rule provenance — closes the curator -> guardrail -> PreToolUse
# loop where LLM output became enforcement input with no provenance.
# command_rules steer PreToolUse output handling (truncate/summary). Curator-
# generated rules are now tagged source='curator'; setting
# token_guard.trust_learned_rules=false excludes them so model output cannot
# silently shape command handling. Human ('manual') rules are unaffected.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/eagle-rule-prov.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR"

. "$ROOT_DIR/lib/common.sh"
"$ROOT_DIR/db/migrate.sh" >/dev/null
. "$ROOT_DIR/lib/db.sh"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

project="rule-prov"
p=$(eagle_sql_escape "$project")
eagle_db "INSERT INTO command_rules (project, pattern, strategy, max_lines, reason, source)
          VALUES ('$p','curatorcmd','truncate',50,'noisy','curator');" >/dev/null
eagle_db "INSERT INTO command_rules (project, pattern, strategy, max_lines, reason, source)
          VALUES ('$p','manualcmd','truncate',50,'noisy','manual');" >/dev/null

# 1. provenance is persisted
[ "$(eagle_db "SELECT source FROM command_rules WHERE pattern='curatorcmd';")" = "curator" ] \
    && ok "curator rule stored with source=curator" || bad "curator source not persisted"
[ "$(eagle_db "SELECT source FROM command_rules WHERE pattern='manualcmd';")" = "manual" ] \
    && ok "manual rule stored with source=manual" || bad "manual source not persisted"

# 2. default (no config) trusts learned rules — curator rule applies
[ -n "$(eagle_get_command_rule "$project" "curatorcmd" "curatorcmd")" ] \
    && ok "default: curator rule applies (auto-learning preserved)" \
    || bad "default: curator rule should apply"

# 3. trust_learned_rules=false excludes curator rules, keeps manual rules
printf '[token_guard]\ntrust_learned_rules = false\n' > "$EAGLE_MEM_DIR/config.toml"
[ -z "$(eagle_get_command_rule "$project" "curatorcmd" "curatorcmd")" ] \
    && ok "trust=false: curator rule excluded from enforcement" \
    || bad "trust=false: curator rule should be excluded"
[ -n "$(eagle_get_command_rule "$project" "manualcmd" "manualcmd")" ] \
    && ok "trust=false: manual rule still applies" \
    || bad "trust=false: manual rule should still apply"

# 4. the curator code path tags new rules as 'curator'
grep -q "VALUES ('\$p_esc', '\$pattern_esc', '\$strategy', \$ml_val, '\$reason_esc', 'curator')" "$ROOT_DIR/scripts/curate.sh" \
    && ok "curate.sh writes command rules with source='curator'" \
    || bad "curate.sh does not tag command rules as curator"

echo ""
echo "test_command_rule_provenance: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
