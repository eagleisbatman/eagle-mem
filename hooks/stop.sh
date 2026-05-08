#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Stop hook
# Fires when Claude's turn ends
# Primary: extracts summary from transcript heuristically
# Bonus: eagle-summary block overrides where present
# LLM enrichment fills in decisions/gotchas/key_files
# ═══════════════════════════════════════════════════════════
set +e
[ "${EAGLE_MEM_DISABLE_HOOKS:-}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/provider.sh"

eagle_ensure_db

input=$(eagle_read_stdin)
[ -z "$input" ] && exit 0

IFS=$'\x1f' read -r session_id cwd transcript_path agent_type <<< \
    "$(echo "$input" | jq -r '[.session_id, .cwd, .transcript_path, .agent_type] | map(. // "") | join("")')"
last_assistant_message=$(echo "$input" | jq -r '.last_assistant_message // empty')
agent=$(eagle_agent_source_from_json "$input")

[ -z "$session_id" ] && exit 0
[ -n "$agent_type" ] && [ "$agent_type" != "main" ] && exit 0

project=$(eagle_project_from_hook_input "$input")
[ -z "$project" ] && exit 0

eagle_log "INFO" "Stop: session=$session_id project=$project transcript=$transcript_path agent=$agent"

# Ensure session exists (may not if SessionStart didn't fire)
eagle_upsert_session "$session_id" "$project" "$cwd" "" "" "$agent"

# Reconcile from git diff, not only from edit-tool hooks. This keeps
# anti-regression agent-agnostic: Claude, Codex, manual edits, and script edits
# all become visible before a release boundary.
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    changed_files=$(eagle_changed_files_for_release "$cwd")
    if [ -n "$changed_files" ]; then
        eagle_reconcile_current_feature_verifications "$project" "$cwd" "$session_id" "Stop" "Repository diff detected at turn end" "$changed_files" >/dev/null
    fi
fi

# ─── Primary: heuristic extraction from transcript ───────────

request=""
heuristic_reads=""
heuristic_writes=""

eagle_clean_request_candidates() {
    grep -v '<local-command-caveat>' \
        | grep -v '<system-reminder>' \
        | grep -v '<command-name>' \
        | grep -v '<command-message>' \
        | grep -v '^\[{' \
        | grep -v '^# AGENTS.md instructions' \
        | grep -v '^<environment_context>' \
        | awk 'NF' \
        | tail -1 \
        | cut -c1-500
}

if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    request=$(jq -r 'select(.type == "user") | .message.content | if type == "string" then . elif type == "array" then [.[] | select(.type == "text") | .text] | join(" ") else "" end' "$transcript_path" 2>/dev/null \
        | eagle_clean_request_candidates)

    if [ -z "$request" ]; then
        request=$(jq -r '
            select(.type == "response_item" and .payload.role == "user")
            | .payload.content
            | if type == "string" then .
              elif type == "array" then [.[]? | select(.type == "input_text" or .type == "text") | .text] | join(" ")
              else "" end
        ' "$transcript_path" 2>/dev/null \
            | eagle_clean_request_candidates)
    fi

    if [ -z "$request" ]; then
        request=$(jq -r 'select(.type == "event_msg" and .payload.type == "user_message") | .payload.message // empty' "$transcript_path" 2>/dev/null \
            | eagle_clean_request_candidates)
    fi

    heuristic_reads=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | select(.name == "Read") | .input.file_path // empty' "$transcript_path" 2>/dev/null | sort -u | head -20)
    heuristic_writes=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | select(.name == "Write" or .name == "Edit") | .input.file_path // empty' "$transcript_path" 2>/dev/null | sort -u | head -20)
fi

files_read="[]"
files_modified="[]"
if [ -n "$heuristic_reads" ]; then
    files_read=$(echo "$heuristic_reads" | jq -Rsc 'split("\n") | map(select(. != ""))')
fi
if [ -n "$heuristic_writes" ]; then
    files_modified=$(echo "$heuristic_writes" | jq -Rsc 'split("\n") | map(select(. != ""))')
fi

investigated=""
learned=""
completed=""
next_steps=""
notes=""
decisions=""
gotchas=""
key_files=""
affected_features=""
verified_features=""
regression_risks=""

eagle_log "INFO" "Stop: heuristic extraction complete"

# ─── Bonus: eagle-summary block overrides where present ──────

if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    text_content=$(jq -r -s '
        [.[] | select(.type == "assistant")] | last |
        if . then
            [.message.content[]? | select(.type == "text") | .text] | join("\n")
        else "" end
    ' "$transcript_path" 2>/dev/null)

    if [ -z "$text_content" ]; then
        text_content=$(jq -r -s '
            def content_text:
                if type == "string" then .
                elif type == "array" then
                    [.[]? | select(.type == "output_text" or .type == "text") | (.text // empty)] | join("\n")
                else "" end;

            (
                [.[] | select(.type == "response_item" and .payload.role == "assistant") | (.payload.content | content_text)]
                | map(select(. != ""))
                | last
            ) // (
                [.[] | select(.type == "event_msg" and .payload.type == "agent_message") | (.payload.message // "")]
                | map(select(. != ""))
                | last
            ) // ""
        ' "$transcript_path" 2>/dev/null)
    fi
fi

if [ -z "$text_content" ]; then
    text_content="$last_assistant_message"
fi

# Strip <private>...</private> blocks
text_content=$(echo "$text_content" | sed -E '/<[Pp][Rr][Ii][Vv][Aa][Tt][Ee][^>]*>/,/<\/[Pp][Rr][Ii][Vv][Aa][Tt][Ee][[:space:]]*>/d')

summary_block=""
if [ -n "$text_content" ] && echo "$text_content" | grep -q '<eagle-summary>' 2>/dev/null; then
    summary_block=$(echo "$text_content" | sed -n '/<eagle-summary>/,/<\/eagle-summary>/p' | sed '1d;$d')
fi

if [ -n "$summary_block" ]; then
    parse_field() {
        local block="$1"
        local field="$2"
        echo "$block" | awk -v f="$field" '
            BEGIN { IGNORECASE=1; found=0 }
            $0 ~ "^"f":" {
                sub("^"f":[[:space:]]*", ""); found=1; val=$0; next
            }
            found && /^(request|investigated|learned|completed|next_steps|files_read|files_modified|notes|decisions|gotchas|key_files|affected_features|verified_features|regression_risks):/ { exit }
            found { val = val " " $0 }
            END { if (found) print val }
        '
    }

    # Override heuristic fields with eagle-summary where non-empty
    _val=$(parse_field "$summary_block" "request");       [ -n "$_val" ] && request="$_val"
    _val=$(parse_field "$summary_block" "investigated");  [ -n "$_val" ] && investigated="$_val"
    _val=$(parse_field "$summary_block" "learned");       [ -n "$_val" ] && learned="$_val"
    _val=$(parse_field "$summary_block" "completed");     [ -n "$_val" ] && completed="$_val"
    _val=$(parse_field "$summary_block" "next_steps");    [ -n "$_val" ] && next_steps="$_val"
    _val=$(parse_field "$summary_block" "decisions");     [ -n "$_val" ] && decisions="$_val"
    _val=$(parse_field "$summary_block" "gotchas");       [ -n "$_val" ] && gotchas="$_val"
    _val=$(parse_field "$summary_block" "key_files");     [ -n "$_val" ] && key_files="$_val"
    _val=$(parse_field "$summary_block" "affected_features"); [ -n "$_val" ] && affected_features="$_val"
    _val=$(parse_field "$summary_block" "verified_features"); [ -n "$_val" ] && verified_features="$_val"
    _val=$(parse_field "$summary_block" "regression_risks");  [ -n "$_val" ] && regression_risks="$_val"

    # Convert bracket-list to JSON array
    to_json_array() {
        local raw="$1"
        raw=$(echo "$raw" | sed 's/^\[//;s/\]$//')
        echo "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -Rsc 'split("\n") | map(select(. != ""))'
    }

    raw_fr=$(parse_field "$summary_block" "files_read")
    raw_fm=$(parse_field "$summary_block" "files_modified")
    [ -n "$raw_fr" ] && files_read=$(to_json_array "$raw_fr")
    [ -n "$raw_fm" ] && files_modified=$(to_json_array "$raw_fm")

    eagle_log "INFO" "Stop: eagle-summary block merged over heuristic data"
fi

# ─── LLM enrichment: extract structured data when eagle-summary absent ──
# Runs when: (a) no eagle-summary block, OR (b) heuristic data is thin
# Skips when: eagle-summary already provided rich data, OR no text to analyze

context_pressure=0
if [ -f "$EAGLE_MEM_DIR/.context-pressure" ]; then
    context_pressure=1
fi

has_rich_data=0
if [ -n "$decisions" ] || [ -n "$gotchas" ] || [ -n "$key_files" ]; then
    has_rich_data=1
fi

request_is_polluted=0
if echo "$request" | grep -qE '<(local-command-caveat|system-reminder|command-name)>' 2>/dev/null; then
    request_is_polluted=1
fi

needs_enrichment=0
defer_enrichment=0
if [ "$has_rich_data" -eq 0 ]; then
    needs_enrichment=1
elif [ "$context_pressure" -eq 1 ]; then
    needs_enrichment=1
elif [ -z "$completed" ] && [ -z "$learned" ]; then
    needs_enrichment=1
elif [ "$request_is_polluted" -eq 1 ]; then
    needs_enrichment=1
fi

if [ "$needs_enrichment" -eq 1 ]; then
    provider=$(eagle_config_get "provider" "type" "none" 2>/dev/null)
    # Stop hooks must stay fast. Expensive LLM enrichment belongs in curate or
    # another background path; nested agent_cli calls can exceed Codex/Claude
    # lifecycle timeouts and make the hook look broken to users.
    if [ "${EAGLE_MEM_STOP_ENRICH:-0}" != "1" ]; then
        defer_enrichment=1
        eagle_log "INFO" "Stop: LLM enrichment skipped — fast hook path (provider=$provider)"
    elif [ "$provider" != "none" ] && [ -n "$text_content" ]; then
        excerpt=$(echo "$text_content" | tail -c 3000)

        enrich_prompt="Extract facts from this AI coding session. Only include items with clear evidence in the session text. Do NOT invent or repeat example content.

Respond with EXACTLY these sections (omit sections with no evidence):

REQUEST:
One-line summary of what the user asked for. No system tags or XML.

COMPLETED:
What was actually accomplished. Be specific about changes made.

LEARNED:
Non-obvious discoveries or insights from the session.

DECISIONS:
Each as: <what was decided> — why: <reason>

GOTCHAS:
Each as: <surprising finding or pitfall>

KEY_FILES:
Each as: <filepath>

SESSION TEXT:
$excerpt"

        enrich_system="You extract structured facts from Claude Code and Codex development sessions. Output format for decisions: '- Did X — why: Y'. Output format for gotchas: '- Gotcha description'. Be concise. Only include items with clear evidence in the session text. Never fabricate content."
        enrich_result=$(eagle_llm_call "$enrich_prompt" "$enrich_system" 768 2>/dev/null)
        llm_rc=$?

        if [ $llm_rc -ne 0 ] || [ -z "$enrich_result" ]; then
            eagle_log "WARN" "Stop: LLM enrichment failed (rc=$llm_rc) for session=$session_id provider=$provider"
        else
            extract_section() {
                local result="$1" header="$2"
                echo "$result" | awk -v h="$header:" '
                    $0 == h || $0 ~ "^"h { found=1; next }
                    found && /^[A-Z_]+:/ { exit }
                    found && /^[[:space:]]*$/ { next }
                    found && /^- / { sub(/^- /, ""); lines[++n] = $0; next }
                    found { lines[++n] = $0 }
                    END { for (i=1; i<=n; i++) { printf "%s", lines[i]; if (i<n) printf "; " } }
                '
            }
            _req=$(extract_section "$enrich_result" "REQUEST")
            _comp=$(extract_section "$enrich_result" "COMPLETED")
            _learn=$(extract_section "$enrich_result" "LEARNED")
            _dec=$(extract_section "$enrich_result" "DECISIONS")
            _got=$(extract_section "$enrich_result" "GOTCHAS")
            _kf=$(extract_section "$enrich_result" "KEY_FILES")

            [ -z "$request" ] || [ "$request_is_polluted" -eq 1 ] && [ -n "$_req" ] && request="$_req"
            [ -z "$completed" ] && [ -n "$_comp" ] && completed="$_comp"
            [ -z "$learned" ] && [ -n "$_learn" ] && learned="$_learn"
            [ -z "$decisions" ] && [ -n "$_dec" ] && decisions="$_dec"
            [ -z "$gotchas" ] && [ -n "$_got" ] && gotchas="$_got"
            [ -z "$key_files" ] && [ -n "$_kf" ] && key_files="$_kf"

            eagle_log "INFO" "Stop: LLM enrichment extracted for session=$session_id (req=${#_req} comp=${#_comp} dec=${#_dec})"
        fi
    else
        eagle_log "INFO" "Stop: LLM enrichment skipped — provider=$provider text_len=${#text_content}"
    fi
else
    eagle_log "INFO" "Stop: LLM enrichment skipped — rich data already present"
fi

# ─── Heuristic fallback: derive fields from tool activity when no LLM ──
# Fills key_files and completed from files_modified when both are empty

if [ -z "$key_files" ] && [ -n "$files_modified" ] && [ "$files_modified" != "[]" ]; then
    key_files=$(echo "$files_modified" | jq -r '.[]?' 2>/dev/null | while read -r f; do basename "$f"; done | sort -u | head -10 | paste -sd ', ' -)
fi

if [ -z "$completed" ] && [ -n "$files_modified" ] && [ "$files_modified" != "[]" ]; then
    mod_count=$(echo "$files_modified" | jq -r '.[]?' 2>/dev/null | wc -l | tr -d ' ')
    mod_names=$(echo "$files_modified" | jq -r '.[]?' 2>/dev/null | while read -r f; do basename "$f"; done | sort -u | head -5 | paste -sd ', ' -)
    if [ "${mod_count:-0}" -gt 0 ]; then
        completed="Modified ${mod_count} files: ${mod_names}"
    fi
elif [ -z "$completed" ] && [ -n "$files_read" ] && [ "$files_read" != "[]" ]; then
    read_count=$(echo "$files_read" | jq -r '.[]?' 2>/dev/null | wc -l | tr -d ' ')
    read_names=$(echo "$files_read" | jq -r '.[]?' 2>/dev/null | while read -r f; do basename "$f"; done | sort -u | head -5 | paste -sd ', ' -)
    if [ "${read_count:-0}" -gt 0 ]; then
        completed="Reviewed ${read_count} files: ${read_names}"
    fi
fi

if [ -z "$key_files" ] && [ -n "$files_read" ] && [ "$files_read" != "[]" ]; then
    key_files=$(echo "$files_read" | jq -r '.[]?' 2>/dev/null | while read -r f; do basename "$f"; done | sort -u | head -10 | paste -sd ', ' -)
fi

# ─── Test reminder for guardrailed files ─────────────────

if [ -n "$files_modified" ] && [ "$files_modified" != "[]" ]; then
    # Short-circuit: skip per-file loop if project has no guardrails at all
    has_gr=$(eagle_has_any_guardrails "$project" 2>/dev/null)
    if [ -n "$has_gr" ]; then
        guardrailed_files=""
        while IFS= read -r mod_file; do
            [ -z "$mod_file" ] && continue
            mod_basename=$(basename "$mod_file")
            gr_check=$(eagle_get_guardrails_for_file "$project" "$mod_basename" 2>/dev/null)
            if [ -n "$gr_check" ]; then
                guardrailed_files+="${mod_basename}, "
            fi
        done < <(echo "$files_modified" | jq -r '.[]?' 2>/dev/null)

        if [ -n "$guardrailed_files" ]; then
            guardrailed_files=${guardrailed_files%, }
            test_reminder="Run affected tests for guardrailed files: ${guardrailed_files}"
            if [ -n "$next_steps" ]; then
                next_steps="${next_steps}; ${test_reminder}"
            else
                next_steps="$test_reminder"
            fi
            eagle_log "INFO" "Stop: added test reminder for guardrailed files: $guardrailed_files"
        fi
    fi
fi

# ─── Redact secrets from all text fields before storage ────

request=$(echo "$request" | eagle_redact)
investigated=$(echo "$investigated" | eagle_redact)
learned=$(echo "$learned" | eagle_redact)
completed=$(echo "$completed" | eagle_redact)
next_steps=$(echo "$next_steps" | eagle_redact)
decisions=$(echo "$decisions" | eagle_redact)
gotchas=$(echo "$gotchas" | eagle_redact)
key_files=$(echo "$key_files" | eagle_redact)
notes=$(echo "$notes" | eagle_redact)
affected_features=$(echo "$affected_features" | eagle_redact)
verified_features=$(echo "$verified_features" | eagle_redact)
regression_risks=$(echo "$regression_risks" | eagle_redact)

regression_notes=""
[ -n "$affected_features" ] && regression_notes+="affected_features: $affected_features"
if [ -n "$verified_features" ]; then
    [ -n "$regression_notes" ] && regression_notes+="; "
    regression_notes+="verified_features: $verified_features"
fi
if [ -n "$regression_risks" ]; then
    [ -n "$regression_notes" ] && regression_notes+="; "
    regression_notes+="regression_risks: $regression_risks"
fi
if [ -n "$regression_notes" ]; then
    if [ -n "$notes" ]; then
        notes="${notes}; ${regression_notes}"
    else
        notes="$regression_notes"
    fi
fi

# ─── Write to database ─────────────────────────────────────

if [ -n "$request" ] || [ -n "$completed" ] || [ -n "$learned" ]; then
    if eagle_insert_summary "$session_id" "$project" "$request" "$investigated" "$learned" "$completed" "$next_steps" "$files_read" "$files_modified" "$notes" "$decisions" "$gotchas" "$key_files" "$agent"; then
        eagle_log "INFO" "Stop: summary saved for session=$session_id"
    else
        eagle_log "ERROR" "Stop: summary insert FAILED for session=$session_id — check DB constraints"
    fi
fi

if [ "$defer_enrichment" -eq 1 ] && [ "${EAGLE_MEM_STOP_BACKGROUND_ENRICH:-1}" = "1" ] && [ -n "$text_content" ]; then
    mkdir -p "$EAGLE_MEM_DIR/tmp" 2>/dev/null || true
    enrich_job=$(mktemp "$EAGLE_MEM_DIR/tmp/summary-enrich.XXXXXX.json" 2>/dev/null)
    if [ -n "$enrich_job" ]; then
        jq -cn \
            --arg session_id "$session_id" \
            --arg project "$project" \
            --arg agent "$agent" \
            --arg text "$text_content" \
            '{session_id:$session_id, project:$project, agent:$agent, text:$text}' > "$enrich_job"

        enrich_script="$SCRIPT_DIR/../scripts/enrich-summary.sh"
        if [ -x "$enrich_script" ]; then
            nohup env EAGLE_MEM_DISABLE_HOOKS=1 EAGLE_AGENT_SOURCE="$agent" EAGLE_AGENT_CWD="$cwd" bash "$enrich_script" "$enrich_job" >/dev/null 2>&1 &
            eagle_log "INFO" "Stop: queued background summary enrichment for session=$session_id"
        else
            rm -f "$enrich_job" 2>/dev/null || true
            eagle_log "WARN" "Stop: background enrichment script missing: $enrich_script"
        fi
    fi
fi

exit 0
