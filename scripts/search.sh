#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Search
# CLI wrapper for memory search (replaces raw SQL in skills)
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

# ─── Help ────────────────────────────────────────────────

show_help() {
    echo -e "  ${BOLD}eagle-mem search${RESET} — Search persistent memory"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem search ${CYAN}<query>${RESET}                   ${DIM}# keyword search${RESET}"
    echo -e "    eagle-mem search ${CYAN}--timeline${RESET}               ${DIM}# recent sessions${RESET}"
    echo -e "    eagle-mem search ${CYAN}--session <id>${RESET}            ${DIM}# session details${RESET}"
    echo -e "    eagle-mem search ${CYAN}--files${RESET}                  ${DIM}# frequently modified files${RESET}"
    echo -e "    eagle-mem search ${CYAN}--stats${RESET}                  ${DIM}# project statistics${RESET}"
    echo -e "    eagle-mem search ${CYAN}--overview${RESET}                ${DIM}# project overview${RESET}"
    echo -e "    eagle-mem search ${CYAN}--memories${RESET}               ${DIM}# mirrored agent memories${RESET}"
    echo -e "    eagle-mem search ${CYAN}--tasks${RESET}                  ${DIM}# in-flight tasks${RESET}"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    ${CYAN}-p, --project${RESET} <name>    Project name (default: current dir)"
    echo -e "    ${CYAN}-n, --limit${RESET} <N>         Max results (default: 10)"
    echo -e "    ${CYAN}-a, --all${RESET}               Search across all projects"
    echo -e "    ${CYAN}-j, --json${RESET}              Output as JSON"
    echo -e "    ${CYAN}--raw, --debug${RESET}          Show raw IDs and detailed observation rows"
    echo ""
    exit 0
}

# ─── Parse arguments ──────────────────────────────────────

mode="keyword"
project=""
project_was_explicit=false
project_scope=""
project_label=""
limit=10
session_id=""
json_output=false
raw_output=false
query=""
cross_project=false

while [ $# -gt 0 ]; do
    case "$1" in
        --timeline|-t)      mode="timeline"; shift ;;
        --session|-s)        mode="session"; session_id="$2"; shift 2 ;;
        --files|-f)          mode="files"; shift ;;
        --stats)             mode="stats"; shift ;;
        --overview|-o)       mode="overview"; shift ;;
        --memories|-m)       mode="memories"; shift ;;
        --tasks)             mode="tasks"; shift ;;
        --project|-p)        project="$2"; project_was_explicit=true; shift 2 ;;
        --limit|-n)          limit="$2"; shift 2 ;;
        --all|-a)            cross_project=true; shift ;;
        --json|-j)           json_output=true; shift ;;
        --raw|--debug)       raw_output=true; shift ;;
        --help|-h)  show_help ;;
        -*)
            eagle_err "Unknown option: $1"
            exit 1
            ;;
        *)
            query="$1"; shift ;;
    esac
done

[ -z "$project" ] && project=$(eagle_project_from_cwd "$(pwd)")
project_scope="$project"
if [ "$cross_project" = false ] && [ "$project_was_explicit" = false ]; then
    project_scope=$(eagle_recall_project_scope_from_cwd "$(pwd)" "$project")
fi
project_label=$(eagle_project_scope_label "$project_scope")
[ -z "$project_label" ] && project_label="$project"
limit=$(eagle_sql_int "$limit")
[ "$limit" -eq 0 ] && limit=10

# ─── Keyword search ──────────────────────────────────────

search_keyword() {
    local sanitized_q
    sanitized_q=$(eagle_fts_sanitize "$query")
    if [ -z "$sanitized_q" ]; then
        eagle_err "Search query contains no valid search terms"
        exit 1
    fi
    local q; q=$(eagle_sql_escape "$sanitized_q")
    local project_condition
    project_condition=$(eagle_sql_project_scope_condition "s.project" "$project_scope")

    local where_project=""
    if [ "$cross_project" = false ]; then
        where_project="AND $project_condition"
    fi

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT s.id, s.project, s.agent, s.request, s.completed, s.learned, s.created_at,
                              CASE
                                WHEN julianday('now') - julianday(s.created_at) <= 14 THEN 'Fresh'
                                WHEN julianday('now') - julianday(s.created_at) <= 45 THEN 'Recent'
                                ELSE 'Older'
                              END AS freshness
                       FROM summaries s
                       JOIN summaries_fts f ON f.rowid = s.id
                       WHERE summaries_fts MATCH '$q'
                       AND COALESCE(s.request, '') NOT LIKE '%<local-command-caveat>%'
                       AND COALESCE(s.request, '') NOT LIKE '# AGENTS.md instructions%'
                       AND COALESCE(s.request, '') NOT LIKE '<environment_context>%'
                       AND COALESCE(s.request, '') NOT LIKE '<subagent_notification>%'
                       AND COALESCE(s.request, '') NOT LIKE '</subagent_notification>%'
                       $where_project
                       ORDER BY
                         CASE
                           WHEN julianday('now') - julianday(s.created_at) <= 14 THEN 0
                           WHEN julianday('now') - julianday(s.created_at) <= 45 THEN 1
                           ELSE 2
                         END,
                         s.created_at DESC,
                         rank
                       LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT s.id, s.project, s.agent, s.request, s.completed, s.learned, s.created_at,
                               CASE
                                 WHEN julianday('now') - julianday(s.created_at) <= 14 THEN 'Fresh'
                                 WHEN julianday('now') - julianday(s.created_at) <= 45 THEN 'Recent'
                                 ELSE 'Older'
                               END AS freshness
                        FROM summaries s
                        JOIN summaries_fts f ON f.rowid = s.id
                        WHERE summaries_fts MATCH '$q'
                        AND COALESCE(s.request, '') NOT LIKE '%<local-command-caveat>%'
                        AND COALESCE(s.request, '') NOT LIKE '# AGENTS.md instructions%'
                        AND COALESCE(s.request, '') NOT LIKE '<environment_context>%'
                        AND COALESCE(s.request, '') NOT LIKE '<subagent_notification>%'
                        AND COALESCE(s.request, '') NOT LIKE '</subagent_notification>%'
                        $where_project
                        ORDER BY
                          CASE
                            WHEN julianday('now') - julianday(s.created_at) <= 14 THEN 0
                            WHEN julianday('now') - julianday(s.created_at) <= 45 THEN 1
                            ELSE 2
                          END,
                          s.created_at DESC,
                          rank
                        LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No results for '$query'"
        return
    fi

    echo ""
    local idx=1
    while IFS='|' read -r sid sproj sagent req completed learned created_at freshness; do
        [ -z "$sid" ] && continue
        echo -e "  ${BOLD}${idx}. ${req:-Memory match}${RESET}"
        echo -e "  ${DIM}source:${RESET} $(eagle_agent_label "$sagent")  ${DIM}date:${RESET} $created_at  ${DIM}freshness:${RESET} $freshness"
        if [ "$cross_project" = true ]; then
            echo -e "  ${DIM}project:${RESET} $sproj"
        fi
        [ -n "$completed" ] && echo -e "  ${GREEN}Done:${RESET} $completed"
        [ -n "$learned" ] && echo -e "  ${YELLOW}Learned:${RESET} $learned"
        echo ""
        idx=$((idx + 1))
    done <<< "$results"
}

# ─── Timeline ────────────────────────────────────────────

search_timeline() {
    local project_condition
    project_condition=$(eagle_sql_project_scope_condition "s.project" "$project_scope")

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT s.id, s.agent, s.request, s.completed, s.learned, s.next_steps, s.created_at
                       FROM summaries s
                       WHERE $project_condition
                       ORDER BY s.created_at DESC
                       LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT s.id, s.agent, s.request, s.completed, s.learned, s.next_steps, s.created_at
                        FROM summaries s
                        WHERE $project_condition
                        ORDER BY s.created_at DESC
                        LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No sessions found for project '$project'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Recent sessions${RESET} ${DIM}($project_label)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    local idx=1
    while IFS='|' read -r sid sagent req completed learned next_steps created_at; do
        [ -z "$sid" ] && continue
        if [ "$raw_output" = true ]; then
            echo -e "  ${BOLD}#$sid${RESET}  ${DIM}$created_at${RESET}"
        else
            echo -e "  ${BOLD}${idx}. Session summary${RESET}  ${DIM}$created_at${RESET}"
        fi
        echo -e "  ${DIM}source:${RESET} $(eagle_agent_label "$sagent")"
        [ -n "$req" ] && echo -e "  ${CYAN}Request:${RESET} $req"
        [ -n "$completed" ] && echo -e "  ${GREEN}Done:${RESET} $completed"
        [ -n "$learned" ] && echo -e "  ${YELLOW}Learned:${RESET} $learned"
        [ -n "$next_steps" ] && echo -e "  ${DIM}Next:${RESET} $next_steps"
        echo ""
        idx=$((idx + 1))
    done <<< "$results"
    if [ "$raw_output" = false ]; then
        eagle_dim "Run with --raw to show summary IDs."
    fi
}

# ─── Session details ──────────────────────────────────────

search_session() {
    if [ -z "$session_id" ]; then
        eagle_err "Usage: eagle-mem search --session <session-id-or-summary-id>"
        exit 1
    fi

    local lookup_sql resolved_session
    lookup_sql=$(eagle_sql_escape "$session_id")
    case "$session_id" in
        *[!0-9]*) ;;
        *)
            resolved_session=$(eagle_db "SELECT session_id FROM summaries WHERE id = '$lookup_sql' LIMIT 1;" 2>/dev/null | awk 'NF { print; exit }')
            [ -n "$resolved_session" ] && session_id="$resolved_session"
            ;;
    esac

    local sid_sql; sid_sql=$(eagle_sql_escape "$session_id")

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT o.agent, o.tool_name, o.tool_input_summary, o.files_read, o.files_modified, o.created_at
                       FROM observations o
                       WHERE o.session_id = '$sid_sql'
                       ORDER BY o.created_at ASC;"
        return
    fi

    local results_json
    results_json=$(eagle_db_json "SELECT o.agent, o.tool_name, o.tool_input_summary, o.files_read, o.files_modified, o.created_at
                                  FROM observations o
                                  WHERE o.session_id = '$sid_sql'
                                  ORDER BY o.created_at ASC;")

    if [ -z "$results_json" ] || [ "$(printf '%s' "$results_json" | jq 'length' 2>/dev/null)" = "0" ]; then
        eagle_dim "No observations found for session '$session_id'"
        return
    fi

    if [ "$raw_output" = true ]; then
        echo ""
        echo -e "  ${BOLD}Session${RESET} ${DIM}$session_id${RESET}"
        echo -e "  ${DIM}─────────────────────────────────────${RESET}"
        echo ""

        printf '%s' "$results_json" | jq -c '.[]' | while IFS= read -r row; do
            oagent=$(printf '%s' "$row" | jq -r '.agent // ""')
            tool_name=$(printf '%s' "$row" | jq -r '.tool_name // ""')
            summary=$(printf '%s' "$row" | jq -r '.tool_input_summary // ""')
            created_at=$(printf '%s' "$row" | jq -r '.created_at // ""')
            [ -z "$tool_name" ] && continue
            local icon="$DOT"
            case "$tool_name" in
                Read) icon="${CYAN}R${RESET}" ;;
                Write) icon="${GREEN}W${RESET}" ;;
                Edit) icon="${YELLOW}E${RESET}" ;;
                Bash|exec_command|shell_command|unified_exec) icon="${BLUE}\$${RESET}" ;;
            esac
            echo -e "  ${icon}  ${DIM}$created_at $(eagle_agent_label "$oagent")${RESET}  $summary"
        done
        echo ""
        return
    fi

    local first_seen last_seen total_obs agent_counts tool_counts
    first_seen=$(eagle_db "SELECT MIN(created_at) FROM observations WHERE session_id = '$sid_sql';")
    last_seen=$(eagle_db "SELECT MAX(created_at) FROM observations WHERE session_id = '$sid_sql';")
    total_obs=$(printf '%s' "$results_json" | jq 'length' 2>/dev/null)
    agent_counts=$(eagle_db "SELECT agent || ':' || COUNT(*) FROM observations WHERE session_id = '$sid_sql' GROUP BY agent ORDER BY COUNT(*) DESC;")
    tool_counts=$(eagle_db "SELECT tool_name || ':' || COUNT(*) FROM observations WHERE session_id = '$sid_sql' GROUP BY tool_name ORDER BY COUNT(*) DESC LIMIT 8;")

    echo ""
    echo -e "  ${BOLD}Session Activity${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""
    eagle_kv "Observations:" "${total_obs:-0}"
    [ -n "$first_seen" ] && eagle_kv "Started:" "$first_seen"
    [ -n "$last_seen" ] && eagle_kv "Last seen:" "$last_seen"
    if [ -n "$agent_counts" ]; then
        local agents_display=""
        while IFS=':' read -r a count; do
            [ -z "$a" ] && continue
            [ -n "$agents_display" ] && agents_display+=", "
            agents_display+="$(eagle_agent_label "$a") $count"
        done <<< "$agent_counts"
        [ -n "$agents_display" ] && eagle_kv "Agents:" "$agents_display"
    fi
    if [ -n "$tool_counts" ]; then
        local tools_display=""
        while IFS=':' read -r t count; do
            [ -z "$t" ] && continue
            [ -n "$tools_display" ] && tools_display+=", "
            tools_display+="$t $count"
        done <<< "$tool_counts"
        [ -n "$tools_display" ] && eagle_kv "Tools:" "$tools_display"
    fi
    echo ""
    echo -e "  ${BOLD}Recent activity${RESET}"

    printf '%s' "$results_json" | jq -c --argjson limit "$limit" '.[-$limit:][]' | while IFS= read -r row; do
        oagent=$(printf '%s' "$row" | jq -r '.agent // ""')
        tool_name=$(printf '%s' "$row" | jq -r '.tool_name // ""')
        summary=$(printf '%s' "$row" | jq -r '.tool_input_summary // ""')
        files_r=$(printf '%s' "$row" | jq -r '.files_read // "[]"')
        files_m=$(printf '%s' "$row" | jq -r '.files_modified // "[]"')
        created_at=$(printf '%s' "$row" | jq -r '.created_at // ""')
        [ -z "$tool_name" ] && continue
        local label detail
        label="$tool_name"
        detail=$(eagle_trim_text "$summary" 120)
        case "$tool_name" in
            Read)
                label="Read"
                detail=$(printf '%s' "$files_r" | jq -r 'fromjson? | .[0] // empty' 2>/dev/null)
                [ -n "$detail" ] && detail=$(basename "$detail")
                ;;
            Write|Edit)
                label="$tool_name"
                detail=$(printf '%s' "$files_m" | jq -r 'fromjson? | .[0] // empty' 2>/dev/null)
                [ -n "$detail" ] && detail=$(basename "$detail")
                ;;
            apply_patch)
                label="Patch"
                ;;
            Bash|exec_command|shell_command|unified_exec)
                label="Command"
                ;;
        esac
        [ -z "$detail" ] && detail="$(eagle_agent_label "$oagent") activity"
        echo -e "  ${DOT} ${DIM}$created_at${RESET} ${BOLD}$label:${RESET} $detail"
    done
    echo ""
    eagle_dim "Run with --raw for full observation rows and session ID."
    echo ""
}

# ─── Frequently modified files ────────────────────────────

search_files() {
    local p; p=$(eagle_sql_escape "$project")

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT json_each.value as file, COUNT(*) as times
                       FROM observations, json_each(observations.files_modified)
                       WHERE observations.project = '$p'
                       GROUP BY json_each.value
                       ORDER BY times DESC
                       LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT json_each.value as file, COUNT(*) as times
                        FROM observations, json_each(observations.files_modified)
                        WHERE observations.project = '$p'
                        GROUP BY json_each.value
                        ORDER BY times DESC
                        LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No file history for project '$project'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Frequently modified files${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r filepath count; do
        [ -z "$filepath" ] && continue
        printf "  ${GREEN}%3s×${RESET}  %s\n" "$count" "$filepath"
    done <<< "$results"
    echo ""
}

# ─── Stats ────────────────────────────────────────────────

search_stats() {
    local sessions_condition summaries_condition observations_condition tasks_condition chunks_condition
    sessions_condition=$(eagle_sql_project_scope_condition "project" "$project_scope")
    summaries_condition=$(eagle_sql_project_scope_condition "project" "$project_scope")
    observations_condition=$(eagle_sql_project_scope_condition "s.project" "$project_scope")
    tasks_condition=$(eagle_sql_project_scope_condition "project" "$project_scope")
    chunks_condition=$(eagle_sql_project_scope_condition "project" "$project_scope")

    local sessions sessions_claude sessions_codex summaries observations tasks
    sessions=$(eagle_db "SELECT COUNT(*) FROM sessions WHERE $sessions_condition;")
    sessions_claude=$(eagle_db "SELECT COUNT(*) FROM sessions WHERE $sessions_condition AND agent = 'claude-code';")
    sessions_codex=$(eagle_db "SELECT COUNT(*) FROM sessions WHERE $sessions_condition AND agent = 'codex';")
    summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE $summaries_condition;")
    observations=$(eagle_db "SELECT COUNT(*) FROM observations o JOIN sessions s ON s.id = o.session_id WHERE $observations_condition;")
    tasks=$(eagle_db "SELECT COUNT(*) FROM agent_tasks WHERE $tasks_condition;")
    local chunks
    chunks=$(eagle_db "SELECT COUNT(*) FROM code_chunks WHERE $chunks_condition;")

    if [ "$json_output" = true ]; then
        jq -nc --arg project "$project_label" \
            --argjson sessions "${sessions:-0}" \
            --argjson sessions_claude "${sessions_claude:-0}" \
            --argjson sessions_codex "${sessions_codex:-0}" \
            --argjson summaries "${summaries:-0}" \
            --argjson observations "${observations:-0}" \
            --argjson tasks "${tasks:-0}" \
            --argjson code_chunks "${chunks:-0}" \
            '{project: $project, sessions: $sessions, sessions_claude: $sessions_claude, sessions_codex: $sessions_codex, summaries: $summaries, observations: $observations, tasks: $tasks, code_chunks: $code_chunks}'
        return
    fi

    echo ""
    echo -e "  ${BOLD}Stats${RESET} ${DIM}($project_label)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""
    eagle_kv "Sessions:" "${sessions:-0}"
    eagle_kv "Claude Code:" "${sessions_claude:-0}"
    eagle_kv "Codex:" "${sessions_codex:-0}"
    eagle_kv "Summaries:" "${summaries:-0}"
    eagle_kv "Observations:" "${observations:-0}"
    eagle_kv "Tasks:" "${tasks:-0}"
    eagle_kv "Code chunks:" "${chunks:-0}"
    echo ""
}

# ─── Overview ────────────────────────────────────────────

search_overview() {
    local p; p=$(eagle_sql_escape "$project")

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT project, content, source, updated_at FROM overviews WHERE project = '$p';"
        return
    fi

    local content
    content=$(eagle_db "SELECT content FROM overviews WHERE project = '$p';")

    if [ -z "$content" ]; then
        eagle_dim "No overview for project '$project'"
        eagle_dim "  Auto-scan runs on first session, or use /eagle-mem-overview for a rich briefing"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Overview${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""
    echo "  $content"
    echo ""

    if [ -n "$query" ]; then
        echo -e "  ${DIM}To update: eagle-mem search --overview set \"new overview text\"${RESET}"
    fi
}

# ─── Memories ────────────────────────────────────────────

search_memories() {
    local project_condition memory_condition
    project_condition=$(eagle_sql_project_scope_condition "project" "$project_scope")
    memory_condition=$(eagle_sql_project_scope_condition "m.project" "$project_scope")

    local where_project=""
    if [ "$cross_project" = false ]; then
        where_project="WHERE $project_condition"
    fi

    if [ -n "$query" ]; then
        local sanitized_mq
        sanitized_mq=$(eagle_fts_sanitize "$query")
        if [ -z "$sanitized_mq" ]; then
            eagle_err "Search query contains no valid search terms"
            exit 1
        fi
        local q; q=$(eagle_sql_escape "$sanitized_mq")
        local where_match="WHERE agent_memories_fts MATCH '$q'"
        if [ "$cross_project" = false ]; then
            where_match="$where_match AND $memory_condition"
        fi

        if [ "$json_output" = true ]; then
            eagle_db_json "SELECT m.memory_name, m.memory_type, m.description, m.project, m.updated_at, m.origin_agent,
                                  CASE
                                    WHEN julianday('now') - julianday(m.updated_at) <= 14 THEN 'Fresh'
                                    WHEN julianday('now') - julianday(m.updated_at) <= 45 THEN 'Recent'
                                    ELSE 'Older'
                                  END AS freshness
                           FROM agent_memories m
                           JOIN agent_memories_fts f ON f.rowid = m.id
                           $where_match
                           ORDER BY
                             CASE
                               WHEN julianday('now') - julianday(m.updated_at) <= 14 THEN 0
                               WHEN julianday('now') - julianday(m.updated_at) <= 45 THEN 1
                               ELSE 2
                             END,
                             m.updated_at DESC,
                             rank
                           LIMIT $limit;"
            return
        fi

        local results
        results=$(eagle_db "SELECT m.memory_name, m.memory_type, m.description, m.project, m.updated_at, m.origin_agent,
                                   CASE
                                     WHEN julianday('now') - julianday(m.updated_at) <= 14 THEN 'Fresh'
                                     WHEN julianday('now') - julianday(m.updated_at) <= 45 THEN 'Recent'
                                     ELSE 'Older'
                                   END AS freshness
                            FROM agent_memories m
                            JOIN agent_memories_fts f ON f.rowid = m.id
                            $where_match
                            ORDER BY
                              CASE
                                WHEN julianday('now') - julianday(m.updated_at) <= 14 THEN 0
                                WHEN julianday('now') - julianday(m.updated_at) <= 45 THEN 1
                                ELSE 2
                              END,
                              m.updated_at DESC,
                              rank
                            LIMIT $limit;")

        if [ -z "$results" ]; then
            eagle_dim "No memories matching '$query'"
            return
        fi

        echo ""
        while IFS='|' read -r mname mtype mdesc mproj mupdated morigin freshness; do
            [ -z "$mname" ] && continue
            echo -e "  ${BOLD}$mname${RESET}  ${DIM}[$mtype][$(eagle_agent_label "$morigin")][$freshness]${RESET}"
            [ "$cross_project" = true ] && echo -e "  ${DIM}project:${RESET} $mproj"
            [ -n "$mdesc" ] && echo -e "  $mdesc"
            echo ""
        done <<< "$results"
        return
    fi

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT memory_name, memory_type, description, project, updated_at, origin_agent
                       FROM agent_memories $where_project
                       ORDER BY updated_at DESC LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT memory_name, memory_type, description, updated_at, origin_agent
                        FROM agent_memories $where_project
                        ORDER BY updated_at DESC LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No memories found"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Memories${RESET} ${DIM}($project_label)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r mname mtype mdesc mupdated morigin; do
        [ -z "$mname" ] && continue
        echo -e "  ${CYAN}[$mtype][$(eagle_agent_label "$morigin")]${RESET} ${BOLD}$mname${RESET}"
        [ -n "$mdesc" ] && echo -e "         ${DIM}$mdesc${RESET}"
    done <<< "$results"
    echo ""
}

# ─── Tasks ───────────────────────────────────────────────

search_tasks() {
    local task_condition bare_task_condition
    task_condition=$(eagle_sql_project_scope_condition "t.project" "$project_scope")
    bare_task_condition=$(eagle_sql_project_scope_condition "project" "$project_scope")

    local where_project=""
    local where_task_project=""
    if [ "$cross_project" = false ]; then
        where_project="AND $bare_task_condition"
        where_task_project="AND $task_condition"
    fi

    if [ -n "$query" ]; then
        local sanitized_tq
        sanitized_tq=$(eagle_fts_sanitize "$query")
        if [ -z "$sanitized_tq" ]; then
            eagle_err "Search query contains no valid search terms"
            exit 1
        fi
        local q; q=$(eagle_sql_escape "$sanitized_tq")

        if [ "$json_output" = true ]; then
            eagle_db_json "SELECT t.subject, t.status, t.project, t.updated_at, t.origin_agent
                           FROM agent_tasks t
                           JOIN agent_tasks_fts f ON f.rowid = t.id
                           WHERE agent_tasks_fts MATCH '$q'
                           $where_task_project
                           ORDER BY rank
                           LIMIT $limit;"
            return
        fi

        local results
        results=$(eagle_db "SELECT t.subject, t.status, t.project, t.updated_at, t.origin_agent
                            FROM agent_tasks t
                            JOIN agent_tasks_fts f ON f.rowid = t.id
                            WHERE agent_tasks_fts MATCH '$q'
                            $where_task_project
                            ORDER BY rank
                            LIMIT $limit;")

        if [ -z "$results" ]; then
            eagle_dim "No tasks matching '$query'"
            return
        fi

        echo ""
        while IFS='|' read -r tsubject tstatus tproj tupdated torigin; do
            [ -z "$tsubject" ] && continue
            local color="$DIM"
            case "$tstatus" in
                in_progress) color="$YELLOW" ;;
                completed) color="$GREEN" ;;
                pending) color="$CYAN" ;;
            esac
            echo -e "  ${color}[$tstatus][$(eagle_agent_label "$torigin")]${RESET} $tsubject"
        done <<< "$results"
        echo ""
        return
    fi

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT subject, status, project, updated_at, origin_agent
                       FROM agent_tasks
                       WHERE status IN ('in_progress', 'pending')
                       $where_project
                       ORDER BY CASE status WHEN 'in_progress' THEN 0 ELSE 1 END, updated_at DESC
                       LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT subject, status, updated_at, origin_agent
                        FROM agent_tasks
                        WHERE status IN ('in_progress', 'pending')
                        $where_project
                        ORDER BY CASE status WHEN 'in_progress' THEN 0 ELSE 1 END, updated_at DESC
                        LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No active tasks for project '$project_label'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Tasks${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r tsubject tstatus tupdated torigin; do
        [ -z "$tsubject" ] && continue
        local color="$DIM"
        case "$tstatus" in
            in_progress) color="$YELLOW" ;;
            pending) color="$CYAN" ;;
        esac
        echo -e "  ${color}[$tstatus][$(eagle_agent_label "$torigin")]${RESET} $tsubject"
    done <<< "$results"
    echo ""
}

# ─── Dispatch ─────────────────────────────────────────────

case "$mode" in
    keyword)
        if [ -z "$query" ]; then
            eagle_err "Usage: eagle-mem search <query>"
            eagle_dim "  Run 'eagle-mem search --help' for options"
            exit 1
        fi
        search_keyword
        ;;
    timeline)    search_timeline ;;
    session)     search_session ;;
    files)       search_files ;;
    stats)       search_stats ;;
    overview)    search_overview ;;
    memories)    search_memories ;;
    tasks)       search_tasks ;;
esac
