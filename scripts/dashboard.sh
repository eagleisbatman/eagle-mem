#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Local Dashboard
# Generates a static HTML inspection surface from ~/.eagle-mem/memory.db.
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

project=""
project_was_explicit=false
cross_project=false
output_path=""
json_output=false
open_after=false

show_help() {
    echo -e "  ${BOLD}eagle-mem dashboard${RESET} — Generate a local HTML memory dashboard"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem dashboard"
    echo -e "    eagle-mem dashboard ${CYAN}--project <name>${RESET}"
    echo -e "    eagle-mem dashboard ${CYAN}--output <path>${RESET}"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    ${CYAN}-p, --project${RESET} <name>  Project name (default: current dir scope)"
    echo -e "    ${CYAN}--all${RESET}                 Include all projects"
    echo -e "    ${CYAN}-o, --output${RESET} <path>   Output file (default: ~/.eagle-mem/dashboard/index.html)"
    echo -e "    ${CYAN}--open${RESET}                Open the generated dashboard"
    echo -e "    ${CYAN}-j, --json${RESET}            Output structured JSON"
    echo ""
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project|-p) project="$2"; project_was_explicit=true; shift 2 ;;
        --all|-a) cross_project=true; shift ;;
        --output|-o) output_path="$2"; shift 2 ;;
        --open) open_after=true; shift ;;
        --json|-j) json_output=true; shift ;;
        --help|-h) show_help ;;
        *)
            eagle_err "Unknown option: $1"
            exit 1
            ;;
    esac
done

dashboard_fail() {
    local error_code="$1"
    local message="$2"
    local db_status="${3:-unknown}"
    local db_detail="${4:-}"

    if [ "$json_output" = true ]; then
        jq -nc \
            --arg status "error" \
            --arg command "dashboard" \
            --arg error "$error_code" \
            --arg message "$message" \
            --arg project "${project:-}" \
            --arg output "${output_path:-}" \
            --arg db_status "$db_status" \
            --arg db_detail "$db_detail" \
            '{status:$status, command:$command, error:$error, message:$message,
              project:$project, output:$output,
              database:{integrity:{status:$db_status, detail:$db_detail}}}'
    else
        eagle_err "$message"
        [ -n "$db_detail" ] && eagle_dim "  $db_detail"
    fi
    exit 1
}

html_escape() {
    jq -Rn --arg v "${1:-}" '$v | @html'
}

json_len() {
    printf '%s' "${1:-[]}" | jq 'length' 2>/dev/null || printf '0\n'
}

if ! eagle_ensure_db; then
    dashboard_fail "database_unavailable" "Database is unavailable; SQLite/FTS5 setup failed." "unavailable" "eagle_ensure_db failed"
fi

db_integrity_check=$(eagle_db_integrity_status "$EAGLE_MEM_DB" 2>/dev/null || true)
db_integrity_status="${db_integrity_check%%|*}"
db_integrity_detail="${db_integrity_check#*|}"
[ -n "$db_integrity_status" ] || db_integrity_status="unknown"
[ -n "$db_integrity_detail" ] || db_integrity_detail="not checked"
if [ "$db_integrity_status" != "ok" ]; then
    dashboard_fail "database_integrity" "Database integrity check failed; dashboard is unavailable." "$db_integrity_status" "$db_integrity_detail"
fi

if [ -z "$project" ] && [ "$cross_project" = false ]; then
    project=$(eagle_project_from_cwd "$(pwd)")
fi
if [ "$cross_project" = false ] && [ "$project_was_explicit" = false ]; then
    project=$(eagle_recall_project_scope_from_cwd "$(pwd)" "$project")
fi

project_label="$project"
if [ "$cross_project" = true ]; then
    project_label="All projects"
else
    project_label=$(eagle_project_scope_label "$project")
fi

[ -n "$output_path" ] || output_path="$EAGLE_MEM_DIR/dashboard/index.html"
mkdir -p "$(dirname "$output_path")"

where_project="1 = 1"
if [ "$cross_project" = false ]; then
    where_project=$(eagle_sql_project_scope_condition "project" "$project")
fi

where_summary="1 = 1"
where_observation="1 = 1"
where_task="1 = 1"
where_graph="1 = 1"
if [ "$cross_project" = false ]; then
    where_summary=$(eagle_sql_project_scope_condition "project" "$project")
    where_observation=$(eagle_sql_project_scope_condition "project" "$project")
    where_task=$(eagle_sql_project_scope_condition "project" "$project")
    where_graph=$(eagle_sql_project_scope_condition "project" "$project")
fi

overview_json="[]"
if [ "$cross_project" = false ]; then
    overview_json=$(eagle_db_json "SELECT content, source, updated_at
                                   FROM overviews
                                   WHERE $where_project
                                   ORDER BY updated_at DESC
                                   LIMIT 1;" 2>/dev/null || printf '[]')
fi
summary_json=$(eagle_db_json "SELECT request, completed, learned, decisions, gotchas, key_files, agent, created_at
                              FROM summaries
                              WHERE $where_summary
                              ORDER BY created_at DESC
                              LIMIT 10;" 2>/dev/null || printf '[]')
recall_json="[]"
if [ -n "$(eagle_db "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'recall_events' LIMIT 1;" 2>/dev/null || true)" ]; then
    recall_json=$(eagle_db_json "SELECT prompt_snippet, fts_query, summary_matches, memory_matches, code_matches,
                                        injected_token_estimate, status, agent, created_at
                                 FROM recall_events
                                 WHERE $where_project
                                 ORDER BY created_at DESC, id DESC
                                 LIMIT 10;" 2>/dev/null || printf '[]')
fi
files_json=$(eagle_db_json "SELECT json_each.value AS file, COUNT(*) AS touches
                            FROM observations, json_each(observations.files_modified)
                            WHERE $where_observation
                            GROUP BY json_each.value
                            ORDER BY touches DESC
                            LIMIT 12;" 2>/dev/null || printf '[]')
agents_json=$(eagle_db_json "SELECT agent, COUNT(*) AS sessions
                             FROM sessions
                             WHERE $where_project
                             GROUP BY agent
                             ORDER BY sessions DESC;" 2>/dev/null || printf '[]')
tasks_json=$(eagle_db_json "SELECT source_task_id, subject, status, updated_at
                            FROM agent_tasks
                            WHERE $where_task AND status IN ('pending', 'in_progress', 'blocked')
                            ORDER BY updated_at DESC
                            LIMIT 10;" 2>/dev/null || printf '[]')
graph_json=$(eagle_db_json "SELECT node_type, COUNT(*) AS nodes
                            FROM graph_nodes
                            WHERE $where_graph
                            GROUP BY node_type
                            ORDER BY nodes DESC;" 2>/dev/null || printf '[]')

overview_count=$(json_len "$overview_json")
summary_count=$(json_len "$summary_json")
recall_count=$(json_len "$recall_json")
file_count=$(json_len "$files_json")
agent_count=$(json_len "$agents_json")
task_count=$(json_len "$tasks_json")
graph_type_count=$(json_len "$graph_json")
edge_count=$(eagle_db "SELECT COUNT(*) FROM graph_edges WHERE $where_graph;" 2>/dev/null || printf '0')

render_summary_rows() {
    printf '%s' "$summary_json" | jq -c '.[]' | while IFS= read -r row; do
        local created request completed learned agent
        created=$(printf '%s' "$row" | jq -r '.created_at // ""')
        request=$(printf '%s' "$row" | jq -r '.request // "Session summary"')
        completed=$(printf '%s' "$row" | jq -r '.completed // ""')
        learned=$(printf '%s' "$row" | jq -r '.learned // ""')
        agent=$(printf '%s' "$row" | jq -r '.agent // ""')
        printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$(html_escape "$created")" "$(html_escape "$(eagle_agent_label "$agent")")" \
            "$(html_escape "$request")" "$(html_escape "$completed")" "$(html_escape "$learned")"
    done
}

render_recall_rows() {
    printf '%s' "$recall_json" | jq -c '.[]' | while IFS= read -r row; do
        local created prompt query summaries memories code tokens status agent
        created=$(printf '%s' "$row" | jq -r '.created_at // ""')
        prompt=$(printf '%s' "$row" | jq -r '.prompt_snippet // ""')
        query=$(printf '%s' "$row" | jq -r '.fts_query // ""')
        summaries=$(printf '%s' "$row" | jq -r '.summary_matches // 0')
        memories=$(printf '%s' "$row" | jq -r '.memory_matches // 0')
        code=$(printf '%s' "$row" | jq -r '.code_matches // 0')
        tokens=$(printf '%s' "$row" | jq -r '.injected_token_estimate // 0')
        status=$(printf '%s' "$row" | jq -r '.status // ""')
        agent=$(printf '%s' "$row" | jq -r '.agent // ""')
        printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s/%s/%s</td><td>%s</td></tr>\n' \
            "$(html_escape "$created")" "$(html_escape "$(eagle_agent_label "$agent")")" \
            "$(html_escape "$status")" "$(html_escape "$prompt")" "$(html_escape "$query")" \
            "$(html_escape "$summaries")" "$(html_escape "$memories")" "$(html_escape "$code")" \
            "$(html_escape "$tokens")"
    done
}

render_simple_rows() {
    local json="$1" first="$2" second="$3"
    printf '%s' "$json" | jq -c '.[]' | while IFS= read -r row; do
        local a b
        a=$(printf '%s' "$row" | jq -r --arg first "$first" '.[$first] // ""')
        b=$(printf '%s' "$row" | jq -r --arg second "$second" '.[$second] // ""')
        printf '<tr><td>%s</td><td>%s</td></tr>\n' "$(html_escape "$a")" "$(html_escape "$b")"
    done
}

overview_content="No project overview recorded yet."
if [ "$overview_count" -gt 0 ]; then
    overview_content=$(printf '%s' "$overview_json" | jq -r '.[0].content // "No project overview recorded yet."')
fi

cat > "$output_path" <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Eagle Mem Dashboard - $(html_escape "$project_label")</title>
  <style>
    :root { color-scheme: light; --ink:#111; --muted:#626262; --line:#d8d8d8; --soft:#f6f6f3; --accent:#096b72; --warn:#8a3f00; }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: Helvetica, Arial, sans-serif; color: var(--ink); background: #fff; line-height: 1.45; }
    header { padding: 28px 36px 20px; border-bottom: 2px solid var(--ink); background: var(--soft); }
    main { padding: 24px 36px 44px; display: grid; gap: 24px; }
    h1 { margin: 0; font-size: 30px; letter-spacing: 0; }
    h2 { margin: 0 0 12px; font-size: 18px; letter-spacing: 0; }
    .meta { margin-top: 8px; color: var(--muted); font-size: 14px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
    .metric { border: 1px solid var(--line); padding: 14px; background: #fff; }
    .metric strong { display:block; font-size: 24px; }
    section { border-top: 1px solid var(--line); padding-top: 18px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { padding: 9px 8px; border-bottom: 1px solid var(--line); vertical-align: top; text-align: left; }
    th { color: var(--muted); font-weight: 700; background: #fafafa; }
    p { max-width: 900px; margin: 0; }
    code { font-family: "Courier New", monospace; font-size: 12px; }
    .empty { color: var(--muted); padding: 12px 0; }
  </style>
</head>
<body>
  <header>
    <h1>Eagle Mem Dashboard</h1>
    <div class="meta">Project: $(html_escape "$project_label") | Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) | DB integrity: $(html_escape "$db_integrity_status")</div>
  </header>
  <main>
    <section>
      <h2>Project Brain</h2>
      <p>$(html_escape "$overview_content")</p>
    </section>
    <section>
      <h2>Signals</h2>
      <div class="grid">
        <div class="metric"><strong>$summary_count</strong> recent summaries</div>
        <div class="metric"><strong>$recall_count</strong> recall events</div>
        <div class="metric"><strong>$file_count</strong> touched files</div>
        <div class="metric"><strong>$task_count</strong> active tasks</div>
        <div class="metric"><strong>$graph_type_count</strong> graph node types</div>
        <div class="metric"><strong>$edge_count</strong> graph edges</div>
      </div>
    </section>
    <section>
      <h2>Recall Inspector</h2>
      <table>
        <thead><tr><th>Time</th><th>Agent</th><th>Status</th><th>Prompt</th><th>Query</th><th>Summary/Memory/Code</th><th>Token estimate</th></tr></thead>
        <tbody>
          $(render_recall_rows)
        </tbody>
      </table>
    </section>
    <section>
      <h2>Timeline</h2>
      <table>
        <thead><tr><th>Time</th><th>Agent</th><th>Request</th><th>Completed</th><th>Learned</th></tr></thead>
        <tbody>
          $(render_summary_rows)
        </tbody>
      </table>
    </section>
    <section>
      <h2>File Intelligence</h2>
      <table>
        <thead><tr><th>File</th><th>Touches</th></tr></thead>
        <tbody>
          $(render_simple_rows "$files_json" "file" "touches")
        </tbody>
      </table>
    </section>
    <section>
      <h2>Agent Comparison</h2>
      <table>
        <thead><tr><th>Agent</th><th>Sessions</th></tr></thead>
        <tbody>
          $(render_simple_rows "$agents_json" "agent" "sessions")
        </tbody>
      </table>
    </section>
    <section>
      <h2>Active Tasks</h2>
      <table>
        <thead><tr><th>Task</th><th>Status</th></tr></thead>
        <tbody>
          $(render_simple_rows "$tasks_json" "subject" "status")
        </tbody>
      </table>
    </section>
    <section>
      <h2>Graph Readiness</h2>
      <table>
        <thead><tr><th>Node type</th><th>Count</th></tr></thead>
        <tbody>
          $(render_simple_rows "$graph_json" "node_type" "nodes")
        </tbody>
      </table>
    </section>
  </main>
</body>
</html>
HTML

if [ "$json_output" = true ]; then
    jq -nc \
        --arg status "ok" \
        --arg command "dashboard" \
        --arg project "$project_label" \
        --arg output "$output_path" \
        --argjson summaries "$summary_count" \
        --argjson recall_events "$recall_count" \
        --argjson files "$file_count" \
        --argjson active_tasks "$task_count" \
        --argjson graph_node_types "$graph_type_count" \
        --argjson graph_edges "${edge_count:-0}" \
        '{status:$status, command:$command, project:$project, output:$output,
          counts:{summaries:$summaries, recall_events:$recall_events, files:$files,
                  active_tasks:$active_tasks, graph_node_types:$graph_node_types,
                  graph_edges:$graph_edges}}'
else
    eagle_ok "Dashboard generated"
    eagle_kv "Output:" "$output_path"
fi

if [ "$open_after" = true ]; then
    if command -v open >/dev/null 2>&1; then
        open "$output_path" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$output_path" >/dev/null 2>&1 || true
    fi
fi
