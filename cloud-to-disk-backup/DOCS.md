# Cloud to Disk Backup — Documentation

## Overview

This Home Assistant add-on backs up cloud storage accounts to local disks. It uses **rclone** for cloud synchronization and creates compressed, split archives that are easy to manage and restore.

## Architecture

```
┌──────────────────────────────────────────────┐
│  Home Assistant Add-on Container             │
│                                              │
│  ┌──────────────┐  ┌──────────────────────┐  │
│  │  Flask UI    │  │ Watcher (watcher.sh) │  │
│  │  Port 8099   │  │  - Reads jobs.json   │  │
│  │  Ingress     │  │  - Cron scheduling   │  │
│  │  - Dashboard │  │  - Crash detection   │  │
│  │  - Jobs CRUD │  │  - Auto-resume       │  │
│  │  - Remotes   │  └────────┬─────────────┘  │
│  │  - Logs      │           │                │
│  └──────┬───────┘  ┌────────▼────────────┐   │
│         │          │ Backup (backup.sh)   │   │
│  ┌──────▼───────┐  │  Phase 1: Sync      │   │
│  │ rclone RCD   │  │  Phase 2: Archive   │   │
│  │ RC API :5572 │  │  Phase 3: Cleanup   │   │
│  └──────────────┘  └────────┬────────────┘   │
│                             │                │
│  /data/jobs.json   ┌───────▼─────────┐       │
│  /data/rclone.conf │ Throttled I/O   │       │
│                    │ dd+gzip+split   │       │
│                    └─────────────────┘       │
└──────────────────────────────────────────────┘
          │                    │
     Cloud APIs          Local Disk
   (OneDrive, etc.)    (/media/...)
```

**Key change in v2.0:** Backup jobs and cloud remotes are configured
entirely via the Web UI. No more editing `config.yaml` for accounts.

## Getting Started

### 1. Install the Add-on

Add `https://github.com/mistljo/ha-addon-cloud-to-disk-backup` as a
repository in Home Assistant (Settings → Add-ons → Store → ⋮ → Repositories).
Then install **Cloud to Disk Backup** and start it.

### 2. Configure Cloud Remotes (Web UI → Cloud Remotes tab)

1. Open the add-on via the sidebar ("Cloud Backup")
2. Go to the **Cloud Remotes** tab
3. Select your provider (OneDrive, Google Drive, Dropbox, …)
4. On your **local PC**, run `rclone authorize "onedrive"` (or the displayed command)
5. Complete the OAuth login in your browser
6. Copy the JSON token from the terminal output
7. Paste the token into the Web UI and click **Create Remote**
8. Click **Test Connection** to verify

**Alternative:** If you already have a working `rclone.conf`, you can
paste its contents in the "Advanced: Import rclone.conf" section.

### 3. Create Backup Jobs (Web UI → Backup Jobs tab)

1. Go to the **Backup Jobs** tab
2. Fill in the form:
   - **Job Name** — unique identifier (e.g., "My OneDrive")
   - **Cloud Provider** — matches your remote type
   - **rclone Remote** — select the remote you created in step 2
   - **Backup Path** — target directory on a mounted disk (e.g., `/media/Backup_Disk/backups`)
   - **Excludes** — optional rclone filter patterns, one per line
3. Click **Save Job**

Jobs are stored in `/data/jobs.json` and persist across restarts.

**Notes:**
- Job names must be unique (used for directory names, logs, and status files)
- The rclone remote must match a configured remote from the Cloud Remotes tab
- Backup paths should point to a mounted external disk under `/media/`
- Excludes support rclone filter patterns (globs, `**` wildcards)

## Detailed Configuration

Global settings are configured via the HA add-on configuration panel
(not the Web UI). They apply to all backup jobs.

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
