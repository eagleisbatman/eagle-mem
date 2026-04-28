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

eagle_ensure_db

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
source_type=$(echo "$input" | jq -r '.source // empty')
model=$(echo "$input" | jq -r '.model // empty')

[ -z "$session_id" ] && exit 0

project=$(eagle_project_from_cwd "$cwd")

# Skip ephemeral directories (tmp, Downloads, etc.) — no tracking
[ -z "$project" ] && exit 0

p_esc=$(eagle_sql_escape "$project")

eagle_log "INFO" "SessionStart: session=$session_id project=$project source=$source_type"

eagle_upsert_session "$session_id" "$project" "$cwd" "$model" "$source_type"

# ─── Sweep stuck sessions (no activity for 7 days) ─────────
# Uses last_activity_at (updated by trigger on every observation insert)
# so long-lived sessions with regular compactions aren't falsely abandoned
eagle_abandon_stale_sessions "$session_id"

# ─── Auto-curate trigger (background, non-blocking) ──────────
# Moved here from SessionEnd because SessionEnd rarely fires in long-lived sessions.
# SessionStart fires on every new session, resume, and compaction — reliable trigger.
curator_schedule=$(eagle_config_get "curator" "schedule" "manual")
if [ "$curator_schedule" = "auto" ]; then
    _curator_provider=$(eagle_config_get "provider" "type" "none")
    if [ "$_curator_provider" != "none" ]; then
        _min_sessions=$(eagle_config_get "curator" "min_sessions" "5")
        _min_sessions=$(eagle_sql_int "$_min_sessions")
        _last_curated=$(eagle_meta_get "last_curated_at" "$project")
        _since="${_last_curated:-1970-01-01T00:00:00Z}"
        _sessions_since=$(eagle_count_sessions_since "$project" "$_since")
        if [ "${_sessions_since:-0}" -ge "$_min_sessions" ]; then
            eagle_log "INFO" "SessionStart: auto-curate triggered (${_sessions_since} sessions since last curate)"
            nohup bash "$SCRIPTS_DIR/curate.sh" -p "$project" >> "$EAGLE_MEM_LOG" 2>&1 &
        fi
    fi
fi

# ─── Version check (non-blocking) ────────────────────────────

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

# ─── Gather stats ───────────────────────────────────────────

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

# Build task summary line
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
[ -z "$task_parts" ] && task_parts="none"

# Truncate last summary for display
stat_last_display="${stat_last_summary:0:60}"
[ ${#stat_last_summary} -gt 60 ] && stat_last_display+="..."
[ -z "$stat_last_display" ] && stat_last_display="(no sessions yet)"

# ─── Build context injection ────────────────────────────────

eagle_banner="======================================
       Eagle Mem Loaded
======================================
 Project      | $project
 Sessions     | $stat_sessions total ($stat_with_summaries with summaries)
 Memories     | $stat_memories stored
 Plans        | $stat_plans saved
 Tasks        | $task_parts
 Code Index   | $stat_chunks chunks indexed
 Observations | $stat_observations captured
 Last Active  | $stat_last_active
 Last Work    | $stat_last_display
======================================"

context="$eagle_banner
"

if [ -n "$update_notice" ]; then
    context+="
=== $update_notice ===
"
fi

# Project overview
overview=$(eagle_get_overview "$project")
if [ -n "$overview" ]; then
    context+="
=== Project Overview ===
$overview
"
else
    context+="
=== Action Required ===
No overview exists for '$project'. Run /eagle-mem-overview to build one.
"
fi

# Recent summaries for this project (last 5 sessions)
recent=$(eagle_get_recent_summaries "$project" 5)

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

# ─── Mirrored Claude memories (with age) ─────────────────

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

# ─── Mirrored Claude plans ────────────────────────────────

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

# ─── Claude Code tasks ───────────────────────────────────

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

# ─── Instructions (full on startup, minimal on compact) ──

if [ "$source_type" = "compact" ] || [ "$source_type" = "clear" ]; then
    context+="
=== Eagle Mem (compact reload) ===
Persistent memory active. Attribute recalled context to Eagle Mem. Do not revert past decisions surfaced by PostToolUse without asking the user. Emit <eagle-summary> before your final response.
"
else
    context+="
=== Eagle Mem ===
Persistent memory active for '$project'. Attribute recalled context: \"Eagle Mem recalls:\" When PostToolUse surfaces past decisions about a file, do not revert without explicit user request. Never include raw secrets in eagle-summary fields. If you change something that contradicts a loaded memory, update that memory file.

Emit an <eagle-summary> block before your FINAL response:

<eagle-summary>
request: [what the user asked for]
investigated: [file paths read or explored]
learned: [non-obvious discoveries a future session couldn't guess from code]
completed: [what shipped — be specific]
next_steps: [concrete actions for next session]
decisions:
  - [choice] Why: [reason]
gotchas:
  - [what failed or surprised — \"X doesn't work because Y\"]
key_files:
  - [path] — [role in this work]
files_read: [file1, file2]
files_modified: [file1, file2]
</eagle-summary>
"
fi

# Output context (plain text stdout = additionalContext for SessionStart)
if [ -n "$context" ]; then
    echo "$context"
fi

exit 0
