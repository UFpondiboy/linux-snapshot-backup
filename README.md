# Snapshot Backup (Engine v5.1)

A lightweight, hardened snapshot-based backup system for Linux, built on `rsync` and hard links.

Each backup appears as a complete, independent copy of your files, while unchanged files are shared between snapshots using hard links. This gives you Time Machine–style versioned backups without duplicating unchanged data on disk.

Built and tested on KDE Plasma / udisks2 automount setups, with fallback support for other Linux desktop environments.

> **What "snapshot" means in this project**
>
> This project creates **directory-based snapshots** using `rsync` and hard links.
> It does **not** create filesystem snapshots such as **Btrfs**, **ZFS**, or **LVM** snapshots.
>
> Every snapshot is an ordinary directory that can be browsed, searched, copied, and restored using standard Linux file tools — no special restore utility, database, or proprietary format is required.

---

## Design Goals

This project intentionally prioritizes **reliability, simplicity, and long-term recoverability** over feature count.

The guiding principles are:

- **Single self-contained Bash script** — no helper scripts, libraries, or installation process.
- **Human-readable backups** — every snapshot is a normal directory that can be browsed with any file manager.
- **Simple restores** — recover files using standard Linux tools such as `cp`, `rsync`, or your preferred file manager.
- **No proprietary formats** — backups remain usable even if this project is no longer available.
- **Fail safely** — if the script cannot verify that a snapshot completed correctly, it refuses to mark it as complete.
- **Integrity first** — completed snapshots include SHA-256 manifests and multiple verification stages to help detect corruption.
- **Portable by design** — depends only on standard Linux utilities available on virtually every distribution.
- **No cloud services, databases, daemons, or background processes** — the script performs its work and exits.

The philosophy is simple:

> **If this script disappeared tomorrow, every backup it created should still be completely usable with standard Linux filesystem tools.**

---

## Table of Contents

- [Quick Start](#quick-start)
- [Features](#features)
- [Requirements](#requirements)
- [Filesystem Support](#filesystem-support)
- [How It Works](#how-it-works)
- [Usage](#usage)
- [Restoring Files](#restoring-files)
- [Snapshot Verification](#snapshot-verification)
- [Configuration](#configuration)
- [.backupignore Support](#backupignore-support)
- [Retention](#retention)
- [Security & Privacy](#security--privacy)
- [Known Limitations](#known-limitations)
- [Example Output](#example-output)
- [Design Philosophy](#design-philosophy)
- [License](#license)
- [Disclaimer](#disclaimer)

---

## Quick Start

```
git clone https://github.com/UFpondiboy/linux-snapshot-backup.git
cd linux-snapshot-backup
chmod +x snapshot-backup.sh
mkdir -p ~/.local/bin
cp snapshot-backup.sh ~/.local/bin/
```

Make sure `~/.local/bin` is on your `PATH` (most modern distros already add it automatically for interactive shells). If it isn't, add this to your `~/.bashrc`:

```
export PATH="$HOME/.local/bin:$PATH"
```

Then run it:

```
snapshot-backup.sh
```

The script will detect connected external drives, let you pick one, and create a snapshot. To preview what a backup *would* do without writing anything to disk:

```
snapshot-backup.sh --dry-run
```

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

```
Backups/
└── Backup_2026-06-27_10-00-56/
```

### Subsequent Backups

Later runs use `rsync --link-dest=<previous_snapshot>`:

- Unchanged files are hard-linked to the previous snapshot (zero extra disk space)
- Changed or new files are copied normally

```
Backups/
├── Backup_2026-06-27_10-00-56/
├── Backup_2026-06-28_10-00-22/
└── Backup_2026-06-29_10-00-11/
```

Each snapshot looks and browses like a complete, independent backup — but unchanged files physically occupy disk space only once.

---

## Usage

Run interactively:

```
snapshot-backup.sh
```

Preview a run without writing anything:

```
snapshot-backup.sh --dry-run
```

The script will:

1. Detect available external drives and show a table of path / filesystem / free space
2. Let you select a target drive
3. Check filesystem hard-link support
4. Estimate required space via an actual `rsync --dry-run` (not a naive folder-size guess)
5. Run the backup, then verify it — hard-link check, added/removed/modified report, random sanity check, and incremental manifest build
6. Quarantine any incomplete snapshot from a previous interrupted run, then apply time-based retention to completed snapshots

---

## Restoring Files

No special restore process exists — that's intentional. Browse to the desired snapshot with any file manager (Dolphin, Nautilus, Thunar) or the command line:

```
Backups/
└── Backup_2026-06-27_10-00-56/
```

Copy files back with `cp` or `rsync`:

```
cp Backup_2026-06-27_10-00-56/Documents/report.pdf ~/Documents/
```

Entire folders can be restored the same way.

---

## Snapshot Verification

Every completed snapshot contains `.snapshot_manifest.sha256`. To verify a snapshot at any point in the future — confirming the data hasn't been corrupted or bit-rotted since it was created:

```
cd Backup_2026-06-27_10-00-56
sha256sum --check .snapshot_manifest.sha256
```

A successful verification reports every file as `OK` with no `FAILED` entries:

```
./Documents/report.pdf: OK
./Pictures/photo.jpg: OK
```

For a quiet pass/fail check instead of per-file output:

```
sha256sum --check --quiet .snapshot_manifest.sha256 && echo "All files verified OK"
```

This check reads the snapshot data directly off the backup drive — it verifies the backup itself, independent of your live system. Even if your primary drive fails entirely, a verified snapshot has already proven itself intact on its own.

---

## Configuration

Optional custom source list:

```
~/.config/snapshot-backup/sources.conf
```

One path per line:

```
~/Documents
~/Pictures
~/Videos
```

Blank lines and lines starting with `#` are ignored. A leading `~` expands to `$HOME`. If no config file exists, the script uses its built-in default source list (Desktop, Documents, Downloads, Pictures, Videos).

---

## .backupignore Support

Place a `.backupignore` file inside any source directory to exclude patterns from that folder only:

```
*.tmp
*.bak
cache/
```

Rules apply only to that directory subtree. Implemented using rsync's native per-directory merge filter (`--filter=': .backupignore'`), so path handling is done correctly by rsync itself rather than hand-built exclude logic.

In addition to your own `.backupignore` rules, the script always excludes a small built-in set of common junk regardless of configuration: `.cache`, trash directories, editor backup files (`*~`), and LibreOffice/OpenOffice lock files (`.~lock.*#`) — the latter being transient session-state files that only exist while a document is actually open.

---

## Retention

Snapshots are retained automatically, on a time basis rather than a fixed count — a fixed count is a poor proxy for calendar time under irregular, non-daily usage, since the same count can silently mean anywhere from a few weeks to several months of coverage depending on how often you actually run backups.

- **Default:** keeps every completed snapshot newer than **365 days**
- Snapshots older than that window are removed automatically, regardless of how many that turns out to be
- Every deletion is guarded by a strict filename-pattern check (`^Backup_YYYY-MM-DD_HH-MM-SS$`) before anything is removed — this script will never `rm -rf` a directory whose name doesn't match the exact expected snapshot format

**Incomplete snapshots are quarantined, not deleted.** If a run is interrupted (power loss, unplugged drive, Ctrl+C mid-transfer), the partial snapshot is moved into a `.incomplete_trash` folder on the next run rather than being removed outright — the move is a same-filesystem rename, not a copy, so it costs no meaningful extra disk space. The quarantine folder keeps the last 5 interrupted snapshots and purges older ones automatically, so partial data from a failed run stays recoverable for a while instead of vanishing the moment the script runs again.

---

## Security & Privacy

This software operates entirely on local storage selected by the user. It does not:

- Upload data to cloud services
- Transmit data over any network
- Collect telemetry
- Require internet access or user accounts

Integrity verification is performed using per-snapshot SHA-256 manifests, generated and stored entirely locally. All backup data remains under your control at all times.

---

## Known Limitations

**Renamed files** — Renaming a file causes it to be treated as a deletion (old path) plus a new file (new path), and rehashed during manifest generation rather than recognized as the same file. This does not affect correctness or data safety, only efficiency in that specific case.

**Manifest sorting** — Manifest generation sorts the full file list on every run. At typical personal-backup file counts (tens of thousands of files) this overhead is negligible; it may become noticeable well beyond that scale.

**Timestamp resolution** — Manifest inheritance relies on inode + size + modification time (second resolution). A file rewritten multiple times within the same second, ending at the same size, could theoretically inherit a stale checksum. Extremely unlikely in practice on modern Linux filesystems, and has not been observed in testing.

**Filenames containing a literal backslash or newline** — GNU `sha256sum` encodes these using an escaped record format that the manifest's fast-path parser can't safely inherit from. The script detects this automatically and rehashes only that specific file each run; every other file continues to inherit normally. This is a permanent, ongoing (small) cost for the specific file in question, not a one-time event — renaming the file to remove the special character stops the rehashing.

---

## Example Output

A typical incremental run, showing hard-link verification, added/removed/modified tracking, sanity check, and incremental manifest inheritance in action:

```
======================================================
 Snapshot Backup (Engine v5.1)
======================================================
Detecting external drives...

Available drives:
  #  Path                                          FS         Free
[0]  /run/media/user/BackupDrive                   ext4       822G

Select drive: 0

Repository : /run/media/user/BackupDrive/Backups
Filesystem : ext4
Previous   : Backup_2026-07-02_09-36-03
Mode       : HARD LINK SNAPSHOT (ACTIVE)

Creating Snapshot:
/run/media/user/BackupDrive/Backups/Backup_2026-07-03_09-45-24
------------------------------------------------------
Estimating required space (running rsync dry-run, this can take a moment)...
Estimated new data to write : 3 GB
Available space on target   : 822 GB
[RUNNING] Backup in progress...

======================================================
Snapshot Summary
======================================================
Base snapshot : Backup_2026-07-02_09-36-03

Snapshot created  : Backup_2026-07-03_09-45-24
Files transferred : 11
New data written  : 2,194,552,464 bytes
rsync duration    : 31 sec

No per-file errors detected.

Verifying hard links against previous snapshot...
Hard-linked to previous snapshot : 36692 / 36703 files (99.97%)

Checking for files changed since previous snapshot...
No files removed since previous snapshot.
Added since last snapshot: 2 file(s)
First few:
  + Documents/Report/Q3_summary.pdf
  + Pictures/Trip/beach.jpg

Running sanity check (20 random files, not exhaustive)...
Sanity check passed: 20 sampled files match the source.

Building snapshot manifest (incremental)...
Hashing 12 new/changed/uninheritable file(s)...
Manifest written: 36704 file(s) total (36692 inherited [99.97%], 12 hashed).
To verify later: cd .../Backup_2026-07-03_09-45-24 && sha256sum --check .snapshot_manifest.sha256
Modified since last snapshot: 1 file(s)
First few:
  ~ Documents/Notes/journal.txt

======================================================
Backup Completed Successfully
======================================================

======================================================
Retention
Quarantined incomplete snapshots on drive : 0 (keeping last 5, in .incomplete_trash)
Completed snapshots on drive : 14 (retention: 365 days)
Nothing to remove.
======================================================

Quick integrity signal:
Apparent snapshot size (includes hard-linked data): 44G
Total script duration : 42 sec
(rsync-only duration shown separately in snapshot summary above)
======================================================
```

Out of 36,704 files, 36,692 checksums were inherited from the previous snapshot's manifest — only 12 files needed to be freshly hashed. That's the incremental manifest doing its job: full integrity coverage without re-reading the entire dataset on every run.

## Example Screenshots

Incremental backup:

[![Screenshot](https://github.com/UFpondiboy/linux-snapshot-backup/raw/main/Docs/Screenshots.jpg)](/UFpondiboy/linux-snapshot-backup/blob/main/Docs/Screenshots.jpg)

[![Final Results](https://github.com/UFpondiboy/linux-snapshot-backup/raw/main/Docs/Screenshots2.jpg)](/UFpondiboy/linux-snapshot-backup/blob/main/Docs/Screenshots2.jpg)

> **Note:** these screenshots are from an earlier version of the script and predate the Added/Removed/Modified reports and updated retention output above.

---

## Design Philosophy

**Simple restore beats clever restore.** **One script beats many scripts.**

This project intentionally ships as a single self-contained Bash script. There are no helper scripts, libraries, or runtime dependencies beyond standard Linux utilities. Copy one file to another machine and it is immediately usable without worrying about missing components or keeping multiple files synchronized.

Every snapshot is an ordinary directory of ordinary files — directly browsable and restorable with any file manager or `cp`. This project intentionally avoids:

- Databases
- Proprietary backup formats
- Catalog files
- Background daemons
- Network services
- Dedicated restore utilities

If this script disappears tomorrow, every backup it created remains fully accessible through standard filesystem tools. The primary goal is long-term recoverability, not feature complexity.

---

## License

This project is licensed under the MIT License. See the [LICENSE](https://github.com/UFpondiboy/linux-snapshot-backup/blob/main/LICENSE) file for details.

If you redistribute or modify this project, please retain the original copyright notice and license text as required by the license. Forks, improvements, bug fixes, and derivative works are welcome — credit to the original project is appreciated.

---

## Disclaimer

This software has been tested on personal Linux systems and is provided as-is, without warranty. The author is not responsible for data loss, corruption, or damage resulting from its use.

**Always test restores before relying on any backup solution.** And always follow the golden rule of backups: if your data exists in only one place, it is not backed up — maintain at least one additional copy of anything important.

Use at your own risk.
