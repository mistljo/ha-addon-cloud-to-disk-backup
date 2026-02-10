#!/usr/bin/with-contenv bashio
# ==============================================================================
# Cloud to Disk Backup - Main Backup Script
# 3-Phase: Sync -> Archive -> Cleanup
# ==============================================================================

ACCOUNT="$1"
PROVIDER="$2"
REMOTE_NAME="$3"
BACKUP_PATH="$4"
EXCLUDES="$5"

if [ -z "$ACCOUNT" ] || [ -z "$REMOTE_NAME" ] || [ -z "$BACKUP_PATH" ]; then
    bashio::log.error "Usage: backup.sh <account> <provider> <remote> <path> [excludes]"
    exit 1
fi

REMOTE="${REMOTE_NAME}:"
CURRENT_DIR="${BACKUP_PATH}/${ACCOUNT}/current"
ARCHIVE_DIR="${BACKUP_PATH}/${ACCOUNT}/archive"
LOG_DIR="${BACKUP_PATH}/logs"
LOG_FILE="${LOG_DIR}/backup_${ACCOUNT}_$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE="${ADDON_STATUS_DIR}/status_${ACCOUNT}.json"
SYNC_MARKER="${ADDON_DATA_DIR}/sync_complete_${ACCOUNT}"
RETRY_FILE="${ADDON_RETRY_DIR}/retry_${ACCOUNT}"

mkdir -p "$LOG_DIR" "$ARCHIVE_DIR" "$CURRENT_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

trap 'log "STOP: Script terminated by signal."; exit 1' SIGTERM SIGINT

update_status() {
    local status="$1"
    local stage="$2"
    local stage_num="$3"
    local message="$4"
    local progress="$5"
    local speed="${6:-0}"

    if [[ "$speed" == .* ]]; then speed="0${speed}"; fi

    local retry_count=0
    if [ -f "$RETRY_FILE" ]; then
        retry_count=$(cat "$RETRY_FILE" 2>/dev/null)
        [ -z "$retry_count" ] && retry_count=0
    fi

    cat > "$STATUS_FILE" << JSONEOF
{
    "account": "$ACCOUNT",
    "backup_path": "$BACKUP_PATH",
    "status": "$status",
    "stage": "$stage",
    "stage_number": $stage_num,
    "timestamp": "$(date -Iseconds)",
    "message": "$message",
    "progress": $progress,
    "speed_mbps": $speed,
    "retry_count": $retry_count
}
JSONEOF
}

get_cloud_size() {
    rclone about "$1" --config="$ADDON_RCLONE_CONF" 2>/dev/null | \
        grep "Used:" | awk '{print $2}' | awk '{printf "%.0f", $1}'
}

get_archive_bases() {
    ls -1 "$ARCHIVE_DIR"/${ACCOUNT}_*.part* 2>/dev/null | sed 's/\.part.*//' | sort -u
}

count_archives() {
    get_archive_bases | grep -c . 2>/dev/null || echo 0
}

get_available_gb() {
    df -BG "$BACKUP_PATH" | tail -1 | awk '{print $4}' | sed 's/G//'
}

# ==============================================================================
log "========================================="
log "Starting backup for ${ACCOUNT} (${PROVIDER})"
log "========================================="

# Kernel I/O tuning
if [ -w /proc/sys/vm/dirty_ratio ]; then
    echo "$ADDON_DIRTY_RATIO" > /proc/sys/vm/dirty_ratio 2>/dev/null
    echo "$ADDON_DIRTY_BG_RATIO" > /proc/sys/vm/dirty_background_ratio 2>/dev/null
    log "Kernel I/O tuning: dirty_ratio=${ADDON_DIRTY_RATIO}, dirty_background_ratio=${ADDON_DIRTY_BG_RATIO}"
fi

# ==============================================================================
# PRE-FLIGHT
# ==============================================================================
if [ ! -d "$BACKUP_PATH" ]; then
    log "ERROR: Backup path not mounted: $BACKUP_PATH"
    update_status "error" "error" 0 "Backup path not mounted" 0 0
    exit 1
fi

update_status "running" "preflight" 0 "Checking cloud storage size..." 0 0

TOTAL_SIZE=$(get_cloud_size "$REMOTE")
if [ -z "$TOTAL_SIZE" ] || [ "$TOTAL_SIZE" -eq 0 ] 2>/dev/null; then
    log "WARNING: Could not determine cloud size, using estimate 155GB"
    TOTAL_SIZE=155
fi

AVAILABLE_GB=$(get_available_gb)
ARCHIVE_COUNT=$(count_archives)

log "Cloud size:     ${TOTAL_SIZE} GB"
log "Free space:     ${AVAILABLE_GB} GB"
log "Archives:       ${ARCHIVE_COUNT}"

if [ "$AVAILABLE_GB" -lt 5 ]; then
    log "ERROR: Disk almost full - less than 5GB free"
    update_status "error" "preflight" 0 "Disk full: only ${AVAILABLE_GB}GB free" 0 0
    exit 1
fi

log "Space check OK: ${AVAILABLE_GB}GB free"
sleep 1

# ==============================================================================
# Check Sync Marker: Skip Phase 1 if already synced today
# ==============================================================================
SKIP_SYNC=false
if [ -f "$SYNC_MARKER" ]; then
    MARKER_DATE=$(cat "$SYNC_MARKER" 2>/dev/null)
    TODAY=$(date +%Y%m%d)
    if [ "$MARKER_DATE" = "$TODAY" ]; then
        log "========================================="
        log "PHASE 1 SKIPPED - Sync already completed today"
        log "========================================="
        update_status "running" "sync" 1 "Phase 1 skipped - sync already done" 100 0
        SKIP_SYNC=true
        sleep 1
    else
        log "Sync marker outdated (${MARKER_DATE}), new sync needed"
        rm -f "$SYNC_MARKER"
    fi
fi

if [ "$SKIP_SYNC" = false ]; then
# ==============================================================================
# PHASE 1: SYNC
# ==============================================================================
log "========================================="
log "PHASE 1/3: Synchronization"
log "========================================="
update_status "running" "sync" 1 "Phase 1/3: Starting sync" 0 0

# Build rclone command with excludes
RCLONE_CMD="rclone sync -vv \"${REMOTE}\" \"${CURRENT_DIR}\" --config=\"${ADDON_RCLONE_CONF}\" --progress --stats 30s --transfers ${ADDON_RCLONE_TRANSFERS} --checkers ${ADDON_RCLONE_CHECKERS} --stats-one-line --log-file=\"${LOG_FILE}\""

# Add excludes
eval "set -- $EXCLUDES"
for exc in "$@"; do
    RCLONE_CMD="${RCLONE_CMD} --exclude \"${exc}\""
done

eval $RCLONE_CMD &

RCLONE_PID=$!
log "rclone started with PID $RCLONE_PID"

LAST_SIZE=0
LAST_TIME=$(date +%s)
while kill -0 $RCLONE_PID 2>/dev/null; do
    if [ -d "$CURRENT_DIR" ]; then
        CURRENT_SIZE=$(du -sb "$CURRENT_DIR" 2>/dev/null | awk '{print $1}')
        CURRENT_TIME=$(date +%s)

        if [ -n "$CURRENT_SIZE" ] && [ "$TOTAL_SIZE" != "0" ]; then
            CURRENT_GB=$(echo "scale=2; $CURRENT_SIZE / 1073741824" | bc)
            PROGRESS=$(echo "scale=0; ($CURRENT_GB * 100) / $TOTAL_SIZE" | bc)
            [ "$PROGRESS" -gt 100 ] && PROGRESS=100

            SPEED_MBPS="0"
            if [ "$LAST_SIZE" -ne 0 ]; then
                TIME_DIFF=$((CURRENT_TIME - LAST_TIME))
                if [ "$TIME_DIFF" -gt 0 ]; then
                    SIZE_DIFF=$((CURRENT_SIZE - LAST_SIZE))
                    SPEED_MBPS=$(echo "scale=2; $SIZE_DIFF / $TIME_DIFF / 1048576" | bc)
                fi
            fi

            update_status "running" "sync" 1 "Syncing: ${CURRENT_GB}GB / ${TOTAL_SIZE}GB" $PROGRESS "$SPEED_MBPS"
            LAST_SIZE=$CURRENT_SIZE
            LAST_TIME=$CURRENT_TIME
        fi
    fi
    sleep 30
done

wait $RCLONE_PID
SYNC_RESULT=$?

if [ $SYNC_RESULT -ne 0 ]; then
    log "ERROR: Sync failed (exit code: $SYNC_RESULT)"
    update_status "error" "sync" 1 "Sync failed" 100 0
    exit 1
fi

log "Phase 1 complete - Sync successful"
date +%Y%m%d > "$SYNC_MARKER"
log "Sync marker written for Phase 2 resume"
update_status "running" "sync" 1 "Phase 1/3 complete" 100 0
sleep 2

fi  # End SKIP_SYNC

# ==============================================================================
# PHASE 2: ARCHIVE
# ==============================================================================
log "========================================="
log "PHASE 2/3: Archiving"
log "========================================="
update_status "running" "archive" 2 "Phase 2/3: Checking space for archive" 0 0

ARCHIVE_ESTIMATE=$(echo "scale=0; $TOTAL_SIZE * 40 / 100" | bc)
SAFETY_BUFFER=10
SPACE_FOR_ARCHIVE=$((ARCHIVE_ESTIMATE + SAFETY_BUFFER))
AVAILABLE_GB=$(get_available_gb)

log "Archive estimate: ${ARCHIVE_ESTIMATE} GB (~40% of ${TOTAL_SIZE}GB)"
log "Safety buffer:    ${SAFETY_BUFFER} GB"
log "Space needed:     ${SPACE_FOR_ARCHIVE} GB"
log "Available:        ${AVAILABLE_GB} GB"

# Delete old archives if needed
if [ "$AVAILABLE_GB" -lt "$SPACE_FOR_ARCHIVE" ]; then
    ARCHIVE_COUNT=$(count_archives)
    log "Not enough space - deleting old archives (${ARCHIVE_COUNT} present)"
    update_status "running" "archive" 2 "Deleting old archives for space..." 5 0

    if [ "$ARCHIVE_COUNT" -gt 0 ]; then
        get_archive_bases | while read archive_base; do
            [ -z "$archive_base" ] && continue
            log "Deleting archive: $(basename $archive_base)"
            rm -f "${archive_base}".part* 2>/dev/null

            NEW_AVAILABLE=$(get_available_gb)
            log "Free after delete: ${NEW_AVAILABLE} GB"
            [ "$NEW_AVAILABLE" -ge "$SPACE_FOR_ARCHIVE" ] && break
        done
    fi

    AVAILABLE_GB=$(get_available_gb)
    if [ "$AVAILABLE_GB" -lt "$SPACE_FOR_ARCHIVE" ]; then
        DEFICIT=$((SPACE_FOR_ARCHIVE - AVAILABLE_GB))
        log "ERROR: Not enough space even after cleanup. ${DEFICIT}GB missing"
        update_status "error" "archive" 2 "No space for archive: ${DEFICIT}GB missing" 50 0
        exit 1
    fi
fi

log "Space OK: ${AVAILABLE_GB}GB free (need ${SPACE_FOR_ARCHIVE}GB)"

# Cleanup incomplete archives from today
INCOMPLETE=$(ls -1 "$ARCHIVE_DIR"/${ACCOUNT}_$(date +%Y%m%d)_*.part* 2>/dev/null | sed 's/\.part.*//' | sort -u)
if [ -n "$INCOMPLETE" ]; then
    echo "$INCOMPLETE" | while read inc_base; do
        log "Deleting incomplete archive: $(basename $inc_base)"
        rm -f "${inc_base}".part* 2>/dev/null
    done
fi

ARCHIVE_NAME="${ACCOUNT}_$(date +%Y%m%d_%H%M%S).tar.gz"
ARCHIVE_PATH="${ARCHIVE_DIR}/${ARCHIVE_NAME}"

log "Starting compression: $CURRENT_DIR -> $ARCHIVE_PATH"
log "Source size: $(du -sh $CURRENT_DIR | cut -f1)"
update_status "running" "archive" 2 "Compression started..." 10 0

# Adaptive throttle based on disk type (SATA vs USB)
if [ "$ADDON_THROTTLE_AUTO" = "true" ]; then
    DISK_DEV=$(df "$ARCHIVE_DIR" | tail -1 | awk '{print $1}' | sed 's|/dev/||;s|[0-9]*$||')
    DISK_TRAN=$(lsblk -no TRAN "/dev/${DISK_DEV}" 2>/dev/null)

    if [ "$DISK_TRAN" = "sata" ] || [ "$DISK_TRAN" = "ata" ]; then
        DD_BS="1M"; DD_COUNT=$ADDON_SATA_CHUNK_MB; THROTTLE_SLEEP=$ADDON_SATA_PAUSE_SEC
        log "SATA disk detected (${DISK_DEV}) - heavy throttle: ${DD_COUNT}MB + ${THROTTLE_SLEEP}s pause"
    else
        DD_BS="1M"; DD_COUNT=$ADDON_USB_CHUNK_MB; THROTTLE_SLEEP=$ADDON_USB_PAUSE_SEC
        log "USB disk detected (${DISK_DEV}) - normal throttle: ${DD_COUNT}MB + ${THROTTLE_SLEEP}s pause"
    fi
else
    DD_BS="1M"; DD_COUNT=$ADDON_USB_CHUNK_MB; THROTTLE_SLEEP=$ADDON_USB_PAUSE_SEC
    log "Auto-detect disabled - using USB throttle: ${DD_COUNT}MB + ${THROTTLE_SLEEP}s pause"
fi

nohup nice -n 19 ionice -c 3 tar -cf - -C "$(dirname $CURRENT_DIR)" "$(basename $CURRENT_DIR)" 2>> "$LOG_FILE" | \
  nice -n 19 ionice -c 3 sh -c "while true; do dd bs=$DD_BS count=$DD_COUNT iflag=fullblock 2>/tmp/.tar_throttle_stat_${ACCOUNT}; if grep -q '^0+0' /tmp/.tar_throttle_stat_${ACCOUNT} 2>/dev/null; then break; fi; sleep $THROTTLE_SLEEP; done; rm -f /tmp/.tar_throttle_stat_${ACCOUNT}" | \
  nice -n 19 ionice -c 3 gzip -${ADDON_COMPRESSION_LEVEL} | \
  nice -n 19 ionice -c 3 split -b ${ADDON_SPLIT_SIZE_MB}m - "${ARCHIVE_PATH}.part" 2>> "$LOG_FILE" &
TAR_PID=$!
log "tar started PID: $TAR_PID (nice+ionice, throttled pipeline)"

EXPECTED_SIZE=$(du -sb $CURRENT_DIR | awk '{print $1}')
log "Estimated archive: ~$(echo "scale=2; $EXPECTED_SIZE / 1024 / 1024 / 1024 * 0.3" | bc)GB (~30% compression)"

for i in {10..95..5}; do
    if kill -0 $TAR_PID 2>/dev/null; then
        if ls "${ARCHIVE_PATH}".part* >/dev/null 2>&1; then
            CURRENT_ARCHIVE_SIZE=$(du -ch "${ARCHIVE_PATH}".part* 2>/dev/null | tail -1 | cut -f1)
            update_status "running" "archive" 2 "Compressing: ${i}% - Archive: $CURRENT_ARCHIVE_SIZE" $i 0
        else
            update_status "running" "archive" 2 "Compressing: ${i}%" $i 0
        fi
        sleep 15
    else
        break
    fi
done

log "Waiting for tar/split processes..."
while ps aux | grep -E "[t]ar.*${ACCOUNT}|[s]plit.*${ARCHIVE_PATH}" > /dev/null; do
    if ls "${ARCHIVE_PATH}".part* >/dev/null 2>&1; then
        CURRENT_ARCHIVE_SIZE=$(du -ch "${ARCHIVE_PATH}".part* 2>/dev/null | tail -1 | cut -f1)
        update_status "running" "archive" 2 "Compressing - Archive: $CURRENT_ARCHIVE_SIZE" 98 0
    fi
    sleep 10
done

if ! ls "${ARCHIVE_PATH}".part* >/dev/null 2>&1; then
    log "ERROR: No archive parts found"
    update_status "error" "archive" 2 "Compression failed" 100 0
    exit 1
fi

log "Compression complete"
ARCHIVE_SIZE=$(du -ch "${ARCHIVE_PATH}".part* 2>/dev/null | tail -1 | cut -f1)
rm -f "$SYNC_MARKER"
log "Sync marker removed (archive complete)"
update_status "running" "archive" 2 "Phase 2/3 complete - Archive: $ARCHIVE_SIZE" 100 0
sleep 2

# ==============================================================================
# PHASE 3: CLEANUP
# ==============================================================================
log "========================================="
log "PHASE 3/3: Cleanup"
log "========================================="
update_status "running" "cleanup" 3 "Phase 3/3: Cleaning old archives" 30 0

ARCHIVE_BASES=$(get_archive_bases)
ARCHIVE_COUNT=$(echo "$ARCHIVE_BASES" | grep -c . 2>/dev/null || echo 0)
log "Current archives: ${ARCHIVE_COUNT}"

if [ "$ARCHIVE_COUNT" -gt "$ADDON_MAX_ARCHIVES" ]; then
    ARCHIVES_TO_DELETE=$(echo "$ARCHIVE_BASES" | head -n -${ADDON_MAX_ARCHIVES})
    if [ -n "$ARCHIVES_TO_DELETE" ]; then
        echo "$ARCHIVES_TO_DELETE" | while read old_base; do
            [ -z "$old_base" ] && continue
            log "Deleting old archive: $(basename $old_base)"
            rm -f "${old_base}".part* 2>/dev/null
        done
    fi
    log "Old archives deleted, keeping ${ADDON_MAX_ARCHIVES} newest"
else
    log "Only ${ARCHIVE_COUNT} archives - nothing to delete"
fi

# Log cleanup
LOG_COUNT=$(ls -1 "$LOG_DIR"/backup_${ACCOUNT}_*.log 2>/dev/null | wc -l)
if [ "$LOG_COUNT" -gt "$ADDON_MAX_LOGS" ]; then
    LOGS_TO_DELETE=$(ls -1t "$LOG_DIR"/backup_${ACCOUNT}_*.log | tail -n +$((ADDON_MAX_LOGS + 1)))
    echo "$LOGS_TO_DELETE" | while read old_log; do
        [ -z "$old_log" ] && continue
        [ "$old_log" = "$LOG_FILE" ] && continue
        rm -f "$old_log"
    done
    log "Old logs cleaned: keeping ${ADDON_MAX_LOGS} newest"
fi

ARCHIVE_COUNT=$(count_archives)
DISK_USED=$(df -h "$BACKUP_PATH" | tail -1 | awk '{print $5}' | sed 's/%//')

update_status "running" "cleanup" 3 "Phase 3/3 complete" 100 0
sleep 2

# ==============================================================================
# DONE
# ==============================================================================
log "========================================="
log "Backup completed successfully!"
log "  Account:  $ACCOUNT"
log "  Archive:  $ARCHIVE_NAME ($ARCHIVE_SIZE)"
log "  Archives: $ARCHIVE_COUNT stored"
log "  Disk:     ${DISK_USED}% used"
log "========================================="
update_status "completed" "completed" 3 "Backup complete - ${ARCHIVE_COUNT} archives, disk ${DISK_USED}% used" 100 0

exit 0
