#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — UserPromptSubmit hook
# Fires when the user submits a prompt
# Searches memory for relevant context and injects it
# ═══════════════════════════════════════════════════════════
set +e
[ "${EAGLE_MEM_DISABLE_HOOKS:-}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

[ ! -f "$EAGLE_MEM_DB" ] && exit 0

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
user_prompt=$(echo "$input" | jq -r '.prompt // empty')
agent=$(eagle_agent_source_from_json "$input")

[ -z "$user_prompt" ] && exit 0

project=$(eagle_project_from_hook_input "$input")
recall_scope=$(eagle_recall_project_scope_from_cwd "$cwd" "$project")
[ -z "$recall_scope" ] && recall_scope="$project"
codex_compact=0
[ "$agent" = "codex" ] && codex_compact=1

# ─── Context pressure detection (turn counter since last compact) ──
# Must run before any early exits so every prompt is counted

context=""

if [ -n "$session_id" ] && eagle_validate_session_id "$session_id"; then
    counter_file="$EAGLE_MEM_DIR/.turn-counter.${session_id}"
    turn_count=0
    [ -f "$counter_file" ] && turn_count=$(cat "$counter_file" 2>/dev/null | tr -d '[:space:]')
    turn_count=${turn_count:-0}
    turn_count=$((turn_count + 1))
    echo "$turn_count" > "$counter_file" 2>/dev/null
    eagle_log "INFO" "UserPromptSubmit: turn=$turn_count session=$session_id"

    if [ "$turn_count" -ge 30 ]; then
        if [ "$codex_compact" -eq 1 ]; then
            context+="
Eagle Mem context pressure: critical ($turn_count turns since compact)
- Keep the next Codex reply user-clean.
- Do not print Eagle Mem summary blocks or internals.
- Add a short normal handoff note if useful, then ask the user to run /compact.
"
        else
            context+="
=== Eagle Mem: Context Pressure Critical ($turn_count turns since compact) ===
IMMEDIATELY emit a detailed <eagle-summary> covering ALL work this session.
Tell the user to run /compact NOW to avoid losing context.
"
        fi
        echo "$turn_count" > "$EAGLE_MEM_DIR/.context-pressure"
    elif [ "$turn_count" -ge 20 ]; then
        if [ "$codex_compact" -eq 1 ]; then
            context+="
Eagle Mem context pressure: high ($turn_count turns since compact)
- Keep the next Codex reply clean.
- Do not print Eagle Mem summary blocks or internals.
- Summarize durable decisions in normal prose only.
"
        else
            context+="
=== Eagle Mem: Context Pressure High ($turn_count turns since compact) ===
Include a thorough <eagle-summary> in your next response — capture all decisions, gotchas, and learned context before compaction.
Suggest the user run /compact to free context for continued work.
"
        fi
        echo "$turn_count" > "$EAGLE_MEM_DIR/.context-pressure"
    else
        rm -f "$EAGLE_MEM_DIR/.context-pressure" 2>/dev/null
    fi
fi

# Skip short prompts — not enough signal for meaningful search
word_count=$(echo "$user_prompt" | wc -w | tr -d ' ')
if [ "$word_count" -lt 3 ]; then
    eagle_emit_context_for_agent "$agent" "UserPromptSubmit" "$context"
    exit 0
fi

# Build FTS5 query from significant words (drop stop words, take first 6)
fts_query=$(echo "$user_prompt" | tr -cs '[:alnum:]' ' ' | tr '[:upper:]' '[:lower:]' | \
    awk '{
        split("the a an is are was were be been being have has had do does did will would shall should may might can could of in to for on with at by from", sw, " ")
        for (i in sw) stop[sw[i]]=1
        n=0
        split("ad ai ui ux db", keep, " ")
        for (i in keep) short_keep[keep[i]]=1
        for (i=1; i<=NF && n<6; i++) {
            if ((length($i) > 2 || ($i in short_keep)) && !($i in stop)) {
                printf "%s%s", (n>0?" OR ":""), $i; n++
            }
        }
    }')

if [ -z "$fts_query" ]; then
    eagle_emit_context_for_agent "$agent" "UserPromptSubmit" "$context"
    exit 0
fi

# ─── Agent-run orchestration nudge ────────────────────────

lower_prompt=$(printf '%s' "$user_prompt" | tr '[:upper:]' '[:lower:]')
if printf '%s\n' "$lower_prompt" | grep -Eq '(orchestrat|worker|parallel|multi-agent|multi agent|split|lane|scope out|plan and get started|broad|full codebase|release|publish|ship)'; then
    if [ "$codex_compact" -eq 1 ]; then
        context+="
Eagle Mem orchestration:
- For broad work, you run eagle-mem orchestrate yourself.
- Use durable lanes, opposite-agent workers, and concise user-visible status.
"
    else
        context+="=== Eagle Mem: Orchestration Protocol ===
If this request is broad enough to split into worker lanes, YOU run the orchestration commands. Do not ask the user to run them.

Use:
  eagle-mem orchestrate init \"<goal>\"
  eagle-mem orchestrate lane add <key> --agent codex|claude-code --desc \"<self-contained scope>\" --validate \"<command>\"
  eagle-mem orchestrate lane start|block|complete <key>

Keep this mostly invisible to the user; surface only concise status or handoff when useful.
"
    fi
fi

# Search for relevant past summaries (cross-session)
summary_limit=2
code_limit=3
if [ "$codex_compact" -eq 1 ]; then
    summary_limit=1
    code_limit=2
fi

memory_limit=3
[ "$codex_compact" -eq 1 ] && memory_limit=2

results=$(eagle_search_summaries "$fts_query" "$recall_scope" "$summary_limit")
memory_results=$(eagle_search_agent_memories "$fts_query" "$recall_scope" "$memory_limit" 2>/dev/null || true)

if [ -n "$results" ] || [ -n "$memory_results" ]; then
    if [ "$codex_compact" -eq 1 ]; then
        context+="
Eagle Mem recalls:
"
    else
        context+="Eagle Mem recalls: apply these retrieved project facts before answering. If they are relevant to the user's prompt, start with one short \"Eagle Mem recalls:\" attribution line.

=== Eagle Mem: Relevant Recall ===
"
    fi
    while IFS='|' read -r req completed learned _next_steps created_at _proj decisions gotchas key_files summary_agent; do
        [ -z "$req" ] && [ -z "$completed" ] && continue
        origin_label=$(eagle_agent_label "$summary_agent")
        if [ "$codex_compact" -eq 1 ]; then
            req=$(eagle_trim_text "$req" 90)
            completed=$(eagle_trim_text "$completed" 150)
            learned=$(eagle_trim_text "$learned" 110)
            context+="- Recent [$origin_label]: "
            if [ -n "$completed" ]; then
                context+="$completed"
            else
                context+="$req"
            fi
            [ -n "$learned" ] && context+="
  Learned: $learned"
            context+="
"
        else
            req=$(eagle_trim_text "$req" 160)
            completed=$(eagle_trim_text "$completed" 220)
            learned=$(eagle_trim_text "$learned" 180)
            decisions=$(eagle_trim_text "$decisions" 160)
            gotchas=$(eagle_trim_text "$gotchas" 160)
            key_files=$(eagle_trim_text "$key_files" 160)
            context+="[$created_at][$origin_label] "
            [ -n "$req" ] && context+="$req"
            [ -n "$completed" ] && context+=" → $completed"
            [ -n "$learned" ] && context+=" (Learned: $learned)"
            [ -n "$decisions" ] && context+="
  Decisions: $decisions"
            [ -n "$gotchas" ] && context+="
  Gotchas: $gotchas"
            [ -n "$key_files" ] && context+="
  Key files: $key_files"
            context+="
"
        fi
    done <<< "$results"

    while IFS='|' read -r mname mtype mdesc msnippet _mfile _mupdated morigin; do
        [ -z "$mname" ] && continue
        case "$mname" in
            "Codex Memory Registry"|"Codex Memory Summary") continue ;;
        esac
        origin_label=$(eagle_agent_label "$morigin")
        if [ "$codex_compact" -eq 1 ]; then
            mdesc=$(eagle_trim_text "$mdesc" 120)
            context+="- Memory [$mtype][$origin_label]: $mname"
            [ -n "$mdesc" ] && context+=" — $mdesc"
            context+="
"
        else
            mdesc=$(eagle_trim_text "$mdesc" 180)
            msnippet=$(eagle_trim_text "$msnippet" 220)
            context+="[Memory][$origin_label][$mtype] $mname"
            [ -n "$mdesc" ] && context+=" — $mdesc"
            [ -n "$msnippet" ] && context+="
  Snippet: $msnippet"
            context+="
"
        fi
    done <<< "$memory_results"
fi

# Search indexed code chunks (if any exist for this project)
has_chunks=$(eagle_count_code_chunks "$project")
if [ "${has_chunks:-0}" -gt 0 ]; then
    code_results=$(eagle_search_code_chunks "$fts_query" "$project" "$code_limit")

    if [ -n "$code_results" ]; then
        if [ "$codex_compact" -eq 1 ]; then
            context+="
Relevant code:
"
        else
            context+="=== Eagle Mem: Relevant Code ===
"
        fi
        while IFS='|' read -r fpath sline eline lang; do
            [ -z "$fpath" ] && continue
            if [ "$codex_compact" -eq 1 ]; then
                context+="- $fpath:${sline}-${eline}"
            else
                context+="$fpath:${sline}-${eline}"
            fi
            [ -n "$lang" ] && context+=" ($lang)"
            context+="
"
        done <<< "$code_results"
    fi
fi

[ -z "$context" ] && exit 0

if [ "$codex_compact" -eq 1 ]; then
    context+="
Note: use only if directly useful. If you mention it to the user, keep Eagle Mem attribution to one short line.
"
else
    context+="
IMPORTANT: If directly useful, start with one short Eagle Mem attribution line, then proceed.

=== Eagle Mem: Persistent Memory ===
"
fi

eagle_emit_context_for_agent "$agent" "UserPromptSubmit" "$context"
exit 0
