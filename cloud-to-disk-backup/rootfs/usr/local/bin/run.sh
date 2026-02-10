#!/usr/bin/with-contenv bashio
# ==============================================================================
# Cloud to Disk Backup - Entry Point (v2.0 - Dynamic Configuration)
# Backup jobs & cloud remotes are configured entirely via the Web UI.
# Only global settings (schedule, archive, throttle) come from HA config.
# ==============================================================================
set -e

DATA_DIR="/data"
RCLONE_CONF="${DATA_DIR}/rclone.conf"
STATUS_DIR="${DATA_DIR}/status"
RETRY_DIR="${DATA_DIR}/retry"
JOBS_FILE="${DATA_DIR}/jobs.json"

mkdir -p "$STATUS_DIR" "$RETRY_DIR" "${DATA_DIR}/logs"

# Initialize jobs.json if it doesn't exist
if [ ! -f "$JOBS_FILE" ]; then
    echo '[]' > "$JOBS_FILE"
fi

# Initialize rclone.conf if it doesn't exist
if [ ! -f "$RCLONE_CONF" ]; then
    touch "$RCLONE_CONF"
fi

bashio::log.info "Cloud to Disk Backup v2.0 starting..."

# ==============================================================================
# Export global configuration (from HA add-on settings)
# ==============================================================================
export ADDON_SCHEDULE_ENABLED=$(bashio::config 'schedule.enabled')
export ADDON_SCHEDULE_CRON=$(bashio::config 'schedule.cron')
export ADDON_MAX_ARCHIVES=$(bashio::config 'archive.max_archives')
export ADDON_MAX_LOGS=$(bashio::config 'archive.max_logs')
export ADDON_SPLIT_SIZE_MB=$(bashio::config 'archive.split_size_mb')
export ADDON_COMPRESSION_LEVEL=$(bashio::config 'archive.compression_level')
export ADDON_THROTTLE_AUTO=$(bashio::config 'throttle.auto_detect')
export ADDON_SATA_CHUNK_MB=$(bashio::config 'throttle.sata_chunk_mb')
export ADDON_SATA_PAUSE_SEC=$(bashio::config 'throttle.sata_pause_sec')
export ADDON_USB_CHUNK_MB=$(bashio::config 'throttle.usb_chunk_mb')
export ADDON_USB_PAUSE_SEC=$(bashio::config 'throttle.usb_pause_sec')
export ADDON_DIRTY_RATIO=$(bashio::config 'advanced.dirty_ratio')
export ADDON_DIRTY_BG_RATIO=$(bashio::config 'advanced.dirty_background_ratio')
export ADDON_MAX_RETRIES=$(bashio::config 'advanced.max_retries')
export ADDON_RCLONE_TRANSFERS=$(bashio::config 'advanced.rclone_transfers')
export ADDON_RCLONE_CHECKERS=$(bashio::config 'advanced.rclone_checkers')
export ADDON_RCLONE_CONF="$RCLONE_CONF"
export ADDON_STATUS_DIR="$STATUS_DIR"
export ADDON_RETRY_DIR="$RETRY_DIR"
export ADDON_DATA_DIR="$DATA_DIR"
export ADDON_JOBS_FILE="$JOBS_FILE"

# HA API access
export SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN}"

# Ingress path for Web UI
export INGRESS_PATH="$(bashio::addon.ingress_entry)"

# ==============================================================================
# Start rclone RC daemon (internal API for remote management)
# ==============================================================================
bashio::log.info "Starting rclone RC daemon on 127.0.0.1:5572..."
rclone rcd --rc-addr 127.0.0.1:5572 --rc-no-auth --config "$RCLONE_CONF" \
    > "${DATA_DIR}/logs/rclone_rcd.log" 2>&1 &
RCLONE_RCD_PID=$!
bashio::log.info "rclone RCD started (PID: ${RCLONE_RCD_PID})"
sleep 2

# ==============================================================================
# Start Ingress Web UI
# ==============================================================================
bashio::log.info "Starting Web UI on port 8099..."
export ADDON_WEB_PORT=8099
python3 /usr/local/bin/web/app.py > "${DATA_DIR}/logs/web_ui.log" 2>&1 &
WEB_PID=$!
bashio::log.info "Web UI started (PID: ${WEB_PID})"

# ==============================================================================
# Log configuration summary
# ==============================================================================
JOB_COUNT=$(jq 'length' "$JOBS_FILE" 2>/dev/null || echo 0)
bashio::log.info "Configuration:"
bashio::log.info "  Schedule:  ${ADDON_SCHEDULE_ENABLED} (${ADDON_SCHEDULE_CRON})"
bashio::log.info "  Jobs:      ${JOB_COUNT} configured (managed via Web UI)"
bashio::log.info "  Ingress:   ${INGRESS_PATH}"

# ==============================================================================
# Start Watcher (main loop - reads jobs from /data/jobs.json)
# ==============================================================================
bashio::log.info "Starting backup watcher..."
exec /usr/local/bin/watcher.sh
