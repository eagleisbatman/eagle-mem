#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Claude Code Memory Mirror CLI
# List, show, search, and sync Claude Code auto-memories
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

# ─── Parse arguments ──────────────────────────────────────

action="${1:-list}"
shift 2>/dev/null || true

project=""
limit=20
query=""

show_help() {
    echo -e "  ${BOLD}eagle-mem memories${RESET} — Claude Code memory, plan & task mirror"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem memories                          ${DIM}# list all mirrored memories${RESET}"
    echo -e "    eagle-mem memories list                     ${DIM}# same as above${RESET}"
    echo -e "    eagle-mem memories search ${CYAN}<query>${RESET}           ${DIM}# full-text search memories${RESET}"
    echo -e "    eagle-mem memories show ${CYAN}<file_path>${RESET}         ${DIM}# show a specific memory${RESET}"
    echo -e "    eagle-mem memories plans                    ${DIM}# list captured plans${RESET}"
    echo -e "    eagle-mem memories plans search ${CYAN}<query>${RESET}     ${DIM}# full-text search plans${RESET}"
    echo -e "    eagle-mem memories plans show ${CYAN}<file_path>${RESET}   ${DIM}# show a specific plan${RESET}"
    echo -e "    eagle-mem memories tasks                    ${DIM}# list captured tasks${RESET}"
    echo -e "    eagle-mem memories tasks search ${CYAN}<query>${RESET}     ${DIM}# full-text search tasks${RESET}"
    echo -e "    eagle-mem memories tasks show ${CYAN}<file_path>${RESET}   ${DIM}# show a specific task${RESET}"
    echo -e "    eagle-mem memories sync                     ${DIM}# backfill memories + plans + tasks${RESET}"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    ${CYAN}-p, --project${RESET} <name>  Filter by project"
    echo -e "    ${CYAN}-l, --limit${RESET} <N>       Max results (default: 20)"
    echo ""
    echo -e "  ${BOLD}How it works:${RESET}"
    echo -e "    ${DOT} Eagle Mem intercepts Claude Code's auto-memory, plan, and task writes"
    echo -e "    ${DOT} All are mirrored into Eagle Mem's SQLite + FTS5"
    echo -e "    ${DOT} Use ${CYAN}sync${RESET} to backfill items written before mirroring was enabled"
    echo ""
    exit 0
}

plan_action=""
task_action=""

case "$action" in
    --help|-h) show_help ;;
    plans)
        plan_action="${1:-list}"
        shift 2>/dev/null || true
        ;;
    tasks)
        task_action="${1:-list}"
        shift 2>/dev/null || true
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --project|-p)   project="$2"; shift 2 ;;
        --limit|-l)     limit="$2"; shift 2 ;;
        --help|-h)      show_help ;;
        *)
            if [ -z "$query" ]; then
                query="$1"; shift
            else
                eagle_err "Unknown option: $1"
                exit 1
            fi
            ;;
    esac
done

# ─── Actions ─────────────────────────────────────────────

memories_list() {
    eagle_header "Memories"

    local result
    result=$(eagle_list_claude_memories "$project" "$limit")

    if [ -z "$result" ]; then
        eagle_dim "No mirrored memories found."
        echo ""
        eagle_dim "Memories are captured automatically when Claude Code writes to its auto-memory."
        eagle_dim "Run 'eagle-mem memories sync' to backfill existing memories."
        echo ""
        return
    fi

    local count=0
    while IFS='|' read -r name mtype desc _fp updated; do
        [ -z "$name" ] && continue
        count=$((count + 1))

        local type_color="$DIM"
        case "$mtype" in
            user)      type_color="$CYAN" ;;
            feedback)  type_color="$YELLOW" ;;
            project)   type_color="$GREEN" ;;
            reference) type_color="$BLUE" ;;
        esac

        echo -e "  ${BOLD}${name}${RESET}  ${type_color}[${mtype}]${RESET}"
        [ -n "$desc" ] && echo -e "    ${DIM}${desc}${RESET}"
        echo -e "    ${DIM}updated: ${updated}${RESET}"
        echo ""
    done <<< "$result"

    eagle_dim "$count memories shown"
    echo ""
}

memories_search() {
    if [ -z "$query" ]; then
        eagle_err "Usage: eagle-mem memories search <query>"
        exit 1
    fi

    eagle_header "Memory Search"
    eagle_info "Query: $query"
    echo ""

    local result
    result=$(eagle_search_claude_memories "$query" "$project" "$limit")

    if [ -z "$result" ]; then
        eagle_dim "No memories matching '$query'"
        echo ""
        return
    fi

    local count=0
    while IFS='|' read -r name mtype desc content _fp updated; do
        [ -z "$name" ] && continue
        count=$((count + 1))

        local type_color="$DIM"
        case "$mtype" in
            user)      type_color="$CYAN" ;;
            feedback)  type_color="$YELLOW" ;;
            project)   type_color="$GREEN" ;;
            reference) type_color="$BLUE" ;;
        esac

        echo -e "  ${BOLD}${name}${RESET}  ${type_color}[${mtype}]${RESET}"
        [ -n "$desc" ] && echo -e "    ${DIM}${desc}${RESET}"
        local snippet
        snippet=$(printf '%s' "$content" | head -c 200)
        [ -n "$snippet" ] && echo -e "    ${snippet}"
        echo -e "    ${DIM}updated: ${updated}${RESET}"
        echo ""
    done <<< "$result"

    eagle_dim "$count results"
    echo ""
}

memories_show() {
    if [ -z "$query" ]; then
        eagle_err "Usage: eagle-mem memories show <file_path>"
        exit 1
    fi

    local meta
    meta=$(eagle_db "SELECT memory_name, memory_type, description, file_path, updated_at, origin_session_id
                     FROM claude_memories WHERE file_path = '$(eagle_sql_escape "$query")';")

    if [ -z "$meta" ]; then
        eagle_err "Memory not found: $query"
        exit 1
    fi

    IFS='|' read -r name mtype desc fp updated origin <<< "$meta"

    eagle_header "Memory Detail"

    eagle_kv "Name:" "$name"
    eagle_kv "Type:" "$mtype"
    eagle_kv "File:" "$fp"
    eagle_kv "Updated:" "$updated"
    [ -n "$origin" ] && eagle_kv "Session:" "$origin"
    echo ""

    [ -n "$desc" ] && echo -e "  ${BOLD}Description:${RESET} $desc"
    echo ""

    if [ -f "$fp" ]; then
        echo -e "  ${BOLD}Content:${RESET}"
        awk '/^---$/{c++; next} c>=2' "$fp" | while IFS= read -r line; do
            echo "    $line"
        done
    else
        eagle_dim "Source file no longer exists on disk."
    fi
    echo ""
}

plans_list() {
    eagle_header "Plans"

    local result
    result=$(eagle_list_claude_plans "$project" "$limit")

    if [ -z "$result" ]; then
        eagle_dim "No captured plans found."
        echo ""
        eagle_dim "Plans are captured when Claude Code writes to ~/.claude/plans/"
        eagle_dim "Run 'eagle-mem memories sync' to backfill existing plans."
        echo ""
        return
    fi

    local count=0
    while IFS='|' read -r title proj _fp updated; do
        [ -z "$title" ] && continue
        count=$((count + 1))

        local proj_label=""
        [ -n "$proj" ] && proj_label="  ${DIM}[${proj}]${RESET}"

        echo -e "  ${BOLD}${title}${RESET}${proj_label}"
        echo -e "    ${DIM}updated: ${updated}${RESET}"
        echo ""
    done <<< "$result"

    eagle_dim "$count plans shown"
    echo ""
}

plans_search() {
    if [ -z "$query" ]; then
        eagle_err "Usage: eagle-mem memories plans search <query>"
        exit 1
    fi

    eagle_header "Plan Search"
    eagle_info "Query: $query"
    echo ""

    local result
    result=$(eagle_search_claude_plans "$query" "$project" "$limit")

    if [ -z "$result" ]; then
        eagle_dim "No plans matching '$query'"
        echo ""
        return
    fi

    local count=0
    while IFS='|' read -r title proj snippet _fp updated; do
        [ -z "$title" ] && continue
        count=$((count + 1))

        local proj_label=""
        [ -n "$proj" ] && proj_label="  ${DIM}[${proj}]${RESET}"

        echo -e "  ${BOLD}${title}${RESET}${proj_label}"
        [ -n "$snippet" ] && echo -e "    ${snippet}"
        echo -e "    ${DIM}updated: ${updated}${RESET}"
        echo ""
    done <<< "$result"

    eagle_dim "$count results"
    echo ""
}

plans_show() {
    if [ -z "$query" ]; then
        eagle_err "Usage: eagle-mem memories plans show <file_path>"
        exit 1
    fi

    local meta
    meta=$(eagle_db "SELECT title, project, file_path, updated_at, origin_session_id
                     FROM claude_plans WHERE file_path = '$(eagle_sql_escape "$query")';")

    if [ -z "$meta" ]; then
        eagle_err "Plan not found: $query"
        exit 1
    fi

    IFS='|' read -r title proj fp updated origin <<< "$meta"

    eagle_header "Plan Detail"

    eagle_kv "Title:" "$title"
    [ -n "$proj" ] && eagle_kv "Project:" "$proj"
    eagle_kv "File:" "$fp"
    eagle_kv "Updated:" "$updated"
    [ -n "$origin" ] && eagle_kv "Session:" "$origin"
    echo ""

    if [ -f "$fp" ]; then
        echo -e "  ${BOLD}Content:${RESET}"
        cat "$fp" | while IFS= read -r line; do
            echo "    $line"
        done
    else
        eagle_dim "Source file no longer exists on disk."
    fi
    echo ""
}

tasks_list() {
    eagle_header "Claude Code Tasks"

    local result
    result=$(eagle_list_claude_tasks "$project" "$limit")

    if [ -z "$result" ]; then
        eagle_dim "No captured tasks found."
        echo ""
        eagle_dim "Tasks are captured when Claude Code uses TaskCreate/TaskUpdate."
        eagle_dim "Run 'eagle-mem memories sync' to backfill existing tasks."
        echo ""
        return
    fi

    local count=0
    while IFS='|' read -r subject status sid tid updated; do
        [ -z "$subject" ] && continue
        count=$((count + 1))

        local status_color="$DIM"
        case "$status" in
            pending)     status_color="$DIM" ;;
            in_progress) status_color="$CYAN" ;;
            completed)   status_color="$GREEN" ;;
        esac

        echo -e "  ${BOLD}${subject}${RESET}  ${status_color}[${status}]${RESET}"
        echo -e "    ${DIM}session: ${sid:0:8}…  task: #${tid}  updated: ${updated}${RESET}"
        echo ""
    done <<< "$result"

    eagle_dim "$count tasks shown"
    echo ""
}

tasks_search() {
    if [ -z "$query" ]; then
        eagle_err "Usage: eagle-mem memories tasks search <query>"
        exit 1
    fi

    eagle_header "Task Search"
    eagle_info "Query: $query"
    echo ""

    local result
    result=$(eagle_search_claude_tasks "$query" "$project" "$limit")

    if [ -z "$result" ]; then
        eagle_dim "No tasks matching '$query'"
        echo ""
        return
    fi

    local count=0
    while IFS='|' read -r subject status desc sid tid updated; do
        [ -z "$subject" ] && continue
        count=$((count + 1))

        local status_color="$DIM"
        case "$status" in
            pending)     status_color="$DIM" ;;
            in_progress) status_color="$CYAN" ;;
            completed)   status_color="$GREEN" ;;
        esac

        echo -e "  ${BOLD}${subject}${RESET}  ${status_color}[${status}]${RESET}"
        [ -n "$desc" ] && echo -e "    ${desc}"
        echo -e "    ${DIM}session: ${sid:0:8}…  task: #${tid}  updated: ${updated}${RESET}"
        echo ""
    done <<< "$result"

    eagle_dim "$count results"
    echo ""
}

tasks_show() {
    if [ -z "$query" ]; then
        eagle_err "Usage: eagle-mem memories tasks show <file_path>"
        exit 1
    fi

    local meta
    meta=$(eagle_db "SELECT subject, status, description, active_form, source_session_id, source_task_id, file_path, updated_at
                     FROM claude_tasks WHERE file_path = '$(eagle_sql_escape "$query")';")

    if [ -z "$meta" ]; then
        eagle_err "Task not found: $query"
        exit 1
    fi

    IFS='|' read -r subject status desc af sid tid fp updated <<< "$meta"

    eagle_header "Task Detail"

    eagle_kv "Subject:" "$subject"
    eagle_kv "Status:" "$status"
    eagle_kv "Task ID:" "$tid"
    eagle_kv "Session:" "$sid"
    eagle_kv "File:" "$fp"
    eagle_kv "Updated:" "$updated"
    echo ""

    [ -n "$desc" ] && echo -e "  ${BOLD}Description:${RESET} $desc" && echo ""
    [ -n "$af" ] && echo -e "  ${BOLD}Active Form:${RESET} $af" && echo ""

    if [ -f "$fp" ]; then
        echo -e "  ${BOLD}Raw JSON:${RESET}"
        jq '.' "$fp" 2>/dev/null | while IFS= read -r line; do
            echo "    $line"
        done
    else
        eagle_dim "Source file no longer exists on disk."
    fi
    echo ""
}

memories_sync() {
    eagle_header "Memory, Plan & Task Sync"

    # ─── Sync memories ───────────────────────────────────
    eagle_info "Scanning for Claude Code auto-memory files..."
    echo ""

    local claude_mem_root="$EAGLE_CLAUDE_PROJECTS_DIR"
    local mem_synced=0
    local mem_skipped=0

    if [ -d "$claude_mem_root" ]; then
        while IFS= read -r -d '' memfile; do
            local base
            base=$(basename "$memfile")
            [ "$base" = "MEMORY.md" ] && continue

            local existing_hash
            existing_hash=$(eagle_db "SELECT content_hash FROM claude_memories WHERE file_path = '$(eagle_sql_escape "$memfile")';")
            local new_hash
            new_hash=$(shasum -a 256 "$memfile" | awk '{print $1}')

            if [ "$existing_hash" = "$new_hash" ]; then
                mem_skipped=$((mem_skipped + 1))
                continue
            fi

            eagle_capture_claude_memory "$memfile" "" ""
            mem_synced=$((mem_synced + 1))
            eagle_ok "Memory: $base"
        done < <(find "$claude_mem_root" -path "*/memory/*.md" -print0 2>/dev/null)
    fi

    eagle_kv "Memories:" "$mem_synced synced, $mem_skipped unchanged"
    echo ""

    # ─── Sync plans ──────────────────────────────────────
    eagle_info "Scanning for Claude Code plan files..."
    echo ""

    local plans_dir="$EAGLE_CLAUDE_PLANS_DIR"
    local plan_synced=0
    local plan_skipped=0

    if [ -d "$plans_dir" ]; then
        for planfile in "$plans_dir"/*.md; do
            [ ! -f "$planfile" ] && continue

            local existing_hash
            existing_hash=$(eagle_db "SELECT content_hash FROM claude_plans WHERE file_path = '$(eagle_sql_escape "$planfile")';")
            local new_hash
            new_hash=$(shasum -a 256 "$planfile" | awk '{print $1}')

            if [ "$existing_hash" = "$new_hash" ]; then
                plan_skipped=$((plan_skipped + 1))
                continue
            fi

            eagle_capture_claude_plan "$planfile" "" ""
            plan_synced=$((plan_synced + 1))
            local ptitle
            ptitle=$(awk '/^# /{print; exit}' "$planfile" | sed 's/^# //')
            eagle_ok "Plan: $ptitle"
        done
    fi

    eagle_kv "Plans:" "$plan_synced synced, $plan_skipped unchanged"
    echo ""

    # ─── Sync tasks ──────────────────────────────────────
    eagle_info "Scanning for Claude Code task files..."
    echo ""

    local tasks_dir="$EAGLE_CLAUDE_TASKS_DIR"
    local task_synced=0
    local task_skipped=0

    if [ -d "$tasks_dir" ]; then
        for session_dir in "$tasks_dir"/*/; do
            [ ! -d "$session_dir" ] && continue
            local sid
            sid=$(basename "$session_dir")

            local task_project=""
            task_project=$(eagle_db "SELECT project FROM sessions WHERE id = '$(eagle_sql_escape "$sid")' LIMIT 1;")

            for taskfile in "$session_dir"*.json; do
                [ ! -f "$taskfile" ] && continue

                local existing_hash
                existing_hash=$(eagle_db "SELECT content_hash FROM claude_tasks WHERE file_path = '$(eagle_sql_escape "$taskfile")';")
                local new_hash
                new_hash=$(shasum -a 256 "$taskfile" | awk '{print $1}')

                if [ "$existing_hash" = "$new_hash" ]; then
                    task_skipped=$((task_skipped + 1))
                    continue
                fi

                eagle_capture_claude_task "$taskfile" "$sid" "$task_project"
                task_synced=$((task_synced + 1))
            done
        done
    fi

    eagle_kv "Tasks:" "$task_synced synced, $task_skipped unchanged"
    echo ""

    # ─── Backfill project names ──────────────────────────
    eagle_info "Resolving project names from Claude Code transcripts..."

    local backfilled
    backfilled=$(eagle_backfill_projects)
    if [ "${backfilled:-0}" -gt 0 ]; then
        eagle_ok "$backfilled rows updated with correct project names"
    else
        eagle_ok "All project names up to date"
    fi

    eagle_footer "Sync complete."
}

# ─── Dispatch ────────────────────────────────────────────

case "$action" in
    list)    memories_list ;;
    search)  memories_search ;;
    show)    memories_show ;;
    plans)
        case "$plan_action" in
            list)    plans_list ;;
            search)  plans_search ;;
            show)    plans_show ;;
            *)       plans_list ;;
        esac
        ;;
    tasks)
        case "$task_action" in
            list)    tasks_list ;;
            search)  tasks_search ;;
            show)    tasks_show ;;
            *)       tasks_list ;;
        esac
        ;;
    sync)    memories_sync ;;
    *)
        eagle_err "Unknown action: $action"
        echo -e "  ${DIM}Available: list, search, show, plans, tasks, sync${RESET}"
        exit 1
        ;;
esac
