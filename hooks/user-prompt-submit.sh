#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — UserPromptSubmit hook
# Fires when the user submits a prompt
# Searches memory for relevant context and injects it
# ═══════════════════════════════════════════════════════════
set +e

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

project=$(eagle_project_from_cwd "$cwd")

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
        context+="
=== Eagle Mem: Context Pressure Critical ($turn_count turns since compact) ===
IMMEDIATELY emit a detailed <eagle-summary> covering ALL work this session.
Tell the user to run /compact NOW to avoid losing context.
"
        echo "$turn_count" > "$EAGLE_MEM_DIR/.context-pressure"
    elif [ "$turn_count" -ge 20 ]; then
        context+="
=== Eagle Mem: Context Pressure High ($turn_count turns since compact) ===
Include a thorough <eagle-summary> in your next response — capture all decisions, gotchas, and learned context before compaction.
Suggest the user run /compact to free context for continued work.
"
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
        for (i=1; i<=NF && n<6; i++) {
            if (length($i) > 2 && !($i in stop)) {
                printf "%s%s", (n>0?" OR ":""), $i; n++
            }
        }
    }')

if [ -z "$fts_query" ]; then
    eagle_emit_context_for_agent "$agent" "UserPromptSubmit" "$context"
    exit 0
fi

# Search for relevant past summaries (cross-session)
results=$(eagle_search_summaries "$fts_query" "$project" 3)

if [ -n "$results" ]; then
    context+="=== Eagle Mem: Relevant Recall ===
"
    while IFS='|' read -r req completed learned _next_steps created_at _proj decisions gotchas key_files summary_agent; do
        [ -z "$req" ] && [ -z "$completed" ] && continue
        origin_label=$(eagle_agent_label "$summary_agent")
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
    done <<< "$results"
fi

# Search indexed code chunks (if any exist for this project)
has_chunks=$(eagle_count_code_chunks "$project")
if [ "${has_chunks:-0}" -gt 0 ]; then
    code_results=$(eagle_search_code_chunks "$fts_query" "$project" 5)

    if [ -n "$code_results" ]; then
        context+="=== Eagle Mem: Relevant Code ===
"
        while IFS='|' read -r fpath sline eline lang; do
            [ -z "$fpath" ] && continue
            context+="$fpath:${sline}-${eline}"
            [ -n "$lang" ] && context+=" ($lang)"
            context+="
"
        done <<< "$code_results"
    fi
fi

[ -z "$context" ] && exit 0

context+="
IMPORTANT: When Eagle Mem finds relevant memories or code for the user's prompt, briefly mention it at the start of your response: \"Eagle Mem recalled N relevant sessions\" or \"Eagle Mem found related code in [files]\". One line max — then proceed with the answer.

=== Eagle Mem: Persistent Memory ===
"

eagle_emit_context_for_agent "$agent" "UserPromptSubmit" "$context"
exit 0
