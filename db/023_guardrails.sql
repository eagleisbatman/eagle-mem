-- ═══════════════════════════════════════════════════════════
-- Migration 023: Guardrails table
-- Persistent per-project rules surfaced at Edit/Write time
-- ═══════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS guardrails (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    project      TEXT NOT NULL,
    file_pattern TEXT NOT NULL DEFAULT '',
    rule         TEXT NOT NULL,
    source       TEXT NOT NULL DEFAULT 'manual',
    active       INTEGER NOT NULL DEFAULT 1,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(project, source, file_pattern, rule)
);

CREATE INDEX IF NOT EXISTS idx_guardrails_project ON guardrails(project, active);
