#!/usr/bin/env bash
# Static guard for the compatibility-first Rust migration plan.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLAN="$ROOT_DIR/MIGRATION.md"

fail() {
    echo "rust migration plan check failed: $*" >&2
    exit 1
}

require_contains() {
    local pattern="$1"
    local label="$2"
    if ! grep -Eq "$pattern" "$PLAN"; then
        fail "MIGRATION.md does not mention $label"
    fi
}

# MIGRATION.md is a maintainer-only roadmap and is intentionally NOT shipped in
# the npm package (`files` allowlist), so this contract test has nothing to
# guard when the suite runs from a published install via `eagle-mem test`.
# Skip cleanly (exit 2) in that case; run strictly from a source checkout.
if [ ! -f "$PLAN" ]; then
    echo "skip: MIGRATION.md not present (dev-only contract test)" >&2
    exit 2
fi

require_contains "~/.eagle-mem/memory\\.db" "the existing user database path"
require_contains "compatibility wrapper" "the Bash compatibility wrapper"
require_contains "additive migrations" "additive migrations"
require_contains "never deleted|Never mutate|Never make destructive" "data preservation"
require_contains "eagle_events" "structured observability events"
require_contains "ratatui" "Rust TUI library"
require_contains "crossterm" "Rust terminal backend"
require_contains "rusqlite|sqlx" "SQLite Rust library options"
require_contains "Phase 0" "Phase 0"
require_contains "Phase 1" "Phase 1"
require_contains "Phase 2" "Phase 2"
require_contains "Phase 3" "Phase 3"
require_contains "Phase 4" "Phase 4"
require_contains "Phase 5" "Phase 5"
require_contains "Phase 6" "Phase 6"
require_contains "Phase 7" "Phase 7"

for crate in eagle-core eagle-db eagle-hooks eagle-cli eagle-tui; do
    require_contains "$crate" "crate $crate"
done

for table in \
    sessions observations summaries summaries_fts overviews code_chunks code_chunks_fts \
    agent_memories agent_tasks features feature_files pending_feature_verifications \
    graph_nodes graph_edges orchestrations orchestration_lanes recall_events \
    orchestration_auto_events eagle_meta
do
    require_contains "\\b$table\\b" "table $table"
done

for command in \
    install update uninstall search health doctor repair inspect replay dashboard logs \
    config updates statusline guard overview graph session sessions memories tasks \
    orchestrate curate feature grok-bootstrap test compaction prune scan index help version
do
    require_contains "\`$command\`|^(- )?$command$| $command" "command $command"
done

for event in \
    hook_started hook_completed memory_created memory_retrieved context_injected \
    compact_started compact_completed index_started index_completed lane_created \
    task_created task_completed graph_rebuilt dashboard_generated replay_generated
do
    require_contains "$event" "event $event"
done

require_contains "Rust disabled" "Rust disabled test mode"
require_contains "Rust enabled" "Rust enabled test mode"
require_contains "sanitized" "sanitized migrated DB fixtures"
require_contains "docs/agent-compatibility" "agent compatibility docs integration"

echo "rust migration plan check passed"

