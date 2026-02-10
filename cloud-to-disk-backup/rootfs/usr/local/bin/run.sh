#!/usr/bin/with-contenv bashio
# ==============================================================================
# Cloud to Disk Backup - Entry Point
# ==============================================================================
set -e

CONFIG_PATH="/data/options.json"
DATA_DIR="/data"
RCLONE_CONF="${DATA_DIR}/rclone.conf"
STATUS_DIR="${DATA_DIR}/status"
RETRY_DIR="${DATA_DIR}/retry"

mkdir -p "$STATUS_DIR" "$RETRY_DIR" "${DATA_DIR}/logs"

# ==============================================================================
# Read Add-on Configuration
# ==============================================================================
bashio::log.info "Cloud to Disk Backup Add-on starting..."

# Export config as environment variables for child scripts
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

# Get HA API access
export SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN}"
export HA_API_URL="http://supervisor/core/api"

# ==============================================================================
# Build account list from config
# ==============================================================================
ACCOUNT_COUNT=$(bashio::config 'accounts | length')
bashio::log.info "Configured accounts: ${ACCOUNT_COUNT}"

export ADDON_ACCOUNT_COUNT="$ACCOUNT_COUNT"

for i in $(seq 0 $((ACCOUNT_COUNT - 1))); do
    name=$(bashio::config "accounts[${i}].name")
    provider=$(bashio::config "accounts[${i}].cloud_provider")
    remote=$(bashio::config "accounts[${i}].remote_name")
    path=$(bashio::config "accounts[${i}].backup_path")

    export "ADDON_ACCOUNT_${i}_NAME=${name}"
    export "ADDON_ACCOUNT_${i}_PROVIDER=${provider}"
    export "ADDON_ACCOUNT_${i}_REMOTE=${remote}"
    export "ADDON_ACCOUNT_${i}_PATH=${path}"

    # Build excludes list
    exclude_count=$(bashio::config "accounts[${i}].excludes | length")
    excludes=""
    for j in $(seq 0 $((exclude_count - 1))); do
        exc=$(bashio::config "accounts[${i}].excludes[${j}]")
        excludes="${excludes} --exclude \"${exc}\""
    done
    export "ADDON_ACCOUNT_${i}_EXCLUDES=${excludes}"

    bashio::log.info "  Account ${i}: ${name} (${provider}) -> ${path}"
done

# ==============================================================================
# Check rclone configuration
# ==============================================================================
if [ ! -f "$RCLONE_CONF" ]; then
    bashio::log.warning "No rclone.conf found at ${RCLONE_CONF}"
    bashio::log.warning "Please configure cloud storage via the Web UI"
fi

# ==============================================================================
# Start Ingress Web UI (background)
# ==============================================================================
bashio::log.info "Starting Web UI on port 8099..."
python3 /usr/local/bin/web/app.py &
WEB_PID=$!
bashio::log.info "Web UI started (PID: ${WEB_PID})"

# ==============================================================================
# Start Watcher (main loop)
# ==============================================================================
bashio::log.info "Starting backup watcher..."
exec /usr/local/bin/watcher.sh
