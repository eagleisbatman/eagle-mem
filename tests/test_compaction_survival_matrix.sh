#!/usr/bin/env bash
# End-to-end compaction survival matrix. A pre-compact session creates every
# durable entity Eagle Mem promises to preserve, then a post-compact prompt must
# recover it through search, recall, replay, status, and the project graph.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EAGLE_BIN="$ROOT_DIR/bin/eagle-mem"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-compaction-survival.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR"

. "$ROOT_DIR/lib/common.sh"
"$ROOT_DIR/db/migrate.sh" >/dev/null
. "$ROOT_DIR/lib/db.sh"

assert_json() {
    local json="$1" filter="$2" message="$3"
    if ! printf '%s' "$json" | jq -e "$filter" >/dev/null; then
        echo "$message" >&2
        echo "$json" >&2
        exit 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    case "$haystack" in
        *"$needle"*) ;;
        *)
            echo "$message" >&2
            echo "Expected to find: $needle" >&2
            echo "$haystack" >&2
            exit 1
            ;;
    esac
}

strip_ansi() {
    sed -E $'s/\x1b\\[[0-9;]*m//g'
}

project="project-compaction-matrix"
export EAGLE_MEM_PROJECT="$project"
repo="$HOME/$project"
mkdir -p "$repo/src"

cat > "$repo/src/auth-client.ts" <<'EOF'
export function refreshOauthToken() {
  return "oauth-token-refresh compaction survival rotates credentials safely";
}
EOF

pre_session="compact-pre-session"
post_session="compact-post-session"
files_json='["src/auth-client.ts"]'

seed_summary() {
    local session_id="$1" request="$2" learned="$3" completed="$4" decisions="$5"
    eagle_upsert_session "$session_id" "$project" "$repo" "test-model" "test" "codex" >/dev/null
    eagle_insert_summary \
        "$session_id" \
        "$project" \
        "$request" \
        "Read src/auth-client.ts and the oauth-token-refresh path" \
        "$learned" \
        "$completed" \
        "Verify oauth-token-refresh after compact in a new session" \
        "$files_json" \
        "$files_json" \
        "compaction survival matrix seed" \
        "$decisions" \
        "Do not regress oauth-token-refresh token rotation after compaction" \
        "src/auth-client.ts" \
        "codex" >/dev/null
}

seed_summary \
    "$pre_session" \
    "Create oauth-token-refresh compaction survival context" \
    "oauth-token-refresh must survive compaction through summaries, memories, tasks, features, recall, and graph edges" \
    "Stored durable oauth-token-refresh compaction survival context" \
    "Decision: oauth-token-refresh is the durable compaction survival feature for auth replay"
seed_summary \
    "compact-pre-session-2" \
    "Record oauth-token-refresh retry decision" \
    "Retry safety depends on rotated credentials" \
    "Stored second enriched oauth-token-refresh summary" \
    "Decision: oauth-token-refresh keeps retry safety explicit"
seed_summary \
    "compact-pre-session-3" \
    "Record oauth-token-refresh stale-token gotcha" \
    "Stale refresh tokens fail silently without durable recall" \
    "Stored third enriched oauth-token-refresh summary" \
    "Decision: oauth-token-refresh stale-token gotcha must remain searchable"

eagle_insert_observation \
    "$pre_session" \
    "$project" \
    "Edit" \
    "Updated oauth-token-refresh compaction fixture" \
    "$files_json" \
    "$files_json" \
    "" "" "" "codex" >/dev/null

memory_file="$tmp_dir/oauth-token-refresh-memory.md"
cat > "$memory_file" <<'EOF'
---
name: oauth-token-refresh memory
description: oauth-token-refresh compaction survival decision
type: decision
originSessionId: compact-pre-session
---
oauth-token-refresh must survive compaction and recall the auth client before edits.
EOF
eagle_capture_agent_memory "$memory_file" "$pre_session" "$project" "codex" >/dev/null

task_file="$tmp_dir/oauth-token-refresh-task.json"
cat > "$task_file" <<'EOF'
{
  "id": "compact-task-oauth",
  "subject": "Verify oauth-token-refresh compaction survival",
  "description": "Ensure oauth-token-refresh survives compact through summary, memory, feature, recall, replay, and graph lookup.",
  "activeForm": "Verifying oauth-token-refresh survival",
  "status": "in_progress",
  "blocks": [],
  "blockedBy": []
}
EOF
eagle_capture_agent_task "$task_file" "$pre_session" "$project" "codex" >/dev/null

eagle_upsert_feature "$project" "oauth-token-refresh" "OAuth token refresh compaction survival feature" >/dev/null
feature_id=$(eagle_get_feature_id "$project" "oauth-token-refresh")
[ -n "$feature_id" ] || { echo "feature id missing" >&2; exit 1; }
eagle_add_feature_file "$feature_id" "src/auth-client.ts" "auth client" >/dev/null
eagle_add_feature_smoke_test "$feature_id" "bash tests/test_compaction_survival_matrix.sh" "compaction survival matrix" >/dev/null

(cd "$repo" && "$EAGLE_BIN" graph rebuild >/dev/null)
eagle_graph_wire_recent_session_edges "$project" 10 >/dev/null

for node_type in feature memory task session decision file; do
    count=$(eagle_db "SELECT COUNT(*) FROM graph_nodes WHERE project = '$project' AND node_type = '$node_type';")
    [ "${count:-0}" -gt 0 ] || {
        echo "expected graph node type $node_type to survive, got $count" >&2
        exit 1
    }
done

semantic_edges=$(eagle_db "SELECT COUNT(*)
                           FROM graph_edges e
                           JOIN graph_nodes s ON s.id = e.source_node_id
                           JOIN graph_nodes t ON t.id = e.target_node_id
                           WHERE e.project = '$project'
                             AND (
                               (s.node_type = 'feature' AND t.node_type = 'file' AND e.edge_type = 'covers')
                               OR (s.node_type = 'memory' AND t.node_type = 'feature' AND e.edge_type = 'mentions')
                               OR (s.node_type = 'task' AND t.node_type = 'feature' AND e.edge_type = 'mentions')
                               OR (s.node_type = 'decision' AND t.node_type = 'feature' AND e.edge_type = 'mentions')
                               OR (s.node_type = 'decision' AND t.node_type = 'file' AND e.edge_type = 'touches')
                             );")
[ "${semantic_edges:-0}" -ge 5 ] || {
    echo "expected semantic graph edges for durable context, got $semantic_edges" >&2
    exit 1
}

summary_search=$(cd "$repo" && "$EAGLE_BIN" search "oauth token refresh compaction" --json)
assert_json "$summary_search" 'length >= 1 and (.[0].completed | contains("oauth-token-refresh"))' "summary search did not recover pre-compact decision"

memory_search=$(cd "$repo" && "$EAGLE_BIN" search --memories "oauth token refresh compaction" --json)
assert_json "$memory_search" 'length >= 1 and (.[0].memory_name | contains("oauth-token-refresh"))' "memory search did not recover mirrored memory"

task_search=$(cd "$repo" && "$EAGLE_BIN" search --tasks "oauth token refresh compaction" --json)
assert_json "$task_search" 'length >= 1 and (.[0].subject | contains("oauth-token-refresh"))' "task search did not recover active task"

feature_show=$(cd "$repo" && "$EAGLE_BIN" feature show "oauth-token-refresh")
assert_contains "$feature_show" "src/auth-client.ts" "feature show did not recover feature file binding"

compaction_json=$(cd "$repo" && "$EAGLE_BIN" compaction --json)
assert_json "$compaction_json" '
    .status == "ok"
    and .readiness == "strong"
    and .metrics.enriched_summaries >= 3
    and .metrics.active_tasks >= 1
    and .metrics.durable_memories >= 1
    and .metrics.active_features >= 1
    and .metrics.semantic_graph_nodes >= 5
' "compaction --json did not report durable survival metrics"

eagle_upsert_session "$post_session" "$project" "$repo" "test-model" "test" "codex" >/dev/null
hook_input=$(jq -nc \
    --arg sid "$post_session" \
    --arg cwd "$repo" \
    --arg prompt "Before editing auth client restore oauth-token-refresh compaction survival context" \
    '{session_id:$sid, cwd:$cwd, prompt:$prompt}')

hook_output=$(EAGLE_MEM_PROJECT="$project" EAGLE_MEM_DIR="$EAGLE_MEM_DIR" bash "$ROOT_DIR/hooks/user-prompt-submit.sh" <<< "$hook_input")
assert_contains "$hook_output" "Eagle Mem recalls" "post-compact prompt did not receive recalled memory context"
assert_contains "$hook_output" "Relevant Code" "post-compact prompt did not receive indexed code context"

event_json=$(eagle_db_json "SELECT summary_matches, memory_matches, code_matches, summary_refs, memory_refs, code_refs, status
                            FROM recall_events
                            WHERE session_id = '$post_session'
                            ORDER BY id DESC
                            LIMIT 1;")
assert_json "$event_json" '
    length == 1
    and .[0].status == "ok"
    and .[0].summary_matches >= 1
    and .[0].memory_matches >= 1
    and .[0].code_matches >= 1
    and ((.[0].summary_refs | fromjson) | length >= 1)
    and ((.[0].memory_refs | fromjson) | length >= 1)
    and ((.[0].code_refs | fromjson) | length >= 1)
' "post-compact recall event did not capture expected refs"

replay_json=$(cd "$repo" && "$EAGLE_BIN" replay "$post_session" --json)
assert_json "$replay_json" '
    .status == "ok"
    and .session_id == "compact-post-session"
    and (.recall_events | length >= 1)
    and (.recall_events[0].summary_refs | length >= 1)
    and (.recall_events[0].memory_refs | length >= 1)
    and (.recall_events[0].code_refs | length >= 1)
' "replay did not preserve post-compact recall evidence"

neighbors_output=$(cd "$repo" && "$EAGLE_BIN" graph neighbors "oauth-token-refresh" | strip_ansi)
assert_contains "$neighbors_output" "src/auth-client.ts" "graph neighbors did not expose feature-file survival edge"
assert_contains "$neighbors_output" "compact-task-oauth" "graph neighbors did not expose task-feature survival edge"

compaction_after_recall=$(cd "$repo" && "$EAGLE_BIN" compaction --json)
assert_json "$compaction_after_recall" '.metrics.recall_events >= 1' "compaction metrics did not count post-compact recall event"

echo "compaction survival matrix regressions passed"
