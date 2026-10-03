
---

## Features

- Snapshot-based backups using `rsync --link-dest`
- Hard-link deduplication — unchanged files cost zero extra disk space
- Incremental storage growth — only new/changed data is written
- Restore by simple file copy — no special tooling required
- Per-snapshot SHA-256 integrity manifests
- **Incremental manifest generation** — unchanged files inherit their checksum from the previous snapshot instead of being re-hashed every run, with live progress shown during a full/large hash
- **Named Added / Removed / Modified reports** — every run tells you exactly which files were added, removed, or changed in place since the last snapshot, not just a raw count
- **Time-based retention** (default: 365 days) — keeps every completed snapshot newer than the configured window, regardless of how many that turns out to be
- **Incomplete-run quarantine** — an interrupted snapshot (power loss, unplugged drive, Ctrl+C) is moved to a separate quarantine folder instead of being deleted, so partial data stays recoverable
- External drive auto-detection (`/run/media/$USER`, `/media/$USER`, `/media`)
- Source/destination overlap protection
- Concurrent-run protection via file locking
- Safe interrupt cleanup for all temporary files (Ctrl+C, SIGTERM, crashes)
- Optional per-folder `.backupignore`, plus built-in exclusion of common junk (editor backup files, LibreOffice/OpenOffice lock files, cache/trash directories)
- Post-backup sanity check (random sample vs. live source)
- Dry-run mode
- Desktop notifications on success/failure
- Detailed per-run logging

---

## Non-Goals

This project intentionally does not provide:

- Cloud backup
- Encryption
- Compression
- Backup databases
- Windows support
- Network repositories
- Continuous real-time backup
- Enterprise backup management

---

## Requirements

**Required:**

- Linux
- Bash 4+
- `rsync`
- `coreutils` (includes `sha256sum`, `sort`, `wc`, `tr`, `mkdir`, `date`, `basename`, `dirname`, `realpath`, `du`, `mktemp`, `sync`)
- `findutils` (`find`, `xargs`)
- `util-linux` (`flock`) — used to prevent concurrent runs; the script will not start without it

**Optional (script degrades gracefully if missing):**

- `notify-send` — desktop notifications
- `upower` — battery status warning
- `shuf` — required for the sanity check step

If a required command is missing, the script fails immediately with a clear message and an install suggestion for common package managers (`apt`, `pacman`, `dnf`, `eopkg`) rather than failing partway through a run.

---

## Filesystem Support

**Recommended (destination drive):**

- ext4
- xfs
- btrfs

**Not recommended for snapshot mode:**

- exFAT
- vFAT / FAT32
- NTFS (including FUSE-mounted NTFS/exFAT)

These filesystems do not reliably support hard links. Using one as your backup destination will cause every snapshot to become a full, non-deduplicated copy rather than a space-efficient incremental one. The script detects this and warns you before proceeding.

---

## How It Works

### First Backup

The first run creates a complete baseline snapshot:
