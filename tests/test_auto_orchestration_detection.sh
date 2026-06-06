#!/usr/bin/env bash
# Broad prompts should create durable orchestration state automatically. This
# proves Eagle detects the need for lanes instead of relying only on agent
# obedience to instructions.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EAGLE_BIN="$ROOT_DIR/bin/eagle-mem"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-auto-orchestration.XXXXXX")
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

project="project-auto-orchestration"
repo="$HOME/$project"
mkdir -p "$repo"

hook_input=$(jq -nc \
    --arg sid "auto-orchestration-session" \
    --arg cwd "$repo" \
    --arg prompt "Please plan and get started on a broad full codebase release. Split the work into lanes, coordinate workers, implement the fixes, and verify the ship path." \
    '{session_id:$sid, cwd:$cwd, prompt:$prompt, transcript_path:"/tmp/transcript.jsonl"}')

hook_output=$(EAGLE_MEM_PROJECT="$project" EAGLE_MEM_DIR="$EAGLE_MEM_DIR" EAGLE_AGENT_SOURCE="codex" bash "$ROOT_DIR/hooks/user-prompt-submit.sh" <<< "$hook_input")
assert_contains "$hook_output" "created durable orchestration 'auto'" "broad prompt did not report auto orchestration creation"
assert_contains "$hook_output" "Continue from the durable lanes" "hook did not tell the agent to continue from durable lanes"

orchestration_json=$(cd "$repo" && EAGLE_MEM_PROJECT="$project" EAGLE_MEM_DIR="$EAGLE_MEM_DIR" "$EAGLE_BIN" orchestrate --name auto --json)
assert_json "$orchestration_json" '
    length == 3
    and ([.[].lane_key] | sort == ["implementation","scope","verification"])
    and all(.[]; .status == "pending")
' "auto orchestration did not create the expected pending lanes"

task_json=$(cd "$repo" && EAGLE_MEM_PROJECT="$project" EAGLE_MEM_DIR="$EAGLE_MEM_DIR" "$EAGLE_BIN" tasks --json)
assert_json "$task_json" '
    length >= 3
    and ([.[] | select(.source_task_id | startswith("lane-auto-"))] | length == 3)
' "auto orchestration did not mirror lanes into durable tasks"

event_json=$(eagle_db_json "SELECT session_id, project, agent, prompt_snippet, orchestration_name, lanes, status
                            FROM orchestration_auto_events
                            WHERE project = '$project'
                            ORDER BY id DESC;")
assert_json "$event_json" '
    length == 1
    and .[0].session_id == "auto-orchestration-session"
    and .[0].orchestration_name == "auto"
    and .[0].status == "created"
    and ((.[0].lanes | fromjson) | length == 3)
' "auto orchestration event was not recorded"

hook_output_again=$(EAGLE_MEM_PROJECT="$project" EAGLE_MEM_DIR="$EAGLE_MEM_DIR" EAGLE_AGENT_SOURCE="codex" bash "$ROOT_DIR/hooks/user-prompt-submit.sh" <<< "$hook_input")
assert_contains "$hook_output_again" "created durable orchestration 'auto'" "repeated broad prompt did not reuse auto orchestration"

lane_count=$(eagle_db "SELECT COUNT(*)
                       FROM orchestration_lanes l
                       JOIN orchestrations o ON o.id = l.orchestration_id
                       WHERE o.project = '$project'
                         AND o.name = 'auto';")
task_count=$(eagle_db "SELECT COUNT(*)
                       FROM agent_tasks
                       WHERE project = '$project'
                         AND source_task_id LIKE 'lane-auto-%';")
event_count=$(eagle_db "SELECT COUNT(*) FROM orchestration_auto_events WHERE project = '$project';")

[ "$lane_count" = "3" ] || { echo "expected 3 auto lanes after repeat, got $lane_count" >&2; exit 1; }
[ "$task_count" = "3" ] || { echo "expected 3 auto tasks after repeat, got $task_count" >&2; exit 1; }
[ "$event_count" = "2" ] || { echo "expected 2 auto events after repeat, got $event_count" >&2; exit 1; }

quiet_input=$(jq -nc \
    --arg sid "quiet-session" \
    --arg cwd "$repo" \
    --arg prompt "Please inspect the config value." \
    '{session_id:$sid, cwd:$cwd, prompt:$prompt}')
EAGLE_MEM_PROJECT="$project" EAGLE_MEM_DIR="$EAGLE_MEM_DIR" EAGLE_AGENT_SOURCE="codex" bash "$ROOT_DIR/hooks/user-prompt-submit.sh" <<< "$quiet_input" >/dev/null
quiet_event_count=$(eagle_db "SELECT COUNT(*) FROM orchestration_auto_events WHERE project = '$project';")
[ "$quiet_event_count" = "2" ] || { echo "quiet prompt should not create auto orchestration event" >&2; exit 1; }

echo "auto orchestration detection regressions passed"
