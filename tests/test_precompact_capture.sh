#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — PreCompact capture regression test
#
# Guards the contract of hooks/pre-compact.sh (synchronous rich capture before
# Claude Code compacts the window):
#   1. Registers for BOTH "manual" and "auto" matchers (auto is the real gap).
#   2. With a provider, runs enrich-summary.sh SYNCHRONOUSLY so the rich summary
#      is persisted before compaction (capture_source = enrich).
#   3. Never overwrites an agent-authored summary (capture_source = agent).
#   4. Degrades gracefully with no provider, and ALWAYS exits 0 (never blocks
#      compaction — it must never exit 2).
# ═══════════════════════════════════════════════════════════
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

export EAGLE_MEM_DIR="$tmp_dir/em"
export EAGLE_AGENT_SOURCE="claude-code"
mkdir -p "$EAGLE_MEM_DIR"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1" >&2; fail=$((fail+1)); }

bash "$ROOT_DIR/db/migrate.sh" >/dev/null 2>&1

. "$ROOT_DIR/lib/common.sh"
. "$ROOT_DIR/lib/db.sh"
. "$ROOT_DIR/lib/hooks.sh"

PRECOMPACT="$ROOT_DIR/hooks/pre-compact.sh"

# A minimal Claude-format transcript with assistant text for the enricher.
transcript="$tmp_dir/transcript.jsonl"
{
    printf '%s\n' '{"type":"user","message":{"content":"build a precompact hook"}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"I implemented the PreCompact hook with synchronous enrichment before compaction."}]}}'
} > "$transcript"

mk_input() {
    local sid="$1" trigger="$2"
    jq -nc \
        --arg sid "$sid" \
        --arg cwd "$tmp_dir/work" \
        --arg tp "$transcript" \
        --arg trig "$trigger" \
        '{session_id:$sid, cwd:$cwd, transcript_path:$tp, hook_event_name:"PreCompact", trigger:$trig}'
}

# Resolve the project the hook will derive, so parent-side inserts line up.
PROJ=$(eagle_project_from_hook_input "$(mk_input "probe" "auto")")
[ -n "$PROJ" ] || PROJ="precompact/test"

# ── 1. Registration: both matchers ──────────────────────────────────────────
settings="$tmp_dir/settings.json"
echo '{}' > "$settings"
eagle_register_claude_hooks "$settings" >/dev/null 2>&1
manual_cmd=$(jq -r '.hooks.PreCompact[]? | select(.matcher=="manual") | .hooks[].command' "$settings" 2>/dev/null)
auto_cmd=$(jq -r '.hooks.PreCompact[]? | select(.matcher=="auto") | .hooks[].command' "$settings" 2>/dev/null)
if echo "$manual_cmd" | grep -q 'pre-compact.sh'; then
    ok "PreCompact registered for matcher 'manual'"
else
    bad "PreCompact not registered for matcher 'manual'"
fi
if echo "$auto_cmd" | grep -q 'pre-compact.sh'; then
    ok "PreCompact registered for matcher 'auto' (auto-compaction covered)"
else
    bad "PreCompact not registered for matcher 'auto'"
fi

# ── 2. No provider: graceful, exits 0, writes no enriched summary ────────────
SID2="precompact-noprovider-001"
eagle_upsert_session "$SID2" "$PROJ" "$tmp_dir/work" "" "test" "claude-code"
mk_input "$SID2" "auto" | bash "$PRECOMPACT"; rc2=$?
if [ "$rc2" -eq 0 ]; then
    ok "no-provider run exits 0 (never blocks compaction)"
else
    bad "no-provider run exited $rc2 (must be 0; exit 2 would block compaction)"
fi
src2=$(eagle_summary_capture_source "$SID2" 2>/dev/null || true)
if [ -z "$src2" ]; then
    ok "no-provider run writes no summary (Stop already covers it)"
else
    bad "no-provider run unexpectedly wrote a summary (capture_source='$src2')"
fi

# ── 3. Agent-authored summary is never clobbered ────────────────────────────
SID3="precompact-agentrow-001"
eagle_upsert_session "$SID3" "$PROJ" "$tmp_dir/work" "" "test" "claude-code"
eagle_insert_summary "$SID3" "$PROJ" "agent req" "" "" "AGENT_ORIGINAL_COMPLETED" "" "[]" "[]" "" "" "" "" "claude-code" "agent" >/dev/null 2>&1
mk_input "$SID3" "manual" | bash "$PRECOMPACT"; rc3=$?
src3=$(eagle_summary_capture_source "$SID3" 2>/dev/null || true)
comp3=$(eagle_db "SELECT completed FROM summaries WHERE session_id = '$(eagle_sql_escape "$SID3")' LIMIT 1;" 2>/dev/null)
if [ "$rc3" -eq 0 ] && [ "$src3" = "agent" ] && [ "$comp3" = "AGENT_ORIGINAL_COMPLETED" ]; then
    ok "agent-authored summary preserved (capture_source=agent, content intact)"
else
    bad "agent summary perturbed: rc=$rc3 source='$src3' completed='$comp3'"
fi

# ── 4. With a provider: synchronous enrichment writes a rich summary ─────────
fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/claude" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
REQUEST:
Build a PreCompact hook for Eagle Mem
COMPLETED:
Added PRECOMPACT_SYNC_CAPTURE before the window collapses
DECISIONS:
- Reused enrich-summary synchronously — why: guarantee rich capture before compaction
GOTCHAS:
- PreCompact cannot inject context, only side effects
KEY_FILES:
hooks/pre-compact.sh
OUT
SH
chmod +x "$fake_bin/claude"
cat > "$EAGLE_MEM_DIR/config.toml" <<'TOML'
[provider]
type = "agent_cli"
fallback = "auto"

[agent_cli]
preferred = "claude"
codex_model = ""
claude_model = ""
TOML

SID4="precompact-enrich-001"
eagle_upsert_session "$SID4" "$PROJ" "$tmp_dir/work" "" "test" "claude-code"
mk_input "$SID4" "manual" | PATH="$fake_bin:$PATH" bash "$PRECOMPACT"; rc4=$?
src4=$(eagle_summary_capture_source "$SID4" 2>/dev/null || true)
comp4=$(eagle_db "SELECT completed FROM summaries WHERE session_id = '$(eagle_sql_escape "$SID4")' LIMIT 1;" 2>/dev/null)
if [ "$rc4" -eq 0 ]; then
    ok "provider run exits 0"
else
    bad "provider run exited $rc4 (must be 0)"
fi
if [ "$src4" = "enrich" ] && echo "$comp4" | grep -q 'PRECOMPACT_SYNC_CAPTURE'; then
    ok "synchronous enrichment wrote a rich summary before compaction (capture_source=enrich)"
else
    bad "synchronous enrichment did not write the expected summary: source='$src4' completed='$comp4'"
fi

# ── 5. Structural guard: hook never exits 2 (would block compaction) ─────────
if grep -nE '^[[:space:]]*exit[[:space:]]+2' "$PRECOMPACT" >/dev/null 2>&1; then
    bad "pre-compact.sh contains 'exit 2' — PreCompact must never block compaction"
else
    ok "pre-compact.sh has no 'exit 2' (cannot block compaction)"
fi

echo
echo "precompact capture: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
