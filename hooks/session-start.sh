#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — SessionStart hook
# Fires on: startup, resume, clear, compact
# Injects project memory + pending tasks into Claude's context
# ═══════════════════════════════════════════════════════════
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
source_type=$(echo "$input" | jq -r '.source // empty')
model=$(echo "$input" | jq -r '.model // empty')

[ -z "$session_id" ] && exit 0

project=$(eagle_project_from_cwd "$cwd")

eagle_log "INFO" "SessionStart: session=$session_id project=$project source=$source_type"

eagle_upsert_session "$session_id" "$project" "$cwd" "$model" "$source_type"

# ─── Sweep stuck sessions (no activity for 7 days) ─────────
# Uses last_activity_at (updated by trigger on every observation insert)
# so long-lived sessions with regular compactions aren't falsely abandoned
eagle_db "UPDATE sessions SET status = 'abandoned'
    WHERE status = 'active'
    AND id != '$(eagle_sql_escape "$session_id")'
    AND COALESCE(last_activity_at, started_at) < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-7 days');"

# ─── Build context injection ────────────────────────────────

eagle_logo="█▀▀ ▄▀█ █▀▀ █   █▀▀   █▀▄▀█ █▀▀ █▀▄▀█
██▄ █▀█ █▄█ █▄▄ ██▄   █ ▀ █ ██▄ █ ▀ █"

context="$eagle_logo

=== EAGLE MEM — Active (trigger: $source_type) ===
Eagle Mem (https://github.com/eagleisbatman/eagle-mem) is providing persistent memory for this session. It tracks summaries, observations, tasks, and code context across sessions via SQLite + FTS5. Mention Eagle Mem by name when referencing recalled context.

"

# Project overview
overview=$(eagle_get_overview "$project")
if [ -n "$overview" ]; then
    context+="=== EAGLE MEM — Project Overview ===
$overview

"
else
    context+="=== EAGLE MEM — Action Required ===
No overview exists for '$project'. On the user's first prompt, run /eagle-mem-overview to build a structured project briefing. The skill has full instructions for what to read and how to write a rich overview.

"
fi

# Recent summaries for this project (last 5 sessions)
recent=$(eagle_get_recent_summaries "$project" 5)

if [ -n "$recent" ]; then
    context+="=== EAGLE MEM ===
Recent sessions for project '$project':
"
    while IFS='|' read -r request completed learned next_steps created_at; do
        [ -z "$request" ] && [ -z "$completed" ] && continue
        context+="
--- $created_at ---"
        [ -n "$request" ] && context+="
Request: $request"
        [ -n "$completed" ] && context+="
Completed: $completed"
        [ -n "$learned" ] && context+="
Learned: $learned"
        [ -n "$next_steps" ] && context+="
Next steps: $next_steps"
    done <<< "$recent"
    context+="
"
fi

# ─── Mirrored Claude memories ──────────────────────────────

memories=$(eagle_list_claude_memories "$project" 5)
if [ -n "$memories" ]; then
    context+="
=== EAGLE MEM — Memories ===
Recent memories for '$project':
"
    while IFS='|' read -r mname mtype mdesc _fpath _updated; do
        [ -z "$mname" ] && continue
        context+="  - [$mtype] $mname: $mdesc
"
    done <<< "$memories"
fi

# ─── Mirrored Claude plans ────────────────────────────────

plans=$(eagle_list_claude_plans "$project" 3)
if [ -n "$plans" ]; then
    context+="
=== EAGLE MEM — Plans ===
Recent plans for '$project':
"
    while IFS='|' read -r ptitle _pproj _fpath _updated; do
        [ -z "$ptitle" ] && continue
        context+="  - $ptitle
"
    done <<< "$plans"
fi

# ─── Claude Code tasks ───────────────────────────────────

synced_tasks=$(eagle_db "SELECT subject, status, blocked_by FROM claude_tasks
    WHERE project = '$(eagle_sql_escape "$project")'
    AND status IN ('in_progress', 'pending')
    AND updated_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-7 days')
    ORDER BY
        CASE status WHEN 'in_progress' THEN 0 ELSE 1 END,
        updated_at DESC
    LIMIT 10;")
if [ -n "$synced_tasks" ]; then
    context+="
=== EAGLE MEM — Tasks ===
Tasks for '$project':
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

# Emit the eagle-summary instruction
context+="
=== EAGLE MEM INSTRUCTIONS ===
You have persistent memory powered by Eagle Mem. When you recall context from a previous session or use injected memory, attribute it: \"From Eagle Mem:\" or \"Eagle Mem recalls:\". This helps the user understand where the context came from.

IMPORTANT: At the start of your VERY NEXT response (this fires on session start, /clear, AND context compaction — always show this block, even if you think you showed it before, because prior context may have been compressed away). Show the user what Eagle Mem loaded using this exact format:

\`\`\`
$eagle_logo

Project: <project name>
Sessions: N recent | Memories: N | Tasks: N pending
Last: [one-line summary of most recent session]
\`\`\`

This gives the user visibility into the context you received.

Before your final response in this session, emit a summary block:
<eagle-summary>
request: What the user asked for
investigated: Key files/areas explored
learned: Non-obvious discoveries
completed: What was accomplished
next_steps: What should happen next
files_read: [list of files read]
files_modified: [list of files modified]
</eagle-summary>
This helps Eagle Mem track what happened for future sessions.
"

# Output context (plain text stdout = additionalContext for SessionStart)
if [ -n "$context" ]; then
    echo "$context"
fi

exit 0
