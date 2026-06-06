#!/usr/bin/env bash
# Hooks should emit a general Eagle event log so users can inspect what Eagle
# did, not only the final memory rows.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-eagle-events.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR"

. "$ROOT_DIR/lib/common.sh"
"$ROOT_DIR/db/migrate.sh" >/dev/null
. "$ROOT_DIR/lib/db.sh"

repo="$tmp_dir/repo"
mkdir -p "$repo"
project="project-events"

eagle_upsert_session "seed-events-session" "$project" "$repo" "test-model" "test" "codex" >/dev/null
eagle_insert_summary \
    "seed-events-session" \
    "$project" \
    "Implement hook event logging" \
    "Read hook observability code" \
    "Hooks need visible events" \
    "Added event logging" \
    "" \
    "[]" \
    "[]" \
    "event note" \
    "Record hook_started and hook_completed" \
    "" \
    "hooks/user-prompt-submit.sh" \
    "codex" >/dev/null

hook_input=$(jq -nc \
    --arg sid "event-hook-session" \
    --arg cwd "$repo" \
    --arg prompt "Please review hook event logging before editing observability" \
    '{session_id:$sid, cwd:$cwd, prompt:$prompt, hook_event_name:"UserPromptSubmit"}')

hook_output=$(EAGLE_MEM_PROJECT="$project" EAGLE_MEM_DIR="$EAGLE_MEM_DIR" EAGLE_AGENT_SOURCE="codex" bash "$ROOT_DIR/hooks/user-prompt-submit.sh" <<< "$hook_input")
case "$hook_output" in
    *"Eagle Mem recalls"*|*"Relevant"*) ;;
    *)
        echo "UserPromptSubmit did not inject event-test context" >&2
        echo "$hook_output" >&2
        exit 1
        ;;
esac

events_json=$(eagle_db_json "SELECT event_type, hook_event_name, status, detail_json
                             FROM eagle_events
                             WHERE session_id = 'event-hook-session'
                             ORDER BY id ASC;")

printf '%s' "$events_json" | jq -e '
    length >= 3
    and any(.[]; .event_type == "hook_started" and .hook_event_name == "UserPromptSubmit")
    and any(.[]; .event_type == "context_injected" and .hook_event_name == "UserPromptSubmit")
    and any(.[]; .event_type == "hook_completed" and .hook_event_name == "UserPromptSubmit" and .status == "ok")
    and any(.[]; .event_type == "hook_completed" and ((.detail_json | fromjson).injected_chars > 0))
' >/dev/null || {
    echo "eagle_events did not capture expected UserPromptSubmit lifecycle" >&2
    echo "$events_json" >&2
    exit 1
}

inspect_json=$(cd "$repo" && EAGLE_MEM_DIR="$EAGLE_MEM_DIR" "$ROOT_DIR/bin/eagle-mem" inspect events --project "$project" --session event-hook-session --json)
printf '%s' "$inspect_json" | jq -e '
    .status == "ok"
    and .action == "events"
    and (.events | length >= 3)
    and any(.events[]; .event_type == "context_injected" and .detail.injected_chars > 0)
' >/dev/null || {
    echo "inspect events --json did not return event details" >&2
    echo "$inspect_json" >&2
    exit 1
}

inspect_text=$(cd "$repo" && EAGLE_MEM_DIR="$EAGLE_MEM_DIR" "$ROOT_DIR/bin/eagle-mem" inspect events --project "$project" --session event-hook-session --last)
case "$inspect_text" in
    *"Event Inspector"*hook_completed*UserPromptSubmit*) ;;
    *)
        echo "inspect events --last did not render hook event" >&2
        echo "$inspect_text" >&2
        exit 1
        ;;
esac

echo "eagle event regressions passed"

