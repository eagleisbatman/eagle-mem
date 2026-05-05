#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Auto-update helpers
# ═══════════════════════════════════════════════════════════
[ -n "${_EAGLE_UPDATER_LOADED:-}" ] && return 0
_EAGLE_UPDATER_LOADED=1

EAGLE_UPDATE_LATEST_FILE="$EAGLE_MEM_DIR/.latest-version"
EAGLE_UPDATE_NOTICE_FILE="$EAGLE_MEM_DIR/.update-notice"
EAGLE_UPDATE_STATE_FILE="$EAGLE_MEM_DIR/.last-update.json"
EAGLE_UPDATE_LOCK_DIR="$EAGLE_MEM_DIR/.update.lock"

eagle_update_config_mode() {
    eagle_config_get "updates" "mode" "auto"
}

eagle_update_config_allow() {
    eagle_config_get "updates" "allow" "patch"
}

eagle_update_config_channel() {
    eagle_config_get "updates" "channel" "latest"
}

eagle_update_config_interval_hours() {
    local hours
    hours=$(eagle_config_get "updates" "interval_hours" "24")
    case "$hours" in
        ''|*[!0-9]*) echo "24" ;;
        *) [ "$hours" -lt 1 ] 2>/dev/null && echo "1" || echo "$hours" ;;
    esac
}

eagle_update_ensure_defaults() {
    if [ ! -f "$EAGLE_CONFIG_FILE" ]; then
        eagle_config_init
        return
    fi

    if ! grep -q '^\[updates\]' "$EAGLE_CONFIG_FILE" 2>/dev/null; then
        cat >> "$EAGLE_CONFIG_FILE" << 'TOML'

[updates]
# Patch fixes auto-apply by default so stale bugs do not block sessions.
mode = "auto"
allow = "patch"
channel = "latest"
interval_hours = 24
TOML
    fi
}

eagle_update_installed_version() {
    local version_file="$EAGLE_MEM_DIR/.version"
    if [ -f "$version_file" ] && [ -s "$version_file" ]; then
        tr -d '[:space:]' < "$version_file"
        return
    fi

    if command -v eagle-mem >/dev/null 2>&1; then
        eagle-mem version 2>/dev/null | sed -nE 's/.*v([0-9][0-9A-Za-z.+-]*).*/\1/p' | head -1
        return
    fi

    echo "0.0.0"
}

_eagle_update_file_age_seconds() {
    local path="$1"
    [ -f "$path" ] || { echo 999999999; return; }
    local now mtime
    now=$(date +%s)
    mtime=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || echo 0)
    echo $((now - mtime))
}

eagle_update_latest_version() {
    local force="${1:-0}"
    local channel
    channel=$(eagle_update_config_channel)
    case "$channel" in latest|next) ;; *) channel="latest" ;; esac

    local interval_seconds age
    interval_seconds=$(( $(eagle_update_config_interval_hours) * 3600 ))
    age=$(_eagle_update_file_age_seconds "$EAGLE_UPDATE_LATEST_FILE")

    if [ "$force" != "1" ] && [ -f "$EAGLE_UPDATE_LATEST_FILE" ] && [ -s "$EAGLE_UPDATE_LATEST_FILE" ] && [ "$age" -lt "$interval_seconds" ]; then
        tr -d '[:space:]' < "$EAGLE_UPDATE_LATEST_FILE"
        return 0
    fi

    command -v npm >/dev/null 2>&1 || return 1

    local latest tmp
    latest=$(npm view "eagle-mem@${channel}" version 2>/dev/null | tr -d '[:space:]')
    [ -n "$latest" ] || return 1

    mkdir -p "$EAGLE_MEM_DIR" 2>/dev/null
    tmp=$(mktemp "${EAGLE_MEM_DIR}/.latest-version.XXXXXX" 2>/dev/null || mktemp)
    printf '%s\n' "$latest" > "$tmp"
    mv "$tmp" "$EAGLE_UPDATE_LATEST_FILE"
    printf '%s\n' "$latest"
}

_eagle_update_clean_version() {
    printf '%s' "${1:-0.0.0}" | sed -E 's/^v//; s/[^0-9.].*$//'
}

_eagle_update_part() {
    local version part
    version=$(_eagle_update_clean_version "$1")
    part="$2"
    printf '%s' "$version" | awk -F. -v p="$part" '{ v=$p; if (v == "") v=0; gsub(/[^0-9]/, "", v); print v + 0 }'
}

eagle_update_version_gt() {
    local a="$1" b="$2" i av bv
    for i in 1 2 3; do
        av=$(_eagle_update_part "$a" "$i")
        bv=$(_eagle_update_part "$b" "$i")
        [ "$av" -gt "$bv" ] && return 0
        [ "$av" -lt "$bv" ] && return 1
    done
    return 1
}

eagle_update_allowed() {
    local installed="$1" latest="$2" allow="$3"
    eagle_update_version_gt "$latest" "$installed" || return 1

    local imaj imin lmaj lmin
    imaj=$(_eagle_update_part "$installed" 1)
    imin=$(_eagle_update_part "$installed" 2)
    lmaj=$(_eagle_update_part "$latest" 1)
    lmin=$(_eagle_update_part "$latest" 2)

    case "$allow" in
        major) return 0 ;;
        minor) [ "$imaj" -eq "$lmaj" ] ;;
        patch|*) [ "$imaj" -eq "$lmaj" ] && [ "$imin" -eq "$lmin" ] ;;
    esac
}

eagle_update_write_state() {
    local status="$1" installed="$2" latest="$3" message="$4"
    mkdir -p "$EAGLE_MEM_DIR" 2>/dev/null
    jq -nc \
        --arg status "$status" \
        --arg installed "$installed" \
        --arg latest "$latest" \
        --arg message "$message" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{status:$status, installed:$installed, latest:$latest, message:$message, updated_at:$at}' \
        > "$EAGLE_UPDATE_STATE_FILE" 2>/dev/null || true
}

eagle_update_set_notice() {
    local message="$1"
    mkdir -p "$EAGLE_MEM_DIR" 2>/dev/null
    printf '%s\n' "$message" > "$EAGLE_UPDATE_NOTICE_FILE" 2>/dev/null || true
}

eagle_update_take_notice() {
    [ -f "$EAGLE_UPDATE_NOTICE_FILE" ] || return 0
    cat "$EAGLE_UPDATE_NOTICE_FILE" 2>/dev/null
    rm -f "$EAGLE_UPDATE_NOTICE_FILE" 2>/dev/null || true
}

eagle_update_lock() {
    mkdir -p "$EAGLE_MEM_DIR" 2>/dev/null
    mkdir "$EAGLE_UPDATE_LOCK_DIR" 2>/dev/null
}

eagle_update_unlock() {
    rmdir "$EAGLE_UPDATE_LOCK_DIR" 2>/dev/null || true
}

eagle_update_backup_runtime() {
    local backup_dir="$1"
    mkdir -p "$backup_dir"

    for item in hooks lib db scripts; do
        if [ -d "$EAGLE_MEM_DIR/$item" ]; then
            cp -R "$EAGLE_MEM_DIR/$item" "$backup_dir/$item" 2>/dev/null || true
        fi
    done

    if [ -f "$EAGLE_MEM_DB" ]; then
        local sqlite_bin
        sqlite_bin=$(eagle_sqlite_path)
        if [ -n "$sqlite_bin" ]; then
            "$sqlite_bin" "$EAGLE_MEM_DB" ".backup '$backup_dir/memory.db'" >/dev/null 2>&1 || cp "$EAGLE_MEM_DB" "$backup_dir/memory.db" 2>/dev/null || true
        else
            cp "$EAGLE_MEM_DB" "$backup_dir/memory.db" 2>/dev/null || true
        fi
    fi
}

eagle_update_restore_runtime() {
    local backup_dir="$1"

    for item in hooks lib db scripts; do
        if [ -d "$backup_dir/$item" ]; then
            cp -R "$backup_dir/$item" "$EAGLE_MEM_DIR/" 2>/dev/null || true
        fi
    done

    if [ -f "$backup_dir/memory.db" ]; then
        cp "$backup_dir/memory.db" "$EAGLE_MEM_DB" 2>/dev/null || true
    fi
}

eagle_update_apply_version() {
    local latest="${1:-}"
    local dry_run="${2:-0}"
    local force="${3:-0}"

    command -v npm >/dev/null 2>&1 || {
        eagle_update_write_state "failed" "$(eagle_update_installed_version)" "${latest:-unknown}" "npm not found"
        return 1
    }
    command -v eagle-mem >/dev/null 2>&1 || {
        eagle_update_write_state "failed" "$(eagle_update_installed_version)" "${latest:-unknown}" "eagle-mem binary not found on PATH"
        return 1
    }

    local installed allow
    installed=$(eagle_update_installed_version)
    [ -n "$latest" ] || latest=$(eagle_update_latest_version 1)
    [ -n "$latest" ] || return 1
    allow=$(eagle_update_config_allow)

    if ! eagle_update_version_gt "$latest" "$installed"; then
        eagle_update_write_state "current" "$installed" "$latest" "already current"
        printf 'current|%s|%s\n' "$installed" "$latest"
        return 0
    fi

    if [ "$force" != "1" ] && ! eagle_update_allowed "$installed" "$latest" "$allow"; then
        eagle_update_write_state "skipped" "$installed" "$latest" "outside allowed ${allow} update range"
        return 2
    fi

    if [ "$dry_run" = "1" ]; then
        eagle_update_write_state "dry-run" "$installed" "$latest" "eligible for auto-update"
        printf 'eligible|%s|%s\n' "$installed" "$latest"
        return 0
    fi

    if ! eagle_update_lock; then
        eagle_log "INFO" "Auto-update skipped: lock already held"
        eagle_update_write_state "locked" "$installed" "$latest" "update already running"
        printf 'locked|%s|%s\n' "$installed" "$latest"
        return 3
    fi

    local stamp backup_dir update_output update_rc
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    backup_dir="$EAGLE_MEM_DIR/backups/update-${stamp}-${installed}"
    eagle_update_backup_runtime "$backup_dir"

    eagle_log "INFO" "Auto-update: installing eagle-mem@$latest from $installed"
    update_output=$(npm install -g "eagle-mem@$latest" 2>&1)
    update_rc=$?
    if [ "$update_rc" -ne 0 ]; then
        eagle_log "ERROR" "Auto-update npm install failed: $update_output"
        eagle_update_write_state "failed" "$installed" "$latest" "npm install failed"
        eagle_update_set_notice "Eagle Mem auto-update failed while installing v${latest}; keeping v${installed}. Run: eagle-mem updates apply"
        eagle_update_unlock
        return 1
    fi

    update_output=$(EAGLE_MEM_AUTO_UPDATE_ACTIVE=1 eagle-mem update 2>&1)
    update_rc=$?
    if [ "$update_rc" -ne 0 ]; then
        eagle_log "ERROR" "Auto-update runtime update failed: $update_output"
        npm install -g "eagle-mem@$installed" >/dev/null 2>&1 || true
        eagle_update_restore_runtime "$backup_dir"
        printf '%s\n' "$installed" > "$EAGLE_MEM_DIR/.version" 2>/dev/null || true
        eagle_update_write_state "rolled-back" "$installed" "$latest" "runtime update failed; restored backup"
        eagle_update_set_notice "Eagle Mem auto-update to v${latest} failed and was rolled back to v${installed}. Run: eagle-mem updates status"
        eagle_update_unlock
        return 1
    fi

    printf '%s\n' "$latest" > "$EAGLE_MEM_DIR/.version" 2>/dev/null || true
    eagle_update_write_state "updated" "$installed" "$latest" "auto-update applied"
    eagle_update_set_notice "Eagle Mem auto-updated from v${installed} to v${latest}. Hooks and skills were refreshed automatically."
    eagle_log "INFO" "Auto-update complete: $installed -> $latest"
    eagle_update_unlock
    printf 'updated|%s|%s\n' "$installed" "$latest"
}

eagle_update_auto() {
    [ "${EAGLE_MEM_DISABLE_AUTO_UPDATE:-}" = "1" ] && return 0
    [ "${EAGLE_MEM_AUTO_UPDATE_ACTIVE:-}" = "1" ] && return 0

    eagle_update_ensure_defaults

    local mode installed latest allow
    mode=$(eagle_update_config_mode)
    [ "$mode" = "off" ] && return 0

    installed=$(eagle_update_installed_version)
    latest=$(eagle_update_latest_version 0) || return 0
    [ -n "$latest" ] || return 0
    eagle_update_version_gt "$latest" "$installed" || return 0

    allow=$(eagle_update_config_allow)
    if ! eagle_update_allowed "$installed" "$latest" "$allow"; then
        eagle_update_write_state "available" "$installed" "$latest" "outside allowed ${allow} update range"
        eagle_update_set_notice "Eagle Mem v${latest} is available, but auto-update is limited to ${allow} releases. Run: eagle-mem updates apply --force"
        return 0
    fi

    if [ "$mode" = "auto" ]; then
        eagle_update_apply_version "$latest" 0 0 >/dev/null 2>&1 || true
    else
        eagle_update_write_state "available" "$installed" "$latest" "notify mode"
        eagle_update_set_notice "Eagle Mem v${latest} is available. Run: eagle-mem updates apply"
    fi
}
