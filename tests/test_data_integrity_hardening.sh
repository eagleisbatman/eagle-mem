#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Data integrity hardening regression test
# Covers:
#   - migrate.sh idempotency (re-run is a no-op, _migrations unchanged)
#   - SQL escaping units (single quotes, FTS metachars, GLOB/LIKE patterns
#     stored verbatim and queryable — no injection, no crash)
#   - Summary precedence: eagle_insert_summary vs _fill_only — capture_source
#     AND project stickiness on agent rows (finding #8 clobber)
# ═══════════════════════════════════════════════════════════
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

export EAGLE_MEM_DIR="$tmp_dir/em"
export EAGLE_AGENT_SOURCE="claude-code"
export EAGLE_MEM_DISABLE_HOOKS=1
mkdir -p "$EAGLE_MEM_DIR"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1" >&2; fail=$((fail+1)); }

bash "$ROOT_DIR/db/migrate.sh" >/dev/null 2>&1

. "$ROOT_DIR/lib/common.sh"
. "$ROOT_DIR/lib/db.sh"

# ── migrate.sh idempotency ──────────────────────────────────
mig_before=$(eagle_db "SELECT COUNT(*) || ':' || COALESCE(MAX(id),0) FROM _migrations;")
mig_out=$(bash "$ROOT_DIR/db/migrate.sh" 2>&1); mig_rc=$?
[ "$mig_rc" -eq 0 ] && ok "migrate 2nd run exits 0" || bad "migrate 2nd run rc=$mig_rc out=$mig_out"
case "$mig_out" in
    *applied:*) bad "migrate 2nd run re-applied a migration: $mig_out" ;;
    *) ok "migrate 2nd run applied nothing" ;;
esac
mig_after=$(eagle_db "SELECT COUNT(*) || ':' || COALESCE(MAX(id),0) FROM _migrations;")
[ "$mig_before" = "$mig_after" ] && ok "_migrations unchanged on 2nd run ($mig_after)" || bad "_migrations drifted: $mig_before -> $mig_after"

# ── SQL escaping units ──────────────────────────────────────
# Each payload is stored verbatim via eagle_insert_summary (escaped) and read
# back; a quote/metachar that broke out of the literal would error or truncate.
SID_Q="esc-quote-001"
eagle_upsert_session "$SID_Q" "esc/proj" "$tmp_dir" "" "test" "claude-code"
quote_payload="it's a \"trap\"; DROP TABLE summaries;-- '' or 1=1"
eagle_insert_summary "$SID_Q" "esc/proj" "$quote_payload" "" "" "" "" "[]" "[]" "" "" "" "" "claude-code" "agent"
got_q=$(eagle_db "SELECT request FROM summaries WHERE session_id='$SID_Q';")
[ "$got_q" = "$quote_payload" ] && ok "single-quote/SQL-injection payload stored verbatim" || bad "quote payload mangled -> '$got_q'"
# summaries table still present (no DROP executed)
have_tbl=$(eagle_db "SELECT name FROM sqlite_master WHERE type='table' AND name='summaries';")
[ "$have_tbl" = "summaries" ] && ok "summaries table intact after injection attempt" || bad "summaries table missing — injection executed"

SID_F="esc-fts-002"
eagle_upsert_session "$SID_F" "esc/proj" "$tmp_dir" "" "test" "claude-code"
fts_payload='NEAR("foo" bar)* AND col:val OR -baz {set}'
eagle_insert_summary "$SID_F" "esc/proj" "$fts_payload" "" "" "" "" "[]" "[]" "" "" "" "" "claude-code" "agent"
got_f=$(eagle_db "SELECT request FROM summaries WHERE session_id='$SID_F';")
[ "$got_f" = "$fts_payload" ] && ok "FTS-metachar payload stored verbatim" || bad "FTS payload mangled -> '$got_f'"
# FTS search over a benign token must not crash even though row has metachars
srch=$(eagle_search_summaries "foo" "" 5 2>&1); srch_rc=$?
[ "$srch_rc" -eq 0 ] && ok "FTS search over metachar corpus did not crash (rc=0)" || bad "FTS search crashed rc=$srch_rc: $srch"

SID_G="esc-glob-003"
eagle_upsert_session "$SID_G" "esc/proj" "$tmp_dir" "" "test" "claude-code"
glob_payload='100% OFF _now_ [a-z]* path\to\file'
eagle_insert_observation "$SID_G" "esc/proj" "Bash" "$glob_payload" "[]" "[]"
got_g=$(eagle_db "SELECT tool_input_summary FROM observations WHERE session_id='$SID_G';")
[ "$got_g" = "$glob_payload" ] && ok "GLOB/LIKE-metachar payload stored verbatim in observations" || bad "glob payload mangled -> '$got_g'"

# guardrail field escaping (single quote)
if declare -F eagle_add_guardrail >/dev/null 2>&1; then
    eagle_add_guardrail "esc/proj" "don't touch '; DELETE FROM guardrails;--" "*.sh" "test" >/dev/null 2>&1
    grc=$(eagle_db "SELECT rule FROM guardrails WHERE project='esc/proj' ORDER BY id DESC LIMIT 1;")
    case "$grc" in *"don't touch"*) ok "guardrail rule with quote stored verbatim" ;; *) bad "guardrail rule mangled -> '$grc'" ;; esac
    gcount=$(eagle_db "SELECT name FROM sqlite_master WHERE type='table' AND name='guardrails';")
    [ "$gcount" = "guardrails" ] && ok "guardrails table intact after injection attempt" || bad "guardrails table dropped — injection executed"
else
    ok "eagle_add_guardrail not present — skipped (non-fatal)"
fi

# ── Summary precedence / clobber (finding #8) ───────────────
# An agent-authored row must NOT have its project rekeyed by a later hook-path
# writer that arrives with a drifted project key.
SID_P="precedence-004"
eagle_upsert_session "$SID_P" "real/project" "$tmp_dir" "" "test" "claude-code"
eagle_insert_summary "$SID_P" "real/project" "agent req" "" "" "agent done" "" "[]" "[]" "" "agent decision" "" "" "claude-code" "agent"
[ "$(eagle_db "SELECT capture_source FROM summaries WHERE session_id='$SID_P';")" = "agent" ] && ok "P: capture_source=agent after agent insert" || bad "P: capture_source not agent"
[ "$(eagle_db "SELECT project FROM summaries WHERE session_id='$SID_P';")" = "real/project" ] && ok "P: project=real/project after agent insert" || bad "P: project wrong"

# Later hook writer with a DRIFTED project key + heuristic capture_source.
eagle_insert_summary "$SID_P" "DRIFTED/wrong-key" "" "" "" "" "" "[]" "[]" "" "" "" "" "claude-code" "hook"
proj_after=$(eagle_db "SELECT project FROM summaries WHERE session_id='$SID_P';")
[ "$proj_after" = "real/project" ] && ok "P: agent row project NOT clobbered by drifted hook write" || bad "P: project clobbered -> '$proj_after'"
[ "$(eagle_db "SELECT capture_source FROM summaries WHERE session_id='$SID_P';")" = "agent" ] && ok "P: capture_source stays agent" || bad "P: capture_source downgraded"
[ "$(eagle_db "SELECT completed FROM summaries WHERE session_id='$SID_P';")" = "agent done" ] && ok "P: agent completed preserved" || bad "P: completed clobbered"

# Contrast: a hook-authored row (capture_source != agent) SHOULD still accept a
# project correction (the normal drift-repair path must not regress).
SID_H="precedence-005"
eagle_upsert_session "$SID_H" "hookproj/a" "$tmp_dir" "" "test" "claude-code"
eagle_insert_summary "$SID_H" "hookproj/a" "hook req" "" "" "hook done" "" "[]" "[]" "" "" "" "" "claude-code" "hook"
eagle_insert_summary "$SID_H" "hookproj/b" "" "" "" "" "" "[]" "[]" "" "" "" "" "claude-code" "hook"
proj_h=$(eagle_db "SELECT project FROM summaries WHERE session_id='$SID_H';")
[ "$proj_h" = "hookproj/b" ] && ok "H: hook row project STILL repairable (no regression)" || bad "H: hook project not updated -> '$proj_h'"

# fill_only must never change project or downgrade capture_source on agent row
eagle_insert_summary_fill_only "$SID_P" "ANOTHER/drift" "" "" "fill learned" "" "" "[]" "[]" "" "" "" "" "claude-code" "enrich"
[ "$(eagle_db "SELECT project FROM summaries WHERE session_id='$SID_P';")" = "real/project" ] && ok "P: fill_only did not change project" || bad "P: fill_only changed project"
case "$(eagle_db "SELECT learned FROM summaries WHERE session_id='$SID_P';")" in *"fill learned"*) ok "P: fill_only filled empty learned gap" ;; *) bad "P: fill_only did not fill learned" ;; esac

echo ""
echo "test_data_integrity_hardening: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
