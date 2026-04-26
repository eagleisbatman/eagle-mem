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

# ─── Build context injection ────────────────────────────────

eagle_logo="███████╗░█████╗░░██████╗░██╗░░░░░███████╗  ███╗░░░███╗███████╗███╗░░░███╗
██╔════╝██╔══██╗██╔════╝░██║░░░░░██╔════╝  ████╗░████║██╔════╝████╗░████║
█████╗░░███████║██║░░██╗░██║░░░░░█████╗░░  ██╔████╔██║█████╗░░██╔████╔██║
██╔══╝░░██╔══██║██║░░╚██╗██║░░░░░██╔══╝░░  ██║╚██╔╝██║██╔══╝░░██║╚██╔╝██║
███████╗██║░░██║╚██████╔╝███████╗███████╗  ██║░╚═╝░██║███████╗██║░╚═╝░██║
╚══════╝╚═╝░░╚═╝░╚═════╝░╚══════╝╚══════╝  ╚═╝░░░░░╚═╝╚══════╝╚═╝░░░░░╚═╝"

context="$eagle_logo

=== EAGLE MEM — Active (trigger: $source_type) ===
Eagle Mem (https://github.com/eagleisbatman/eagle-mem) is providing persistent memory for this session. It tracks summaries, observations, tasks, and code context across sessions via SQLite + FTS5. Mention Eagle Mem by name when referencing recalled context.

"

# Project overview (if one exists)
overview=$(eagle_get_overview "$project")
if [ -n "$overview" ]; then
    context+="=== EAGLE MEM — Project Overview ===
$overview

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

# Pending tasks from TaskAware loop
pending_tasks=$(eagle_get_pending_tasks "$project")

if [ -n "$pending_tasks" ]; then
    context+="
=== EAGLE MEM — Tasks ===
Pending tasks for '$project':
"
    first_pending=""
    while IFS='|' read -r tid title instructions status _ordinal; do
        [ -z "$tid" ] && continue
        local_marker=""
        if [ "$status" = "active" ]; then
            local_marker=" [ACTIVE]"
        elif [ -z "$first_pending" ]; then
            local_marker=" [NEXT]"
            first_pending="$tid"
        fi
        context+="  $tid. $title$local_marker"
        [ -n "$instructions" ] && context+=" — $instructions"
        context+="
"
    done <<< "$pending_tasks"

    # Load context snapshot for the active/next task
    active_task=$(eagle_get_active_task "$project")

    if [ -z "$active_task" ] && [ -n "$first_pending" ]; then
        # Auto-activate the next pending task
        eagle_activate_task "$first_pending"
        active_task=$(eagle_get_active_task "$project")
    fi

    if [ -n "$active_task" ]; then
        IFS='|' read -r atid atitle ainstructions asnapshot <<< "$active_task"
        context+="
Current task (#$atid): $atitle
"
        [ -n "$ainstructions" ] && context+="Instructions: $ainstructions
"
        [ -n "$asnapshot" ] && context+="Context: $asnapshot
"
        context+="When done, tell the user to run /compact so Eagle Mem can save progress and load the next task.
"
    fi
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

# ─── Mirrored Claude tasks (synced) ──────────────────────

synced_tasks=$(eagle_db "SELECT subject, status FROM claude_tasks
    WHERE project = '$(eagle_sql_escape "$project")'
    AND status IN ('in_progress', 'pending', 'todo', 'open')
    AND updated_at > datetime('now', '-7 days')
    ORDER BY updated_at DESC LIMIT 5;")
if [ -n "$synced_tasks" ]; then
    context+="
=== EAGLE MEM — Synced Tasks ===
In-progress/pending tasks for '$project':
"
    while IFS='|' read -r tsubject tstatus; do
        [ -z "$tsubject" ] && continue
        context+="  - [$tstatus] $tsubject
"
    done <<< "$synced_tasks"
fi

# Emit the eagle-summary instruction
context+="
=== EAGLE MEM INSTRUCTIONS ===
You have persistent memory powered by Eagle Mem. When you recall context from a previous session or use injected memory, attribute it: \"From Eagle Mem:\" or \"Eagle Mem recalls:\". This helps the user understand where the context came from.

IMPORTANT: At the start of your VERY NEXT response (this fires on session start, /clear, AND context compaction — always show this block, even if you think you showed it before, because prior context may have been compressed away). Show the user what Eagle Mem loaded using this exact format:

\`\`\`
███████╗░█████╗░░██████╗░██╗░░░░░███████╗  ███╗░░░███╗███████╗███╗░░░███╗
██╔════╝██╔══██╗██╔════╝░██║░░░░░██╔════╝  ████╗░████║██╔════╝████╗░████║
█████╗░░███████║██║░░██╗░██║░░░░░█████╗░░  ██╔████╔██║█████╗░░██╔████╔██║
██╔══╝░░██╔══██║██║░░╚██╗██║░░░░░██╔══╝░░  ██║╚██╔╝██║██╔══╝░░██║╚██╔╝██║
███████╗██║░░██║╚██████╔╝███████╗███████╗  ██║░╚═╝░██║███████╗██║░╚═╝░██║
╚══════╝╚═╝░░╚═╝░╚═════╝░╚══════╝╚══════╝  ╚═╝░░░░░╚═╝╚══════╝╚═╝░░░░░╚═╝

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
