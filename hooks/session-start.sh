#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — SessionStart hook
# Fires on: startup, resume, clear, compact
# Injects project memory + pending tasks into Claude's context
# ═══════════════════════════════════════════════════════════
set +e
[ "${EAGLE_MEM_DISABLE_HOOKS:-}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/provider.sh"
. "$LIB_DIR/updater.sh"
. "$LIB_DIR/hooks-sessionstart.sh"

eagle_ensure_db

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
source_type=$(echo "$input" | jq -r '.source // empty')
model=$(echo "$input" | jq -r '.model // empty')
agent=$(eagle_agent_source_from_json "$input")
agent_label=$(eagle_agent_label "$agent")
codex_compact=0
[ "$agent" = "codex" ] && codex_compact=1

[ -z "$session_id" ] && exit 0

project=$(eagle_project_from_hook_input "$input")
[ -z "$project" ] && exit 0

p_esc=$(eagle_sql_escape "$project")
recall_scope=$(eagle_recall_project_scope_from_cwd "$cwd" "$project")
[ -z "$recall_scope" ] && recall_scope="$project"
recall_scope_label=$(eagle_project_scope_label "$recall_scope")
recall_project_filter=$(eagle_sql_project_scope_condition "project" "$recall_scope")
recall_memory_filter=$(eagle_sql_project_scope_condition "m.project" "$recall_scope")
recall_lane_filter=$(eagle_sql_project_scope_condition "l.project" "$recall_scope")

eagle_log "INFO" "SessionStart: session=$session_id project=$project source=$source_type agent=$agent"

eagle_upsert_session "$session_id" "$project" "$cwd" "$model" "$source_type" "$agent"
eagle_abandon_stale_sessions "$session_id"

# ─── Reset turn counter on compact/clear ─────────────────

case "$source_type" in
    compact|clear)
        echo "0" > "$EAGLE_MEM_DIR/.turn-counter.${session_id}" 2>/dev/null
        rm -f "$EAGLE_MEM_DIR/.context-pressure" 2>/dev/null
        ;;
    startup)
        echo "0" > "$EAGLE_MEM_DIR/.turn-counter.${session_id}" 2>/dev/null
        ;;
esac

# ─── Background automation (non-blocking) ────────────────

eagle_sessionstart_auto_provision "$project" "$cwd" "$SCRIPTS_DIR"
eagle_sessionstart_auto_prune "$project" "$SCRIPTS_DIR" "$(eagle_db "SELECT COUNT(*) FROM observations WHERE session_id IN (SELECT id FROM sessions WHERE project='$p_esc');")"
eagle_sessionstart_auto_curate "$project" "$SCRIPTS_DIR"
nohup bash "$SCRIPTS_DIR/updates.sh" auto >> "$EAGLE_MEM_LOG" 2>&1 &

find "$EAGLE_MEM_DIR/read-tracker" -type f -mtime +1 -delete 2>/dev/null &
find "$EAGLE_MEM_DIR/mod-tracker" -type f -mtime +1 -delete 2>/dev/null &
find "$EAGLE_MEM_DIR/edit-tracker" -type f -mtime +1 -delete 2>/dev/null &
find "$EAGLE_MEM_DIR" -name ".turn-counter.*" -mtime +1 -delete 2>/dev/null &

# ─── Update notice from previous background run ────────────

update_notice=$(eagle_update_take_notice)

# ─── Gather stats ────────────────────────────────────────

stat_sessions=0; stat_sessions_claude=0; stat_sessions_codex=0
stat_summaries=0; stat_with_summaries=0; stat_memories=0
stat_tasks_pending=0; stat_tasks_progress=0; stat_tasks_done=0
stat_chunks=0; stat_observations=0; stat_plans=0
stat_last_active="never"; stat_last_summary=""

while IFS='|' read -r key val; do
    case "$key" in
        sessions)        stat_sessions="$val" ;;
        sessions_claude) stat_sessions_claude="$val" ;;
        sessions_codex)  stat_sessions_codex="$val" ;;
        summaries)       stat_summaries="$val" ;;
        with_summaries)  stat_with_summaries="$val" ;;
        memories)        stat_memories="$val" ;;
        plans)           stat_plans="$val" ;;
        tasks_pending)   stat_tasks_pending="$val" ;;
        tasks_progress)  stat_tasks_progress="$val" ;;
        tasks_done)      stat_tasks_done="$val" ;;
        chunks)          stat_chunks="$val" ;;
        observations)    stat_observations="$val" ;;
        last_active)     stat_last_active="$val" ;;
        last_summary)    stat_last_summary="$val" ;;
    esac
done <<< "$(eagle_get_project_stats "$recall_scope")"

# ─── Build compressed banner (elide zero-value lines) ────

task_parts=""
[ "$stat_tasks_progress" -gt 0 ] && task_parts="${stat_tasks_progress} in progress"
if [ "$stat_tasks_pending" -gt 0 ]; then
    [ -n "$task_parts" ] && task_parts+=", "
    task_parts+="${stat_tasks_pending} pending"
fi
if [ "$stat_tasks_done" -gt 0 ]; then
    [ -n "$task_parts" ] && task_parts+=", "
    task_parts+="${stat_tasks_done} completed"
fi

stat_last_display=$(eagle_trim_text "$stat_last_summary" 60)

eagle_banner="======================================
       Eagle Mem Recall Ready
======================================
 Project      | $project
 Agent        | $agent_label
 Sessions     | $stat_sessions ($stat_with_summaries with summaries)"
if [ "$recall_scope_label" != "$project" ]; then
    eagle_banner+="
 Recall Scope | $recall_scope_label"
fi
if [ "$stat_sessions_codex" -gt 0 ] || [ "$stat_sessions_claude" -gt 0 ]; then
    eagle_banner+="
 Sources      | Claude $stat_sessions_claude, Codex $stat_sessions_codex"
fi
[ "$stat_memories" -gt 0 ] && eagle_banner+="
 Memories     | $stat_memories stored"
[ "$stat_plans" -gt 0 ] && eagle_banner+="
 Plans        | $stat_plans saved"
[ -n "$task_parts" ] && eagle_banner+="
 Tasks        | $task_parts"
[ "$stat_chunks" -gt 0 ] && eagle_banner+="
 Code Index   | $stat_chunks chunks"
[ -n "$stat_last_display" ] && eagle_banner+="
 Last Work    | $stat_last_display"
eagle_banner+="
======================================"

context="$eagle_banner
Eagle Mem recalls: use the project memory below before making design or implementation claims. If it affects your answer, mention the recall in one short attribution line.
"

if [ "$codex_compact" -eq 1 ]; then
    codex_context="Eagle Mem Recall Ready
Project: $project | Agent: $agent_label
Memory: $stat_sessions sessions"
    if [ "$recall_scope_label" != "$project" ]; then
        codex_context="Eagle Mem Recall Ready
Project: $project | Recall: $recall_scope_label | Agent: $agent_label
Memory: $stat_sessions sessions"
    fi
    [ "$stat_with_summaries" -gt 0 ] && codex_context+=", $stat_with_summaries summarized"
    [ "$stat_memories" -gt 0 ] && codex_context+=", $stat_memories memories"
    [ "$stat_chunks" -gt 0 ] && codex_context+=", $stat_chunks code chunks"
    codex_context+="
"

    if [ -n "$update_notice" ]; then
        codex_context+="
Update: $(eagle_trim_text "$update_notice" 180)
"
    fi

    if [ "${stat_with_summaries:-0}" -eq 0 ] 2>/dev/null; then
        codex_context+="
Capture: Codex hooks are active. Eagle Mem will summarize decisions and gotchas from the transcript automatically.
"
    fi

    overview=$(eagle_get_overview "$project")
    if [ -n "$overview" ]; then
        codex_context+="
Project brief: $(eagle_trim_text "$overview" 260)
"
    else
        codex_context+="
Project brief: no overview yet; background scan is running.
"
    fi

    recent=$(eagle_get_recent_summaries "$recall_scope" 1)
    if [ -n "$recent" ]; then
        codex_context+="
Relevant now:
"
        while IFS='|' read -r request completed learned _next_steps created_at _decisions gotchas _key_files summary_agent; do
            [ -z "$request" ] && [ -z "$completed" ] && continue
            summary_agent_label=$(eagle_agent_label "$summary_agent")
            recent_line="$completed"
            [ -z "$recent_line" ] && recent_line="$request"
            codex_context+="- Recent [$summary_agent_label]: $(eagle_trim_text "$recent_line" 180)
"
            [ -n "$learned" ] && codex_context+="  Learned: $(eagle_trim_text "$learned" 140)
"
            [ -n "$gotchas" ] && codex_context+="  Watch: $(eagle_trim_text "$gotchas" 120)
"
        done <<< "$recent"
    fi

    memories=$(eagle_db "SELECT memory_name, memory_type, description, origin_agent,
        CAST(julianday('now') - julianday(updated_at) AS INTEGER) as days_ago
        FROM agent_memories
        WHERE $recall_project_filter
        AND memory_name NOT IN ('Codex Memory Registry', 'Codex Memory Summary')
        ORDER BY
            CASE
                WHEN lower(memory_name) LIKE 'current status%' THEN 4
                WHEN memory_type = 'project' THEN 0
                WHEN memory_type = 'feedback' THEN 1
                WHEN memory_type IN ('user', 'reference') THEN 2
                ELSE 3
            END,
            updated_at DESC
        LIMIT 4;")
    if [ -n "$memories" ]; then
        [ -z "$recent" ] && codex_context+="
Relevant now:
"
        while IFS='|' read -r mname mtype mdesc morigin days_ago; do
            [ -z "$mname" ] && continue
            origin_label=$(eagle_agent_label "$morigin")
            age_label="fresh"
            if [ -n "$days_ago" ] && [ "$days_ago" -gt 14 ] 2>/dev/null; then
                age_label="older"
            elif [ -n "$days_ago" ] && [ "$days_ago" -gt 0 ] 2>/dev/null; then
                age_label="${days_ago}d old"
            fi
            codex_context+="- Memory [$mtype][$origin_label][$age_label]: $mname"
            [ -n "$mdesc" ] && codex_context+=" — $(eagle_trim_text "$mdesc" 120)"
            codex_context+="
"
        done <<< "$memories"
    fi

    synced_tasks=$(eagle_db "SELECT subject, status, blocked_by, origin_agent FROM agent_tasks
        WHERE $recall_project_filter
        AND status IN ('in_progress', 'pending')
        AND source_session_id != 'orchestration'
        AND updated_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-7 days')
        ORDER BY CASE status WHEN 'in_progress' THEN 0 ELSE 1 END, updated_at DESC
        LIMIT 3;")
    orchestration_lanes=$(eagle_db "SELECT o.name, l.lane_key, l.title, l.agent, l.status
        FROM orchestration_lanes l
        JOIN orchestrations o ON o.id = l.orchestration_id
        WHERE $recall_lane_filter
          AND o.status = 'active'
          AND l.status IN ('in_progress', 'pending', 'blocked')
        ORDER BY CASE l.status WHEN 'in_progress' THEN 0 WHEN 'blocked' THEN 1 ELSE 2 END, l.updated_at DESC
        LIMIT 3;" 2>/dev/null)
    if [ -n "$synced_tasks" ] || [ -n "$orchestration_lanes" ]; then
        codex_context+="
Work state:
"
        while IFS='|' read -r tsubject tstatus tblocked torigin; do
            [ -z "$tsubject" ] && continue
            origin_label=$(eagle_agent_label "$torigin")
            block_marker=""
            [ "$tblocked" != "[]" ] && [ -n "$tblocked" ] && block_marker=" blocked"
            codex_context+="- Task [$tstatus][$origin_label$block_marker]: $(eagle_trim_text "$tsubject" 130)
"
        done <<< "$synced_tasks"
        while IFS='|' read -r oname lkey ltitle lagent lstatus; do
            [ -z "$lkey" ] && continue
            origin_label=$(eagle_agent_label "$lagent")
            codex_context+="- Lane [$lstatus][$origin_label]: $lkey"
            [ -n "$ltitle" ] && codex_context+=" — $(eagle_trim_text "$ltitle" 100)"
            [ -n "$oname" ] && codex_context+=" ($oname)"
            codex_context+="
"
        done <<< "$orchestration_lanes"
        [ -n "$orchestration_lanes" ] && codex_context+="  Agent rule: you update lane status with eagle-mem orchestrate; do not ask the user to run it.
"
    fi

    pending_features=$(eagle_list_pending_feature_verifications "$project" 3 2>/dev/null)
    if [ -n "$pending_features" ]; then
        codex_context+="
Guardrail:
"
        while IFS='|' read -r pf_id pf_name pf_file pf_reason _pf_trigger _pf_created pf_smoke _pfingerprint; do
            [ -z "$pf_id" ] && continue
            codex_context+="- Pending verification #$pf_id: $pf_name"
            [ -n "$pf_file" ] && codex_context+=" ($pf_file)"
            [ -n "$pf_reason" ] && codex_context+=" — $(eagle_trim_text "$pf_reason" 90)"
            [ -n "$pf_smoke" ] && codex_context+=" | smoke: $(eagle_trim_text "$pf_smoke" 100)"
            codex_context+="
"
        done <<< "$pending_features"
        codex_context+="  Release commands are blocked until these are verified or waived.
"
    fi

    hot_files=$(eagle_get_hot_files "$project")
    if [ -n "$hot_files" ]; then
        core_files=""
        IFS=',' read -ra hf_arr <<< "$hot_files"
        hf_count=0
        for hf in "${hf_arr[@]}"; do
            [ "$hf_count" -ge 5 ] && break
            [ -z "$hf" ] && continue
            [ -n "$core_files" ] && core_files+=", "
            core_files+="$(basename "$hf")"
            hf_count=$((hf_count + 1))
        done
        [ -n "$core_files" ] && codex_context+="
Core files: $core_files
"
    fi

    if [ "$source_type" = "compact" ] || [ "$source_type" = "clear" ]; then
        working_set=$(eagle_get_working_set "$session_id")
        if [ -n "$working_set" ]; then
            codex_context+="
Working set:
"
            while IFS='|' read -r ws_path ws_edits; do
                [ -z "$ws_path" ] && continue
                codex_context+="- $(basename "$ws_path") (${ws_edits} edits)
"
            done <<< "$working_set"
        fi
    fi

    codex_context+="
Use recalled context only when relevant. Keep user-facing replies clean; do not print raw Eagle Mem internals."
    eagle_emit_context_for_agent "$agent" "SessionStart" "$codex_context"
    exit 0
fi

if [ -n "$update_notice" ]; then
    context+="
=== Eagle Mem: Update Available ===
$update_notice
"
fi

if [ "$agent" = "codex" ] && [ "${stat_with_summaries:-0}" -eq 0 ] 2>/dev/null; then
    context+="
=== Eagle Mem: Codex Capture Warming Up ===
Codex hooks are active. Keep final replies clean; Eagle Mem will capture decisions, gotchas, key files, and next steps from the transcript automatically.
"
fi

# ─── Project overview (capped at 500 chars) ──────────────

overview=$(eagle_get_overview "$project")
if [ -n "$overview" ]; then
    overview_limit=500
    [ "$codex_compact" -eq 1 ] && overview_limit=320
    overview=$(eagle_trim_text "$overview" "$overview_limit")
    context+="
=== Eagle Mem: Project Overview ===
$overview
"
else
    context+="
=== Eagle Mem: New Project ===
No overview yet — auto-scan is running. Run /eagle-mem-overview for a richer briefing.
"
fi

# ─── Recent sessions (1 on compact, 3 on startup) ────────

if [ "$source_type" = "compact" ] || [ "$source_type" = "clear" ]; then
    _summary_limit=1
elif [ "$codex_compact" -eq 1 ]; then
    _summary_limit=1
else
    _summary_limit=2
fi

recent=$(eagle_get_recent_summaries "$recall_scope" "$_summary_limit")

if [ -n "$recent" ]; then
    context+="
=== Eagle Mem: Recent Recall ===
"
    while IFS='|' read -r request completed learned next_steps created_at decisions gotchas key_files summary_agent; do
        [ -z "$request" ] && [ -z "$completed" ] && continue
        summary_agent_label=$(eagle_agent_label "$summary_agent")
        request=$(eagle_trim_text "$request" 160)
        completed=$(eagle_trim_text "$completed" 220)
        learned=$(eagle_trim_text "$learned" 180)
        decisions=$(eagle_trim_text "$decisions" 160)
        gotchas=$(eagle_trim_text "$gotchas" 160)
        key_files=$(eagle_trim_text "$key_files" 160)
        next_steps=$(eagle_trim_text "$next_steps" 160)
        if [ "$codex_compact" -eq 1 ]; then
            request=$(eagle_trim_text "$request" 120)
            completed=$(eagle_trim_text "$completed" 160)
            learned=$(eagle_trim_text "$learned" 120)
            decisions=""
            key_files=""
            next_steps=""
        fi
        context+="
--- $created_at ---"
        [ -n "$summary_agent" ] && context+="
Source: $summary_agent_label"
        [ -n "$request" ] && context+="
Request: $request"
        [ -n "$completed" ] && context+="
Completed: $completed"
        [ -n "$learned" ] && context+="
Learned: $learned"
        [ -n "$decisions" ] && context+="
Decisions: $decisions"
        [ -n "$gotchas" ] && context+="
Gotchas: $gotchas"
        [ -n "$key_files" ] && context+="
Key files: $key_files"
        [ -n "$next_steps" ] && context+="
Next steps: $next_steps"
    done <<< "$recent"
    context+="
"
fi

# ─── Memories (skip if none) ─────────────────────────────

memory_limit=5
[ "$codex_compact" -eq 1 ] && memory_limit=3
memories=$(eagle_db "SELECT memory_name, memory_type, description, file_path, updated_at, origin_agent,
    CAST(julianday('now') - julianday(updated_at) AS INTEGER) as days_ago
    FROM agent_memories
    WHERE $recall_project_filter
    AND memory_name NOT IN ('Codex Memory Registry', 'Codex Memory Summary')
    ORDER BY
        CASE
            WHEN lower(memory_name) LIKE 'current status%' THEN 4
            WHEN memory_type = 'project' THEN 0
            WHEN memory_type = 'feedback' THEN 1
            WHEN memory_type IN ('user', 'reference') THEN 2
            ELSE 3
        END,
        updated_at DESC
    LIMIT $memory_limit;")
if [ -n "$memories" ]; then
    context+="
=== Eagle Mem: Stored Memories ===
"
    while IFS='|' read -r mname mtype mdesc _fpath _updated morigin days_ago; do
        [ -z "$mname" ] && continue
        origin_label=$(eagle_agent_label "$morigin")
        mdesc=$(eagle_trim_text "$mdesc" 180)
        age_label=""
        if [ -n "$days_ago" ] && [ "$days_ago" -gt 0 ] 2>/dev/null; then
            if [ "$days_ago" -eq 1 ]; then
                age_label=" (1 day ago)"
            else
                age_label=" (${days_ago} days ago)"
            fi
        else
            age_label=" (today)"
        fi
        context+="  - [$mtype][$origin_label] $mname: $mdesc$age_label
"
    done <<< "$memories"
fi

# ─── Plans (skip if none) ────────────────────────────────

plans=$(eagle_list_agent_plans "$recall_scope" 3)
if [ -n "$plans" ]; then
    context+="
=== Eagle Mem: Plans ===
"
    while IFS='|' read -r ptitle _pproj _fpath _updated porigin; do
        [ -z "$ptitle" ] && continue
        origin_label=$(eagle_agent_label "$porigin")
        context+="  - [$origin_label] $ptitle
"
    done <<< "$plans"
fi

# ─── Tasks (skip if none) ────────────────────────────────

task_limit=5
[ "$codex_compact" -eq 1 ] && task_limit=3
synced_tasks=$(eagle_db "SELECT subject, status, blocked_by, origin_agent FROM agent_tasks
    WHERE $recall_project_filter
    AND status IN ('in_progress', 'pending')
    AND source_session_id != 'orchestration'
    AND updated_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-7 days')
    ORDER BY
        CASE status WHEN 'in_progress' THEN 0 ELSE 1 END,
        updated_at DESC
    LIMIT $task_limit;")
if [ -n "$synced_tasks" ]; then
    context+="
=== Eagle Mem: Tasks ===
"
    while IFS='|' read -r tsubject tstatus tblocked torigin; do
        [ -z "$tsubject" ] && continue
        origin_label=$(eagle_agent_label "$torigin")
        block_marker=""
        if [ "$tblocked" != "[]" ] && [ -n "$tblocked" ]; then
            block_marker=" (blocked)"
        fi
        context+="  - [$tstatus][$origin_label] $tsubject$block_marker
"
    done <<< "$synced_tasks"
fi

# ─── Orchestration lanes (skip if none) ───────────────────

lane_limit=8
[ "$codex_compact" -eq 1 ] && lane_limit=4
orchestration_lanes=$(eagle_db "SELECT o.name, o.goal, l.lane_key, l.title,
        COALESCE(REPLACE(REPLACE(l.description, char(10), ' '), '|', '/'), ''),
        l.agent, l.status, l.validation, l.worktree_path, l.notes
    FROM orchestration_lanes l
    JOIN orchestrations o ON o.id = l.orchestration_id
    WHERE $recall_lane_filter
      AND o.status = 'active'
      AND l.status IN ('in_progress', 'pending', 'blocked')
    ORDER BY
        CASE l.status WHEN 'in_progress' THEN 0 WHEN 'blocked' THEN 1 ELSE 2 END,
        l.updated_at DESC
    LIMIT $lane_limit;" 2>/dev/null)
if [ -n "$orchestration_lanes" ]; then
    context+="
=== Eagle Mem: Orchestration Lanes ===
"
    while IFS='|' read -r oname ogoal lkey ltitle ldesc lagent lstatus lvalidation lworktree lnotes; do
        [ -z "$lkey" ] && continue
        origin_label=$(eagle_agent_label "$lagent")
        context+="  - [$lstatus][$origin_label] $lkey: $ltitle"
        if [ -n "$ldesc" ]; then
            desc_limit=220
            [ "$codex_compact" -eq 1 ] && desc_limit=120
            context+=" | scope: $(eagle_trim_text "$ldesc" "$desc_limit")"
        fi
        [ -n "$oname" ] && context+=" | plan: $oname"
        [ -n "$lvalidation" ] && context+=" | validate: $lvalidation"
        [ -n "$lworktree" ] && context+=" | worktree: $lworktree"
        [ -n "$lnotes" ] && context+=" | notes: $lnotes"
        context+="
"
    done <<< "$orchestration_lanes"
    context+="You, the active agent, must run 'eagle-mem orchestrate' before taking lane work. Do not ask the user to run these commands. Update lane status when work starts, blocks, or completes.
"
fi

# ─── Pending feature verifications ───────────────────────

pending_limit=5
[ "$codex_compact" -eq 1 ] && pending_limit=3
pending_features=$(eagle_list_pending_feature_verifications "$project" "$pending_limit" 2>/dev/null)
if [ -n "$pending_features" ]; then
    pending_total=$(eagle_db "SELECT COUNT(*) FROM pending_feature_verifications WHERE project = '$p_esc' AND status = 'pending';" 2>/dev/null)
    pending_total=${pending_total:-0}
    context+="
=== Eagle Mem: Pending Feature Verification ===
Release-boundary commands are blocked until these are verified or waived.
"
    while IFS='|' read -r pf_id pf_name pf_file pf_reason _pf_trigger _pf_created pf_smoke pfingerprint; do
        [ -z "$pf_id" ] && continue
        context+="  - #${pf_id} ${pf_name}"
        [ -n "$pf_file" ] && context+=" (${pf_file})"
        [ -n "$pf_reason" ] && context+=" — ${pf_reason}"
        [ -n "$pf_smoke" ] && context+=" | smoke: ${pf_smoke}"
        [ -n "$pfingerprint" ] && context+=" | diff: ${pfingerprint}"
        context+="
"
    done <<< "$pending_features"
    if [ "$pending_total" -gt "$pending_limit" ] 2>/dev/null; then
        context+="  - ... $((pending_total - pending_limit)) more pending; run: eagle-mem feature pending
"
    fi
    context+="Resolve with: eagle-mem feature verify <name> --notes \"what passed\"; or eagle-mem feature waive <id> --reason \"why safe\".
"
fi

# ─── Core files (hot file hints from curator) ───────────

hot_files=$(eagle_get_hot_files "$project")
if [ -n "$hot_files" ]; then
    context+="
=== Eagle Mem: Core Files ===
Frequently read — re-read sparingly if unchanged.
"
    IFS=',' read -ra hf_arr <<< "$hot_files"
    hf_count=0
    hot_file_limit=8
    [ "$codex_compact" -eq 1 ] && hot_file_limit=5
    for hf in "${hf_arr[@]}"; do
        [ "$hf_count" -ge "$hot_file_limit" ] && break
        [ -n "$hf" ] && context+="  - $(basename "$hf")
"
        hf_count=$((hf_count + 1))
    done
fi

# ─── Working set (on compact — what you were editing) ────

if [ "$source_type" = "compact" ] || [ "$source_type" = "clear" ]; then
    working_set=$(eagle_get_working_set "$session_id")
    if [ -n "$working_set" ]; then
        context+="
=== Eagle Mem: Working Set ===
Files you were modifying before compact.
"
        while IFS='|' read -r ws_path ws_edits; do
            [ -z "$ws_path" ] && continue
            context+="  - $(basename "$ws_path") (${ws_edits} edits)
"
        done <<< "$working_set"
    fi
fi

# ─── Instructions (compressed) ───────────────────────────

if [ "$agent" = "codex" ]; then
    context+="
=== Eagle Mem: Active ===
Memory active for '$project'. Keep user-facing Codex replies clean: do not print Eagle Mem summary capture blocks, XML, JSON hook payloads, or internal templates unless the user explicitly asks. The Stop hook captures summaries from the transcript automatically.
"
elif [ "$source_type" = "compact" ] || [ "$source_type" = "clear" ]; then
    context+="
=== Eagle Mem: Active ===
Memory active. Attribute recalled context to Eagle Mem. Do not revert PostToolUse-surfaced decisions without asking. Emit <eagle-summary> before final response.
"
else
    context+="
=== Eagle Mem: Active ===
Memory active for '$project'. Scan, index, prune, and self-learning run automatically — never ask the user to run these. Attribute recalled context: \"Eagle Mem recalls:\" Do not revert PostToolUse-surfaced decisions without user request. No raw secrets in summaries. If you contradict a loaded memory, update the memory file.

Before your final response, emit:
<eagle-summary>
request: [what user asked]
completed: [what shipped]
learned: [non-obvious discoveries]
decisions: [choice — why]
gotchas: [what surprised]
next_steps: [concrete actions]
key_files: [path — role]
files_read: [path, ...]
files_modified: [path, ...]
affected_features: [feature, ...]
verified_features: [feature, ...]
regression_risks: [risk, ...]
</eagle-summary>
"
fi

if [ -n "$context" ]; then
    eagle_emit_context_for_agent "$agent" "SessionStart" "$context"
fi

exit 0
