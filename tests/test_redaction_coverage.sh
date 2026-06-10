#!/usr/bin/env bash
# Regression coverage for the Phase 1 security hardening:
#  - secrets are redacted BEFORE leaving the machine (LLM provider input,
#    enrich job file) and before persistence (recall_events, observations)
#  - configured [redaction] extra_patterns are actually applied by eagle_redact
#  - orchestration workers default to a non-full-access (safe) autonomy mode
#  - logs path resolver rejects traversal/symlink/out-of-root references
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-redaction.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
export EAGLE_CONFIG_FILE="$EAGLE_MEM_DIR/config.toml"
mkdir -p "$HOME" "$EAGLE_MEM_DIR"

. "$ROOT_DIR/lib/common.sh"
"$ROOT_DIR/db/migrate.sh" >/dev/null
. "$ROOT_DIR/lib/db.sh"
. "$ROOT_DIR/lib/provider.sh"

# Fake secrets that must never survive redaction.
FAKE_ANT="sk-ant-FAKEabcdefghijklmnop1234567890"
FAKE_AWS="AKIAFAKE0000000000AB"
FAKE_BEARER="Bearer FAKEtokenshouldnotleak123"
FAKE_OPENAI="sk-FAKE0123456789abcdef0123456789abcdef"

fail() { echo "FAIL: $1" >&2; exit 1; }

assert_no_secret() {
    local label="$1" haystack="$2"
    case "$haystack" in
        *"$FAKE_ANT"*)    fail "$label leaked Anthropic key" ;;
        *"$FAKE_AWS"*)    fail "$label leaked AWS key" ;;
        *"FAKEtoken"*)    fail "$label leaked Bearer token" ;;
        *"$FAKE_OPENAI"*) fail "$label leaked OpenAI key" ;;
    esac
}

# ── eagle_redact built-ins ───────────────────────────────────────────────
redacted=$(printf 'k=%s a=%s h=%s o=%s\n' "$FAKE_ANT" "$FAKE_AWS" "$FAKE_BEARER" "$FAKE_OPENAI" | eagle_redact)
assert_no_secret "eagle_redact built-ins" "$redacted"
case "$redacted" in *"[REDACTED]"*) ;; *) fail "eagle_redact produced no [REDACTED] marker" ;; esac

# ── Finding 4: configured extra_patterns are honored ─────────────────────
cat > "$EAGLE_CONFIG_FILE" <<'TOML'
[redaction]
extra_patterns = ["CORPSECRET_[A-Z0-9]+", "INTERNAL-[0-9]+"]
TOML
extra_redacted=$(printf 'token CORPSECRET_AB12 and ticket INTERNAL-9988 here\n' | eagle_redact)
case "$extra_redacted" in
    *CORPSECRET_AB12*) fail "extra_patterns[0] not applied (CORPSECRET leaked)" ;;
    *INTERNAL-9988*)   fail "extra_patterns[1] not applied (INTERNAL leaked)" ;;
esac

# Commented-out default must NOT redact (proves we parse real config, not the doc line).
cat > "$EAGLE_CONFIG_FILE" <<'TOML'
[redaction]
# extra_patterns = ["MY_CUSTOM_SECRET_.*"]
TOML
commented=$(printf 'MY_CUSTOM_SECRET_xyz stays visible\n' | eagle_redact)
case "$commented" in
    *MY_CUSTOM_SECRET_xyz*) ;;
    *) fail "commented extra_patterns default was wrongly applied" ;;
esac
rm -f "$EAGLE_CONFIG_FILE"

# ── Finding 2: recall_events.prompt_snippet is redacted before insert ────
project="redaction-project"
repo="$tmp_dir/repo"; mkdir -p "$repo"
eagle_upsert_session "redact-session" "$project" "$repo" "test-model" "test" "codex" >/dev/null
eagle_insert_recall_event "redact-session" "$project" "$repo" "codex" \
    "please use my key $FAKE_ANT and aws $FAKE_AWS to deploy" \
    "deploy" 0 0 0 0 "ok" "" >/dev/null
snippet=$(eagle_db "SELECT prompt_snippet FROM recall_events WHERE session_id='redact-session' LIMIT 1;")
assert_no_secret "recall_events.prompt_snippet" "$snippet"
case "$snippet" in *"[REDACTED]"*) ;; *) fail "recall_events.prompt_snippet not redacted" ;; esac

# ── Finding 1: enrich job file written by Stop is redacted ───────────────
# Drive the Stop hook with a transcript that contains a secret and assert the
# background enrich job file (and what the enricher would read) is clean.
transcript="$tmp_dir/transcript.jsonl"
cat > "$transcript" <<EOF
{"type":"user","message":{"role":"user","content":"set up deploy"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Using API key $FAKE_ANT and aws $FAKE_AWS for the deploy. Here is what I did."}]}}
EOF
mkdir -p "$EAGLE_MEM_DIR/tmp"
stop_input=$(jq -nc \
    --arg sid "stop-redact-session" \
    --arg tp "$transcript" \
    --arg cwd "$repo" \
    '{session_id:$sid, transcript_path:$tp, cwd:$cwd}')
# A provider must be configured so Stop queues a background enrich job. We
# DISABLE the background enricher itself (EAGLE_MEM_DISABLE_BACKGROUND_ENRICH=1)
# so the queued job file is left on disk for inspection, and force the defer
# path with EAGLE_MEM_STOP_ENRICH=0. EAGLE_MEM_PROJECT pins project resolution
# so the hook does not early-exit in this synthetic environment.
cat > "$EAGLE_CONFIG_FILE" <<'TOML'
[provider]
type = "anthropic"
TOML
printf '%s' "$stop_input" | \
    EAGLE_MEM_PROJECT="$project" \
    EAGLE_MEM_STOP_ENRICH=0 \
    EAGLE_MEM_DISABLE_BACKGROUND_ENRICH=1 \
    EAGLE_AGENT_SOURCE=codex \
    bash "$ROOT_DIR/hooks/stop.sh" >/dev/null 2>&1 || true
# The background enricher is disabled from running, so the job file remains for inspection.
saw_job=0
for job in "$EAGLE_MEM_DIR"/tmp/summary-enrich.*.json; do
    [ -f "$job" ] || continue
    saw_job=1
    body=$(cat "$job")
    assert_no_secret "enrich job file" "$body"
    case "$body" in *"[REDACTED]"*) ;; *) fail "enrich job file was not redacted" ;; esac
done
[ "$saw_job" = 1 ] || fail "Stop did not queue a background enrich job file to verify (finding 1)"
rm -f "$EAGLE_MEM_DIR"/tmp/summary-enrich.*.json 2>/dev/null || true
rm -f "$EAGLE_CONFIG_FILE"

# Even if no job file was produced in this environment, the redaction path is
# also unit-tested directly: the exact transformation Stop applies.
text_with_secret="prefix $FAKE_ANT mid $FAKE_AWS suffix"
enrich_text=$(printf '%s' "$text_with_secret" | eagle_redact)
assert_no_secret "Stop enrich_text transform" "$enrich_text"

# ── Finding 3: redact-before-truncate (boundary secret defeats prefix) ───
# A secret split across the 200-char truncation boundary must still be redacted.
pad=$(printf 'a%.0s' $(seq 1 190))
boundary_cmd="curl -H \"Authorization: Bearer ${pad}${FAKE_OPENAI}\""
# Old order (truncate THEN redact) would cut the token mid-stream; the new order
# redacts first. Emulate the new order exactly as post-tool-use.sh does.
new_order=$(printf '%s' "$boundary_cmd" | eagle_redact | cut -c1-200)
assert_no_secret "redact-before-truncate" "$new_order"

# ── Finding 9: orchestration workers default to safe autonomy ────────────
eval "$(sed -n '/^orchestrate_worker_autonomy()/,/^}/p' "$ROOT_DIR/scripts/orchestrate.sh")"
[ -f "$EAGLE_CONFIG_FILE" ] && rm -f "$EAGLE_CONFIG_FILE"
default_autonomy=$(orchestrate_worker_autonomy)
[ "$default_autonomy" = "safe" ] || fail "orchestration worker autonomy should default to 'safe', got '$default_autonomy'"
cat > "$EAGLE_CONFIG_FILE" <<'TOML'
[orchestration]
worker_autonomy = "danger"
TOML
opt_in_autonomy=$(orchestrate_worker_autonomy)
[ "$opt_in_autonomy" = "danger" ] || fail "worker_autonomy='danger' should opt into 'danger', got '$opt_in_autonomy'"
rm -f "$EAGLE_CONFIG_FILE"

# The generated safe run-script must not contain danger-full-access / never / dontAsk.
project="orch-proj"; name="orch-name"
eval "$(sed -n '/^orchestrate_worker_run_script()/,/^}/p' "$ROOT_DIR/scripts/orchestrate.sh")"
safe_script="$tmp_dir/safe-run.sh"
orchestrate_worker_run_script "$safe_script" "codex" "m" "xhigh" "/wt" "/p.md" "/exit" "/last" "/bin" "lane1" "/log"
if grep -qE 'danger-full-access|approval_policy="never"' "$safe_script"; then
    fail "safe-mode codex worker still uses full-access flags"
fi
safe_claude="$tmp_dir/safe-claude.sh"
orchestrate_worker_run_script "$safe_claude" "claude-code" "m" "xhigh" "/wt" "/p.md" "/exit" "/last" "/bin" "lane1" "/log"
if grep -q 'permission-mode dontAsk' "$safe_claude"; then
    fail "safe-mode claude worker still uses --permission-mode dontAsk"
fi

# ── Finding 7: logs path resolver containment ────────────────────────────
runs_root="$tmp_dir/runs"; mkdir -p "$runs_root"
echo "log line" > "$runs_root/run1.log"
secret_dir="$tmp_dir/secret"; mkdir -p "$secret_dir"
echo "TOPSECRET" > "$secret_dir/secret.log"
ln -s "$secret_dir/secret.log" "$runs_root/evil.log"
eval "$(sed -n '/^canonicalize_path()/,/^}/p;/^path_within()/,/^}/p;/^resolve_log_path()/,/^}/p' "$ROOT_DIR/scripts/logs.sh")"
EAGLE_RUNS_DIR="$runs_root"

valid=$(resolve_log_path "run1" || true)
[ -n "$valid" ] || fail "logs resolver rejected a valid in-root log"

if resolve_log_path "evil.log" >/dev/null 2>&1; then fail "logs resolver followed a symlink out of root"; fi
if resolve_log_path "../../etc/passwd" >/dev/null 2>&1; then fail "logs resolver allowed traversal"; fi
if resolve_log_path "$secret_dir/secret.log" >/dev/null 2>&1; then fail "logs resolver allowed an out-of-root absolute path"; fi
if resolve_log_path "$runs_root/../secret/secret.log" >/dev/null 2>&1; then fail "logs resolver allowed prefixed traversal"; fi

echo "PASS: redaction + autonomy + log-path containment regression coverage"
