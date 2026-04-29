-- Clear fossil placeholder data that the COALESCE upsert preserves forever.
-- These rows block real data from being written on future Stop hook fires.
PRAGMA trusted_schema=ON;

UPDATE summaries SET completed = ''
WHERE completed LIKE '%(auto-captured%';

UPDATE summaries SET request = ''
WHERE request LIKE '%<local-command-caveat>%';

UPDATE summaries SET request = ''
WHERE request LIKE '%<system-reminder>%';
