#!/usr/bin/env bash
# Dashboard regression: generated HTML should expose the human product surface
# promised by Eagle Mem's memory layer.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-dashboard.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR"

. "$ROOT_DIR/lib/common.sh"
"$ROOT_DIR/db/migrate.sh" >/dev/null
. "$ROOT_DIR/lib/db.sh"

repo="$tmp_dir/repo"
mkdir -p "$repo"
project="project-dashboard"
project_sql=$(eagle_sql_escape "$project")

eagle_upsert_session "dash-session-1" "$project" "$repo" "test-model" "test" "codex" >/dev/null
eagle_insert_summary \
    "dash-session-1" \
    "$project" \
    "Review dashboard memory surface" \
    "Read docs and hooks" \
    "Dashboard should reveal recall events" \
    "Generated dashboard" \
    "" \
    "[]" \
    "[]" \
    "dashboard note" \
    "Keep HTML for humans" \
    "" \
    "scripts/dashboard.sh" \
    "codex" >/dev/null

eagle_upsert_overview "$project" "Dashboard project overview with current architecture and risks." "test" >/dev/null
eagle_insert_observation "dash-session-1" "$project" "Edit" "edited dashboard" "[]" "[\"scripts/dashboard.sh\"]" "" "" "" "codex" >/dev/null
eagle_insert_recall_event \
    "dash-session-1" "$project" "$repo" "codex" \
    "Show me what Eagle recalled for dashboard work" \
    "eagle OR dashboard OR recall" \
    2 1 3 960 "ok" "" >/dev/null

eagle_db "INSERT INTO agent_tasks (project, source_session_id, source_task_id, subject, description, active_form, status, content_hash, origin_agent)
          VALUES ('$project_sql', 'dash-session-1', 'task-dashboard', 'Build dashboard surface',
                  'Expose memory inspection in HTML', 'Build dashboard surface', 'in_progress',
                  'dashboard-task-hash', 'codex');" >/dev/null

eagle_graph_add_node "$project" "project" "$project" "Dashboard graph project" "" >/dev/null
eagle_graph_add_node "$project" "file" "scripts/dashboard.sh" "" "$repo/scripts/dashboard.sh" >/dev/null

dashboard_file="$tmp_dir/dashboard/index.html"
dashboard_json=$(cd "$repo" && EAGLE_MEM_DIR="$EAGLE_MEM_DIR" "$ROOT_DIR/bin/eagle-mem" dashboard --project "$project" --output "$dashboard_file" --json)

printf '%s' "$dashboard_json" | jq -e '
    .status == "ok"
    and .output != ""
    and .counts.summaries >= 1
    and .counts.recall_events >= 1
    and .counts.files >= 1
    and .counts.active_tasks >= 1
    and .counts.graph_node_types >= 1
' >/dev/null || {
    echo "dashboard --json did not report expected counts" >&2
    echo "$dashboard_json" >&2
    exit 1
}

[ -f "$dashboard_file" ] || {
    echo "dashboard output file was not created" >&2
    exit 1
}

for needle in \
    "Eagle Mem Dashboard" \
    "Project Brain" \
    "Recall Inspector" \
    "Timeline" \
    "File Intelligence" \
    "Agent Comparison" \
    "Active Tasks" \
    "Graph Readiness" \
    "Show me what Eagle recalled" \
    "scripts/dashboard.sh"; do
    if ! grep -q "$needle" "$dashboard_file"; then
        echo "dashboard missing expected content: $needle" >&2
        exit 1
    fi
done

echo "dashboard regressions passed"
