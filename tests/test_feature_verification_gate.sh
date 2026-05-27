#!/usr/bin/env bash
# Focused feature-verification gate regressions. Runs in an isolated HOME/EAGLE_MEM_DIR.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-feature-gate.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR"

. "$ROOT_DIR/lib/common.sh"
"$ROOT_DIR/db/migrate.sh" >/dev/null
. "$ROOT_DIR/lib/db.sh"

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

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    case "$haystack" in
        *"$needle"*)
            echo "$message" >&2
            echo "Did not expect to find: $needle" >&2
            echo "Actual: $haystack" >&2
            exit 1
            ;;
    esac
}

assert_not_denied() {
    local output="$1" message="$2"
    case "$output" in
        *'"permissionDecision":"deny"'*)
            echo "$message" >&2
            echo "Actual: $output" >&2
            exit 1
            ;;
    esac
}

feature_id_for() {
    local project="$1" name="$2"
    local id
    id=$(eagle_get_feature_id "$project" "$name")
    [ -n "$id" ] || {
        echo "Missing feature id for $project/$name" >&2
        exit 1
    }
    printf '%s\n' "$id"
}

project="monorepo-collision"
eagle_upsert_feature "$project" "ussd-farm-profile-menu" "USSD app feature"
eagle_upsert_feature "$project" "telegram-webhook-processing" "Telegram app feature"
eagle_upsert_feature "$project" "whatsapp-webhook-processing" "WhatsApp app feature"

eagle_add_feature_file "$(feature_id_for "$project" "ussd-farm-profile-menu")" "apps/ussd/src/server.js" "entrypoint"
eagle_add_feature_file "$(feature_id_for "$project" "telegram-webhook-processing")" "apps/telegram/src/server.js" "entrypoint"
eagle_add_feature_file "$(feature_id_for "$project" "whatsapp-webhook-processing")" "apps/whatsapp/src/server.js" "entrypoint"

impacts=$(eagle_find_feature_impacts_for_file "$project" "apps/ussd/src/server.js")
assert_contains "$impacts" "ussd-farm-profile-menu" "full-path feature match should find the USSD feature"
assert_not_contains "$impacts" "telegram-webhook-processing" "full-path feature match should not fall back to Telegram basename"
assert_not_contains "$impacts" "whatsapp-webhook-processing" "full-path feature match should not fall back to WhatsApp basename"

impact_count=$(printf '%s\n' "$impacts" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [ "$impact_count" != "1" ]; then
    echo "expected exactly one full-path feature impact, got $impact_count" >&2
    echo "$impacts" >&2
    exit 1
fi

eagle_record_pending_feature_verifications \
    "$project" \
    "apps/ussd/src/server.js" \
    "session-feature-gate" \
    "test" \
    "Release boundary detected for current repository diff" \
    "fingerprint-ussd" >/dev/null

pending_rows=$(eagle_db "SELECT feature_name || '|' || file_path
                         FROM pending_feature_verifications
                         WHERE project = '$project'
                           AND status = 'pending'
                         ORDER BY feature_name;")
assert_contains "$pending_rows" "ussd-farm-profile-menu|apps/ussd/src/server.js" "pending gate should create the matching USSD verification"
assert_not_contains "$pending_rows" "telegram-webhook-processing" "pending gate should not create Telegram false positives"
assert_not_contains "$pending_rows" "whatsapp-webhook-processing" "pending gate should not create WhatsApp false positives"

waived=$(eagle_resolve_pending_feature_verifications "$project" "ussd-farm-profile-menu" "waived" "current change is safe" | tail -1)
if [ "${waived:-0}" != "1" ]; then
    echo "expected one pending verification to be waived, got ${waived:-0}" >&2
    exit 1
fi
eagle_record_pending_feature_verifications \
    "$project" \
    "apps/ussd/src/server.js" \
    "session-feature-gate" \
    "test" \
    "Release boundary detected for current repository diff" \
    "fingerprint-ussd" >/dev/null
same_fingerprint_pending=$(eagle_db "SELECT COUNT(*)
                                      FROM pending_feature_verifications
                                      WHERE project = '$project'
                                        AND feature_name = 'ussd-farm-profile-menu'
                                        AND file_path = 'apps/ussd/src/server.js'
                                        AND status = 'pending';")
if [ "$same_fingerprint_pending" != "0" ]; then
    echo "same-fingerprint waiver should suppress the current pending record only" >&2
    exit 1
fi
eagle_record_pending_feature_verifications \
    "$project" \
    "apps/ussd/src/server.js" \
    "session-feature-gate" \
    "test" \
    "Release boundary detected for current repository diff" \
    "fingerprint-ussd-2" >/dev/null
new_fingerprint_pending=$(eagle_db "SELECT COUNT(*)
                                     FROM pending_feature_verifications
                                     WHERE project = '$project'
                                       AND feature_name = 'ussd-farm-profile-menu'
                                       AND file_path = 'apps/ussd/src/server.js'
                                       AND status = 'pending';")
if [ "$new_fingerprint_pending" != "1" ]; then
    echo "new fingerprint should reopen a pending verification after a waiver" >&2
    exit 1
fi

push_context=$(eagle_find_feature_for_push "$project" "apps/ussd/src/server.js")
assert_contains "$push_context" "ussd-farm-profile-menu" "push feature reminder should find the exact full-path feature"
assert_not_contains "$push_context" "telegram-webhook-processing" "push feature reminder should not use basename-only full-path matches"
assert_not_contains "$push_context" "whatsapp-webhook-processing" "push feature reminder should not use basename-only full-path matches"

read_context=$(eagle_find_features_for_file "$project" "apps/telegram/src/server.js")
assert_contains "$read_context" "telegram-webhook-processing" "read feature reminder should find the exact full-path feature"
assert_not_contains "$read_context" "ussd-farm-profile-menu" "read feature reminder should not use basename-only full-path matches"
assert_not_contains "$read_context" "whatsapp-webhook-processing" "read feature reminder should not use basename-only full-path matches"

legacy_project="bare-filename-compat"
eagle_upsert_feature "$legacy_project" "legacy-server-feature" "Legacy bare filename feature"
eagle_add_feature_file "$(feature_id_for "$legacy_project" "legacy-server-feature")" "server.js" "legacy"
legacy_impacts=$(eagle_find_feature_impacts_for_file "$legacy_project" "apps/ussd/src/server.js")
assert_contains "$legacy_impacts" "legacy-server-feature" "bare filename feature associations should still match full changed paths"

wild_project="literal-like-paths"
eagle_upsert_feature "$wild_project" "short-boundary-feature" "Boundary fixture"
eagle_upsert_feature "$wild_project" "long-boundary-feature" "Boundary fixture"
eagle_upsert_feature "$wild_project" "api-v1-underscore" "LIKE underscore fixture"
eagle_upsert_feature "$wild_project" "api-xv1" "LIKE underscore fixture"
eagle_upsert_feature "$wild_project" "api-percent-two" "LIKE percent fixture"
eagle_upsert_feature "$wild_project" "api-z-two" "LIKE percent fixture"
eagle_upsert_feature "$wild_project" "backslash-path" "LIKE backslash fixture"
eagle_add_feature_file "$(feature_id_for "$wild_project" "short-boundary-feature")" "app/server.js" "entrypoint"
eagle_add_feature_file "$(feature_id_for "$wild_project" "long-boundary-feature")" "myapp/server.js" "entrypoint"
eagle_add_feature_file "$(feature_id_for "$wild_project" "api-v1-underscore")" "root/apps/api_v1/src/server.js" "entrypoint"
eagle_add_feature_file "$(feature_id_for "$wild_project" "api-xv1")" "root/apps/apiXv1/src/server.js" "entrypoint"
eagle_add_feature_file "$(feature_id_for "$wild_project" "api-percent-two")" "root/apps/api%2/src/server.js" "entrypoint"
eagle_add_feature_file "$(feature_id_for "$wild_project" "api-z-two")" "root/apps/apiZ2/src/server.js" "entrypoint"
eagle_add_feature_file "$(feature_id_for "$wild_project" "backslash-path")" 'root/apps/api\_v1/src/server.js' "entrypoint"

boundary_hits=$(eagle_find_feature_impacts_for_file "$wild_project" "myapp/server.js")
assert_contains "$boundary_hits" "long-boundary-feature" "boundary match should find myapp/server.js"
assert_not_contains "$boundary_hits" "short-boundary-feature" "app/server.js should not match myapp/server.js"

underscore_hits=$(eagle_find_feature_impacts_for_file "$wild_project" "apps/apiXv1/src/server.js")
assert_contains "$underscore_hits" "api-xv1" "literal underscore fixture should find apiXv1"
assert_not_contains "$underscore_hits" "api-v1-underscore" "stored underscore should not act as a LIKE wildcard"

percent_hits=$(eagle_find_feature_impacts_for_file "$wild_project" "apps/apiZ2/src/server.js")
assert_contains "$percent_hits" "api-z-two" "literal percent fixture should find apiZ2"
assert_not_contains "$percent_hits" "api-percent-two" "stored percent should not act as a LIKE wildcard"

backslash_hits=$(eagle_find_feature_impacts_for_file "$wild_project" 'apps/api\_v1/src/server.js')
assert_contains "$backslash_hits" "backslash-path" "literal backslash path should match itself"
assert_not_contains "$backslash_hits" "api-v1-underscore" "literal backslash should not turn underscore into a wildcard match"

like_escaped=$(eagle_like_escape 'apps\api_v1%/server.js')
if [ "$like_escaped" != 'apps\\api\_v1\%/server.js' ]; then
    echo "LIKE escape should escape backslash, underscore, and percent" >&2
    echo "Actual: $like_escaped" >&2
    exit 1
fi

hook_project="hook-monorepo-collision"
hook_repo="$tmp_dir/hook-repo"
mkdir -p "$hook_repo/apps/ussd/src" "$hook_repo/apps/telegram/src" "$hook_repo/apps/whatsapp/src"
git -C "$hook_repo" init -q
git -C "$hook_repo" config user.email "test@example.com"
git -C "$hook_repo" config user.name "Eagle Mem Test"
printf 'console.log("ussd v1");\n' > "$hook_repo/apps/ussd/src/server.js"
printf 'console.log("telegram v1");\n' > "$hook_repo/apps/telegram/src/server.js"
printf 'console.log("whatsapp v1");\n' > "$hook_repo/apps/whatsapp/src/server.js"
git -C "$hook_repo" add .
git -C "$hook_repo" commit -q -m "initial app files"

eagle_upsert_feature "$hook_project" "hook-ussd" "USSD hook feature"
eagle_upsert_feature "$hook_project" "hook-telegram" "Telegram hook feature"
eagle_upsert_feature "$hook_project" "hook-whatsapp" "WhatsApp hook feature"
eagle_add_feature_file "$(feature_id_for "$hook_project" "hook-ussd")" "apps/ussd/src/server.js" "entrypoint"
eagle_add_feature_file "$(feature_id_for "$hook_project" "hook-telegram")" "apps/telegram/src/server.js" "entrypoint"
eagle_add_feature_file "$(feature_id_for "$hook_project" "hook-whatsapp")" "apps/whatsapp/src/server.js" "entrypoint"

printf 'console.log("ussd v2");\n' > "$hook_repo/apps/ussd/src/server.js"
hook_input=$(jq -nc --arg sid "session-hook-feature-gate" --arg cwd "$hook_repo" \
    '{tool_name:"Bash",session_id:$sid,cwd:$cwd,tool_input:{command:"git push origin main"}}')
hook_output=$(EAGLE_MEM_PROJECT="$hook_project" bash "$ROOT_DIR/hooks/pre-tool-use.sh" <<< "$hook_input")
assert_contains "$hook_output" '"permissionDecision":"deny"' "pre-tool-use should block git push with a pending matching feature"
assert_contains "$hook_output" "hook-ussd" "pre-tool-use denial should mention the matching USSD feature"
assert_not_contains "$hook_output" "hook-telegram" "pre-tool-use denial should not include Telegram false positives"
assert_not_contains "$hook_output" "hook-whatsapp" "pre-tool-use denial should not include WhatsApp false positives"

eagle_resolve_pending_feature_verifications "$hook_project" "hook-ussd" "verified" "verified by hook regression" >/dev/null
hook_after_verify=$(EAGLE_MEM_PROJECT="$hook_project" bash "$ROOT_DIR/hooks/pre-tool-use.sh" <<< "$hook_input")
assert_not_denied "$hook_after_verify" "same-fingerprint verification should release the pre-tool-use block"

echo "feature verification gate regressions passed"
