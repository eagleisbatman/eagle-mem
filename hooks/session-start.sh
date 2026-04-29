#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — SessionStart hook
# Fires on: startup, resume, clear, compact
# Injects project memory + pending tasks into Claude's context
# ═══════════════════════════════════════════════════════════
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/provider.sh"
. "$LIB_DIR/hooks-sessionstart.sh"

eagle_ensure_db

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
source_type=$(echo "$input" | jq -r '.source // empty')
model=$(echo "$input" | jq -r '.model // empty')

[ -z "$session_id" ] && exit 0

project=$(eagle_project_from_cwd "$cwd")
[ -z "$project" ] && exit 0

p_esc=$(eagle_sql_escape "$project")

eagle_log "INFO" "SessionStart: session=$session_id project=$project source=$source_type"

eagle_upsert_session "$session_id" "$project" "$cwd" "$model" "$source_type"
eagle_abandon_stale_sessions "$session_id"

# ─── Background automation (non-blocking) ────────────────

eagle_sessionstart_auto_provision "$project" "$cwd" "$SCRIPTS_DIR"
eagle_sessionstart_auto_prune "$project" "$SCRIPTS_DIR" "$(eagle_db "SELECT COUNT(*) FROM observations WHERE session_id IN (SELECT id FROM sessions WHERE project='$p_esc');")"
eagle_sessionstart_auto_curate "$project" "$SCRIPTS_DIR"

find "$EAGLE_MEM_DIR/read-tracker" -type f -mtime +1 -delete 2>/dev/null &
find "$EAGLE_MEM_DIR/mod-tracker" -type f -mtime +1 -delete 2>/dev/null &
find "$EAGLE_MEM_DIR/edit-tracker" -type f -mtime +1 -delete 2>/dev/null &

# ─── Version check (non-blocking) ────────────────────────

update_notice=""
version_file="$EAGLE_MEM_DIR/.version"
latest_file="$EAGLE_MEM_DIR/.latest-version"

if [ -f "$version_file" ] && [ -s "$version_file" ]; then
    installed_version=$(tr -d '[:space:]' < "$version_file")

    if [ -f "$latest_file" ] && [ -s "$latest_file" ]; then
        latest_version=$(tr -d '[:space:]' < "$latest_file")
        newest=$(printf '%s\n' "$installed_version" "$latest_version" | sort -V | tail -1)
        if [ "$newest" != "$installed_version" ]; then
            update_notice="Update available: v${installed_version} → v${latest_version} — run: npm update -g eagle-mem && eagle-mem update"
        fi
    fi

    if [ ! -f "$latest_file" ] || [ -n "$(find "$latest_file" -mtime +0 2>/dev/null)" ]; then
        (tmp_latest=$(mktemp)
         npm view eagle-mem version 2>/dev/null | tr -d '[:space:]' > "$tmp_latest"
         if [ -s "$tmp_latest" ]; then
             mv "$tmp_latest" "$latest_file"
         else
             rm -f "$tmp_latest"
         fi) &
    fi
fi

# ─── Gather stats ────────────────────────────────────────

stat_sessions=0; stat_summaries=0; stat_with_summaries=0; stat_memories=0
stat_tasks_pending=0; stat_tasks_progress=0; stat_tasks_done=0
stat_chunks=0; stat_observations=0; stat_plans=0
stat_last_active="never"; stat_last_summary=""

while IFS='|' read -r key val; do
    case "$key" in
        sessions)        stat_sessions="$val" ;;
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
done <<< "$(eagle_get_project_stats "$project")"

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

stat_last_display="${stat_last_summary:0:60}"
[ ${#stat_last_summary} -gt 60 ] && stat_last_display+="..."

eagle_banner="======================================
       Eagle Mem Loaded
======================================
 Project      | $project
 Sessions     | $stat_sessions ($stat_with_summaries with summaries)"
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
"

if [ -n "$update_notice" ]; then
    context+="
=== $update_notice ===
"
fi

# ─── Project overview (capped at 500 chars) ──────────────

overview=$(eagle_get_overview "$project")
if [ -n "$overview" ]; then
    if [ ${#overview} -gt 500 ]; then
        overview="${overview:0:497}..."
    fi
    context+="
=== Overview ===
$overview
"
else
    context+="
=== New Project ===
No overview yet — auto-scan is running. Run /eagle-mem-overview for a richer briefing.
"
fi

# ─── Recent sessions (1 on compact, 3 on startup) ────────

if [ "$source_type" = "compact" ] || [ "$source_type" = "clear" ]; then
    _summary_limit=1
else
    _summary_limit=3
fi

recent=$(eagle_get_recent_summaries "$project" "$_summary_limit")

if [ -n "$recent" ]; then
    context+="
=== Recent Sessions ===
"
    while IFS='|' read -r request completed learned next_steps created_at decisions gotchas key_files; do
        [ -z "$request" ] && [ -z "$completed" ] && continue
        context+="
--- $created_at ---"
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

memories=$(eagle_db "SELECT memory_name, memory_type, description, file_path, updated_at,
    CAST(julianday('now') - julianday(updated_at) AS INTEGER) as days_ago
    FROM claude_memories
    WHERE project = '$p_esc'
    ORDER BY updated_at DESC
    LIMIT 5;")
if [ -n "$memories" ]; then
    context+="
=== Memories ===
"
    while IFS='|' read -r mname mtype mdesc _fpath _updated days_ago; do
        [ -z "$mname" ] && continue
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
        context+="  - [$mtype] $mname: $mdesc$age_label
"
    done <<< "$memories"
fi

# ─── Plans (skip if none) ────────────────────────────────

plans=$(eagle_list_claude_plans "$project" 3)
if [ -n "$plans" ]; then
    context+="
=== Plans ===
"
    while IFS='|' read -r ptitle _pproj _fpath _updated; do
        [ -z "$ptitle" ] && continue
        context+="  - $ptitle
"
    done <<< "$plans"
fi

# ─── Tasks (skip if none) ────────────────────────────────

synced_tasks=$(eagle_db "SELECT subject, status, blocked_by FROM claude_tasks
    WHERE project = '$p_esc'
    AND status IN ('in_progress', 'pending')
    AND updated_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-7 days')
    ORDER BY
        CASE status WHEN 'in_progress' THEN 0 ELSE 1 END,
        updated_at DESC
    LIMIT 10;")
if [ -n "$synced_tasks" ]; then
    context+="
=== Tasks ===
"
    while IFS='|' read -r tsubject tstatus tblocked; do
        [ -z "$tsubject" ] && continue
        block_marker=""
        if [ "$tblocked" != "[]" ] && [ -n "$tblocked" ]; then
            block_marker=" (blocked)"
        fi
        context+="  - [$tstatus] $tsubject$block_marker
"
    done <<< "$synced_tasks"
fi

# ─── Core files (hot file hints from curator) ───────────

hot_files=$(eagle_get_hot_files "$project")
if [ -n "$hot_files" ]; then
    context+="
=== Core Files (frequently read — re-read sparingly if unchanged) ===
"
    IFS=',' read -ra hf_arr <<< "$hot_files"
    for hf in "${hf_arr[@]}"; do
        [ -n "$hf" ] && context+="  - $(basename "$hf")
"
    done
fi

# ─── Working set (on compact — what you were editing) ────

if [ "$source_type" = "compact" ] || [ "$source_type" = "clear" ]; then
    working_set=$(eagle_get_working_set "$session_id")
    if [ -n "$working_set" ]; then
        context+="
=== Working Set (files you were modifying before compact) ===
"
        while IFS='|' read -r ws_path ws_edits; do
            [ -z "$ws_path" ] && continue
            context+="  - $(basename "$ws_path") (${ws_edits} edits)
"
        done <<< "$working_set"
    fi
fi

# ─── Instructions (compressed) ───────────────────────────

if [ "$source_type" = "compact" ] || [ "$source_type" = "clear" ]; then
    context+="
=== Eagle Mem ===
Memory active. Attribute recalled context to Eagle Mem. Do not revert PostToolUse-surfaced decisions without asking. Emit <eagle-summary> before final response.
"
else
    context+="
=== Eagle Mem ===
Memory active for '$project'. Scan, index, prune, and self-learning run automatically — never ask the user to run these. Attribute recalled context: \"Eagle Mem recalls:\" Do not revert PostToolUse-surfaced decisions without user request. No raw secrets in summaries. If you contradict a loaded memory, update the memory file.

Before your final response, emit:
<eagle-summary>
request: [what user asked] | completed: [what shipped] | learned: [non-obvious discoveries]
next_steps: [concrete actions] | decisions: [choice — why] | gotchas: [what surprised]
key_files: [path — role] | files_read: [...] | files_modified: [...]
</eagle-summary>
"
fi

if [ -n "$context" ]; then
    echo "$context"
fi

exit 0
