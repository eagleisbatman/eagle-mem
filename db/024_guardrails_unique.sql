-- Migration 024: Normalize guardrail de-duplication
-- Older installs used UNIQUE(project, source, file_pattern, rule). Runtime
-- installs already moved to project+file_pattern+rule, so rebuild the table
-- to make fresh and upgraded databases agree.

CREATE TABLE IF NOT EXISTS guardrails_new (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    project      TEXT NOT NULL,
    file_pattern TEXT NOT NULL DEFAULT '',
    rule         TEXT NOT NULL,
    source       TEXT NOT NULL DEFAULT 'manual',
    active       INTEGER NOT NULL DEFAULT 1,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

INSERT OR IGNORE INTO guardrails_new (id, project, file_pattern, rule, source, active, created_at, updated_at)
SELECT
    MIN(g.id) AS id,
    g.project,
    COALESCE(g.file_pattern, '') AS file_pattern,
    g.rule,
    COALESCE((
        SELECT g2.source
        FROM guardrails g2
        WHERE g2.project = g.project
          AND COALESCE(g2.file_pattern, '') = COALESCE(g.file_pattern, '')
          AND g2.rule = g.rule
        ORDER BY
            CASE g2.source WHEN 'manual' THEN 0 ELSE 1 END,
            g2.updated_at DESC,
            g2.id DESC
        LIMIT 1
    ), 'manual') AS source,
    MAX(g.active) AS active,
    MIN(g.created_at) AS created_at,
    MAX(g.updated_at) AS updated_at
FROM guardrails g
GROUP BY g.project, COALESCE(g.file_pattern, ''), g.rule;

DROP TABLE guardrails;
ALTER TABLE guardrails_new RENAME TO guardrails;

CREATE INDEX IF NOT EXISTS idx_guardrails_project ON guardrails(project, active);
CREATE UNIQUE INDEX IF NOT EXISTS idx_guardrails_dedup
    ON guardrails(project, COALESCE(file_pattern, ''), rule);
