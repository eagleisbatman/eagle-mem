-- Migration 020: Remove seeded global command rules.
-- Self-learning pipeline (curator) now generates rules from real usage.
-- Per-project rules created by the curator are preserved.
--
-- Safety: back up any existing global rules before deleting so they
-- can be restored if a user manually created rules they want to keep.
-- The backup table is left in place intentionally.

CREATE TABLE IF NOT EXISTS _backup_020_global_rules AS
    SELECT * FROM command_rules WHERE project = '';

DELETE FROM command_rules WHERE project = '';
