#!/usr/bin/env bash
# UserPromptSubmit should persist recall observability facts: what matched and
# how much context was injected.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-recall-observability.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR"

. "$ROOT_DIR/lib/common.sh"
"$ROOT_DIR/db/migrate.sh" >/dev/null
. "$ROOT_DIR/lib/db.sh"

repo="$tmp_dir/repo"
mkdir -p "$repo"
project="project-recall"

eagle_upsert_session "seed-summary-session" "$project" "$repo" "test-model" "test" "codex" >/dev/null
eagle_insert_summary \
    "seed-summary-session" \
    "$project" \
    "Implement oauth token refresh" \
    "Read auth client" \
    "OAuth refresh needs rotating tokens" \
    "Added oauth refresh guard" \
    "" \
    "[]" \
    "[]" \
    "oauth recall note" \
    "Do not regress token refresh" \
    "" \
    "auth/client.ts" \
    "codex" >/dev/null

memory_file="$tmp_dir/oauth-memory.md"
cat > "$memory_file" <<'EOF'
---
name: OAuth Memory
description: OAuth token refresh decision
type: decision
originSessionId: seed-summary-session
---
OAuth token refresh must rotate credentials and preserve retry safety.
EOF
eagle_capture_agent_memory "$memory_file" "seed-summary-session" "$project" "codex" >/dev/null

eagle_db "INSERT INTO code_chunks (project, file_path, language, start_line, end_line, content, mtime)
          VALUES ('$project', 'auth/client.ts', 'typescript', 1, 20,
                  'export function refreshOauthToken() { /* oauth token refresh */ return rotateCredentials(); }',
                  123);" >/dev/null

hook_input=$(jq -nc \
    --arg sid "recall-hook-session" \
    --arg cwd "$repo" \
    --arg prompt "Please review oauth token refresh before editing auth client" \
    '{session_id:$sid, cwd:$cwd, prompt:$prompt}')

hook_output=$(EAGLE_MEM_PROJECT="$project" EAGLE_MEM_DIR="$EAGLE_MEM_DIR" bash "$ROOT_DIR/hooks/user-prompt-submit.sh" <<< "$hook_input")
case "$hook_output" in
    *"Eagle Mem recalls"*|*"Relevant code"*) ;;
    *)
        echo "UserPromptSubmit did not inject recall context" >&2
        echo "$hook_output" >&2
        exit 1
        ;;
esac

event_json=$(eagle_db_json "SELECT session_id, project, agent, fts_query, summary_matches, memory_matches,
                                   code_matches, summary_refs, memory_refs, code_refs,
                                   injected_chars, injected_token_estimate, status
                            FROM recall_events
                            WHERE session_id = 'recall-hook-session'
                            ORDER BY id DESC
                            LIMIT 1;")

printf '%s' "$event_json" | jq -e '
    length == 1
    and .[0].project == "project-recall"
    and .[0].status == "ok"
    and .[0].summary_matches >= 1
    and .[0].memory_matches >= 1
    and .[0].code_matches >= 1
    and ((.[0].summary_refs | fromjson) | length >= 1)
    and ((.[0].memory_refs | fromjson) | length >= 1)
    and ((.[0].code_refs | fromjson) | length >= 1)
    and .[0].injected_chars > 0
    and .[0].injected_token_estimate > 0
' >/dev/null || {
    echo "recall event did not capture expected match counts" >&2
    echo "$event_json" >&2
    exit 1
}

inspect_json=$(cd "$repo" && EAGLE_MEM_DIR="$EAGLE_MEM_DIR" "$ROOT_DIR/bin/eagle-mem" inspect recall --project "$project" --json)
printf '%s' "$inspect_json" | jq -e '
    .status == "ok"
    and .action == "recall"
    and (.events | length >= 1)
' >/dev/null || {
    echo "inspect recall --json did not return recall events" >&2
    echo "$inspect_json" >&2
    exit 1
}

inspect_last=$(cd "$repo" && EAGLE_MEM_DIR="$EAGLE_MEM_DIR" "$ROOT_DIR/bin/eagle-mem" inspect recall --project "$project" --last)
case "$inspect_last" in
    *"Recall Inspector"*summaries=1*memories=1*code=1*) ;;
    *)
        echo "inspect recall --last did not render recall counts" >&2
        echo "$inspect_last" >&2
        exit 1
        ;;
esac

replay_json=$(cd "$repo" && EAGLE_MEM_DIR="$EAGLE_MEM_DIR" "$ROOT_DIR/bin/eagle-mem" replay recall-hook-session --json)
printf '%s' "$replay_json" | jq -e '
    .status == "ok"
    and .session_id == "recall-hook-session"
    and (.recall_events | length == 1)
    and (.recall_events[0].summary_refs | length >= 1)
    and (.recall_events[0].memory_refs | length >= 1)
    and (.recall_events[0].code_refs | length >= 1)
' >/dev/null || {
    echo "replay --json did not return recall refs" >&2
    echo "$replay_json" >&2
    exit 1
}

replay_last=$(cd "$repo" && EAGLE_MEM_DIR="$EAGLE_MEM_DIR" "$ROOT_DIR/bin/eagle-mem" replay --project "$project" --last)
case "$replay_last" in
    *"Replay"*recall-hook-session*"Retrieved refs"*auth/client.ts*) ;;
    *)
        echo "replay --last did not render retrieved refs" >&2
        echo "$replay_last" >&2
        exit 1
        ;;
esac

echo "recall observability regressions passed"
