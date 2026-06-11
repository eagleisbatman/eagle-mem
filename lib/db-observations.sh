#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Observation + code chunk helpers
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_DB_OBSERVATIONS_LOADED:-}" ] && return 0
_EAGLE_DB_OBSERVATIONS_LOADED=1

eagle_insert_observation() {
    local session_id; session_id=$(eagle_sql_escape "$1")
    local project; project=$(eagle_sql_escape "$2")
    local tool_name; tool_name=$(eagle_sql_escape "$3")
    local tool_input_summary; tool_input_summary=$(eagle_sql_escape "$4")
    local files_read; files_read=$(eagle_sql_escape "$5")
    local files_modified; files_modified=$(eagle_sql_escape "$6")
    local output_bytes="${7:-}"
    local output_lines="${8:-}"
    local command_category; command_category=$(eagle_sql_escape "${9:-}")
    local agent; agent=$(eagle_sql_escape "${10:-$(eagle_agent_source)}")

    local extra_cols=""
    local extra_vals=""
    if [ -n "$output_bytes" ]; then
        extra_cols=", output_bytes, output_lines, command_category"
        extra_vals=", $(eagle_sql_int "$output_bytes"), $(eagle_sql_int "$output_lines"), '$command_category'"
    fi

    # BEGIN IMMEDIATE serializes the check-then-insert under the write lock so
    # two concurrent hooks can't both pass NOT EXISTS and double-insert (the
    # second blocks via busy_timeout, then sees the first row). Without it the
    # 5-second dedup window is racy. eagle_db_strict (.bail on) ensures a failed
    # INSERT aborts before COMMIT so the transaction rolls back cleanly.
    eagle_db_strict "BEGIN IMMEDIATE;
              INSERT INTO observations (session_id, project, agent, tool_name, tool_input_summary, files_read, files_modified${extra_cols})
              SELECT '$session_id', '$project', '$agent', '$tool_name', '$tool_input_summary', '$files_read', '$files_modified'${extra_vals}
              WHERE NOT EXISTS (
                  SELECT 1 FROM observations
                  WHERE session_id = '$session_id'
                  AND tool_name = '$tool_name'
                  AND tool_input_summary = '$tool_input_summary'
                  AND created_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-5 seconds')
              );
              COMMIT;"
}

eagle_insert_recall_event() {
    local session_id; session_id=$(eagle_sql_escape "${1:-}")
    local project; project=$(eagle_sql_escape "${2:-}")
    local cwd; cwd=$(eagle_sql_escape "${3:-}")
    local agent; agent=$(eagle_sql_escape "${4:-$(eagle_agent_source)}")
    local prompt_snippet; prompt_snippet=$(eagle_sql_escape "$(eagle_trim_text "${5:-}" 240 | eagle_redact)")
    local fts_query; fts_query=$(eagle_sql_escape "${6:-}")
    local summary_matches; summary_matches=$(eagle_sql_int "${7:-0}")
    local memory_matches; memory_matches=$(eagle_sql_int "${8:-0}")
    local code_matches; code_matches=$(eagle_sql_int "${9:-0}")
    local injected_chars; injected_chars=$(eagle_sql_int "${10:-0}")
    local status; status=$(eagle_sql_escape "${11:-ok}")
    local error; error=$(eagle_sql_escape "${12:-}")
    local summary_refs; summary_refs=$(eagle_sql_escape "${13:-[]}")
    local memory_refs; memory_refs=$(eagle_sql_escape "${14:-[]}")
    local code_refs; code_refs=$(eagle_sql_escape "${15:-[]}")
    local injected_token_estimate=$(( (injected_chars + 3) / 4 ))

    [ -n "$project" ] || project="unknown"

    eagle_db "INSERT INTO recall_events (
                  session_id, project, cwd, agent, prompt_snippet, fts_query,
                  summary_matches, memory_matches, code_matches,
                  summary_refs, memory_refs, code_refs, injected_chars,
                  injected_token_estimate, status, error
              )
              VALUES (
                  '$session_id', '$project', '$cwd', '$agent', '$prompt_snippet', '$fts_query',
                  $summary_matches, $memory_matches, $code_matches,
                  '$summary_refs', '$memory_refs', '$code_refs', $injected_chars,
                  $injected_token_estimate, '$status', '$error'
              );"
}

eagle_prune_observations() {
    local days; days=$(eagle_sql_int "${1:-90}")
    local project_filter=""
    if [ -n "${2:-}" ]; then
        local proj; proj=$(eagle_sql_escape "$2")
        project_filter="AND session_id IN (SELECT id FROM sessions WHERE project = '$proj')"
    fi
    eagle_db "DELETE FROM observations WHERE created_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-$days days') $project_filter;"
}

eagle_get_command_rule() {
    local project; project=$(eagle_sql_escape "$1")
    local base_cmd; base_cmd=$(eagle_sql_escape "$2")
    local full_cmd; full_cmd=$(eagle_sql_escape "${3:-$2}")

    # Provenance gate: command_rules are human-authored ('manual') or generated
    # by the LLM curator ('curator'). When token_guard.trust_learned_rules is
    # false, only human-authored rules may steer command handling — model-derived
    # rules are excluded so LLM output cannot silently shape execution. Default
    # true preserves the auto-learning behavior. COALESCE guards rows written
    # before migration 045 (treated as 'manual').
    local trust
    if declare -F eagle_config_get >/dev/null 2>&1; then
        trust=$(eagle_config_get "token_guard" "trust_learned_rules" "true")
    else
        trust=$(eagle_config_get_light "token_guard" "trust_learned_rules" "true")
    fi
    local source_filter=""
    [ "$trust" = "false" ] && source_filter="AND COALESCE(source, 'manual') = 'manual'"

    eagle_db "SELECT strategy, max_lines, reason
        FROM command_rules
        WHERE enabled = 1
        $source_filter
        AND (project = '$project' OR project = '')
        AND ('$base_cmd' = pattern OR '$full_cmd' = pattern OR '$full_cmd' LIKE pattern || ' %')
        ORDER BY CASE WHEN project != '' THEN 0 ELSE 1 END,
            LENGTH(pattern) DESC
        LIMIT 1;"
}

eagle_search_code_chunks() {
    local query; query=$(eagle_fts_sanitize "$1")
    query=$(eagle_sql_escape "$query")
    local project; project=$(eagle_sql_escape "$2")
    local limit; limit=$(eagle_sql_int "${3:-5}")

    eagle_db "SELECT c.file_path, c.start_line, c.end_line, c.language
              FROM code_chunks c
              JOIN code_chunks_fts f ON f.rowid = c.id
              WHERE code_chunks_fts MATCH '$query'
              AND c.project = '$project'
              AND c.file_path NOT LIKE '.playwright-mcp/%'
              AND c.file_path NOT LIKE '.eagle-worktrees/%'
              AND c.file_path NOT LIKE '.git/%'
              AND c.file_path NOT LIKE 'node_modules/%'
              AND c.file_path NOT LIKE 'dist/%'
              AND c.file_path NOT LIKE 'build/%'
              AND c.file_path NOT LIKE 'coverage/%'
              ORDER BY rank
              LIMIT $limit;"
}

eagle_count_code_chunks() {
    local project; project=$(eagle_sql_escape "$1")
    eagle_db "SELECT COUNT(*) FROM code_chunks WHERE project = '$project' LIMIT 1;"
}
