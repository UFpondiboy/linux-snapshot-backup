# Changelog

All notable changes to this project are documented here.

## v5 (Verified Engine)

### Round 8

- Refactored the script into a `main()` function.
- Added trap-based cleanup for temporary files created with `mktemp`.
- Improved interrupt safety (Ctrl+C and abnormal exits no longer leave temporary files behind).
- Minor ShellCheck-related improvements.

### Round 7

#### Documentation
- Clarified in the README that this project creates directory-based snapshots using `rsync` and hard links, not filesystem snapshots (Btrfs, ZFS, LVM, etc.).
- 
### Round 6

- Fixed deletion report false positives caused by internal snapshot metadata files.
- Added total script duration timer (previously only rsync runtime was shown).
- Improved manifest baseline messaging when no previous manifest exists.

### Round 5

- Fixed basename collision detection for source directories.
- Added incremental snapshot manifests (`.snapshot_manifest.sha256`) — every snapshot can be independently verified at any point in the future via `sha256sum --check`, without needing to re-hash unchanged files on each run.
- Added manifest integrity guard before checksum inheritance.
- Removed SMART health check section.
- Improved sanity-check terminology and documentation.

### Round 4

- Fixed hard-link verification for filenames containing spaces.
- Fixed dry-run cleanup logic.
- Added `sources.conf` support for configurable source folders.
- Added sanity-check verification using random file sampling.
- Improved drive detection fallback locations.

### Round 3

- Added drive selection table showing path, filesystem, and free space.
- Added free-space estimation using `rsync --dry-run` statistics.
- Added `LC_ALL=C` enforcement for reliable rsync output parsing.
- Moved rsync logs into the snapshot directory.

### Round 2

- Added per-folder `.backupignore` support using rsync merge filters.
- Added hard-link verification against the previous snapshot.
- Added retention safety guards around snapshot deletion.
- Improved deleted-file reporting.

### Initial v5 Release

- Added dry-run mode (`--dry-run`).
- Added `rsync -aH` support to preserve hard links within source trees.
- Added snapshot retention management.
- Added source/destination overlap protection.
- Added concurrent-run protection using file locking.
- Added per-file rsync error reporting.
- Added desktop notifications.
- Added completion markers for successful snapshots.

## v4

- Introduced snapshot-based backups using `rsync --link-dest`.
- Added automatic retention cleanup.
- Added filesystem compatibility checks.
- Added available-space verification.
- Added snapshot completion markers.
- Added snapshot statistics reporting.

## v3

- Added lock-file protection to prevent concurrent runs.
- Added source/destination overlap protection.
- Added snapshot completion markers.
- Improved snapshot detection logic.

## v2

- Improved snapshot handling reliability.
- Improved validation and error handling.
- Refined backup workflow.

## v1

Initial public release.

**Features:**
- Snapshot-style backups using `rsync`.
- Hard-link deduplication.
- Timestamped snapshot directories.
- Manual file restoration.
- External drive support.
