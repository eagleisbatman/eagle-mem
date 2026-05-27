#!/usr/bin/env bash
# Ensures curate wires source agent memories before adding consolidated graph edges.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EAGLE_BIN="$ROOT_DIR/bin/eagle-mem"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-curate-graph.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR" "$tmp_dir/bin"

cat > "$tmp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [ -n "${EAGLE_CURATE_FAKE_CURL_MARKER:-}" ]; then
    echo called >> "$EAGLE_CURATE_FAKE_CURL_MARKER"
fi

content="${EAGLE_CURATE_FAKE_RESPONSE:-NONE}"
jq -nc --arg content "$content" '{message:{role:"assistant",content:$content}}'
EOF
chmod +x "$tmp_dir/bin/curl"
export PATH="$tmp_dir/bin:$PATH"

. "$ROOT_DIR/lib/common.sh"
"$ROOT_DIR/db/migrate.sh" >/dev/null
. "$ROOT_DIR/lib/db.sh"

cat > "$EAGLE_MEM_DIR/config.toml" <<'EOF'
[provider]
type = "ollama"

[ollama]
url = "http://127.0.0.1:11434"
model = "fake"
EOF

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    if [ "$actual" != "$expected" ]; then
        echo "$message: expected $expected, got $actual" >&2
        exit 1
    fi
}

insert_memory() {
    local project="$1" file_path="$2" memory_name="$3" description="$4" content="$5"
    eagle_db "INSERT INTO agent_memories (project, file_path, memory_name, memory_type, description, content)
              VALUES
              ('$(eagle_sql_escape "$project")',
               '$(eagle_sql_escape "$file_path")',
               '$(eagle_sql_escape "$memory_name")',
               'project',
               '$(eagle_sql_escape "$description")',
               '$(eagle_sql_escape "$content")');" >/dev/null
}

agent_memory_rows() {
    local project="$1"
    eagle_db "SELECT COUNT(*)
              FROM agent_memories
              WHERE project = '$(eagle_sql_escape "$project")';"
}

memory_graph_nodes() {
    local project="$1"
    eagle_db "SELECT COUNT(*)
              FROM graph_nodes
              WHERE project = '$(eagle_sql_escape "$project")'
                AND node_type = 'memory';"
}

supersedes_edges() {
    local project="$1" new_name="${2:-}"
    local new_filter=""
    if [ -n "$new_name" ]; then
        new_filter="AND s.node_name = '$(eagle_sql_escape "$new_name")'"
    fi
    eagle_db "SELECT COUNT(*)
              FROM graph_edges e
              JOIN graph_nodes s ON s.id = e.source_node_id
              JOIN graph_nodes t ON t.id = e.target_node_id
              WHERE e.project = '$(eagle_sql_escape "$project")'
                AND e.edge_type = 'supersedes'
                AND s.node_type = 'memory'
                AND t.node_type = 'memory'
                $new_filter;"
}

# Happy path: structured JSON survives punctuation that broke the old text parser.
export EAGLE_CURATE_FAKE_RESPONSE='{"consolidations":[{"source_names":["Memory A - Dash","Memory B > Pipe | Name"],"new_name":"Compiled AB JSON","description":"merged memories","value":"--- Compiled Truth ---\nmerged truth\n\n--- Evidence Trail ---\n- Memory A - Dash\n- Memory B > Pipe | Name"}]}'
insert_memory "project-json" "memory://a" "Memory A - Dash" "First memory" $'Content A\nEvidence line that must not become a graph node'
insert_memory "project-json" "memory://b" "Memory B > Pipe | Name" "Second memory" "Content B"

"$EAGLE_BIN" curate -p project-json >/dev/null
assert_eq "2" "$(agent_memory_rows project-json)" "source agent memories should survive curate"
assert_eq "3" "$(memory_graph_nodes project-json)" "curate should create two originals plus one consolidated memory node"
assert_eq "2" "$(supersedes_edges project-json "Compiled AB JSON")" "consolidated memory should supersede both originals"

# Idempotency: re-running the same consolidation should not create duplicate nodes or edges.
"$EAGLE_BIN" curate -p project-json >/dev/null
assert_eq "3" "$(memory_graph_nodes project-json)" "curate should keep memory graph nodes idempotent"
assert_eq "2" "$(supersedes_edges project-json "Compiled AB JSON")" "curate should keep supersedes edge count idempotent"

# Wrapped provider output: conversational text around JSON should still parse.
export EAGLE_CURATE_FAKE_RESPONSE=$'Here is the JSON you requested:\n{"consolidations":[{"source_names":["Wrapped A","Wrapped B"],"new_name":"Wrapped AB","description":"wrapped","value":"--- Compiled Truth ---\\nwrapped truth\\n\\n--- Evidence Trail ---\\n- Wrapped A\\n- Wrapped B"}]}\nDone.'
insert_memory "project-wrapped" "memory://wrapped-a" "Wrapped A" "First wrapped memory" "Content A"
insert_memory "project-wrapped" "memory://wrapped-b" "Wrapped B" "Second wrapped memory" "Content B"
"$EAGLE_BIN" curate -p project-wrapped >/dev/null
assert_eq "3" "$(memory_graph_nodes project-wrapped)" "wrapped JSON output should still create consolidated memory nodes"
assert_eq "2" "$(supersedes_edges project-wrapped "Wrapped AB")" "wrapped JSON output should still wire supersedes edges"

# No consolidation: source nodes are still wired, but no supersedes edges are created.
export EAGLE_CURATE_FAKE_RESPONSE='{"consolidations":[]}'
insert_memory "project-none" "memory://none-a" "Memory None A" "First none memory" "Content A"
insert_memory "project-none" "memory://none-b" "Memory None B" "Second none memory" "Content B"
"$EAGLE_BIN" curate -p project-none >/dev/null
assert_eq "2" "$(memory_graph_nodes project-none)" "NONE response should still wire source memory nodes"
assert_eq "0" "$(supersedes_edges project-none)" "NONE response should not create supersedes edges"

# Malformed legacy/text output is ignored safely instead of producing partial graph edges.
export EAGLE_CURATE_FAKE_RESPONSE='CONSOLIDATE: Memory Broken A, Memory Broken B -> Broken AB | description: legacy | value: legacy text'
insert_memory "project-malformed" "memory://bad-a" "Memory Broken A" "First malformed memory" "Content A"
insert_memory "project-malformed" "memory://bad-b" "Memory Broken B" "Second malformed memory" "Content B"
"$EAGLE_BIN" curate -p project-malformed >/dev/null
assert_eq "2" "$(memory_graph_nodes project-malformed)" "malformed response should still wire source memory nodes"
assert_eq "0" "$(supersedes_edges project-malformed)" "malformed response should not create supersedes edges"

# Dry-run: memory graph writes and provider calls are skipped for consolidation.
dry_run_marker="$tmp_dir/curl-called"
dry_run_output="$tmp_dir/dry-run.out"
export EAGLE_CURATE_FAKE_CURL_MARKER="$dry_run_marker"
export EAGLE_CURATE_FAKE_RESPONSE='{"consolidations":[{"source_names":["Dry A","Dry B"],"new_name":"Dry AB","description":"dry","value":"dry"}]}'
insert_memory "project-dry" "memory://dry-a" "Dry A" "First dry memory" "Content A"
insert_memory "project-dry" "memory://dry-b" "Dry B" "Second dry memory" "Content B"
"$EAGLE_BIN" curate --dry-run -p project-dry > "$dry_run_output"
if [ -f "$dry_run_marker" ]; then
    echo "dry-run should not call the consolidation provider" >&2
    exit 1
fi
assert_eq "0" "$(memory_graph_nodes project-dry)" "dry-run should not write memory graph nodes"
if ! grep -q "Would wire 2 agent memory graph nodes" "$dry_run_output"; then
    echo "dry-run did not report the memory graph wiring preview" >&2
    exit 1
fi

echo "curate graph memory regressions passed"
