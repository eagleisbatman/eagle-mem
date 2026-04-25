-- ═══════════════════════════════════════════════════════════
-- Eagle Mem — Migration 002: Project overviews
-- One rolling overview per project for quick context injection
-- ═══════════════════════════════════════════════════════════

-- NOTE: PRAGMAs are connection-scoped, set in lib/db.sh
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS overviews (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project    TEXT NOT NULL UNIQUE,
    content    TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_overviews_project ON overviews(project);
