#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Orchestrator
# Durable orchestrator/worker lane tracking for Claude Code and Codex.
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"
. "$LIB_DIR/provider.sh"

project=""
json_output=false
name="main"
agent=""
agent_explicit=false
action="status"
action_explicit=false
args=()

show_help() {
    echo -e "  ${BOLD}eagle-mem orchestrate${RESET} — Coordinate worker lanes"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem orchestrate                         ${DIM}# show active orchestration${RESET}"
    echo -e "    eagle-mem orchestrate ${CYAN}init${RESET} <goal>              ${DIM}# create/update orchestration${RESET}"
    echo -e "    eagle-mem orchestrate ${CYAN}lane add${RESET} <key>           ${DIM}# add worker lane${RESET}"
    echo -e "    eagle-mem orchestrate ${CYAN}lane start${RESET} <key>         ${DIM}# mark lane in progress${RESET}"
    echo -e "    eagle-mem orchestrate ${CYAN}lane block${RESET} <key>         ${DIM}# mark lane blocked${RESET}"
    echo -e "    eagle-mem orchestrate ${CYAN}lane complete${RESET} <key>      ${DIM}# mark lane complete${RESET}"
    echo -e "    eagle-mem orchestrate ${CYAN}lane cancel${RESET} <key>        ${DIM}# cancel lane${RESET}"
    echo -e "    eagle-mem orchestrate ${CYAN}spawn${RESET} <key>              ${DIM}# create worktree + launch worker${RESET}"
    echo -e "    eagle-mem orchestrate ${CYAN}sync${RESET} [key]               ${DIM}# reconcile worker process status${RESET}"
    echo -e "    eagle-mem orchestrate ${CYAN}complete${RESET}                 ${DIM}# mark orchestration complete${RESET}"
    echo -e "    eagle-mem orchestrate ${CYAN}cancel${RESET}                   ${DIM}# cancel orchestration${RESET}"
    echo -e "    eagle-mem orchestrate ${CYAN}handoff${RESET}                  ${DIM}# print markdown handoff${RESET}"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    ${CYAN}-p, --project${RESET} <name>      Project name (default: current dir)"
    echo -e "    ${CYAN}--name${RESET} <name>             Orchestration name (default: main)"
    echo -e "    ${CYAN}--agent${RESET} <name>            Worker agent: codex or claude-code"
    echo -e "    ${CYAN}--title${RESET} <text>            Lane title"
    echo -e "    ${CYAN}--desc${RESET} <text>             Lane description"
    echo -e "    ${CYAN}--worktree${RESET} <path>         Suggested lane worktree"
    echo -e "    ${CYAN}--validate${RESET} <command>      Validation command"
    echo -e "    ${CYAN}--notes${RESET} <text>            Status note"
    echo -e "    ${CYAN}--write${RESET} <path>            Write handoff markdown to a file"
    echo -e "    ${CYAN}--no-launch${RESET}               Prepare worktree without starting worker"
    echo -e "    ${CYAN}--no-worktree${RESET}             Run worker in current repo instead"
    echo -e "    ${CYAN}--foreground${RESET}              Run worker synchronously"
    echo -e "    ${CYAN}--dry-run${RESET}                 Print launch plan only"
    echo -e "    ${CYAN}-j, --json${RESET}                Output JSON where supported"
    echo ""
    echo -e "  ${BOLD}Example:${RESET}"
    echo -e "    ${DIM}\$${RESET} eagle-mem orchestrate init \"Ship auth cleanup\""
    echo -e "    ${DIM}\$${RESET} eagle-mem orchestrate lane add api --agent codex --desc \"Routes + tests\" --validate \"npm test\""
    echo -e "    ${DIM}\$${RESET} eagle-mem orchestrate spawn api"
    echo ""
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project) project="$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        --agent) agent="$2"; agent_explicit=true; shift 2 ;;
        -j|--json) json_output=true; shift ;;
        --help|-h) show_help ;;
        *)
            if [ "$action_explicit" = false ]; then
                action="$1"
                action_explicit=true
            else
                args+=("$1")
            fi
            shift
            ;;
    esac
done

[ -z "$project" ] && project=$(eagle_project_from_cwd "$(pwd)")
[ -z "$project" ] && { eagle_err "Cannot determine project. Use --project <name>."; exit 1; }

if [ "$json_output" = true ]; then
    eagle_ensure_db >/dev/null
else
    eagle_ensure_db
fi

project_sql=$(eagle_sql_escape "$project")
name_sql=$(eagle_sql_escape "$name")
active_agent=$(eagle_agent_source)

orchestration_id() {
    eagle_db "SELECT id FROM orchestrations
              WHERE project = '$project_sql' AND name = '$name_sql'
              ORDER BY CASE status WHEN 'active' THEN 0 ELSE 1 END, updated_at DESC
              LIMIT 1;"
}

require_orchestration_id() {
    local oid
    oid=$(orchestration_id)
    if [ -z "$oid" ]; then
        eagle_err "No orchestration found for '$project' ($name). Run: eagle-mem orchestrate init <goal>"
        exit 1
    fi
    printf '%s\n' "$oid"
}

active_orchestration_id() {
    eagle_db "SELECT id FROM orchestrations
              WHERE project = '$project_sql' AND name = '$name_sql' AND status = 'active'
              ORDER BY updated_at DESC
              LIMIT 1;"
}

require_active_orchestration_id() {
    local oid
    oid=$(active_orchestration_id)
    if [ -z "$oid" ]; then
        eagle_err "No active orchestration found for '$project' ($name). Run: eagle-mem orchestrate init <goal>"
        exit 1
    fi
    printf '%s\n' "$oid"
}

lane_source_task_id() {
    local lane_key="$1"
    printf 'lane-%s-%s\n' "$name" "$lane_key"
}

lane_file_path() {
    local lane_key="$1"
    printf 'orchestration-lane://%s/%s/%s\n' "$project" "$name" "$lane_key"
}

orchestrate_slug() {
    local value="${1:-lane}"
    value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')
    [ -z "$value" ] && value="lane"
    printf '%s\n' "$value"
}

orchestrate_project_hash() {
    printf '%s' "$project" | eagle_sha256_stream | cut -c1-10
}

orchestrate_run_key() {
    local oid="${1:-}"
    local key
    [ -z "$oid" ] && oid=$(orchestration_id)
    if [ -n "$oid" ]; then
        key=$(eagle_db "SELECT run_key FROM orchestrations WHERE id = $oid LIMIT 1;")
    else
        key=""
    fi
    [ -z "$key" ] && key="r${oid:-new}"
    orchestrate_slug "$key"
}

orchestrate_default_worker_agent() {
    local route
    route=$(eagle_config_get "orchestration" "route" "opposite")
    case "$route" in
        codex|openai-codex) echo "codex" ;;
        claude|claude-code|cloud-code) echo "claude-code" ;;
        current) echo "$active_agent" ;;
        opposite|*)
            case "$active_agent" in
                codex) echo "claude-code" ;;
                *) echo "codex" ;;
            esac
            ;;
    esac
}

orchestrate_normalize_agent() {
    local value="${1:-}"
    case "$value" in
        "") orchestrate_default_worker_agent ;;
        codex|openai-codex) echo "codex" ;;
        claude|claude-code|cloud-code) echo "claude-code" ;;
        *) return 1 ;;
    esac
}

orchestrate_worker_model() {
    case "$1" in
        codex) eagle_config_get "orchestration" "codex_worker_model" "gpt-5.5" ;;
        *) eagle_config_get "orchestration" "claude_worker_model" "claude-opus-4-7" ;;
    esac
}

orchestrate_worker_effort() {
    case "$1" in
        codex) eagle_config_get "orchestration" "codex_worker_effort" "xhigh" ;;
        *) eagle_config_get "orchestration" "claude_worker_effort" "xhigh" ;;
    esac
}

orchestrate_require_worker_cli() {
    case "$1" in
        codex)
            command -v codex >/dev/null 2>&1 || { eagle_err "Codex worker requested, but 'codex' was not found on PATH"; exit 1; }
            ;;
        claude-code)
            command -v claude >/dev/null 2>&1 || { eagle_err "Claude Code worker requested, but 'claude' was not found on PATH"; exit 1; }
            ;;
    esac
}

orchestrate_repo_root() {
    git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null
}

orchestrate_branch_name() {
    local lane_key="$1"
    printf 'eagle/%s/%s/%s\n' "$(orchestrate_slug "$name")" "$(orchestrate_run_key)" "$(orchestrate_slug "$lane_key")"
}

orchestrate_default_worktree_path() {
    local repo_root="$1" lane_key="$2"
    local configured_root repo_name root
    configured_root=$(eagle_config_get "orchestration" "worktree_root" "")
    repo_name=$(basename "$repo_root")
    if [ -n "$configured_root" ]; then
        case "$configured_root" in
            /*) root="$configured_root" ;;
            *) root="$(dirname "$repo_root")/$configured_root" ;;
        esac
    else
        root="$(dirname "$repo_root")/.eagle-worktrees/$repo_name"
    fi
    printf '%s/%s-%s-%s\n' "$root" "$(orchestrate_slug "$name")" "$(orchestrate_run_key)" "$(orchestrate_slug "$lane_key")"
}

orchestrate_run_dir() {
    local lane_key="$1"
    local attempt="${2:-current}"
    printf '%s/orchestrations/%s-%s/%s/%s/%s/%s\n' \
        "$EAGLE_MEM_DIR" \
        "$(orchestrate_slug "$project")" \
        "$(orchestrate_project_hash)" \
        "$(orchestrate_slug "$name")" \
        "$(orchestrate_run_key)" \
        "$(orchestrate_slug "$lane_key")" \
        "$(orchestrate_slug "$attempt")"
}

orchestrate_lane_json() {
    local oid="$1" lane_key="$2" key_sql
    key_sql=$(eagle_sql_escape "$lane_key")
    eagle_db_json "SELECT id, lane_key, title, description, agent, worktree_path, validation, status, notes,
                          branch_name, worker_agent, worker_model, worker_effort, worker_pid,
                          worker_log_path, worker_exit_path, worker_prompt_path, worker_command,
                          worker_started_at, worker_finished_at
                   FROM orchestration_lanes
                   WHERE orchestration_id = $oid AND lane_key = '$key_sql'
                   LIMIT 1;"
}

orchestrate_shell_join() {
    local out="" arg
    for arg in "$@"; do
        if [ -n "$out" ]; then out+=" "; fi
        out+="$(printf '%q' "$arg")"
    done
    printf '%s\n' "$out"
}

orchestrate_prepare_prompt() {
    local prompt_file="$1" lane_key="$2" lane_title="$3" lane_desc="$4" lane_validation="$5" worker_agent="$6" worker_model="$7" worker_effort="$8" worktree="$9" branch="${10}" goal="${11}"
    cat > "$prompt_file" <<PROMPT
You are an Eagle Mem worker agent.

Project: $project
Orchestration: $name
Goal: $goal
Lane: $lane_key — $lane_title
Assigned worker: $(eagle_agent_label "$worker_agent")
Model: $worker_model
Reasoning effort: $worker_effort
Worktree: $worktree
Branch: $branch

Lane scope:
$lane_desc

Validation command:
$lane_validation

Rules:
- Work only inside this lane and this worktree.
- Do not revert or overwrite work from other lanes.
- Read Eagle Mem recall if hooks provide it, but keep outputs concise.
- If blocked, run: eagle-mem orchestrate lane --project "$project" --name "$name" block "$lane_key" --notes "<concrete blocker>"
- If you finish manually before the wrapper updates status, run: eagle-mem orchestrate lane --project "$project" --name "$name" complete "$lane_key" --notes "<validation result>"
- Run the validation command when one is provided and it is safe for the lane.
- Keep user-facing final responses clean. Claude Code workers may emit an Eagle Mem summary block when their UI handles it cleanly; Codex workers should not print XML, JSON, or internal capture blocks unless the user explicitly asks. Eagle Mem Stop hooks capture Codex summaries from the transcript automatically.
PROMPT
}

orchestrate_prepare_worktree() {
    local lane_key="$1" lane_worktree="$2" no_worktree="$3" dry_run="${4:-false}"
    local repo_root branch worktree configured repo_common worktree_common worktree_branch
    repo_root=$(orchestrate_repo_root)
    [ -z "$repo_root" ] && { eagle_err "Orchestration workers require a git repository."; exit 1; }

    branch=$(orchestrate_branch_name "$lane_key")
    if [ "$no_worktree" = true ] || [ "$(eagle_config_get "orchestration" "auto_worktree" "true")" = "false" ]; then
        worktree="$repo_root"
    elif [ -n "$lane_worktree" ]; then
        case "$lane_worktree" in
            /*) worktree="$lane_worktree" ;;
            *) worktree="$repo_root/$lane_worktree" ;;
        esac
    else
        worktree=$(orchestrate_default_worktree_path "$repo_root" "$lane_key")
    fi

    if [ "$dry_run" = true ]; then
        :
    elif [ "$worktree" != "$repo_root" ]; then
        if [ -e "$worktree" ]; then
            if [ ! -d "$worktree/.git" ] && [ ! -f "$worktree/.git" ]; then
                eagle_err "Worktree path exists but is not a git worktree: $worktree"
                exit 1
            fi
            repo_common=$(cd "$repo_root" && { git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git rev-parse --git-common-dir 2>/dev/null; })
            worktree_common=$(cd "$worktree" && { git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git rev-parse --git-common-dir 2>/dev/null; })
            case "$repo_common" in /*) ;; *) repo_common="$repo_root/$repo_common" ;; esac
            case "$worktree_common" in /*) ;; *) worktree_common="$worktree/$worktree_common" ;; esac
            if [ -z "$repo_common" ] || [ "$repo_common" != "$worktree_common" ]; then
                eagle_err "Worktree path belongs to a different git repository: $worktree"
                exit 1
            fi
            worktree_branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
            if [ "$worktree_branch" != "$branch" ]; then
                eagle_err "Worktree path is on '$worktree_branch', expected '$branch': $worktree"
                exit 1
            fi
        else
            mkdir -p "$(dirname "$worktree")"
            if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
                if ! git -C "$repo_root" worktree add -q "$worktree" "$branch" >/dev/null; then
                    eagle_err "Failed to create worktree for existing branch '$branch': $worktree"
                    exit 1
                fi
            else
                if ! git -C "$repo_root" worktree add -q -b "$branch" "$worktree" HEAD >/dev/null; then
                    eagle_err "Failed to create worktree branch '$branch': $worktree"
                    exit 1
                fi
            fi
        fi
    else
        branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    fi

    printf '%s|%s|%s\n' "$repo_root" "$worktree" "$branch"
}

orchestrate_init() {
    local goal="${args[*]:-}"
    [ -z "$goal" ] && { eagle_err "Usage: eagle-mem orchestrate init <goal>"; exit 1; }

    local baseline=""
    baseline=$(git -C "$(pwd)" rev-parse --short HEAD 2>/dev/null || true)

    local existing existing_id existing_status run_key goal_sql baseline_sql run_key_sql
    existing=$(eagle_db "SELECT id || '|' || status FROM orchestrations
                         WHERE project = '$project_sql' AND name = '$name_sql'
                         LIMIT 1;")
    IFS='|' read -r existing_id existing_status <<< "$existing"

    if [ "$existing_status" = "completed" ] || [ "$existing_status" = "cancelled" ]; then
        eagle_db_pipe <<SQL >/dev/null
DELETE FROM agent_tasks
WHERE project = '$project_sql'
  AND source_session_id = 'orchestration'
  AND file_path IN (
      SELECT 'orchestration-lane://' || l.project || '/' || o.name || '/' || l.lane_key
      FROM orchestration_lanes l
      JOIN orchestrations o ON o.id = l.orchestration_id
      WHERE l.orchestration_id = $existing_id
  );

DELETE FROM orchestration_lanes
WHERE orchestration_id = $existing_id;
SQL
    fi

    run_key="r$(date -u +%Y%m%d%H%M%S)-$$"
    goal_sql=$(eagle_sql_escape "$goal")
    baseline_sql=$(eagle_sql_escape "$baseline")
    run_key_sql=$(eagle_sql_escape "$run_key")

    eagle_db_pipe <<SQL >/dev/null
INSERT INTO orchestrations (project, name, goal, status, baseline_ref, run_key)
VALUES ('$project_sql', '$name_sql', '$goal_sql', 'active', '$baseline_sql', '$run_key_sql')
ON CONFLICT(project, name) DO UPDATE SET
    goal = excluded.goal,
    status = 'active',
    baseline_ref = COALESCE(NULLIF(excluded.baseline_ref, ''), orchestrations.baseline_ref),
    run_key = CASE
        WHEN orchestrations.status IN ('completed', 'cancelled')
          OR orchestrations.run_key IS NULL
          OR orchestrations.run_key = ''
        THEN excluded.run_key
        ELSE orchestrations.run_key
    END,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');
SQL

    if [ "$json_output" = true ]; then
        jq -nc --arg project "$project" --arg name "$name" --arg goal "$goal" --arg baseline "$baseline" \
            '{project:$project,name:$name,goal:$goal,baseline_ref:$baseline,status:"active"}'
    else
        eagle_ok "Orchestration '$name' active"
        [ -n "$baseline" ] && eagle_kv "Baseline:" "$baseline"
    fi
}

parse_lane_options() {
    lane_title=""
    lane_desc=""
    lane_worktree=""
    lane_validation=""
    lane_notes=""

    local parsed=()
    local i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        case "${args[$i]}" in
            --title)
                i=$((i + 1)); lane_title="${args[$i]:-}" ;;
            --desc|-d)
                i=$((i + 1)); lane_desc="${args[$i]:-}" ;;
            --worktree)
                i=$((i + 1)); lane_worktree="${args[$i]:-}" ;;
            --validate)
                i=$((i + 1)); lane_validation="${args[$i]:-}" ;;
            --notes)
                i=$((i + 1)); lane_notes="${args[$i]:-}" ;;
            *)
                parsed+=("${args[$i]}") ;;
        esac
        i=$((i + 1))
    done
    if [ "${#parsed[@]}" -gt 0 ]; then
        args=("${parsed[@]}")
    else
        args=()
    fi
}

lane_add() {
    parse_lane_options
    local key="${args[0]:-}"
    [ -z "$key" ] && { eagle_err "Usage: eagle-mem orchestrate lane add <key> [--desc <text>]"; exit 1; }
    case "$key" in *[!A-Za-z0-9._-]*) eagle_err "Lane key may contain only letters, numbers, dot, underscore, or dash"; exit 1 ;; esac

    local oid raw_agent
    oid=$(require_active_orchestration_id)
    [ -z "$lane_title" ] && lane_title="$key"

    local key_slug existing_keys existing_key
    key_slug=$(orchestrate_slug "$key")
    existing_keys=$(eagle_db "SELECT lane_key FROM orchestration_lanes WHERE orchestration_id = $oid;")
    while IFS= read -r existing_key; do
        [ -z "$existing_key" ] && continue
        [ "$existing_key" = "$key" ] && continue
        if [ "$(orchestrate_slug "$existing_key")" = "$key_slug" ]; then
            eagle_err "Lane key '$key' collides with existing lane '$existing_key' after normalization."
            exit 1
        fi
    done <<< "$existing_keys"
    if ! git check-ref-format --branch "$(orchestrate_branch_name "$key")" >/dev/null 2>&1; then
        eagle_err "Lane key '$key' cannot be used as a git worker branch. Use letters, numbers, dashes, or underscores without leading/trailing dots."
        exit 1
    fi

    if [ -z "$agent" ] || [ "$agent_explicit" = false ]; then
        agent=$(orchestrate_default_worker_agent)
    else
        raw_agent="$agent"
        if ! agent=$(orchestrate_normalize_agent "$agent"); then
            eagle_err "Invalid worker agent: $raw_agent. Use codex or claude-code."
            exit 1
        fi
    fi

    local source_task_id file_path content_hash
    source_task_id=$(lane_source_task_id "$key")
    file_path=$(lane_file_path "$key")
    content_hash=$(printf '%s|%s|%s|%s|%s' "$key" "$lane_title" "$lane_desc" "$agent" "$lane_validation" | eagle_sha256_stream)

    local key_sql title_sql desc_sql agent_sql worktree_sql validation_sql task_sql fp_sql hash_sql
    key_sql=$(eagle_sql_escape "$key")
    title_sql=$(eagle_sql_escape "$lane_title")
    desc_sql=$(eagle_sql_escape "$lane_desc")
    agent_sql=$(eagle_sql_escape "$agent")
    worktree_sql=$(eagle_sql_escape "$lane_worktree")
    validation_sql=$(eagle_sql_escape "$lane_validation")
    task_sql=$(eagle_sql_escape "$source_task_id")
    fp_sql=$(eagle_sql_escape "$file_path")
    hash_sql=$(eagle_sql_escape "$content_hash")

    eagle_db_pipe <<SQL >/dev/null
INSERT INTO orchestration_lanes (orchestration_id, project, lane_key, title, description, agent, worktree_path, validation, status, source_task_id)
VALUES ($oid, '$project_sql', '$key_sql', '$title_sql', '$desc_sql', '$agent_sql', '$worktree_sql', '$validation_sql', 'pending', '$task_sql')
ON CONFLICT(orchestration_id, lane_key) DO UPDATE SET
    orchestration_id = excluded.orchestration_id,
    title = excluded.title,
    description = excluded.description,
    agent = excluded.agent,
    worktree_path = excluded.worktree_path,
    validation = excluded.validation,
    source_task_id = excluded.source_task_id,
    status = orchestration_lanes.status,
    notes = CASE WHEN orchestration_lanes.status = 'pending' THEN NULL ELSE orchestration_lanes.notes END,
    branch_name = CASE WHEN orchestration_lanes.status = 'pending' THEN NULL ELSE orchestration_lanes.branch_name END,
    worker_agent = CASE WHEN orchestration_lanes.status = 'pending' THEN NULL ELSE orchestration_lanes.worker_agent END,
    worker_model = CASE WHEN orchestration_lanes.status = 'pending' THEN NULL ELSE orchestration_lanes.worker_model END,
    worker_effort = CASE WHEN orchestration_lanes.status = 'pending' THEN NULL ELSE orchestration_lanes.worker_effort END,
    worker_pid = CASE WHEN orchestration_lanes.status = 'in_progress' THEN orchestration_lanes.worker_pid ELSE NULL END,
    worker_log_path = CASE WHEN orchestration_lanes.status = 'pending' THEN NULL ELSE orchestration_lanes.worker_log_path END,
    worker_exit_path = CASE WHEN orchestration_lanes.status = 'pending' THEN NULL ELSE orchestration_lanes.worker_exit_path END,
    worker_prompt_path = CASE WHEN orchestration_lanes.status = 'pending' THEN NULL ELSE orchestration_lanes.worker_prompt_path END,
    worker_command = CASE WHEN orchestration_lanes.status = 'pending' THEN NULL ELSE orchestration_lanes.worker_command END,
    worker_started_at = CASE WHEN orchestration_lanes.status = 'pending' THEN NULL ELSE orchestration_lanes.worker_started_at END,
    worker_finished_at = CASE WHEN orchestration_lanes.status = 'pending' THEN NULL ELSE orchestration_lanes.worker_finished_at END,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');

INSERT INTO agent_tasks (project, source_session_id, source_task_id, file_path, subject, description, active_form, status, blocks, blocked_by, content_hash, origin_agent)
VALUES ('$project_sql', 'orchestration', '$task_sql', '$fp_sql', '$title_sql', '$desc_sql', '$validation_sql', 'pending', '[]', '[]', '$hash_sql', '$agent_sql')
ON CONFLICT(file_path) DO UPDATE SET
    subject = excluded.subject,
    description = excluded.description,
    active_form = excluded.active_form,
    status = CASE
        WHEN (SELECT status FROM orchestration_lanes WHERE orchestration_id = $oid AND lane_key = '$key_sql') = 'in_progress' THEN 'in_progress'
        WHEN (SELECT status FROM orchestration_lanes WHERE orchestration_id = $oid AND lane_key = '$key_sql') = 'completed' THEN 'completed'
        WHEN (SELECT status FROM orchestration_lanes WHERE orchestration_id = $oid AND lane_key = '$key_sql') = 'cancelled' THEN 'cancelled'
        ELSE 'pending'
    END,
    content_hash = excluded.content_hash,
    origin_agent = excluded.origin_agent,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now');

UPDATE orchestrations
SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE id = $oid;
SQL

    local db_status
    db_status=$(eagle_db "SELECT status FROM orchestration_lanes
        WHERE orchestration_id = $oid
          AND lane_key = '$key_sql'
        LIMIT 1;")
    db_status=${db_status:-pending}

    if [ "$json_output" = true ]; then
        jq -nc --arg key "$key" --arg title "$lane_title" --arg agent "$agent" --arg status "$db_status" --arg task "$source_task_id" \
            '{lane_key:$key,title:$title,agent:$agent,status:$status,source_task_id:$task}'
    else
        eagle_ok "Lane '$key' added for $(eagle_agent_label "$agent")"
    fi
}

lane_set_status() {
    parse_lane_options
    local status="$1"
    local key="${args[0]:-}"
    [ -z "$key" ] && { eagle_err "Usage: eagle-mem orchestrate lane $action <key>"; exit 1; }

    local key_sql status_sql notes_sql task_status
    key_sql=$(eagle_sql_escape "$key")
    status_sql=$(eagle_sql_escape "$status")
    notes_sql=$(eagle_sql_escape "$lane_notes")
    case "$status" in
        in_progress) task_status="in_progress" ;;
        completed) task_status="completed" ;;
        cancelled) task_status="cancelled" ;;
        blocked) task_status="pending" ;;
        *) task_status="pending" ;;
    esac

    local task_file_path fp_sql changed current_status
    local oid
    oid=$(require_active_orchestration_id)
    task_file_path=$(lane_file_path "$key")
    fp_sql=$(eagle_sql_escape "$task_file_path")

    current_status=$(eagle_db "SELECT status FROM orchestration_lanes
        WHERE project = '$project_sql'
          AND lane_key = '$key_sql'
          AND orchestration_id = $oid
        LIMIT 1;")
    if [ "$current_status" = "cancelled" ] && [ "$status" != "cancelled" ]; then
        eagle_dim "Lane '$key' is cancelled; leaving status unchanged."
        return 0
    fi
    if [ "$current_status" = "blocked" ] && [ "$status" = "completed" ]; then
        eagle_dim "Lane '$key' is blocked; leaving blocker unchanged. Run lane start before completing it."
        return 0
    fi

    changed=$(eagle_db_pipe <<SQL
UPDATE orchestration_lanes
SET status = '$status_sql',
    notes = CASE WHEN '$notes_sql' != '' THEN '$notes_sql' ELSE notes END,
    worker_pid = CASE
        WHEN '$status_sql' IN ('in_progress', 'blocked', 'completed', 'cancelled') THEN NULL
        ELSE worker_pid
    END,
    worker_exit_path = CASE WHEN '$status_sql' = 'in_progress' THEN NULL ELSE worker_exit_path END,
    worker_started_at = CASE WHEN '$status_sql' = 'in_progress' THEN NULL ELSE worker_started_at END,
    worker_finished_at = CASE
        WHEN '$status_sql' = 'in_progress' THEN NULL
        WHEN '$status_sql' IN ('blocked', 'completed', 'cancelled') THEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
        ELSE worker_finished_at
    END,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE project = '$project_sql'
  AND lane_key = '$key_sql'
  AND orchestration_id = $oid
  AND (status != 'cancelled' OR '$status_sql' = 'cancelled')
  AND NOT (status = 'blocked' AND '$status_sql' = 'completed');
SELECT changes();
SQL
)

    if [ "${changed:-0}" -gt 0 ] 2>/dev/null; then
        eagle_db_pipe <<SQL >/dev/null
UPDATE agent_tasks
SET status = '$task_status',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE project = '$project_sql'
  AND file_path = '$fp_sql';

UPDATE orchestrations
SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE project = '$project_sql' AND name = '$name_sql';
SQL
        eagle_ok "Lane '$key' marked $status"
    else
        current_status=$(eagle_db "SELECT status FROM orchestration_lanes
            WHERE project = '$project_sql'
              AND lane_key = '$key_sql'
              AND orchestration_id = $oid
            LIMIT 1;")
        if [ "$current_status" = "cancelled" ] && [ "$status" != "cancelled" ]; then
            eagle_dim "Lane '$key' is cancelled; leaving status unchanged."
            return 0
        fi
        if [ "$current_status" = "blocked" ] && [ "$status" = "completed" ]; then
            eagle_dim "Lane '$key' is blocked; leaving blocker unchanged. Run lane start before completing it."
            return 0
        fi
        eagle_err "Lane not found: $key"
        exit 1
    fi
}

orchestrate_set_status() {
    local status="$1"
    local status_sql changed oid active_count lane_terminal_where task_terminal_where
    status_sql=$(eagle_sql_escape "$status")
    oid=$(active_orchestration_id)
    if [ -z "$oid" ]; then
        eagle_err "No active orchestration found for '$project' ($name). Run: eagle-mem orchestrate init <goal>"
        exit 1
    fi

    active_count=$(eagle_db "SELECT COUNT(*) FROM orchestration_lanes
        WHERE orchestration_id = $oid
        AND status IN ('pending', 'in_progress', 'blocked');")
    active_count=${active_count:-0}

    if [ "$status" = "completed" ] && [ "$active_count" -gt 0 ] 2>/dev/null; then
        eagle_err "Cannot complete orchestration '$name' while $active_count lane(s) are still active."
        eagle_dim "Complete or cancel active lanes first, then run: eagle-mem orchestrate complete --name \"$name\""
        exit 1
    fi

    lane_terminal_where="0"
    task_terminal_where="0"
    if [ "$status" = "cancelled" ]; then
        lane_terminal_where="orchestration_id = $oid AND status IN ('pending', 'in_progress', 'blocked')"
        task_terminal_where="project = '$project_sql'
  AND source_session_id = 'orchestration'
  AND source_task_id IN (
      SELECT source_task_id
      FROM orchestration_lanes
      WHERE orchestration_id = $oid
        AND status = 'cancelled'
  )"
    fi

    changed=$(eagle_db_pipe <<SQL
UPDATE orchestration_lanes
SET status = 'cancelled',
    notes = CASE WHEN notes IS NULL OR notes = '' THEN 'Cancelled with parent orchestration' ELSE notes END,
    worker_pid = NULL,
    worker_finished_at = CASE
        WHEN worker_started_at IS NOT NULL AND worker_finished_at IS NULL THEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
        ELSE worker_finished_at
    END,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE $lane_terminal_where;

UPDATE agent_tasks
SET status = 'cancelled',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE $task_terminal_where;

UPDATE orchestrations
SET status = '$status_sql',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE id = $oid;
SELECT changes();
SQL
)

    if [ "${changed:-0}" -gt 0 ] 2>/dev/null; then
        eagle_ok "Orchestration '$name' marked $status"
    else
        eagle_err "No orchestration found for '$project' ($name). Run: eagle-mem orchestrate init <goal>"
        exit 1
    fi
}

parse_spawn_options() {
    spawn_no_worktree=false
    spawn_no_launch=false
    spawn_foreground=false
    spawn_dry_run=false
    spawn_notes=""

    local parsed=()
    local i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        case "${args[$i]}" in
            --no-worktree)
                spawn_no_worktree=true ;;
            --no-launch)
                spawn_no_launch=true ;;
            --foreground)
                spawn_foreground=true ;;
            --dry-run)
                spawn_dry_run=true ;;
            --notes)
                i=$((i + 1)); spawn_notes="${args[$i]:-}" ;;
            *)
                parsed+=("${args[$i]}") ;;
        esac
        i=$((i + 1))
    done
    if [ "${#parsed[@]}" -gt 0 ]; then
        args=("${parsed[@]}")
    else
        args=()
    fi
}

orchestrate_worker_run_script() {
    local run_script="$1" worker_agent="$2" worker_model="$3" worker_effort="$4" worktree="$5" prompt_file="$6" exit_path="$7" last_message_path="$8" bin_path="$9" lane_key="${10}" log_path="${11}"
    local effort_config="model_reasoning_effort=\"$worker_effort\""
    local complete_note="Worker exited 0; log: $log_path"
    local block_note="Worker exited non-zero; log: $log_path"

    {
        echo '#!/usr/bin/env bash'
        echo 'set +e'
        printf 'cd %q || exit 1\n' "$worktree"
        printf 'export EAGLE_MEM_DIR=%q\n' "$EAGLE_MEM_DIR"
        printf 'export EAGLE_MEM_PROJECT=%q\n' "$project"
        printf 'export EAGLE_AGENT_SOURCE=%q\n' "$worker_agent"
        printf 'export EAGLE_ORCHESTRATION_NAME=%q\n' "$name"
        printf 'export EAGLE_ORCHESTRATION_LANE=%q\n' "$lane_key"
        printf 'export EAGLE_ORCHESTRATION_WORKTREE=%q\n' "$worktree"
        if [ "$worker_agent" = "codex" ]; then
            printf 'codex exec --cd %q --model %q -c %q -c %q --sandbox danger-full-access --output-last-message %q - < %q\n' \
                "$worktree" "$worker_model" "$effort_config" 'approval_policy="never"' "$last_message_path" "$prompt_file"
        else
            printf 'prompt=$(cat %q)\n' "$prompt_file"
            printf 'claude -p --model %q --effort %q --permission-mode dontAsk --output-format text "$prompt"\n' \
                "$worker_model" "$worker_effort"
        fi
        echo 'rc=$?'
        printf 'printf "%%s\\n" "$rc" > %q\n' "$exit_path"
        printf 'date -u "+%%Y-%%m-%%dT%%H:%%M:%%SZ" > %q.done\n' "$exit_path"
        echo 'if [ "$rc" -eq 0 ]; then'
        printf '  bash %q orchestrate --project %q --name %q lane complete %q --notes %q >/dev/null 2>&1\n' "$bin_path" "$project" "$name" "$lane_key" "$complete_note"
        echo 'else'
        printf '  bash %q orchestrate --project %q --name %q lane block %q --notes %q >/dev/null 2>&1\n' "$bin_path" "$project" "$name" "$lane_key" "$block_note"
        echo 'fi'
        echo 'exit "$rc"'
    } > "$run_script"
    chmod +x "$run_script"
}

orchestrate_spawn() {
    parse_spawn_options
    local lane_key="${args[0]:-}"
    [ -z "$lane_key" ] && { eagle_err "Usage: eagle-mem orchestrate spawn <lane-key>"; exit 1; }

    local oid lane_json lane_count
    oid=$(require_active_orchestration_id)
    lane_json=$(orchestrate_lane_json "$oid" "$lane_key")
    lane_count=$(printf '%s' "$lane_json" | jq 'length' 2>/dev/null)
    if [ "${lane_count:-0}" -eq 0 ] 2>/dev/null; then
        eagle_err "Lane not found: $lane_key"
        exit 1
    fi

    local lane_title lane_desc lane_agent lane_worktree lane_validation lane_status existing_pid goal
    lane_title=$(printf '%s' "$lane_json" | jq -r '.[0].title // ""')
    lane_desc=$(printf '%s' "$lane_json" | jq -r '.[0].description // ""')
    lane_agent=$(printf '%s' "$lane_json" | jq -r '.[0].agent // ""')
    lane_worktree=$(printf '%s' "$lane_json" | jq -r '.[0].worktree_path // ""')
    lane_validation=$(printf '%s' "$lane_json" | jq -r '.[0].validation // ""')
    lane_status=$(printf '%s' "$lane_json" | jq -r '.[0].status // ""')
    existing_pid=$(printf '%s' "$lane_json" | jq -r '.[0].worker_pid // empty')
    goal=$(eagle_db "SELECT goal FROM orchestrations WHERE id = $oid;")

    if [ "$lane_status" = "completed" ] || [ "$lane_status" = "cancelled" ]; then
        eagle_err "Lane '$lane_key' is already $lane_status"
        exit 1
    fi
    if [ "$lane_status" = "in_progress" ]; then
        if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
            eagle_err "Lane '$lane_key' already has a running worker (pid $existing_pid). Run: eagle-mem orchestrate sync $lane_key"
            exit 1
        fi
        eagle_err "Lane '$lane_key' is already in progress. Run sync first, or cancel/block it before spawning again."
        exit 1
    fi

    local worker_agent worker_model worker_effort
    if [ -n "$agent" ]; then
        if ! worker_agent=$(orchestrate_normalize_agent "$agent"); then
            eagle_err "Invalid worker agent: $agent. Use codex or claude-code."
            exit 1
        fi
    elif [ -n "$lane_agent" ]; then
        if ! worker_agent=$(orchestrate_normalize_agent "$lane_agent"); then
            eagle_err "Invalid lane worker agent: $lane_agent. Use codex or claude-code."
            exit 1
        fi
    else
        worker_agent=$(orchestrate_default_worker_agent)
    fi
    worker_model=$(orchestrate_worker_model "$worker_agent")
    worker_effort=$(orchestrate_worker_effort "$worker_agent")

    if [ "$spawn_dry_run" != true ] && [ "$spawn_no_launch" != true ]; then
        orchestrate_require_worker_cli "$worker_agent"
    fi

    local worktree_info repo_root worktree branch
    worktree_info=$(orchestrate_prepare_worktree "$lane_key" "$lane_worktree" "$spawn_no_worktree" "$spawn_dry_run")
    IFS='|' read -r repo_root worktree branch <<< "$worktree_info"

    local run_dir prompt_file log_path exit_path last_message_path run_script bin_path command_display attempt_key
    attempt_key="a$(date -u +%Y%m%d%H%M%S)-$$"
    run_dir=$(orchestrate_run_dir "$lane_key" "$attempt_key")
    prompt_file="$run_dir/prompt.md"
    log_path="$run_dir/worker.log"
    exit_path="$run_dir/exit_code"
    last_message_path="$run_dir/last-message.txt"
    run_script="$run_dir/run-worker.sh"
    bin_path="$(cd "$SCRIPTS_DIR/.." && pwd)/bin/eagle-mem"

    command_display=$(orchestrate_shell_join bash "$run_script")

    if [ "$spawn_dry_run" = true ]; then
        if [ "$json_output" = true ]; then
            jq -nc --arg lane "$lane_key" --arg agent "$worker_agent" --arg model "$worker_model" --arg effort "$worker_effort" --arg worktree "$worktree" --arg branch "$branch" --arg command "$command_display" \
                '{lane_key:$lane, worker_agent:$agent, model:$model, effort:$effort, worktree:$worktree, branch:$branch, command:$command, dry_run:true}'
        else
            eagle_ok "Dry-run worker plan"
            eagle_kv "Lane:" "$lane_key"
            eagle_kv "Worker:" "$(eagle_agent_label "$worker_agent") $worker_model / $worker_effort"
            eagle_kv "Worktree:" "$worktree"
            eagle_kv "Branch:" "$branch"
            eagle_kv "Command:" "$command_display"
        fi
        return 0
    fi

    mkdir -p "$run_dir"
    orchestrate_prepare_prompt "$prompt_file" "$lane_key" "$lane_title" "$lane_desc" "$lane_validation" "$worker_agent" "$worker_model" "$worker_effort" "$worktree" "$branch" "$goal"
    orchestrate_worker_run_script "$run_script" "$worker_agent" "$worker_model" "$worker_effort" "$worktree" "$prompt_file" "$exit_path" "$last_message_path" "$bin_path" "$lane_key" "$log_path"

    local key_sql wt_sql branch_sql worker_agent_sql model_sql effort_sql log_sql exit_sql prompt_sql cmd_sql notes_sql fp_sql
    key_sql=$(eagle_sql_escape "$lane_key")
    wt_sql=$(eagle_sql_escape "$worktree")
    branch_sql=$(eagle_sql_escape "$branch")
    worker_agent_sql=$(eagle_sql_escape "$worker_agent")
    model_sql=$(eagle_sql_escape "$worker_model")
    effort_sql=$(eagle_sql_escape "$worker_effort")
    log_sql=$(eagle_sql_escape "$log_path")
    exit_sql=$(eagle_sql_escape "$exit_path")
    prompt_sql=$(eagle_sql_escape "$prompt_file")
    cmd_sql=$(eagle_sql_escape "$command_display")
    notes_sql=$(eagle_sql_escape "${spawn_notes:-Worker prepared}")
    fp_sql=$(eagle_sql_escape "$(lane_file_path "$lane_key")")

    if [ "$spawn_no_launch" = true ]; then
        eagle_db_pipe <<SQL >/dev/null
UPDATE orchestration_lanes
SET worktree_path = '$wt_sql',
    branch_name = '$branch_sql',
    worker_agent = '$worker_agent_sql',
    worker_model = '$model_sql',
    worker_effort = '$effort_sql',
    worker_log_path = '$log_sql',
    worker_exit_path = '$exit_sql',
    worker_prompt_path = '$prompt_sql',
    worker_command = '$cmd_sql',
    notes = '$notes_sql',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE orchestration_id = $oid AND lane_key = '$key_sql';
SQL
        if [ "$json_output" = true ]; then
            jq -nc --arg lane "$lane_key" --arg agent "$worker_agent" --arg model "$worker_model" --arg effort "$worker_effort" --arg worktree "$worktree" --arg branch "$branch" --arg log "$log_path" --arg prompt "$prompt_file" --arg command "$command_display" \
                '{lane_key:$lane, worker_agent:$agent, model:$model, effort:$effort, worktree:$worktree, branch:$branch, log:$log, prompt:$prompt, command:$command, launched:false}'
        else
            eagle_ok "Lane '$lane_key' prepared"
            eagle_kv "Worker:" "$(eagle_agent_label "$worker_agent") $worker_model / $worker_effort"
            eagle_kv "Worktree:" "$worktree"
            eagle_kv "Branch:" "$branch"
        fi
        return 0
    fi

    rm -f "$exit_path" "$exit_path.done" "$last_message_path"

    local claim_changed
    claim_changed=$(eagle_db_pipe <<SQL
UPDATE orchestration_lanes
SET status = 'in_progress',
    worktree_path = '$wt_sql',
    branch_name = '$branch_sql',
    worker_agent = '$worker_agent_sql',
    worker_model = '$model_sql',
    worker_effort = '$effort_sql',
    worker_pid = NULL,
    worker_log_path = '$log_sql',
    worker_exit_path = '$exit_sql',
    worker_prompt_path = '$prompt_sql',
    worker_command = '$cmd_sql',
    worker_started_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    worker_finished_at = NULL,
    notes = CASE WHEN '$notes_sql' != '' THEN '$notes_sql' ELSE notes END,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE orchestration_id = $oid
  AND lane_key = '$key_sql'
  AND status NOT IN ('in_progress', 'completed', 'cancelled');
SELECT changes();
SQL
)

    if [ "${claim_changed:-0}" -le 0 ] 2>/dev/null; then
        eagle_err "Lane '$lane_key' was not claimed. Run sync/status before spawning again."
        exit 1
    fi

    eagle_db_pipe <<SQL >/dev/null
UPDATE agent_tasks
SET status = 'in_progress',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE project = '$project_sql'
  AND file_path = '$fp_sql';
SQL

    local pid pid_sql
    if [ "$spawn_foreground" = true ]; then
        bash "$run_script" > "$log_path" 2>&1
        pid=""
    else
        nohup bash "$run_script" > "$log_path" 2>&1 &
        pid=$!
        pid_sql=$(eagle_sql_int "$pid")
        eagle_db "UPDATE orchestration_lanes
                  SET worker_pid = $pid_sql,
                      updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                  WHERE orchestration_id = $oid
                    AND lane_key = '$key_sql'
                    AND status = 'in_progress';" >/dev/null
    fi

    if [ "$json_output" = true ]; then
        jq -nc --arg lane "$lane_key" --arg agent "$worker_agent" --arg model "$worker_model" --arg effort "$worker_effort" --arg worktree "$worktree" --arg branch "$branch" --arg log "$log_path" --arg pid "${pid:-}" \
            '{lane_key:$lane, worker_agent:$agent, model:$model, effort:$effort, worktree:$worktree, branch:$branch, log:$log, pid:$pid}'
    else
        eagle_ok "Worker launched for lane '$lane_key'"
        eagle_kv "Worker:" "$(eagle_agent_label "$worker_agent") $worker_model / $worker_effort"
        [ -n "$pid" ] && eagle_kv "PID:" "$pid"
        eagle_kv "Worktree:" "$worktree"
        eagle_kv "Branch:" "$branch"
        eagle_kv "Log:" "$log_path"
    fi
}

orchestrate_sync_one() {
    local lane_key="$1"
    local oid lane_json lane_count lane_status pid exit_path log_path started_at rc key_sql fp_sql note_sql task_status
    oid=$(require_orchestration_id)
    lane_json=$(orchestrate_lane_json "$oid" "$lane_key")
    lane_count=$(printf '%s' "$lane_json" | jq 'length' 2>/dev/null)
    if [ "${lane_count:-0}" -eq 0 ] 2>/dev/null; then
        eagle_err "Lane not found: $lane_key"
        return 1
    fi

    lane_status=$(printf '%s' "$lane_json" | jq -r '.[0].status // ""')
    pid=$(printf '%s' "$lane_json" | jq -r '.[0].worker_pid // empty')
    exit_path=$(printf '%s' "$lane_json" | jq -r '.[0].worker_exit_path // empty')
    log_path=$(printf '%s' "$lane_json" | jq -r '.[0].worker_log_path // empty')
    started_at=$(printf '%s' "$lane_json" | jq -r '.[0].worker_started_at // empty')

    case "$lane_status" in
        completed|cancelled|blocked)
            eagle_ok "Lane '$lane_key' already $lane_status"
            return 0
            ;;
    esac

    if [ -n "$exit_path" ] && [ -f "$exit_path" ]; then
        rc=$(tr -d '[:space:]' < "$exit_path")
        rc=${rc:-1}
        if [ "$rc" = "0" ]; then
            lane_status="completed"
            task_status="completed"
            note_sql=$(eagle_sql_escape "Worker completed; log: $log_path")
        else
            lane_status="blocked"
            task_status="pending"
            note_sql=$(eagle_sql_escape "Worker exited $rc; log: $log_path")
        fi
    elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        eagle_ok "Lane '$lane_key' worker still running (pid $pid)"
        return 0
    elif [ -z "$started_at" ]; then
        eagle_dim "Lane '$lane_key' has not been launched; leaving status as $lane_status."
        return 0
    else
        lane_status="blocked"
        task_status="pending"
        note_sql=$(eagle_sql_escape "Worker process is not running and no exit code was recorded; log: $log_path")
    fi

    key_sql=$(eagle_sql_escape "$lane_key")
    fp_sql=$(eagle_sql_escape "$(lane_file_path "$lane_key")")
    local sync_changed
    sync_changed=$(eagle_db_pipe <<SQL
UPDATE orchestration_lanes
SET status = '$lane_status',
    notes = '$note_sql',
    worker_pid = NULL,
    worker_finished_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE orchestration_id = $oid
  AND lane_key = '$key_sql'
  AND status = 'in_progress';
SELECT changes();
SQL
)

    if [ "${sync_changed:-0}" -le 0 ] 2>/dev/null; then
        lane_status=$(eagle_db "SELECT status FROM orchestration_lanes
            WHERE orchestration_id = $oid AND lane_key = '$key_sql'
            LIMIT 1;")
        if [ "$lane_status" = "cancelled" ] || [ "$lane_status" = "blocked" ] || [ "$lane_status" = "completed" ]; then
            eagle_dim "Lane '$lane_key' is $lane_status; leaving status unchanged."
            return 0
        fi
        eagle_err "Lane not found: $lane_key"
        return 1
    fi

    eagle_db_pipe <<SQL >/dev/null
UPDATE agent_tasks
SET status = '$task_status',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE project = '$project_sql'
  AND file_path = '$fp_sql';
SQL
    eagle_ok "Lane '$lane_key' synced as $lane_status"
}

orchestrate_sync() {
    local lane_key="${args[0]:-}"
    if [ -n "$lane_key" ]; then
        orchestrate_sync_one "$lane_key"
        return
    fi

    local oid keys
    oid=$(require_orchestration_id)
    keys=$(eagle_db "SELECT lane_key FROM orchestration_lanes
                    WHERE orchestration_id = $oid
                      AND (worker_pid IS NOT NULL OR worker_started_at IS NOT NULL)
                      AND status IN ('pending', 'in_progress', 'blocked')
                    ORDER BY lane_key;")
    if [ -z "$keys" ]; then
        eagle_dim "No worker-backed lanes to sync."
        return
    fi
    while IFS= read -r lane_key; do
        [ -z "$lane_key" ] && continue
        orchestrate_sync_one "$lane_key"
    done <<< "$keys"
}

orchestrate_status() {
    local oid
    oid=$(orchestration_id)
    if [ -z "$oid" ]; then
        if [ "$json_output" = true ]; then
            printf '[]\n'
            return
        fi
        eagle_dim "No orchestration for '$project'"
        eagle_dim "Run: eagle-mem orchestrate init <goal>"
        return
    fi

    if [ "$json_output" = true ]; then
        eagle_db_json "SELECT lane_key, title, description, agent, worktree_path, branch_name, validation, status, notes,
                              worker_agent, worker_model, worker_effort, worker_pid, worker_log_path,
                              worker_started_at, worker_finished_at, updated_at
                       FROM orchestration_lanes
                       WHERE orchestration_id = $oid
                       ORDER BY CASE status WHEN 'in_progress' THEN 0 WHEN 'blocked' THEN 1 WHEN 'pending' THEN 2 WHEN 'completed' THEN 3 ELSE 4 END, lane_key;"
        return
    fi

    local meta
    meta=$(eagle_db "SELECT name, goal, status, baseline_ref, updated_at FROM orchestrations WHERE id = $oid;")
    IFS='|' read -r oname goal status baseline updated <<< "$meta"

    echo ""
    echo -e "  ${BOLD}Orchestration${RESET} ${DIM}($project)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────${RESET}"
    eagle_kv "Name:" "$oname"
    eagle_kv "Status:" "$status"
    [ -n "$baseline" ] && eagle_kv "Baseline:" "$baseline"
    [ -n "$goal" ] && eagle_kv "Goal:" "$goal"
    eagle_kv "Updated:" "$updated"
    echo ""

    local rows
    rows=$(eagle_db "SELECT lane_key, title, agent, status, validation, worktree_path, notes, branch_name, worker_agent, worker_model, worker_effort, worker_pid, worker_log_path
                    FROM orchestration_lanes
                    WHERE orchestration_id = $oid
                    ORDER BY CASE status WHEN 'in_progress' THEN 0 WHEN 'blocked' THEN 1 WHEN 'pending' THEN 2 WHEN 'completed' THEN 3 ELSE 4 END, lane_key;")
    if [ -z "$rows" ]; then
        eagle_dim "No lanes yet. Add one with: eagle-mem orchestrate lane add <key>"
        return
    fi

    while IFS='|' read -r key title lane_agent lane_status validation worktree notes branch worker_agent worker_model worker_effort worker_pid worker_log; do
        [ -z "$key" ] && continue
        echo -e "  ${CYAN}${key}${RESET} ${BOLD}$title${RESET} ${DIM}[$lane_status, $(eagle_agent_label "$lane_agent")]${RESET}"
        [ -n "$validation" ] && echo -e "     ${DIM}validate: $validation${RESET}"
        [ -n "$worktree" ] && echo -e "     ${DIM}worktree: $worktree${RESET}"
        [ -n "$branch" ] && echo -e "     ${DIM}branch: $branch${RESET}"
        [ -n "$worker_model" ] && echo -e "     ${DIM}worker: $(eagle_agent_label "$worker_agent") $worker_model / $worker_effort${RESET}"
        [ -n "$worker_pid" ] && echo -e "     ${DIM}pid: $worker_pid${RESET}"
        [ -n "$worker_log" ] && echo -e "     ${DIM}log: $worker_log${RESET}"
        [ -n "$notes" ] && echo -e "     ${DIM}notes: $notes${RESET}"
    done <<< "$rows"
    echo ""
}

orchestrate_handoff() {
    parse_lane_options
    local write_path=""
    local i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        case "${args[$i]}" in
            --write)
                i=$((i + 1)); write_path="${args[$i]:-}" ;;
        esac
        i=$((i + 1))
    done

    local oid
    oid=$(require_orchestration_id)
    local out
    out=$(mktemp)

    {
        local meta
        meta=$(eagle_db "SELECT name, goal, status, baseline_ref, updated_at FROM orchestrations WHERE id = $oid;")
        IFS='|' read -r oname goal status baseline updated <<< "$meta"
        echo "# Eagle Mem Orchestration"
        echo ""
        echo "- Project: $project"
        echo "- Name: $oname"
        echo "- Status: $status"
        [ -n "$baseline" ] && echo "- Baseline: $baseline"
        echo "- Updated: $updated"
        [ -n "$goal" ] && echo "- Goal: $goal"
        echo ""
        echo "## Worker Lanes"
        echo ""
        local rows
        rows=$(eagle_db "SELECT lane_key, title, description, agent, status, validation, worktree_path, notes, branch_name, worker_agent, worker_model, worker_effort, worker_log_path
                        FROM orchestration_lanes
                        WHERE orchestration_id = $oid
                        ORDER BY lane_key;")
        if [ -z "$rows" ]; then
            echo "No lanes recorded."
        else
            while IFS='|' read -r key title desc lane_agent lane_status validation worktree notes branch worker_agent worker_model worker_effort worker_log; do
                [ -z "$key" ] && continue
                echo "### $key — $title"
                echo ""
                echo "- Agent: $(eagle_agent_label "$lane_agent")"
                echo "- Status: $lane_status"
                [ -n "$worktree" ] && echo "- Worktree: $worktree"
                [ -n "$branch" ] && echo "- Branch: $branch"
                [ -n "$worker_model" ] && echo "- Worker: $(eagle_agent_label "$worker_agent") $worker_model / $worker_effort"
                [ -n "$worker_log" ] && echo "- Log: $worker_log"
                [ -n "$validation" ] && echo "- Validation: \`$validation\`"
                [ -n "$desc" ] && echo "- Scope: $desc"
                [ -n "$notes" ] && echo "- Notes: $notes"
                echo ""
            done <<< "$rows"
        fi
    } > "$out"

    if [ -n "$write_path" ]; then
        mkdir -p "$(dirname "$write_path")"
        cp "$out" "$write_path"
        rm -f "$out"
        eagle_ok "Handoff written: $write_path"
    else
        cat "$out"
        rm -f "$out"
    fi
}

case "$action" in
    init) orchestrate_init ;;
    status|list|ls) orchestrate_status ;;
    spawn) orchestrate_spawn ;;
    sync) orchestrate_sync ;;
    complete) orchestrate_set_status "completed" ;;
    cancel) orchestrate_set_status "cancelled" ;;
    handoff) orchestrate_handoff ;;
    lane)
        lane_action="${args[0]:-}"
        if [ "${#args[@]}" -gt 0 ]; then args=("${args[@]:1}"); fi
        case "$lane_action" in
            add) lane_add ;;
            start) lane_set_status "in_progress" ;;
            block) lane_set_status "blocked" ;;
            complete) lane_set_status "completed" ;;
            cancel) lane_set_status "cancelled" ;;
            *) eagle_err "Usage: eagle-mem orchestrate lane [add|start|block|complete|cancel] <key>"; exit 1 ;;
        esac
        ;;
    --help|-h) show_help ;;
    *) eagle_err "Unknown action: $action"; eagle_dim "  Run 'eagle-mem orchestrate --help' for options"; exit 1 ;;
esac
