-- ═══════════════════════════════════════════════════════════
-- Eagle Mem — Migration 011: Overview source tracking
-- Tracks whether overview was written by scan or manually
-- ═══════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

ALTER TABLE overviews ADD COLUMN source TEXT NOT NULL DEFAULT 'manual';

UPDATE overviews SET source = 'scan' WHERE length(content) <= 300;
