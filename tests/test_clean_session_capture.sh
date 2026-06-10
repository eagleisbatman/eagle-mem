#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Clean, branded session capture regression test
# Covers: CLI-first capture, clobber prevention, backward-compat
#         <eagle-summary> override, and enrichment fill-only.
# ═══════════════════════════════════════════════════════════
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

export EAGLE_MEM_DIR="$tmp_dir/em"
export EAGLE_AGENT_SOURCE="claude-code"
export EAGLE_MEM_DISABLE_HOOKS=0
# Pin the project so both the CLI save and the Stop hook resolve identically
# (the temp cwd lives under /var/folders, which Eagle Mem treats as ephemeral).
export EAGLE_MEM_PROJECT="test/clean-capture"
mkdir -p "$EAGLE_MEM_DIR"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1" >&2; fail=$((fail+1)); }

bash "$ROOT_DIR/db/migrate.sh" >/dev/null 2>&1

. "$ROOT_DIR/lib/common.sh"
. "$ROOT_DIR/lib/db.sh"

# A real cwd for the hook payload; project is pinned via EAGLE_MEM_PROJECT.
work="$tmp_dir/work"
mkdir -p "$work"
PROJECT="$EAGLE_MEM_PROJECT"
ok "pinned project: $PROJECT"

field() { eagle_db "SELECT COALESCE($2,'') FROM summaries WHERE session_id='$1';"; }

# ── Scenario A: CLI capture then a heuristic Stop must NOT clobber it ──
SID="clean-capture-aaa111"
eagle_upsert_session "$SID" "$PROJECT" "$work" "" "startup" "claude-code"

bash "$ROOT_DIR/scripts/session.sh" save --session-id "$SID" --project "$PROJECT" \
    --completed "Rich agent completed" \
    --decisions "Pin v1 — why safety; Use TOTP — why no SMTP" \
    --gotchas "needs PUBLIC_URL" >/dev/null 2>&1

[ "$(field "$SID" capture_source)" = "agent" ] && ok "A: capture_source=agent after CLI save" || bad "A: capture_source not agent"

# Heuristic Stop: transcript has an Edit (fills files), NO <eagle-summary> block.
tA="$tmp_dir/transcriptA.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"please harden the pipeline"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"'"$work"'/foo.sh"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done. We hardened the pipeline this session."}]}}'
} > "$tA"

stopA=$(jq -nc --arg s "$SID" --arg c "$work" --arg t "$tA" \
    '{session_id:$s, cwd:$c, transcript_path:$t}')
echo "$stopA" | EAGLE_MEM_STOP_BACKGROUND_ENRICH=0 bash "$ROOT_DIR/hooks/stop.sh" >/dev/null 2>&1

[ "$(field "$SID" completed)" = "Rich agent completed" ] && ok "A: completed NOT clobbered by heuristic" || bad "A: completed was clobbered -> '$(field "$SID" completed)'"
[ "$(field "$SID" capture_source)" = "agent" ] && ok "A: capture_source still agent after Stop" || bad "A: capture_source downgraded"
case "$(field "$SID" files_modified)" in *foo.sh*) ok "A: files_modified gap-filled by heuristic" ;; *) bad "A: files_modified not filled -> '$(field "$SID" files_modified)'" ;; esac
case "$(field "$SID" decisions)" in *"Pin v1"*) ok "A: decisions preserved" ;; *) bad "A: decisions lost" ;; esac
mrows=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE session_id LIKE 'manual-%';")
[ "$mrows" = "0" ] && ok "A: no stray manual-* row" || bad "A: $mrows manual-* rows created"
sstatus=$(eagle_db "SELECT status FROM sessions WHERE id='$SID';")
[ "$sstatus" = "active" ] && ok "A: live session still active (not ended)" || bad "A: session status=$sstatus"

# ── Scenario B: a <eagle-summary> block still overrides (backward compat) ──
SIDB="clean-capture-bbb222"
eagle_upsert_session "$SIDB" "$PROJECT" "$work" "" "startup" "claude-code"
tB="$tmp_dir/transcriptB.jsonl"
blocktext='Summary below.

<eagle-summary>
request: legacy block path
completed: shipped via block
decisions: keep parser — why backward compat
gotchas: none
</eagle-summary>'
{
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"do the legacy thing"}]}}'
  printf '%s\n' "$(jq -nc --arg t "$blocktext" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}')"
} > "$tB"
stopB=$(jq -nc --arg s "$SIDB" --arg c "$work" --arg t "$tB" '{session_id:$s, cwd:$c, transcript_path:$t}')
echo "$stopB" | EAGLE_MEM_STOP_BACKGROUND_ENRICH=0 bash "$ROOT_DIR/hooks/stop.sh" >/dev/null 2>&1

[ "$(field "$SIDB" capture_source)" = "agent" ] && ok "B: block sets capture_source=agent" || bad "B: capture_source=$(field "$SIDB" capture_source)"
case "$(field "$SIDB" completed)" in *"shipped via block"*) ok "B: completed parsed from block" ;; *) bad "B: block completed not parsed" ;; esac
case "$(field "$SIDB" decisions)" in *"keep parser"*) ok "B: decisions parsed from block" ;; *) bad "B: block decisions not parsed" ;; esac

# ── Scenario C: enrichment must not overwrite an agent row ──
SIDC="clean-capture-ccc333"
eagle_upsert_session "$SIDC" "$PROJECT" "$work" "" "startup" "claude-code"
eagle_insert_summary "$SIDC" "$PROJECT" "req" "" "" "agent completed C" "" "[]" "[]" "" "agent decision C" "" "" "claude-code" "agent"
# fill-only path used by enrich when source=agent: simulate enrich trying to overwrite
eagle_insert_summary_fill_only "$SIDC" "$PROJECT" "" "" "enriched learned" "ENRICH OVERWRITE" "" "[]" "[]" "" "ENRICH DECISION" "" "" "claude-code" "enrich"
[ "$(field "$SIDC" completed)" = "agent completed C" ] && ok "C: enrich fill-only did NOT overwrite completed" || bad "C: enrich overwrote -> '$(field "$SIDC" completed)'"
case "$(field "$SIDC" learned)" in *"enriched learned"*) ok "C: enrich filled empty learned gap" ;; *) bad "C: enrich did not fill empty learned" ;; esac
[ "$(field "$SIDC" capture_source)" = "agent" ] && ok "C: capture_source stays agent through enrich" || bad "C: capture_source changed"

echo ""
echo "test_clean_session_capture: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
