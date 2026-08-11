Changelog
All notable changes to this project are documented here.

v5.1 (Engine)

Round 18

* Added a "Modified since last snapshot" report. A file rewritten in place (same path, new content — a log file, an application's autosave, etc.) was previously invisible everywhere in the output except as an unexplained transferred-file count, since the added/removed report only tracks whether a path appears or disappears, not whether its content changed.

Round 17

* Hard-link verification now excludes the script's own bookkeeping files (transfer log, manifest, completion marker) from its deduplication count, matching what the added/removed report already excluded. Previously the transfer log — which is unique every single run by design — was always counted as "not hard-linked," permanently understating the true deduplication percentage.

Round 16

* Added a named "Added since last snapshot" report, alongside the existing "Removed since last snapshot" report. Previously, new files only showed up as an unexplained raw count in rsync's stats output, with no way to confirm by name that a specific new file was actually backed up.

Round 15

* Retention switched from a fixed snapshot count to a time-based cutoff. A fixed count is a poor proxy for calendar time under irregular, non-daily usage — real usage data showed a count-based limit was covering barely six weeks of history despite the number suggesting far more. Retention now keeps every snapshot newer than a configurable number of days, regardless of how many that turns out to be.

Round 14

* Consolidated duplicate y/N confirmation prompts and duplicate section-header banners into shared helper functions. Marked true constant configuration values as read-only. Renamed to "Engine v5.1," dropping "Verified" from the project title.

Round 13

* Readability refactor with no behavior change: repeated error, warning, and notification code consolidated into shared helper functions. Dependency checking and drive detection extracted into their own functions. Also fixed a real bug this surfaced — a file count could be silently corrupted when the true count was legitimately zero, breaking manifest validation on ordinary runs (not just edge cases).

Round 12

* A file with a backslash or newline in its filename no longer forces a full re-hash of the entire manifest on every future run — only that one file is rehashed, everything else continues to inherit normally. Hashing now shows live progress instead of the terminal appearing to hang during a large rehash.

Round 11

* Interrupted or incomplete snapshots are no longer deleted immediately on the next run. They're quarantined into a separate folder instead, with their own retention limit, so partial data from an interrupted run stays recoverable for a while instead of being wiped the moment the script runs again.

Round 10

* Free-space estimation now checks its own exit code. A failed preflight check aborts the run instead of silently continuing with an "unknown GB" estimate and proceeding into the real backup anyway.

v5 (Verified Engine)

Round 9

* Refined temporary file lifecycle management and documentation.
* Improved inline documentation throughout the script for maintainability.
* Added automatic execution guard (`main "$@"`) allowing the script to be safely sourced without immediately starting a backup.
* Improved retention safety comments and internal code documentation.
* Minor code cleanup and consistency improvements.

Round 8

* Refactored the script into a main() function.
* Added trap-based cleanup for temporary files created with mktemp.
* Improved interrupt safety (Ctrl+C, SIGTERM, and abnormal exits no longer leave temporary files behind).
* Applied minor ShellCheck-driven code quality improvements.

Round 7

* Clarified in the README that this project creates directory-based snapshots using rsync and hard links, not filesystem snapshots (Btrfs, ZFS, LVM, etc.).

Round 6

* Fixed deletion report false positives caused by internal snapshot metadata files.
* Added total script duration timer (previously only rsync runtime was shown).
* Improved manifest baseline messaging when no previous manifest exists.

Round 5

* Fixed basename collision detection for source directories.
* Added incremental snapshot manifests (`.snapshot_manifest.sha256`) — every snapshot can be independently verified at any point in the future via `sha256sum --check`, without needing to re-hash unchanged files on each run.
* Added manifest integrity guard before checksum inheritance.
* Removed SMART health check section.
* Improved sanity-check terminology and documentation.

Round 4

* Fixed hard-link verification for filenames containing spaces.
* Fixed dry-run cleanup logic.
* Added `sources.conf` support for configurable source folders.
* Added sanity-check verification using random file sampling.
* Improved drive detection fallback locations.

Round 3

* Added drive selection table showing path, filesystem, and free space.
* Added free-space estimation using `rsync --dry-run` statistics.
* Added `LC_ALL=C` enforcement for reliable rsync output parsing.
* Moved rsync logs into the snapshot directory.

Round 2

* Added per-folder `.backupignore` support using rsync merge filters.
* Added hard-link verification against the previous snapshot.
* Added retention safety guards around snapshot deletion.
* Improved deleted-file reporting.

Initial v5 Release

* Added dry-run mode (`--dry-run`).
* Added `rsync -aH` support to preserve hard links within source trees.
* Added snapshot retention management.
* Added source/destination overlap protection.
* Added concurrent-run protection using file locking.
* Added per-file rsync error reporting.
* Added desktop notifications.
* Added completion markers for successful snapshots.

v4

* Introduced snapshot-based backups using `rsync --link-dest`.
* Added automatic retention cleanup.
* Added filesystem compatibility checks.
* Added available-space verification.
* Added snapshot completion markers.
* Added snapshot statistics reporting.

v3

* Added lock-file protection to prevent concurrent runs.
* Added source/destination overlap protection.
* Added snapshot completion markers.
* Improved snapshot detection logic.

v2

* Improved snapshot handling reliability.
* Improved validation and error handling.
* Refined backup workflow.

v1
Initial public release.
Features:

* Snapshot-style backups using `rsync`.
* Hard-link deduplication.
* Timestamped snapshot directories.
* Manual file restoration.
* External drive support.
