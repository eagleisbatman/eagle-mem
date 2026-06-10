-- Migration 044: Summary capture provenance
-- Tracks how each summary row was captured so later writers do not clobber
-- richer data. Values:
--   'agent'  — agent-authored via `eagle-mem session save` or a parsed
--              <eagle-summary> block (authoritative)
--   'hook'   — Stop-hook heuristic extraction (gap-fill only once 'agent')
--   'enrich' — background LLM enrichment (gap-fill only once 'agent')
-- Empty default preserves existing rows. Not indexed by FTS.

ALTER TABLE summaries ADD COLUMN capture_source TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_summaries_capture_source ON summaries(capture_source);
