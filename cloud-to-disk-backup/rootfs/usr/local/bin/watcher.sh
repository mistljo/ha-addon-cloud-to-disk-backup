#!/usr/bin/with-contenv bashio
# ==============================================================================
# Cloud to Disk Backup - Watcher Service (v2.0)
# Reads job configuration dynamically from /data/jobs.json
# ==============================================================================

# Defaults for environment variables (in case contenv doesn't pass them)
ADDON_JOBS_FILE="${ADDON_JOBS_FILE:-/data/jobs.json}"
ADDON_DATA_DIR="${ADDON_DATA_DIR:-/data}"
ADDON_STATUS_DIR="${ADDON_STATUS_DIR:-/data/status}"
ADDON_RETRY_DIR="${ADDON_RETRY_DIR:-/data/retry}"
ADDON_RCLONE_CONF="${ADDON_RCLONE_CONF:-/data/rclone.conf}"
ADDON_MAX_RETRIES="${ADDON_MAX_RETRIES:-5}"
ADDON_SCHEDULE_ENABLED="${ADDON_SCHEDULE_ENABLED:-true}"
ADDON_SCHEDULE_CRON="${ADDON_SCHEDULE_CRON:-0 2 * * *}"
ADDON_RCLONE_TRANSFERS="${ADDON_RCLONE_TRANSFERS:-4}"
ADDON_RCLONE_CHECKERS="${ADDON_RCLONE_CHECKERS:-8}"

LOOP_INTERVAL=5
LOOP_COUNT=0

# ==============================================================================
# Helper Functions
# ==============================================================================

log() { bashio::log.info "[Watcher] $1"; }
log_warn() { bashio::log.warning "[Watcher] $1"; }
log_error() { bashio::log.error "[Watcher] $1"; }

get_retry_count() {
    cat "${ADDON_RETRY_DIR}/retry_${1}" 2>/dev/null || echo 0
}

set_retry_count() {
    echo "$2" > "${ADDON_RETRY_DIR}/retry_${1}"
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
    pgrep -f "backup.sh.*${1}" > /dev/null 2>&1
}

# ==============================================================================
# Job reading functions (from /data/jobs.json)
# ==============================================================================

get_enabled_job_names() {
    jq -r '.[] | select(.enabled == true) | .name' "$ADDON_JOBS_FILE" 2>/dev/null
}

get_job_field() {
    local job_name="$1"
    local field="$2"
    jq -r --arg n "$job_name" '.[] | select(.name == $n) | .'"$field" "$ADDON_JOBS_FILE" 2>/dev/null
}

start_backup() {
    local job_name="$1"
    local reason="$2"

    local provider=$(get_job_field "$job_name" "cloud_provider")
    local remote=$(get_job_field "$job_name" "remote_name")
    local backup_path=$(get_job_field "$job_name" "backup_path")
    local excludes=$(jq -r --arg n "$job_name" \
        '.[] | select(.name == $n) | .excludes // [] | map("--exclude \"" + . + "\"") | join(" ")' \
        "$ADDON_JOBS_FILE" 2>/dev/null)

    if [ -z "$provider" ] || [ -z "$remote" ] || [ -z "$backup_path" ]; then
        log_error "${job_name} - Incomplete job configuration, skipping"
        return 1
    fi

    log "${reason} - Starting backup for ${job_name} (${provider}) -> ${backup_path}"

    nohup /usr/local/bin/backup.sh \
        "$job_name" "$provider" "$remote" "$backup_path" "$excludes" \
        > "${ADDON_DATA_DIR}/logs/watcher_${job_name}.stdout" 2>&1 &

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
            [ -z "$inc_base" ] && continue
            log "  Cleaning incomplete archive: $(basename $inc_base)"
            rm -f "${inc_base}".part* 2>/dev/null
        done
    fi
}

# ==============================================================================
# Startup: Crash Detection + Auto-Resume
# ==============================================================================
JOB_COUNT=$(jq 'length' "$ADDON_JOBS_FILE" 2>/dev/null || echo 0)

log "======================================"
log "Starting Backup Watcher v2.0"
log "  Max retries: ${ADDON_MAX_RETRIES}"
log "  Schedule: ${ADDON_SCHEDULE_ENABLED} (${ADDON_SCHEDULE_CRON})"
log "  Jobs: ${JOB_COUNT} configured"
log "======================================"

# Check each enabled job for crashed backups
for job_name in $(get_enabled_job_names); do
    backup_path=$(get_job_field "$job_name" "backup_path")
    retry_count=$(get_retry_count "$job_name")
    status=$(get_status "$job_name" "status")

    if [ "$status" = "running" ] && ! is_backup_running "$job_name"; then
        log "Crash detected for ${job_name} (was running, no process found)"

        if [ "$retry_count" -ge "$ADDON_MAX_RETRIES" ]; then
            log_error "${job_name} - ${ADDON_MAX_RETRIES} retries exhausted!"
            cleanup_incomplete_archives "$job_name" "${backup_path}/${job_name}/archive"
            rm -f "${ADDON_DATA_DIR}/sync_complete_${job_name}"
            write_status "$job_name" "$backup_path" "failed" "error" \
                "Failed after ${ADDON_MAX_RETRIES} retries. Manual restart needed." "$retry_count"
        else
            retry_count=$((retry_count + 1))
            set_retry_count "$job_name" "$retry_count"
            log "${job_name} - Auto-resume (attempt ${retry_count}/${ADDON_MAX_RETRIES})"
            cleanup_incomplete_archives "$job_name" "${backup_path}/${job_name}/archive"
            start_backup "$job_name" "AUTO-RESUME (retry ${retry_count}/${ADDON_MAX_RETRIES})"
        fi
    fi

    if [ "$status" = "completed" ] && [ "$retry_count" -gt 0 ]; then
        log "${job_name} - Backup was completed, resetting retry counter"
        reset_retry_count "$job_name"
    fi
done

# ==============================================================================
# Main Loop
# ==============================================================================
LAST_CRON_CHECK=0

while true; do
    LOOP_COUNT=$((LOOP_COUNT + 1))

    # Heartbeat log every ~5 min
    if [ $((LOOP_COUNT % 60)) -eq 0 ]; then
        JOB_COUNT=$(jq 'length' "$ADDON_JOBS_FILE" 2>/dev/null || echo 0)
        log "Heartbeat: loop ${LOOP_COUNT}, ${JOB_COUNT} jobs configured"
    fi

    # ------------------------------------------------------------------
    # Check trigger files (created by Web UI "Run Now" button)
    # ------------------------------------------------------------------
    for job_name in $(get_enabled_job_names); do
        trigger_file="${ADDON_DATA_DIR}/trigger_${job_name}"
        if [ -f "$trigger_file" ]; then
            rm -f "$trigger_file"
            if ! is_backup_running "$job_name"; then
                reset_retry_count "$job_name"
                start_backup "$job_name" "MANUAL TRIGGER"
            else
                log "${job_name} - Already running, ignoring manual trigger"
            fi
        fi
    done

    # ------------------------------------------------------------------
    # Cron schedule check (every 60 seconds)
    # ------------------------------------------------------------------
    CURRENT_TIME=$(date +%s)
    if [ "$ADDON_SCHEDULE_ENABLED" = "true" ] && [ $((CURRENT_TIME - LAST_CRON_CHECK)) -ge 60 ]; then
        LAST_CRON_CHECK=$CURRENT_TIME

        CRON_MIN=$(echo "$ADDON_SCHEDULE_CRON" | awk '{print $1}')
        CRON_HOUR=$(echo "$ADDON_SCHEDULE_CRON" | awk '{print $2}')
        CURRENT_HOUR=$(date +%-H)
        CURRENT_MIN=$(date +%-M)

        if [ "$CURRENT_HOUR" = "$CRON_HOUR" ] && [ "$CURRENT_MIN" = "$CRON_MIN" ]; then
            log "Scheduled backup time reached (${CRON_HOUR}:${CRON_MIN})"

            for job_name in $(get_enabled_job_names); do
                if ! is_backup_running "$job_name"; then
                    start_backup "$job_name" "SCHEDULED"
                else
                    log "${job_name} - Already running, skipping scheduled start"
                fi
            done
        fi
    fi

    # ------------------------------------------------------------------
    # Monitor running backups: detect crashes + auto-retry
    # ------------------------------------------------------------------
    for job_name in $(get_enabled_job_names); do
        backup_path=$(get_job_field "$job_name" "backup_path")
        status=$(get_status "$job_name" "status")
        retry_count=$(get_retry_count "$job_name")

        # Status says running but process is gone = crash
        if [ "$status" = "running" ] && ! is_backup_running "$job_name"; then
            log_warn "${job_name} - Process died unexpectedly"

            if [ "$retry_count" -ge "$ADDON_MAX_RETRIES" ]; then
                log_error "${job_name} - ${ADDON_MAX_RETRIES} retries exhausted!"
                cleanup_incomplete_archives "$job_name" "${backup_path}/${job_name}/archive"
                rm -f "${ADDON_DATA_DIR}/sync_complete_${job_name}"
                write_status "$job_name" "$backup_path" "failed" "error" \
                    "Failed after ${ADDON_MAX_RETRIES} retries. Manual restart needed." "$retry_count"
            else
                retry_count=$((retry_count + 1))
                set_retry_count "$job_name" "$retry_count"
                log "${job_name} - Auto-resume (attempt ${retry_count}/${ADDON_MAX_RETRIES})"
                cleanup_incomplete_archives "$job_name" "${backup_path}/${job_name}/archive"
                start_backup "$job_name" "AUTO-RESUME (retry ${retry_count}/${ADDON_MAX_RETRIES})"
            fi
        fi

        # Status says error -> also retry
        if [ "$status" = "error" ] && [ "$retry_count" -lt "$ADDON_MAX_RETRIES" ]; then
            retry_count=$((retry_count + 1))
            set_retry_count "$job_name" "$retry_count"
            log "${job_name} - Error detected, retrying (${retry_count}/${ADDON_MAX_RETRIES})"
            cleanup_incomplete_archives "$job_name" "${backup_path}/${job_name}/archive"
            start_backup "$job_name" "ERROR-RETRY (retry ${retry_count}/${ADDON_MAX_RETRIES})"
        fi

        # Status completed -> reset retry counter
        if [ "$status" = "completed" ] && [ "$retry_count" -gt 0 ]; then
            log "${job_name} - Backup completed, resetting retry counter"
            reset_retry_count "$job_name"
        fi
    done

    sleep $LOOP_INTERVAL
done
