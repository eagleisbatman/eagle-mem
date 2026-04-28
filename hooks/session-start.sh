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

# Skip ephemeral directories (tmp, Downloads, etc.) — no tracking
[ -z "$project" ] && exit 0

p_esc=$(eagle_sql_escape "$project")

eagle_log "INFO" "SessionStart: session=$session_id project=$project source=$source_type"

eagle_upsert_session "$session_id" "$project" "$cwd" "$model" "$source_type"

# ─── Sweep stuck sessions (no activity for 7 days) ─────────
# Uses last_activity_at (updated by trigger on every observation insert)
# so long-lived sessions with regular compactions aren't falsely abandoned
eagle_abandon_stale_sessions "$session_id"

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

=== EAGLE MEM — Active (trigger: $source_type) ===
Eagle Mem (https://github.com/eagleisbatman/eagle-mem) is providing persistent memory for this session. It tracks summaries, observations, tasks, and code context across sessions via SQLite + FTS5. Mention Eagle Mem by name when referencing recalled context.

"

if [ -n "$update_notice" ]; then
    context+="=== EAGLE MEM — $update_notice ===

"
fi

# Nudge if last session lacked enrichment
last_enriched=$(eagle_last_session_enriched "$project")
if [ "${last_enriched:-1}" = "0" ] && [ "$stat_with_summaries" -gt 0 ]; then
    context+="=== EAGLE MEM — Enrichment Reminder ===
The previous session's summary did NOT include decisions, gotchas, or key_files. These fields power Eagle Mem's self-learning (feature discovery, anti-regression, command intelligence). Please emit an <eagle-summary> block at the end of this session with these fields populated.

"
fi

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
=== EAGLE MEM — Memories ===
Recent memories for '$project':
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
    WHERE project = '$p_esc'
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

IMPORTANT: At the start of your VERY NEXT response (this fires on session start, /clear, AND context compaction — always show this block, even if you think you showed it before, because prior context may have been compressed away). Show the user what Eagle Mem loaded by reproducing this exact banner:

\`\`\`
$eagle_banner
\`\`\`

This gives the user visibility into the full context Eagle Mem loaded for this session.

ANTI-REGRESSION: When Eagle Mem surfaces decision history about a file you are reading (via PostToolUse context), those decisions were made deliberately in past sessions. Do NOT revert or change the implementation approach without explicit user request. If you believe a past decision should change, state why and ask the user before proceeding. This prevents the common regression where Claude 'improves' code back to an older approach that was already rejected.

SECRET SAFETY: Never include raw API keys, tokens, passwords, or secrets in eagle-summary fields or any text that Eagle Mem stores. Reference secrets by name (e.g., 'the Stripe API key', 'GOOGLE_APPLICATION_CREDENTIALS_JSON') not by value. Eagle Mem redacts common patterns automatically, but prevention is better than redaction.

MEMORY FRESHNESS: The memories above include age indicators. If you make a change (edit a file, update a config, change a pattern) that contradicts what a loaded memory says, you MUST update that memory file immediately. Read the memory file, edit it to reflect the new reality, and the PostToolUse hook will sync the update to Eagle Mem. Stale memories mislead future sessions — keeping them current is as important as writing good code.

=== EAGLE MEM — SESSION SUMMARY (MANDATORY) ===
You MUST emit an <eagle-summary> block before your FINAL response in this session. This is how Eagle Mem captures what happened — without it, the next session starts blind and wastes tokens rediscovering context.

FORMAT — emit this block exactly. Every field is REQUIRED. Do not skip fields, do not leave them empty, do not write \"N/A\".

<eagle-summary>
request: [One sentence: what did the user ask for?]
investigated: [Comma-separated file paths you read or explored]
learned: [Non-obvious technical discoveries — things a future session could not guess from reading the code]
completed: [What was accomplished — be specific about what shipped, not what was \"worked on\"]
next_steps: [Concrete actions for the next session, not vague aspirations]
decisions:
  - [Choice made] Why: [the reason — what constraint or tradeoff drove this choice]
  - [Choice made] Why: [reason]
gotchas:
  - [What failed, surprised, or does not work the obvious way. Be specific — \"X does not work because Y\" not just \"X was tricky\"]
key_files:
  - [path/to/file.ext] — [one-line role: what this file does in the context of this work]
  - [path/to/other.ext] — [role]
files_read: [file1, file2, ...]
files_modified: [file1, file2, ...]
</eagle-summary>

EXAMPLE — this is what a well-written summary looks like:

<eagle-summary>
request: Add JWT authentication middleware to the API
investigated: src/middleware/auth.ts, src/routes/users.ts, package.json, src/config/env.ts
learned: express-jwt v8 changed its API — req.auth replaces req.user. The error handler must check err.name === 'UnauthorizedError', not err.status === 401.
completed: JWT middleware deployed on all /api routes. Token validation, role-based guards, and 401/403 error responses all working. Added JWKS endpoint support for key rotation.
next_steps: Add refresh token rotation; rate-limit the /auth/token endpoint
decisions:
  - Chose RS256 over HS256 for JWT signing. Why: allows key rotation via JWKS without redeploying; HS256 requires shared secret on every service.
  - Put auth middleware at router level, not app level. Why: healthcheck and public routes must remain unauthenticated; per-router mounting is explicit about what is protected.
gotchas:
  - express-jwt v8 is ESM-only — require() fails silently and returns undefined. Must use dynamic import().
  - Setting token expiry below 5 min causes refresh storms under load — the refresh endpoint itself requires a valid (but expired) token, creating a chicken-and-egg problem.
key_files:
  - src/middleware/auth.ts — JWT validation + role guard middleware
  - src/config/env.ts — JWKS_URI and JWT_ISSUER environment config
  - src/routes/users.ts — first route to use the new auth guard (reference implementation)
files_read: [src/middleware/auth.ts, src/routes/users.ts, package.json, src/config/env.ts]
files_modified: [src/middleware/auth.ts, src/config/env.ts, src/routes/users.ts, package.json]
</eagle-summary>

WHY THIS MATTERS: Eagle Mem re-injects this summary at the start of future sessions. The 'decisions' field prevents re-debating settled choices. The 'gotchas' field prevents repeating the same mistakes. The 'key_files' field tells the next session exactly where to start reading instead of exploring blindly. Write these fields as if you are briefing a colleague who will pick up your work tomorrow — because that is exactly what happens.
"

# Output context (plain text stdout = additionalContext for SessionStart)
if [ -n "$context" ]; then
    echo "$context"
fi

exit 0
