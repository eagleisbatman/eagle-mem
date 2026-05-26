#!/usr/bin/env bash
# Focused graph-memory regressions. Runs in an isolated HOME/EAGLE_MEM_DIR.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EAGLE_BIN="$ROOT_DIR/bin/eagle-mem"

tmp_dir=$(mktemp -d "$ROOT_DIR/.tmp-graph-memory.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export EAGLE_MEM_DIR="$tmp_dir/eagle-mem"
mkdir -p "$HOME" "$EAGLE_MEM_DIR"

. "$ROOT_DIR/lib/common.sh"
"$ROOT_DIR/db/migrate.sh" >/dev/null
. "$ROOT_DIR/lib/db.sh"

repo="$HOME/project"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Eagle Mem Test"

cat > "$repo/live.sh" <<'EOF'
function liveThing() {
  echo live
}
EOF

cat > "$repo/gone.sh" <<'EOF'
function goneThing() {
  echo gone
}
EOF

git -C "$repo" add live.sh gone.sh
rm "$repo/gone.sh"

collected="$tmp_dir/files.txt"
eagle_collect_files "$repo" "$collected"
grep -qx "live.sh" "$collected"
if grep -qx "gone.sh" "$collected"; then
    echo "deleted tracked file was collected" >&2
    exit 1
fi

for node_type in func struct function fn def class; do
    eagle_db "INSERT INTO graph_nodes (project, node_type, node_name)
              VALUES ('migration-test', '$node_type', '$node_type-node');" >/dev/null
done

cat > "$repo/a.sh" <<'EOF'
function finishDictation() {
  echo a
}
EOF

cat > "$repo/b.sh" <<'EOF'
function finishDictation() {
  echo b
}
EOF

cat > "$repo/old.sh" <<'EOF'
function CloudDictationPipeline() {
  echo old
}
EOF

mkdir -p "$repo/db"
cat > "$repo/db/source_column.sql" <<'EOF'
CREATE TABLE graph_fixture (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL DEFAULT 'manual',
  note TEXT DEFAULT './not-a-real-import'
);
EOF

git -C "$repo" add a.sh b.sh old.sh db/source_column.sql

"$EAGLE_BIN" scan --force "$repo" >/dev/null
"$EAGLE_BIN" index --force "$repo" >/dev/null

decl_count=$(eagle_db "SELECT COUNT(*)
                       FROM graph_nodes
                       WHERE project = 'project'
                         AND node_type = 'function'
                         AND node_name LIKE '%::finishDictation';")
if [ "$decl_count" != "2" ]; then
    echo "expected duplicate declarations to remain file-scoped, got $decl_count" >&2
    exit 1
fi

(cd "$repo" && "$EAGLE_BIN" overview set "Fresh offline-only overview" >/dev/null)
overview_value=$(eagle_db "SELECT node_value
                           FROM graph_nodes
                           WHERE project = 'project'
                             AND node_type = 'project'
                             AND node_name = 'project'
                           LIMIT 1;")
case "$overview_value" in
    *"Fresh offline-only overview"*) ;;
    *)
        echo "overview set did not sync graph project node" >&2
        exit 1
        ;;
esac

eagle_db "INSERT INTO sessions (id, project, cwd, model, status)
          VALUES ('session-graph-test', 'project', '$repo', 'test-model', 'completed');" >/dev/null
eagle_db "INSERT INTO observations (session_id, project, tool_name, files_read, files_modified)
          VALUES ('session-graph-test', 'project', 'Read',
                  '[\"$repo/a.sh\"]',
                  '[\"$repo/b.sh\"]');" >/dev/null

eagle_graph_wire_recent_session_edges "project" 15 >/dev/null
read_edges=$(eagle_db "SELECT COUNT(*)
                       FROM graph_edges e
                       JOIN graph_nodes s ON s.id = e.source_node_id
                       JOIN graph_nodes f ON f.id = e.target_node_id
                       WHERE e.project = 'project'
                         AND e.edge_type = 'read'
                         AND s.node_type = 'session'
                         AND s.node_name = 'session-graph-test'
                         AND f.node_type = 'file'
                         AND f.node_name = 'a.sh';")
modified_edges=$(eagle_db "SELECT COUNT(*)
                           FROM graph_edges e
                           JOIN graph_nodes s ON s.id = e.source_node_id
                           JOIN graph_nodes f ON f.id = e.target_node_id
                           WHERE e.project = 'project'
                             AND e.edge_type = 'modified'
                             AND s.node_type = 'session'
                             AND s.node_name = 'session-graph-test'
                             AND f.node_type = 'file'
                             AND f.node_name = 'b.sh';")
if [ "$read_edges" != "1" ] || [ "$modified_edges" != "1" ]; then
    echo "batched session graph wiring did not normalize absolute paths" >&2
    exit 1
fi

rm "$repo/old.sh"
git -C "$repo" add -u old.sh
(cd "$repo" && "$EAGLE_BIN" graph rebuild >/dev/null)

stale_count=$(eagle_db "SELECT COUNT(*)
                        FROM graph_nodes
                        WHERE project = 'project'
                          AND (node_name LIKE '%CloudDictationPipeline%'
                               OR node_name = 'old.sh');")
if [ "$stale_count" != "0" ]; then
    echo "graph rebuild left stale removed-file nodes" >&2
    exit 1
fi

echo "graph memory regressions passed"
