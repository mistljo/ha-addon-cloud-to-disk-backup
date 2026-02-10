# Cloud to Disk Backup - Home Assistant Add-on

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Back up your cloud storage (OneDrive, Google Drive, Dropbox) to a local disk — automatically, throttled, and crash-resilient.

## Features

- **Multi-Account Support** — Back up multiple cloud accounts simultaneously
- **Multi-Provider** — OneDrive, Google Drive, Dropbox (via rclone)
- **3-Phase Backup** — Sync → Archive → Cleanup pipeline
- **Adaptive I/O Throttle** — Auto-detects SATA vs USB disks, adjusts write speed to prevent system lockups
- **Crash Resilience** — Auto-resume after reboots, persistent retry counters, sync markers
- **Ingress Web UI** — Status dashboard, live logs, rclone setup wizard — all inside Home Assistant
- **Cron Scheduling** — Flexible scheduling with standard cron expressions
- **Hardware Watchdog Safe** — Designed for systems with iTCO_wdt hardware watchdogs (30s timeout)

## Installation

### Adding the Repository

1. Open Home Assistant → **Settings** → **Add-ons** → **Add-on Store**
2. Click **⋮** (top right) → **Repositories**
3. Add: `https://github.com/mistljo/ha-addon-cloud-to-disk-backup`
4. Click **Close** → Refresh → Find **Cloud to Disk Backup**
5. Click **Install**

### Initial Setup

1. **Configure rclone** — Open the add-on's **Web UI** and use the Setup tab to create cloud remotes
2. **Configure accounts** — In the add-on **Configuration** tab, add your accounts:

```yaml
accounts:
  - name: my_onedrive
    cloud_provider: onedrive
    remote_name: my_onedrive_remote
    backup_path: /media/backup_disk
    excludes:
      - "Pers*nlicher Tresor/**"
      - ".tmp/**"
```

3. **Enable scheduling** (optional):
```yaml
schedule:
  enabled: true
  cron: "0 2 * * *"    # Daily at 2 AM
```

4. **Start the add-on**

## Configuration

### Accounts

| Option | Type | Description |
|--------|------|-------------|
| `name` | string | Unique account identifier |
| `cloud_provider` | enum | `onedrive`, `gdrive`, or `dropbox` |
| `remote_name` | string | Name of the rclone remote (configured in Setup) |
| `backup_path` | string | Local path for backups (e.g., `/media/backup_disk`) |
| `excludes` | list | Patterns to exclude from sync |

### Schedule

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | `false` | Enable automatic scheduling |
| `cron` | string | `0 2 * * *` | Cron expression for backup schedule |

### Archive

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `max_archives` | int | `2` | Number of archive versions to keep |
| `max_logs` | int | `10` | Number of log files to keep |
| `split_size_mb` | int | `10240` | Archive split part size in MB |
| `compression_level` | int | `6` | gzip compression level (1-9) |

### Throttle

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `auto_detect` | bool | `true` | Auto-detect SATA/USB and adjust speed |
| `sata_chunk_mb` | int | `10` | Write chunk size for SATA disks |
| `sata_pause_sec` | float | `2.0` | Pause between writes (SATA) |
| `usb_chunk_mb` | int | `50` | Write chunk size for USB disks |
| `usb_pause_sec` | float | `1.0` | Pause between writes (USB) |

### Advanced

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `dirty_ratio` | int | `10` | Linux dirty page ratio for I/O control |
| `max_retries` | int | `5` | Max retry attempts before giving up |
| `rclone_transfers` | int | `4` | Parallel rclone transfer threads |
| `rclone_checkers` | int | `8` | Parallel rclone checker threads |

## How It Works

### Phase 1: Sync
Uses `rclone sync` to mirror cloud storage to a local `current/` directory. A sync marker file is written on success — if the system reboots mid-archive, Phase 1 is skipped on resume.

### Phase 2: Archive
Creates a compressed `tar.gz` archive of the synced data, split into configurable parts. The tar pipeline is throttled with adaptive `dd` chunking to prevent I/O saturation and hardware watchdog timeouts.

### Phase 3: Cleanup
Removes old archives exceeding `max_archives` count. Cleans up old log files.

### Crash Resilience
- **Sync marker** persists across reboots in `/data/` — completed syncs aren't repeated
- **Retry counter** in `/data/` — tracks failures across reboots, gives up after `max_retries`
- **Watcher process** monitors backup lifecycle, auto-restarts failed backups
- **Incomplete archive cleanup** — partial archives from crashed runs are deleted before retry

## Web UI

The Ingress-based web UI provides:
- **Dashboard** — Real-time status for all accounts (progress, speed, stage, retries)
- **Disk Usage** — Visual disk usage with warning thresholds
- **Live Logs** — Stream backup logs in real-time via SSE
- **Setup Wizard** — Create and manage rclone remotes

## Disk Directory Structure

```
/media/backup_disk/
├── account_name/
│   ├── current/          # Live rclone mirror
│   └── archive/          # Compressed archives
│       ├── account_20260210_020000.tar.gz.partaa
│       ├── account_20260210_020000.tar.gz.partab
│       └── ...
└── logs/
    ├── backup_account_20260210_020000.log
    └── ...
```

## Requirements

- Home Assistant OS or Supervised installation
- External USB or SATA disk mounted and accessible under `/media/`
- Internet connection for cloud storage access

## Supported Architectures

- `amd64` (Intel/AMD 64-bit)
- `aarch64` (ARM 64-bit, e.g., Raspberry Pi 4)
- `armv7` (ARM 32-bit)
- `i386` (Intel 32-bit)

## License

MIT License — see [LICENSE](LICENSE) for details.

## Credits

Built from real-world experience backing up 275GB+ OneDrive accounts to local disks on Home Assistant systems with hardware watchdogs and I/O constraints.
