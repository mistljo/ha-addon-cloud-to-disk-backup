#!/usr/bin/with-contenv bashio
# ==============================================================================
# Cloud to Disk Backup - Watcher Service
# Monitors backup processes, handles auto-resume, manual triggers, scheduling
# ==============================================================================

LOOP_INTERVAL=5
LOOP_COUNT=0

# ==============================================================================
# Helper Functions
# ==============================================================================

log() {
    bashio::log.info "[Watcher] $1"
}

log_warn() {
    bashio::log.warning "[Watcher] $1"
}

log_error() {
    bashio::log.error "[Watcher] $1"
}

get_retry_count() {
    local account="$1"
    cat "${ADDON_RETRY_DIR}/retry_${account}" 2>/dev/null || echo 0
}

set_retry_count() {
    local account="$1"
    local count="$2"
    echo "$count" > "${ADDON_RETRY_DIR}/retry_${account}"
}

reset_retry_count() {
    set_retry_count "$1" 0
}

write_status() {
    local account="$1"
    local backup_path="$2"
    local status="$3"
    local stage="$4"
    local message="$5"
    local retry_count="$6"

    cat > "${ADDON_STATUS_DIR}/status_${account}.json" << STATUSEOF
{
    "account": "${account}",
    "backup_path": "${backup_path}",
    "status": "${status}",
    "stage": "${stage}",
    "timestamp": "$(date -Iseconds)",
    "message": "${message}",
    "retry_count": ${retry_count}
}
STATUSEOF
}

get_status() {
    local account="$1"
    local field="$2"
    jq -r ".${field} // empty" "${ADDON_STATUS_DIR}/status_${account}.json" 2>/dev/null
}

is_backup_running() {
    local account="$1"
    pgrep -f "backup.sh.*${account}" > /dev/null 2>&1
}

start_backup() {
    local account="$1"
    local idx="$2"
    local reason="$3"

    local name_var="ADDON_ACCOUNT_${idx}_NAME"
    local provider_var="ADDON_ACCOUNT_${idx}_PROVIDER"
    local remote_var="ADDON_ACCOUNT_${idx}_REMOTE"
    local path_var="ADDON_ACCOUNT_${idx}_PATH"
    local excludes_var="ADDON_ACCOUNT_${idx}_EXCLUDES"

    local name="${!name_var}"
    local provider="${!provider_var}"
    local remote="${!remote_var}"
    local backup_path="${!path_var}"
    local excludes="${!excludes_var}"

    log "${reason} - Starting backup for ${name} (${provider})"

    nohup /usr/local/bin/backup.sh \
        "$name" "$provider" "$remote" "$backup_path" "$excludes" \
        > "${ADDON_DATA_DIR}/logs/backup_${name}.stdout" 2>&1 &

    local pid=$!
    log "  Backup started (PID: ${pid})"
}

cleanup_incomplete_archives() {
    local account="$1"
    local archive_dir="$2"

    local today=$(date +%Y%m%d)
    local incomplete=$(ls -1 "${archive_dir}/${account}_${today}_"*.part* 2>/dev/null | sed 's/\.part.*//' | sort -u)

    if [ -n "$incomplete" ]; then
        echo "$incomplete" | while read inc_base; do
            local parts=$(ls -1 "${inc_base}".part* 2>/dev/null | wc -l)
            local size=$(du -ch "${inc_base}".part* 2>/dev/null | tail -1 | cut -f1)
            log "  Cleaning incomplete archive: $(basename $inc_base) (${parts} parts, ${size})"
            rm -f "${inc_base}".part* 2>/dev/null
        done
        log "  Cleanup complete"
    fi
}

# ==============================================================================
# Startup: Crash Detection + Auto-Resume
# ==============================================================================
log "======================================"
log "Starting Backup Watcher v1.0"
log "  Max retries: ${ADDON_MAX_RETRIES}"
log "  Schedule: ${ADDON_SCHEDULE_ENABLED} (${ADDON_SCHEDULE_CRON})"
log "  Accounts: ${ADDON_ACCOUNT_COUNT}"
log "======================================"

# Check each account for crashed backups
for i in $(seq 0 $((ADDON_ACCOUNT_COUNT - 1))); do
    name_var="ADDON_ACCOUNT_${i}_NAME"
    path_var="ADDON_ACCOUNT_${i}_PATH"
    account="${!name_var}"
    backup_path="${!path_var}"

    retry_count=$(get_retry_count "$account")

    # Check if status says "running" but no process exists (= crash)
    status=$(get_status "$account" "status")
    if [ "$status" = "running" ] && ! is_backup_running "$account"; then
        log "Crash detected for ${account} (was running, no process found)"

        if [ "$retry_count" -ge "$ADDON_MAX_RETRIES" ]; then
            log_error "${account} - ${ADDON_MAX_RETRIES} retries exhausted!"
            cleanup_incomplete_archives "$account" "${backup_path}/${account}/archive"
            rm -f "${ADDON_DATA_DIR}/sync_complete_${account}"
            write_status "$account" "$backup_path" "failed" "error" \
                "Backup failed after ${ADDON_MAX_RETRIES} retries. Manual restart needed." "$retry_count"
        else
            retry_count=$((retry_count + 1))
            set_retry_count "$account" "$retry_count"
            log "${account} - Auto-resume (attempt ${retry_count}/${ADDON_MAX_RETRIES})"
            cleanup_incomplete_archives "$account" "${backup_path}/${account}/archive"
            start_backup "$account" "$i" "AUTO-RESUME (retry ${retry_count})"
        fi
    fi

    # Check for completed status -> reset retry counter
    if [ "$status" = "completed" ]; then
        if [ "$retry_count" -gt 0 ]; then
            log "${account} - Backup completed, resetting retry counter (was ${retry_count})"
            reset_retry_count "$account"
        fi
    fi
done

# ==============================================================================
# Main Loop
# ==============================================================================
LAST_CRON_CHECK=0

while true; do
    LOOP_COUNT=$((LOOP_COUNT + 1))

    # Log every 60th loop (~5 min)
    if [ $((LOOP_COUNT % 60)) -eq 0 ]; then
        log "Loop ${LOOP_COUNT}"
    fi

    # ------------------------------------------------------------------
    # Check manual triggers via HA API
    # ------------------------------------------------------------------
    for i in $(seq 0 $((ADDON_ACCOUNT_COUNT - 1))); do
        name_var="ADDON_ACCOUNT_${i}_NAME"
        account="${!name_var}"

        # Check input_boolean trigger
        trigger_state=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "${HA_API_URL}/states/input_boolean.backup_trigger_${account}" 2>/dev/null | \
            jq -r '.state // "off"' 2>/dev/null)

        if [ "$trigger_state" = "on" ]; then
            log "${account} backup manually triggered!"

            # Turn off trigger
            curl -s -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"entity_id\": \"input_boolean.backup_trigger_${account}\"}" \
                "${HA_API_URL}/services/input_boolean/turn_off" > /dev/null 2>&1

            reset_retry_count "$account"
            start_backup "$account" "$i" "MANUAL START"
        fi
    done

    # ------------------------------------------------------------------
    # Cron schedule check (check every 60 seconds)
    # ------------------------------------------------------------------
    CURRENT_TIME=$(date +%s)
    if [ "$ADDON_SCHEDULE_ENABLED" = "true" ] && [ $((CURRENT_TIME - LAST_CRON_CHECK)) -ge 60 ]; then
        LAST_CRON_CHECK=$CURRENT_TIME

        # Simple cron matching: extract hour and minute from cron expression
        # Format: "minute hour * * *"
        CRON_MIN=$(echo "$ADDON_SCHEDULE_CRON" | awk '{print $1}')
        CRON_HOUR=$(echo "$ADDON_SCHEDULE_CRON" | awk '{print $2}')
        CURRENT_HOUR=$(date +%-H)
        CURRENT_MIN=$(date +%-M)

        if [ "$CURRENT_HOUR" = "$CRON_HOUR" ] && [ "$CURRENT_MIN" = "$CRON_MIN" ]; then
            log "Scheduled backup time reached (${CRON_HOUR}:${CRON_MIN})"

            for i in $(seq 0 $((ADDON_ACCOUNT_COUNT - 1))); do
                name_var="ADDON_ACCOUNT_${i}_NAME"
                account="${!name_var}"

                if ! is_backup_running "$account"; then
                    start_backup "$account" "$i" "SCHEDULED"
                else
                    log "${account} - Already running, skipping scheduled start"
                fi
            done
        fi
    fi

    # ------------------------------------------------------------------
    # Monitor running backups: detect crashes
    # ------------------------------------------------------------------
    for i in $(seq 0 $((ADDON_ACCOUNT_COUNT - 1))); do
        name_var="ADDON_ACCOUNT_${i}_NAME"
        path_var="ADDON_ACCOUNT_${i}_PATH"
        account="${!name_var}"
        backup_path="${!path_var}"

        status=$(get_status "$account" "status")
        retry_count=$(get_retry_count "$account")

        # Status says running but process is gone = crash
        if [ "$status" = "running" ] && ! is_backup_running "$account"; then
            log_warn "${account} - Process died (status was 'running')"

            if [ "$retry_count" -ge "$ADDON_MAX_RETRIES" ]; then
                log_error "${account} - ${ADDON_MAX_RETRIES} retries exhausted!"
                cleanup_incomplete_archives "$account" "${backup_path}/${account}/archive"
                rm -f "${ADDON_DATA_DIR}/sync_complete_${account}"
                write_status "$account" "$backup_path" "failed" "error" \
                    "Backup failed after ${ADDON_MAX_RETRIES} retries. Manual restart needed." "$retry_count"
            else
                retry_count=$((retry_count + 1))
                set_retry_count "$account" "$retry_count"
                log "${account} - Auto-resume (attempt ${retry_count}/${ADDON_MAX_RETRIES})"
                cleanup_incomplete_archives "$account" "${backup_path}/${account}/archive"
                start_backup "$account" "$i" "AUTO-RESUME (retry ${retry_count})"
            fi
        fi

        # Status says error -> also retry
        if [ "$status" = "error" ] && [ "$retry_count" -lt "$ADDON_MAX_RETRIES" ]; then
            retry_count=$((retry_count + 1))
            set_retry_count "$account" "$retry_count"
            log "${account} - Error detected, retrying (${retry_count}/${ADDON_MAX_RETRIES})"
            cleanup_incomplete_archives "$account" "${backup_path}/${account}/archive"
            start_backup "$account" "$i" "ERROR-RETRY (retry ${retry_count})"
        fi

        # Status completed -> reset retry counter
        if [ "$status" = "completed" ] && [ "$retry_count" -gt 0 ]; then
            log "${account} - Backup completed, resetting retry counter"
            reset_retry_count "$account"
        fi
    done

    sleep $LOOP_INTERVAL
done
