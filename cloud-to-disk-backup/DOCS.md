# Cloud to Disk Backup — Documentation

## Overview

This Home Assistant add-on backs up cloud storage accounts to local disks. It uses **rclone** for cloud synchronization and creates compressed, split archives that are easy to manage and restore.

## Architecture

```
┌─────────────────────────────────────────┐
│  Home Assistant Add-on Container        │
│                                         │
│  ┌──────────┐  ┌─────────────────────┐  │
│  │ Flask UI │  │ Watcher (watcher.sh)│  │
│  │ Port 8099│  │  - Cron scheduling  │  │
│  │ Ingress  │  │  - Crash detection  │  │
│  └──────────┘  │  - Auto-resume      │  │
│                └────────┬────────────┘  │
│                         │               │
│                ┌────────▼────────────┐  │
│                │ Backup (backup.sh)  │  │
│                │  Phase 1: Sync      │  │
│                │  Phase 2: Archive   │  │
│                │  Phase 3: Cleanup   │  │
│                └────────┬────────────┘  │
│                         │               │
│  ┌──────────┐  ┌───────▼─────────┐     │
│  │ rclone   │  │ Throttled I/O   │     │
│  │ config   │  │ dd+gzip+split   │     │
│  └──────────┘  └─────────────────┘     │
└─────────────────────────────────────────┘
          │                    │
     Cloud APIs          Local Disk
   (OneDrive, etc.)    (/media/...)
```

## Detailed Configuration

### Account Configuration

Each account entry defines one cloud storage backup job:

```yaml
accounts:
  - name: "my_onedrive"
    cloud_provider: "onedrive"
    remote_name: "onedrive_remote"
    backup_path: "/media/backup_disk"
    excludes:
      - "Pers*nlicher Tresor/**"
      - ".tmp/**"
      - "*.partial"
```

**Notes:**
- `name` must be unique across all accounts and is used for directory names, logs, and status files
- `remote_name` must match a configured rclone remote (set up via Web UI or manually in `/data/rclone.conf`)
- `backup_path` should point to a mounted external disk under `/media/`
- `excludes` supports rclone filter patterns (globs, double-star wildcards)

### Throttle Configuration

The add-on includes adaptive I/O throttling to prevent system lockups on hardware with watchdog timers.

**Why throttling?**
On systems with Intel iTCO_wdt (30-second timeout), writing large tar archives to SATA disks can saturate the I/O bus, causing the kernel to miss watchdog heartbeats. This triggers a hard reboot — corrupting the archive and losing progress.

**SATA vs USB:**
- SATA disks receive bursts instantly and can overwhelm the I/O scheduler
- USB disks are naturally bottlenecked by the USB protocol

**Default settings:**
| Disk Type | Chunk Size | Pause | Effective Speed |
|-----------|-----------|-------|-----------------|
| SATA | 10 MB | 2.0s | ~5 MB/s |
| USB | 50 MB | 1.0s | ~50 MB/s |

### Cron Scheduling

The `schedule.cron` option uses standard 5-field cron syntax:

```
┌─────── minute (0-59)
│ ┌───── hour (0-23)
│ │ ┌─── day of month (1-31)
│ │ │ ┌─ month (1-12)
│ │ │ │ ┌─ day of week (0-7, 0=Sun)
│ │ │ │ │
* * * * *
```

Examples:
- `0 2 * * *` — Daily at 2:00 AM
- `0 3 * * 0` — Weekly on Sunday at 3:00 AM
- `0 */6 * * *` — Every 6 hours

## Troubleshooting

### Backup keeps restarting
Check the retry counter. After `max_retries` failures, the backup stops. Check logs for the error cause (usually disk full or network timeout).

### System reboots during backup
Your hardware watchdog may be triggering. Reduce throttle settings:
```yaml
throttle:
  sata_chunk_mb: 5
  sata_pause_sec: 3.0
```

### rclone authentication fails
Re-run the rclone setup from the Web UI. For OneDrive, you may need to re-authorize if the token has expired (tokens last ~90 days).

### Disk full errors
The add-on automatically manages archive rotation. If disk is still too full:
1. Reduce `max_archives` to 1
2. Increase `split_size_mb` (fewer files)
3. Mount a larger disk

### Log file grows too large
Old logs are automatically cleaned up. Reduce `max_logs` for more aggressive cleanup.

## Restoring from Archives

To restore files from an archive:

```bash
# Combine split parts and extract
cat archive_name.tar.gz.part* | tar -xzf - -C /restore/path/

# List contents without extracting
cat archive_name.tar.gz.part* | tar -tzf -

# Extract specific file
cat archive_name.tar.gz.part* | tar -xzf - -C /restore/path/ path/to/file.txt
```

## Security

- rclone configuration (containing OAuth tokens) is stored in `/data/rclone.conf` — inside the add-on's persistent data volume, not accessible externally
- No credentials are logged or exposed via the Web UI
- The `.gitignore` excludes all sensitive files from version control
- The add-on uses Home Assistant's standard SSL/Ingress authentication
