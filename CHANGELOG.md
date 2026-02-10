# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-02-10

### Added
- Initial release
- Multi-account cloud backup support (OneDrive, Google Drive, Dropbox)
- 3-phase backup pipeline: Sync → Archive → Cleanup
- Adaptive I/O throttling with SATA/USB auto-detection
- Crash resilience: sync markers, persistent retry counters, auto-resume
- Ingress Web UI with status dashboard, live log viewer, rclone setup wizard
- Cron-based scheduling
- Split archive support for large backups
- AppArmor security profile
- Multi-architecture support (amd64, aarch64, armv7, i386)
- English and German translations
