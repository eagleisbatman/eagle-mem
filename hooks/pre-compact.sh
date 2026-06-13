#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — PreCompact hook
# Fires before Claude Code compacts the context window (manual or auto).
#
# PreCompact is a side-effect-only event: per the Claude Code hooks contract it
# can block compaction but CANNOT inject context into the compacted window — that
# is SessionStart(source=compact)'s job. What it CAN do is guarantee a rich
# session summary is persisted *before* the window collapses, instead of racing
# the async background enricher that the Stop hook queues with nohup.
#
# So this hook runs scripts/enrich-summary.sh SYNCHRONOUSLY. PreCompact fires
# rarely (once per compaction), so it can afford the LLM enrichment call that the
# fast Stop path deliberately defers for speed. It NEVER blocks compaction (always
# exits 0) and NEVER overwrites an agent-authored `eagle-mem session save`, which
# is already the richest capture and already survives compaction via SessionStart.
# ═══════════════════════════════════════════════════════════
set +e
[ "${EAGLE_MEM_DISABLE_HOOKS:-}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

IFS=$'\x1f' read -r session_id cwd transcript_path trigger <<< \
    "$(echo "$input" | jq -r '[.session_id, .cwd, .transcript_path, .trigger] | map(. // "") | join("")')"
agent=$(eagle_agent_source_from_json "$input")

[ -z "$session_id" ] && exit 0

project=$(eagle_project_from_hook_input "$input")
[ -z "$project" ] && exit 0

eagle_hook_observability_begin "$input" "PreCompact"
eagle_log "INFO" "PreCompact: trigger=${trigger:-unknown} session=$session_id project=$project — capturing summary before compaction"

# Bound any synchronous work. The agent_cli provider shells out to a nested
# claude/codex CLI with NO internal timeout (provider.sh bounds only the
# curl-based API calls), so a hung provider could otherwise stall compaction up
# to the Claude Code hook timeout and be killed mid-write. We cap it and proceed;
# a missed synchronous enrichment is still covered by Stop's background path and
# the next SessionStart. Portable across macOS (timeout may be absent).
EAGLE_PRECOMPACT_TIMEOUT="${EAGLE_MEM_PRECOMPACT_TIMEOUT:-45}"
eagle_run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${secs}s" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${secs}s" "$@"
    else
        "$@" &
        local pid=$!
        ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
        local watcher=$!
        wait "$pid" 2>/dev/null
        local rc=$?
        kill -TERM "$watcher" 2>/dev/null
        return "$rc"
    fi
}

# Session may not exist yet if SessionStart didn't fire (or fired for a sibling).
eagle_upsert_session "$session_id" "$project" "$cwd" "" "" "$agent"

emit_capture_event() {
    local captured="$1" mode="$2"
    eagle_insert_event "$project" "$session_id" "$agent" "compaction_capture" "" "PreCompact" "ok" \
        "$(jq -nc --arg trigger "${trigger:-}" --arg mode "$mode" --argjson captured "$captured" \
            '{trigger:$trigger, captured:$captured, mode:$mode}')" >/dev/null 2>&1 || true
    eagle_hook_observability_set_detail \
        "$(jq -nc --arg trigger "${trigger:-}" --arg mode "$mode" --argjson captured "$captured" \
            '{trigger:$trigger, captured:$captured, mode:$mode}')"
}

# An agent-authored `eagle-mem session save` is the richest possible capture and
# is authoritative. If one already exists for this session it already survives
# compaction (SessionStart reloads it), so don't spend an LLM call or risk a
# write race against it.
existing_source=$(eagle_summary_capture_source "$session_id" 2>/dev/null || true)
if [ "$existing_source" = "agent" ]; then
    eagle_log "INFO" "PreCompact: agent-authored summary already present for session=$session_id — skipping enrichment"
    emit_capture_event false "agent-summary-present"
    eagle_hook_observability_complete 0
    exit 0
fi

# Latest assistant text from the transcript (Claude format). The same surface the
# Stop hook hands the enricher; enrich-summary.sh bounds it to a tail excerpt
# before sending it to the provider.
text_content=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    text_content=$(jq -r -s '
        [.[] | select(.type == "assistant")]
        | (.[-5:] // [])
        | [.[] | .message.content[]? | select(.type == "text") | .text]
        | join("\n")
    ' "$transcript_path" 2>/dev/null)
fi

captured=false
mode="no-text"
if [ -n "$text_content" ]; then
    provider=$(eagle_config_get "provider" "type" "none" 2>/dev/null)
    if [ "$provider" = "none" ]; then
        # No provider — the Stop hook's heuristic summary already covers this
        # session and survives compaction; nothing richer to do here.
        mode="no-provider"
        eagle_log "INFO" "PreCompact: no provider configured — Stop heuristic summary covers session=$session_id"
    else
        mkdir -p "$EAGLE_MEM_DIR/tmp" 2>/dev/null || true
        enrich_job=$(mktemp "$EAGLE_MEM_DIR/tmp/precompact-enrich.XXXXXX.json" 2>/dev/null)
        if [ -n "$enrich_job" ]; then
            # Redact secrets BEFORE persisting/sending the transcript text.
            enrich_text=$(printf '%s' "$text_content" | eagle_redact)
            jq -cn \
                --arg session_id "$session_id" \
                --arg project "$project" \
                --arg agent "$agent" \
                --arg text "$enrich_text" \
                '{session_id:$session_id, project:$project, agent:$agent, text:$text}' > "$enrich_job"

            enrich_script="$SCRIPT_DIR/../scripts/enrich-summary.sh"
            if [ -f "$enrich_script" ]; then
                # SYNCHRONOUS (not nohup): the point of PreCompact is to land the
                # rich summary before the window collapses. enrich-summary.sh
                # respects capture_source precedence (fill-only over an agent row),
                # exits 0 on provider/LLM failure, and removes its own job file.
                # Time-bounded so a hung provider can never stall compaction.
                eagle_run_bounded "$EAGLE_PRECOMPACT_TIMEOUT" \
                    env EAGLE_MEM_DISABLE_HOOKS=1 EAGLE_AGENT_SOURCE="$agent" EAGLE_AGENT_CWD="$cwd" \
                    bash "$enrich_script" "$enrich_job" >/dev/null 2>&1
                erc=$?
                # Clean up the job file if enrich-summary was killed mid-run (it
                # removes its own on a normal exit).
                rm -f "$enrich_job" 2>/dev/null || true
                if [ "$erc" -eq 0 ]; then
                    captured=true
                    mode="enriched"
                    eagle_log "INFO" "PreCompact: synchronous enrichment complete for session=$session_id provider=$provider"
                else
                    mode="enrich-timeout-or-error"
                    eagle_log "WARN" "PreCompact: synchronous enrichment did not complete (rc=$erc) for session=$session_id — Stop background path will cover it"
                fi
            else
                rm -f "$enrich_job" 2>/dev/null || true
                mode="enricher-missing"
                eagle_log "WARN" "PreCompact: enrichment script missing: $enrich_script"
            fi
        fi
    fi
fi

emit_capture_event "$captured" "$mode"
eagle_hook_observability_complete 0
exit 0
