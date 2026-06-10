#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — SessionStart extracted automation
# Source from hooks/session-start.sh after common.sh + db.sh
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_HOOKS_SESSIONSTART_LOADED:-}" ] && return 0
_EAGLE_HOOKS_SESSIONSTART_LOADED=1

_state_dir="$EAGLE_MEM_DIR/state"

_eagle_state_slug() {
    printf '%s' "$1" | shasum | cut -c1-12
}

_eagle_state_file() {
    local key="$1" project="$2"
    local safe_project; safe_project=$(_eagle_state_slug "$project")
    printf '%s/%s-%s\n' "$_state_dir" "$key" "$safe_project"
}

_eagle_state_fresh() {
    local key="$1" project="$2" max_age_days="${3:-1}"
    local state_file; state_file=$(_eagle_state_file "$key" "$project")
    [ -f "$state_file" ] && [ -z "$(find "$state_file" -mtime +${max_age_days} 2>/dev/null)" ]
}

_eagle_state_touch() {
    local key="$1" project="$2"
    local state_file; state_file=$(_eagle_state_file "$key" "$project")
    mkdir -p "$_state_dir" 2>/dev/null
    touch "$state_file"
}

# In-flight markers debounce concurrent SessionStart spawns WITHOUT doubling as
# the freshness marker. The freshness marker ("$key") is touched ONLY by the
# background job on genuine success, so a job that crashes, is killed, or exits 0
# without producing output never blocks retry for a full day — it leaves at most
# a short-lived in-flight marker that ages out in minutes. Checked in minutes.
_eagle_state_inflight_fresh() {
    local key="$1" project="$2" max_age_min="${3:-15}"
    local state_file; state_file=$(_eagle_state_file "${key}-inflight" "$project")
    [ -f "$state_file" ] && [ -z "$(find "$state_file" -mmin +"${max_age_min}" 2>/dev/null)" ]
}

eagle_sessionstart_auto_provision() {
    local project="$1" cwd="$2" scripts_dir="$3"
    local needs_scan=false needs_index=false

    # Auto-scan: no overview exists
    local overview
    overview=$(eagle_get_overview "$project")
    if [ -z "$overview" ] && ! _eagle_state_fresh "scan" "$project" 1 && ! _eagle_state_inflight_fresh "scan" "$project" 15; then
        needs_scan=true
    fi

    # Auto-index: 0 chunks or stale > 7 days
    local chunk_count
    chunk_count=$(eagle_db "SELECT COUNT(*) FROM code_chunks WHERE project = '$(eagle_sql_escape "$project")';" 2>/dev/null)
    chunk_count=${chunk_count:-0}
    if [ "$chunk_count" -eq 0 ] && ! _eagle_state_fresh "index" "$project" 1 && ! _eagle_state_inflight_fresh "index" "$project" 15; then
        needs_index=true
    elif [ "$chunk_count" -gt 0 ] && ! _eagle_state_fresh "index" "$project" 7 && ! _eagle_state_inflight_fresh "index" "$project" 15; then
        needs_index=true
    fi

    if [ "$needs_scan" = true ] && [ "$needs_index" = true ]; then
        eagle_log "INFO" "SessionStart: first-session provision — scan then index"
        _eagle_state_touch "scan-inflight" "$project"
        _eagle_state_touch "index-inflight" "$project"
        scan_state=$(_eagle_state_file "scan" "$project")
        scan_inflight=$(_eagle_state_file "scan-inflight" "$project")
        index_state=$(_eagle_state_file "index" "$project")
        index_inflight=$(_eagle_state_file "index-inflight" "$project")
        nohup bash -c '
            scripts_dir="$1"; cwd="$2"; log="$3"; scan_state="$4"; scan_inflight="$5"; index_state="$6"; index_inflight="$7"
            bash "$scripts_dir/scan.sh" "$cwd" >> "$log" 2>&1
            scan_rc=$?
            rm -f "$scan_inflight" 2>/dev/null || true
            if [ "$scan_rc" -eq 0 ]; then
                touch "$scan_state" 2>/dev/null || true
            else
                rm -f "$scan_state" 2>/dev/null || true
                printf "[%s] [ERROR] SessionStart: auto-scan failed rc=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$scan_rc" >> "$log" 2>/dev/null || true
            fi

            bash "$scripts_dir/index.sh" "$cwd" >> "$log" 2>&1
            index_rc=$?
            rm -f "$index_inflight" 2>/dev/null || true
            if [ "$index_rc" -eq 0 ]; then
                touch "$index_state" 2>/dev/null || true
            else
                rm -f "$index_state" 2>/dev/null || true
                printf "[%s] [ERROR] SessionStart: auto-index failed rc=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$index_rc" >> "$log" 2>/dev/null || true
            fi

            [ "$scan_rc" -eq 0 ] && exit "$index_rc"
            exit "$scan_rc"
        ' eagle-auto "$scripts_dir" "$cwd" "$EAGLE_MEM_LOG" "$scan_state" "$scan_inflight" "$index_state" "$index_inflight" &
    elif [ "$needs_scan" = true ]; then
        eagle_log "INFO" "SessionStart: auto-scan triggered"
        _eagle_state_touch "scan-inflight" "$project"
        scan_state=$(_eagle_state_file "scan" "$project")
        scan_inflight=$(_eagle_state_file "scan-inflight" "$project")
        nohup bash -c '
            scripts_dir="$1"; cwd="$2"; log="$3"; scan_state="$4"; scan_inflight="$5"
            bash "$scripts_dir/scan.sh" "$cwd" >> "$log" 2>&1
            rc=$?
            rm -f "$scan_inflight" 2>/dev/null || true
            if [ "$rc" -eq 0 ]; then
                touch "$scan_state" 2>/dev/null || true
            else
                rm -f "$scan_state" 2>/dev/null || true
                printf "[%s] [ERROR] SessionStart: auto-scan failed rc=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >> "$log" 2>/dev/null || true
            fi
            exit "$rc"
        ' eagle-auto "$scripts_dir" "$cwd" "$EAGLE_MEM_LOG" "$scan_state" "$scan_inflight" &
    elif [ "$needs_index" = true ]; then
        eagle_log "INFO" "SessionStart: auto-index triggered"
        _eagle_state_touch "index-inflight" "$project"
        index_state=$(_eagle_state_file "index" "$project")
        index_inflight=$(_eagle_state_file "index-inflight" "$project")
        nohup bash -c '
            scripts_dir="$1"; cwd="$2"; log="$3"; index_state="$4"; index_inflight="$5"
            bash "$scripts_dir/index.sh" "$cwd" >> "$log" 2>&1
            rc=$?
            rm -f "$index_inflight" 2>/dev/null || true
            if [ "$rc" -eq 0 ]; then
                touch "$index_state" 2>/dev/null || true
            else
                rm -f "$index_state" 2>/dev/null || true
                printf "[%s] [ERROR] SessionStart: auto-index failed rc=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >> "$log" 2>/dev/null || true
            fi
            exit "$rc"
        ' eagle-auto "$scripts_dir" "$cwd" "$EAGLE_MEM_LOG" "$index_state" "$index_inflight" &
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
