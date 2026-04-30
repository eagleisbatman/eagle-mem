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
    echo -e "    eagle-mem search ${CYAN}--memories${RESET}               ${DIM}# mirrored Claude memories${RESET}"
    echo -e "    eagle-mem search ${CYAN}--tasks${RESET}                  ${DIM}# in-flight tasks${RESET}"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    ${CYAN}-p, --project${RESET} <name>    Project name (default: current dir)"
    echo -e "    ${CYAN}-n, --limit${RESET} <N>         Max results (default: 10)"
    echo -e "    ${CYAN}-a, --all${RESET}               Search across all projects"
    echo -e "    ${CYAN}-j, --json${RESET}              Output as JSON"
    echo ""
    exit 0
}

# ─── Parse arguments ──────────────────────────────────────

mode="keyword"
project=""
limit=10
session_id=""
json_output=false
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
        --project|-p)        project="$2"; shift 2 ;;
        --limit|-n)          limit="$2"; shift 2 ;;
        --all|-a)            cross_project=true; shift ;;
        --json|-j)           json_output=true; shift ;;
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
    local p; p=$(eagle_sql_escape "$project")

    local where_project=""
    if [ "$cross_project" = false ]; then
        where_project="AND s.project = '$p'"
    fi

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT s.id, s.project, s.request, s.completed, s.learned, s.created_at
                       FROM summaries s
                       JOIN summaries_fts f ON f.rowid = s.id
                       WHERE summaries_fts MATCH '$q'
                       $where_project
                       ORDER BY rank
                       LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT s.id, s.project, s.request, s.completed, s.learned, s.created_at
                        FROM summaries s
                        JOIN summaries_fts f ON f.rowid = s.id
                        WHERE summaries_fts MATCH '$q'
                        $where_project
                        ORDER BY rank
                        LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No results for '$query'"
        return
    fi

    echo ""
    while IFS='|' read -r sid sproj req completed learned created_at; do
        [ -z "$sid" ] && continue
        echo -e "  ${BOLD}#$sid${RESET}  ${DIM}$created_at${RESET}"
        if [ "$cross_project" = true ]; then
            echo -e "  ${DIM}project:${RESET} $sproj"
        fi
        [ -n "$req" ] && echo -e "  ${CYAN}Request:${RESET} $req"
        [ -n "$completed" ] && echo -e "  ${GREEN}Done:${RESET} $completed"
        [ -n "$learned" ] && echo -e "  ${YELLOW}Learned:${RESET} $learned"
        echo ""
    done <<< "$results"
}

# ─── Timeline ────────────────────────────────────────────

search_timeline() {
    local p; p=$(eagle_sql_escape "$project")

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT s.id, s.request, s.completed, s.learned, s.next_steps, s.created_at
                       FROM summaries s
                       WHERE s.project = '$p'
                       ORDER BY s.created_at DESC
                       LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT s.id, s.request, s.completed, s.learned, s.next_steps, s.created_at
                        FROM summaries s
                        WHERE s.project = '$p'
                        ORDER BY s.created_at DESC
                        LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No sessions found for project '$project'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Recent sessions${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r sid req completed learned next_steps created_at; do
        [ -z "$sid" ] && continue
        echo -e "  ${BOLD}#$sid${RESET}  ${DIM}$created_at${RESET}"
        [ -n "$req" ] && echo -e "  ${CYAN}Request:${RESET} $req"
        [ -n "$completed" ] && echo -e "  ${GREEN}Done:${RESET} $completed"
        [ -n "$learned" ] && echo -e "  ${YELLOW}Learned:${RESET} $learned"
        [ -n "$next_steps" ] && echo -e "  ${DIM}Next:${RESET} $next_steps"
        echo ""
    done <<< "$results"
}

# ─── Session details ──────────────────────────────────────

search_session() {
    local sid_sql; sid_sql=$(eagle_sql_escape "$session_id")

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT o.tool_name, o.tool_input_summary, o.files_read, o.files_modified, o.created_at
                       FROM observations o
                       WHERE o.session_id = '$sid_sql'
                       ORDER BY o.created_at ASC;"
        return
    fi

    local results
    results=$(eagle_db "SELECT o.tool_name, o.tool_input_summary, o.files_read, o.files_modified, o.created_at
                        FROM observations o
                        WHERE o.session_id = '$sid_sql'
                        ORDER BY o.created_at ASC;")

    if [ -z "$results" ]; then
        eagle_dim "No observations found for session '$session_id'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Session${RESET} ${DIM}$session_id${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r tool_name summary files_r files_m created_at; do
        [ -z "$tool_name" ] && continue
        local icon="$DOT"
        case "$tool_name" in
            Read) icon="${CYAN}R${RESET}" ;;
            Write) icon="${GREEN}W${RESET}" ;;
            Edit) icon="${YELLOW}E${RESET}" ;;
            Bash) icon="${BLUE}\$${RESET}" ;;
        esac
        echo -e "  ${icon}  ${DIM}$created_at${RESET}  $summary"
    done <<< "$results"
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
    local p; p=$(eagle_sql_escape "$project")

    local sessions summaries observations tasks
    sessions=$(eagle_db "SELECT COUNT(*) FROM sessions WHERE project = '$p';")
    summaries=$(eagle_db "SELECT COUNT(*) FROM summaries WHERE project = '$p';")
    observations=$(eagle_db "SELECT COUNT(*) FROM observations o JOIN sessions s ON s.id = o.session_id WHERE s.project = '$p';")
    tasks=$(eagle_db "SELECT COUNT(*) FROM claude_tasks WHERE project = '$p';")
    local chunks
    chunks=$(eagle_db "SELECT COUNT(*) FROM code_chunks WHERE project = '$p';")

    if [ "$json_output" = true ]; then
        jq -nc --arg project "$project" \
            --argjson sessions "${sessions:-0}" \
            --argjson summaries "${summaries:-0}" \
            --argjson observations "${observations:-0}" \
            --argjson tasks "${tasks:-0}" \
            --argjson code_chunks "${chunks:-0}" \
            '{project: $project, sessions: $sessions, summaries: $summaries, observations: $observations, tasks: $tasks, code_chunks: $code_chunks}'
        return
    fi

    echo ""
    echo -e "  ${BOLD}Stats${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""
    eagle_kv "Sessions:" "${sessions:-0}"
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
    local p; p=$(eagle_sql_escape "$project")

    local where_project=""
    if [ "$cross_project" = false ]; then
        where_project="WHERE project = '$p'"
    fi

    if [ -n "$query" ]; then
        local sanitized_mq
        sanitized_mq=$(eagle_fts_sanitize "$query")
        if [ -z "$sanitized_mq" ]; then
            eagle_err "Search query contains no valid search terms"
            exit 1
        fi
        local q; q=$(eagle_sql_escape "$sanitized_mq")
        local where_match="WHERE claude_memories_fts MATCH '$q'"
        if [ "$cross_project" = false ]; then
            where_match="$where_match AND m.project = '$p'"
        fi

        if [ "$json_output" = true ]; then
            eagle_db_json "SELECT m.memory_name, m.memory_type, m.description, m.project, m.updated_at
                           FROM claude_memories m
                           JOIN claude_memories_fts f ON f.rowid = m.id
                           $where_match
                           ORDER BY rank
                           LIMIT $limit;"
            return
        fi

        local results
        results=$(eagle_db "SELECT m.memory_name, m.memory_type, m.description, m.project, m.updated_at
                            FROM claude_memories m
                            JOIN claude_memories_fts f ON f.rowid = m.id
                            $where_match
                            ORDER BY rank
                            LIMIT $limit;")

        if [ -z "$results" ]; then
            eagle_dim "No memories matching '$query'"
            return
        fi

        echo ""
        while IFS='|' read -r mname mtype mdesc mproj mupdated; do
            [ -z "$mname" ] && continue
            echo -e "  ${BOLD}$mname${RESET}  ${DIM}[$mtype]${RESET}"
            [ "$cross_project" = true ] && echo -e "  ${DIM}project:${RESET} $mproj"
            [ -n "$mdesc" ] && echo -e "  $mdesc"
            echo ""
        done <<< "$results"
        return
    fi

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT memory_name, memory_type, description, project, updated_at
                       FROM claude_memories $where_project
                       ORDER BY updated_at DESC LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT memory_name, memory_type, description, updated_at
                        FROM claude_memories $where_project
                        ORDER BY updated_at DESC LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No memories found"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Memories${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r mname mtype mdesc mupdated; do
        [ -z "$mname" ] && continue
        echo -e "  ${CYAN}[$mtype]${RESET} ${BOLD}$mname${RESET}"
        [ -n "$mdesc" ] && echo -e "         ${DIM}$mdesc${RESET}"
    done <<< "$results"
    echo ""
}

# ─── Tasks ───────────────────────────────────────────────

search_tasks() {
    local p; p=$(eagle_sql_escape "$project")

    local where_project=""
    if [ "$cross_project" = false ]; then
        where_project="AND project = '$p'"
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
            eagle_db_json "SELECT t.subject, t.status, t.project, t.updated_at
                           FROM claude_tasks t
                           JOIN claude_tasks_fts f ON f.rowid = t.id
                           WHERE claude_tasks_fts MATCH '$q'
                           ${where_project/AND/AND t.}
                           ORDER BY rank
                           LIMIT $limit;"
            return
        fi

        local results
        results=$(eagle_db "SELECT t.subject, t.status, t.project, t.updated_at
                            FROM claude_tasks t
                            JOIN claude_tasks_fts f ON f.rowid = t.id
                            WHERE claude_tasks_fts MATCH '$q'
                            ${where_project/AND/AND t.}
                            ORDER BY rank
                            LIMIT $limit;")

        if [ -z "$results" ]; then
            eagle_dim "No tasks matching '$query'"
            return
        fi

        echo ""
        while IFS='|' read -r tsubject tstatus tproj tupdated; do
            [ -z "$tsubject" ] && continue
            local color="$DIM"
            case "$tstatus" in
                in_progress) color="$YELLOW" ;;
                completed) color="$GREEN" ;;
                pending) color="$CYAN" ;;
            esac
            echo -e "  ${color}[$tstatus]${RESET} $tsubject"
        done <<< "$results"
        echo ""
        return
    fi

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT subject, status, project, updated_at
                       FROM claude_tasks
                       WHERE status IN ('in_progress', 'pending')
                       $where_project
                       ORDER BY CASE status WHEN 'in_progress' THEN 0 ELSE 1 END, updated_at DESC
                       LIMIT $limit;"
        return
    fi

    local results
    results=$(eagle_db "SELECT subject, status, updated_at
                        FROM claude_tasks
                        WHERE status IN ('in_progress', 'pending')
                        $where_project
                        ORDER BY CASE status WHEN 'in_progress' THEN 0 ELSE 1 END, updated_at DESC
                        LIMIT $limit;")

    if [ -z "$results" ]; then
        eagle_dim "No active tasks for project '$project'"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Tasks${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    echo ""

    while IFS='|' read -r tsubject tstatus tupdated; do
        [ -z "$tsubject" ] && continue
        local color="$DIM"
        case "$tstatus" in
            in_progress) color="$YELLOW" ;;
            pending) color="$CYAN" ;;
        esac
        echo -e "  ${color}[$tstatus]${RESET} $tsubject"
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
