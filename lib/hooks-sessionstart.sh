#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — SessionStart extracted automation
# Source from hooks/session-start.sh after common.sh + db.sh
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_HOOKS_SESSIONSTART_LOADED:-}" ] && return 0
_EAGLE_HOOKS_SESSIONSTART_LOADED=1

_state_dir="$EAGLE_MEM_DIR/state"

_eagle_state_fresh() {
    local key="$1" project="$2" max_age_days="${3:-1}"
    local safe_project="${project//\//-}"
    local state_file="$_state_dir/${key}-${safe_project}"
    [ -f "$state_file" ] && [ -z "$(find "$state_file" -mtime +${max_age_days} 2>/dev/null)" ]
}

_eagle_state_touch() {
    local key="$1" project="$2"
    local safe_project="${project//\//-}"
    mkdir -p "$_state_dir" 2>/dev/null
    touch "$_state_dir/${key}-${safe_project}"
}

eagle_sessionstart_auto_provision() {
    local project="$1" cwd="$2" scripts_dir="$3"
    local needs_scan=false needs_index=false

    # Auto-scan: no overview exists
    local overview
    overview=$(eagle_get_overview "$project")
    if [ -z "$overview" ] && ! _eagle_state_fresh "scan" "$project" 1; then
        needs_scan=true
    fi

    # Auto-index: 0 chunks or stale > 7 days
    local chunk_count
    chunk_count=$(eagle_db "SELECT COUNT(*) FROM code_chunks WHERE project = '$(eagle_sql_escape "$project")';" 2>/dev/null)
    chunk_count=${chunk_count:-0}
    if [ "$chunk_count" -eq 0 ] && ! _eagle_state_fresh "index" "$project" 1; then
        needs_index=true
    elif [ "$chunk_count" -gt 0 ] && ! _eagle_state_fresh "index" "$project" 7; then
        needs_index=true
    fi

    if [ "$needs_scan" = true ] && [ "$needs_index" = true ]; then
        eagle_log "INFO" "SessionStart: first-session provision — scan then index"
        _eagle_state_touch "scan" "$project"
        _eagle_state_touch "index" "$project"
        nohup bash -c "bash '$scripts_dir/scan.sh' '$cwd' >> '$EAGLE_MEM_LOG' 2>&1; bash '$scripts_dir/index.sh' '$cwd' >> '$EAGLE_MEM_LOG' 2>&1" &
    elif [ "$needs_scan" = true ]; then
        eagle_log "INFO" "SessionStart: auto-scan triggered"
        _eagle_state_touch "scan" "$project"
        nohup bash "$scripts_dir/scan.sh" "$cwd" >> "$EAGLE_MEM_LOG" 2>&1 &
    elif [ "$needs_index" = true ]; then
        eagle_log "INFO" "SessionStart: auto-index triggered"
        _eagle_state_touch "index" "$project"
        nohup bash "$scripts_dir/index.sh" "$cwd" >> "$EAGLE_MEM_LOG" 2>&1 &
    fi
}

eagle_sessionstart_auto_prune() {
    local project="$1" scripts_dir="$2" observation_count="$3"
    if [ "${observation_count:-0}" -gt 10000 ] && ! _eagle_state_fresh "prune" "$project" 1; then
        eagle_log "INFO" "SessionStart: auto-prune triggered (${observation_count} observations)"
        _eagle_state_touch "prune" "$project"
        nohup bash "$scripts_dir/prune.sh" -p "$project" >> "$EAGLE_MEM_LOG" 2>&1 &
    fi
}

eagle_sessionstart_auto_curate() {
    local project="$1" scripts_dir="$2"
    local curator_schedule
    curator_schedule=$(eagle_config_get "curator" "schedule" "manual")
    if [ "$curator_schedule" = "auto" ]; then
        local _provider
        _provider=$(eagle_config_get "provider" "type" "none")
        if [ "$_provider" != "none" ]; then
            local _min_sessions _last_curated _since _sessions_since
            _min_sessions=$(eagle_config_get "curator" "min_sessions" "5")
            _min_sessions=$(eagle_sql_int "$_min_sessions")
            _last_curated=$(eagle_meta_get "last_curated_at" "$project")
            _since="${_last_curated:-1970-01-01T00:00:00Z}"
            _sessions_since=$(eagle_count_sessions_since "$project" "$_since")
            if [ "${_sessions_since:-0}" -ge "$_min_sessions" ]; then
                eagle_log "INFO" "SessionStart: auto-curate triggered (${_sessions_since} sessions since last curate)"
                nohup bash "$scripts_dir/curate.sh" -p "$project" >> "$EAGLE_MEM_LOG" 2>&1 &
            fi
        fi
    fi
}
