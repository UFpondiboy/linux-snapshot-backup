# Changelog

*All notable changes to this project are documented here.*

## v5.1 (Engine)

### Round 25

* **Made sanity-check sampling NUL-safe.** *This was the last remaining filename-bearing pipeline in the script that could be affected by a literal newline in a filename. A pathological filename could previously be split into fragments, with some fragments discarded by the existing skip guards, causing the reported number of checked files to be lower than the requested sample without making the discrepancy obvious. The sampling path now uses NUL-delimited file handling throughout, correctly treating unusual filenames as single files.*

### Round 24

* **Hardened retention and quarantine cleanup.** *Failures from `rm -rf` when deleting expired completed snapshots or old quarantined incomplete snapshots are now detected and reported as warnings instead of being silently ignored. A failed deletion is non-fatal because leaving an old snapshot in place is safe; the important point is that the user is told that the cleanup did not actually happen.*

* **Corrected dry-run wording.** *The dry-run message now accurately states that no completed snapshot will be written. On a first-ever run, the `Backups/` directory itself may still be created during setup, so the previous wording that "nothing will be written" was technically overstated.*

* **Kept `head` and `tail` out of the explicit dependency list.** *They are coreutils utilities, as are already-required commands such as `sha256sum`, `sort`, `wc`, and `tr`. Checking every individual coreutils command adds little practical protection when the package itself is already assumed to be present.*

### Round 23

* **Hardened completion-marker creation.** *The `.snapshot_complete` marker is the trust boundary for a completed snapshot: it determines whether the snapshot can become a future `--link-dest` base and whether retention treats it as complete. The marker write is now checked for failure, preventing the script from reporting "Backup Completed Successfully" if the destination becomes read-only or otherwise refuses the write at that point.*

### Round 22

* **Excluded macOS `.DS_Store` Finder metadata files.** *These files contain Finder-specific folder view and icon-position metadata, have no useful content value in a Linux backup, and regenerate automatically when macOS Finder touches a directory. They were also observed appearing in the Added report during real-world use, creating unnecessary backup and reporting noise.*

### Round 21

* **Fixed two real filename-handling bugs discovered using actual archival photo filenames containing embedded newlines.**

  * **Made Added/Removed reporting fully NUL-safe.** *The previous newline-delimited `find | sort | comm` pipeline could split a single filename containing a literal newline into multiple phantom entries, inflating counts and corrupting displayed names. The comparison pipeline now uses `find -print0`, `sort -z`, `comm -z`, and `head -z`.*
  * **Fixed NUL output in Modified-file detection under `mawk`.** *The previous `printf "%s\0"` inside `awk` did not emit a literal NUL byte under `mawk`, causing records to be concatenated when the downstream pipeline expected NUL-separated data. The code now uses `printf "%s%c", path, 0`, which produces a real NUL byte under both `mawk` and `gawk`.*

### Round 20

* **Changed "First few:" reporting to explicitly show the range being displayed.** *Reports for Added, Removed, Modified, and per-file errors now say "First N of M" when only a sample is shown. This removes the ambiguity where a file not appearing in a five-item preview could otherwise be mistaken for a file that was not backed up at all.*

### Round 19

* **Excluded LibreOffice/OpenOffice lock files (`.~lock.*#`).** *These are transient session-state files that exist only while a document is open and disappear when it is closed. They were observed appearing and disappearing in the Added report during normal use, creating meaningless backup and reporting noise.*

### Round 18

* **Added a "Modified since last snapshot" report.** *A file rewritten in place — such as a log file, application autosave, or other same-path content change — was previously visible only indirectly through rsync's transferred-file count because the Added/Removed report tracks path presence rather than content changes. The new report reuses the file-attribute correlation already performed by the incremental manifest stage and therefore requires no additional filesystem scan. `rsync.log` is intentionally excluded because it is newly generated every run by design.*

### Round 17

* **Hard-link verification now excludes the script's bookkeeping files** (`rsync.log`, `.snapshot_manifest.sha256`, and `.snapshot_complete`) from its deduplication calculation. *`rsync.log` is newly generated on every run and can never be inherited through `--link-dest`; counting it as an unlinked file permanently understated the actual hard-link percentage and made the result harder to reconcile with rsync's transfer statistics.*

### Round 16

* **Added a named "Added since last snapshot" report**, alongside the existing Removed report. *Previously, newly created files appeared only as a raw count in rsync's statistics, making it difficult to visually confirm that a particular new file had actually entered the snapshot.*

### Round 15

* **Retention switched from a fixed snapshot count to a time-based cutoff.** *A fixed count is a poor proxy for calendar coverage when backups are irregular or bursty. Retention now keeps every completed snapshot newer than a configurable number of days (`RETENTION_DAYS`), regardless of how many snapshots that represents.*

### Round 14

* **Consolidated duplicate y/N confirmation prompts and section-header banners** into shared helper functions.
* **Marked true constant configuration values as read-only.**
* **Renamed the project to "Engine v5.1,"** removing "Verified" from the title.

### Round 13

* **Readability refactor with no intended behavior change:** repeated error, warning, and notification handling was consolidated into shared helper functions; dependency checking and drive detection were extracted from `main()`.
* **Fixed a real file-count bug discovered during the refactor.** *A `grep -c ... || echo 0` construction could produce duplicate output when the legitimate count was zero, corrupting manifest validation on ordinary runs.*

### Round 12

* **A filename containing a literal backslash or newline no longer forces a full manifest re-hash on every future run.** *Only the affected file is rehashed while other files continue to inherit their previously verified checksums normally.*
* **Added live hashing progress** so large manifest operations no longer appear to have stalled with no terminal output.

### Round 11

* **Interrupted or incomplete snapshots are now quarantined instead of being immediately deleted.** *A partial snapshot left by Ctrl+C, an unplugged drive, power loss, or another interruption is moved into `.incomplete_trash` so its partial data remains available for inspection or recovery for a limited period. Quarantined snapshots have their own retention limit.*

### Round 10

* **Free-space estimation now checks the rsync dry-run exit status.** *A failed preflight estimation no longer silently continues with an "unknown" estimate. The backup aborts before the real transfer if the dry-run itself reports an error.*

### Round 9

* **Added an early rsync dependency check.** *A fresh or minimal installation without rsync now fails fast before reaching the actual backup stage.*

### Round 8

* **Added centralized temporary-file cleanup using an EXIT trap.** *Temporary files created with `mktemp` are tracked and cleaned up on normal completion, explicit exits, and catchable interruptions such as Ctrl+C or SIGTERM.*
* Improved interrupt safety around temporary-file handling.

### Round 7

* **Applied ShellCheck-driven code-quality fixes.**
* **Standardized interactive input handling** using `read -rp`.
* **Added an explicit `${SNAPSHOT_ROOT:?}` retention-delete guard** to prevent an empty/unset snapshot-root variable from ever turning a retention deletion into a deletion from filesystem root.

### Round 6

* **Fixed deletion-report false positives** caused by the `.snapshot_complete` completion marker and other internal snapshot metadata.
* **Added total script duration reporting**, in addition to the existing rsync runtime.
* **Improved baseline-manifest messaging** when no previous usable manifest exists.

### Round 5

* **Fixed basename collision detection** for configured source directories. *Two source folders with the same basename would otherwise be merged by rsync into the same top-level snapshot directory, making restoration ambiguous.*
* **Added incremental snapshot manifests** (`.snapshot_manifest.sha256`). *Each completed snapshot can be independently integrity-checked in the future with standard `sha256sum --check`, while unchanged files normally inherit their previously established checksums instead of being rehashed on every run.*
* **Added a manifest integrity guard** before checksum inheritance.
* Removed the SMART health-check section.
* Improved sanity-check terminology and documentation.

### Round 4

* **Fixed hard-link verification for filenames containing spaces.**
* **Fixed dry-run temporary-file cleanup logic.**
* **Added configurable source-folder support** through `sources.conf`.
* **Added sanity-check verification** using random file sampling.
* Improved drive-detection fallback locations.

### Round 3

* **Added a drive-selection table** showing path, filesystem, and available space.
* **Added free-space estimation** using rsync's dry-run statistics.
* **Added `LC_ALL=C` enforcement** for reliable parsing of rsync output.
* Moved rsync logs into the individual snapshot directory.

### Round 2

* **Added per-folder `.backupignore` support** using rsync's native merge-filter mechanism.
* **Added hard-link verification** against the specific previous completed snapshot.
* **Added retention safety guards** around snapshot deletion.
* Improved deleted-file reporting.

### Round 1 (v5)

* **Added dry-run mode** (`--dry-run`).
* **Added `rsync -aH` support** to preserve hard links within source trees.
* **Added snapshot retention management.**
* **Added free-space estimation** using an rsync dry-run.
* **Added deleted-file reporting.**

## v5

* **Carried over source/destination overlap protection** from earlier versions.
* **Carried over concurrent-run protection** using a lock file.
* **Carried over per-file rsync error reporting.**
* **Carried over desktop notifications.**
* **Carried over completion markers** for successful snapshots.
* **Carried over array-based `--link-dest` snapshot handling.**
* **Carried over drive validation and filesystem compatibility checks.**

## v4

* **Introduced snapshot-based backups** using `rsync --link-dest`.
* **Added automatic retention cleanup.**
* **Added filesystem compatibility checks.**
* **Added available-space verification.**
* **Added snapshot completion markers.**
* **Added snapshot statistics reporting.**

## v3

* **Added lock-file protection** to prevent concurrent runs.
* **Added source/destination overlap protection.**
* **Added snapshot completion markers.**
* Improved snapshot detection logic.

## v2

* Improved snapshot handling reliability.
* Improved validation and error handling.
* Refined backup workflow.

## v1

*Initial public release.*

**Features:**

* Snapshot-style backups using `rsync`.
* Hard-link deduplication.
* Timestamped snapshot directories.
* Manual file restoration.
* External drive support.
# Changelog

*All notable changes to this project are documented here.*

## v5.1 (Engine)

### Round 25

* **Added snapshot-directory collision protection.** *The snapshot directory is now required to not already exist before a new backup begins. Previously, the second-resolution timestamp could theoretically collide with an existing snapshot, particularly if backups were started within the same second or an incomplete snapshot already occupied the generated name. The script now aborts safely rather than risking reuse of an existing snapshot directory.*

### Round 24

* **Hardened completion-marker handling.** *Writing the `.snapshot_complete` marker is now checked for success. A snapshot is not considered successfully completed if the completion marker cannot be created.*

* **Hardened quarantine and retention deletion handling.** *Failures while moving incomplete snapshots into quarantine or removing expired snapshots are now detected and reported instead of being silently ignored.*

### Round 23

* **Expanded dependency validation.** *Startup dependency checking now covers the external commands required by the backup, manifest, reporting, retention, and integrity workflows rather than checking only `rsync`. This allows missing runtime dependencies to be detected before a backup begins.*

* **Clarified the metadata-based change-detection limitation.** *The documentation now makes clear that both rsync's normal transfer decision and incremental manifest inheritance rely on filesystem metadata rather than hashing every unchanged file. A file whose content changes while retaining the same size and an unchanged detectable modification time can therefore theoretically escape both rsync transfer detection and manifest rehashing. This is an inherent trade-off of the fast incremental design; `rsync --checksum` is intentionally not enabled because it would require substantially more I/O on every run.*

### Round 22

* **Hardened incomplete-snapshot handling and retention selection.** *Completed snapshots continue to be identified exclusively through their successful completion marker, while incomplete snapshots are isolated in `.incomplete_trash`. Retention operations also continue to use strict snapshot-name validation so unexpected directories are not treated as snapshots.*

### Round 21

* **Fixed NUL-separated output in the modified-file detection pipeline.** *The previous implementation used `printf "%s\0"` inside `awk`, which does not emit a literal NUL byte under `mawk`. This could cause modified files to be missed when the comparison pipeline expected NUL-separated records. The output path now emits a real NUL byte correctly, making modified-file detection reliable with filenames containing embedded newlines and other unusual characters.*

### Round 20

* **Made Added/Removed file reporting fully NUL-safe.** *The previous newline-based `find | sort | comm` pipeline could incorrectly split filenames containing literal newline characters into multiple phantom entries. The reporting pipeline now uses NUL-safe file handling (`find -print0`, `sort -z`, `comm -z`), so filenames containing newlines, spaces, backslashes, and other unusual characters are treated as single filenames throughout the comparison.*

### Round 19

* **Expanded real-world filename edge-case validation.** *Added/Removed/Modified reporting was tested against filenames containing embedded newlines and other characters that can break conventional line-oriented Unix pipelines. The affected reporting and manifest workflows were verified end-to-end, including modification detection and subsequent SHA-256 manifest verification.*

### Round 18

* **Added a "Modified since last snapshot" report.** *A file rewritten in place (same path, new content — a log file, an application's autosave, etc.) was previously invisible everywhere in the output except as an unexplained transferred-file count, since the added/removed report only tracks whether a path appears or disappears, not whether its content changed.*

### Round 17

* **Hard-link verification now excludes the script's own bookkeeping files** (transfer log, manifest, completion marker) from its deduplication count, matching what the added/removed report already excluded. *Previously the transfer log — which is unique every single run by design — was always counted as "not hard-linked," permanently understating the true deduplication percentage.*

### Round 16

* **Added a named "Added since last snapshot" report**, alongside the existing "Removed since last snapshot" report. *Previously, new files only showed up as an unexplained raw count in rsync's stats output, with no way to confirm by name that a specific new file was actually backed up.*

### Round 15

* **Retention switched from a fixed snapshot count to a time-based cutoff.** *A fixed count is a poor proxy for calendar time under irregular, non-daily usage — real usage data showed a count-based limit was covering barely six weeks of history despite the number suggesting far more. Retention now keeps every snapshot newer than a configurable number of days, regardless of how many that turns out to be.*

### Round 14

* **Consolidated duplicate y/N confirmation prompts and duplicate section-header banners** into shared helper functions.
* **Marked true constant configuration values as read-only.**
* **Renamed to "Engine v5.1,"** dropping "Verified" from the project title.

### Round 13

* **Readability refactor with no behavior change:** repeated error, warning, and notification code consolidated into shared helper functions; dependency checking and drive detection extracted into their own functions.
* **Fixed a real bug this surfaced** — a file count could be silently corrupted when the true count was legitimately zero, breaking manifest validation on *ordinary* runs, not just edge cases.

### Round 12

* **A file with a backslash or newline in its filename no longer forces a full re-hash of the entire manifest on every future run** — only that one file is rehashed, everything else continues to inherit normally.
* **Hashing now shows live progress** instead of the terminal appearing to hang during a large rehash.

### Round 11

* **Interrupted or incomplete snapshots are no longer deleted immediately on the next run.** *They're quarantined into a separate folder instead, with their own retention limit, so partial data from an interrupted run stays recoverable for a while instead of being wiped the moment the script runs again.*

### Round 10

* **Free-space estimation now checks its own exit code.** *A failed preflight check aborts the run instead of silently continuing with an "unknown GB" estimate and proceeding into the real backup anyway.*

## v5 (Verified Engine)

### Round 9

* **Refined temporary file lifecycle management and documentation.**
* **Improved inline documentation** throughout the script for maintainability.
* **Added automatic execution guard** (`main "$@"`) allowing the script to be safely sourced without immediately starting a backup.
* **Improved retention safety comments** and internal code documentation.
* Minor code cleanup and consistency improvements.

### Round 8

* **Refactored the script into a `main()` function.**
* **Added trap-based cleanup** for temporary files created with `mktemp`.
* **Improved interrupt safety** — Ctrl+C, SIGTERM, and abnormal exits no longer leave temporary files behind.
* Applied minor ShellCheck-driven code quality improvements.

### Round 7

* **Clarified in the README** that this project creates directory-based snapshots using rsync and hard links, *not* filesystem snapshots (Btrfs, ZFS, LVM, etc.).

### Round 6

* **Fixed deletion report false positives** caused by internal snapshot metadata files.
* **Added total script duration timer** (previously only rsync runtime was shown).
* **Improved manifest baseline messaging** when no previous manifest exists.

### Round 5

* **Fixed basename collision detection** for source directories.
* **Added incremental snapshot manifests** (`.snapshot_manifest.sha256`) — *every snapshot can be independently verified at any point in the future via `sha256sum --check`, without needing to re-hash unchanged files on each run.*
* **Added manifest integrity guard** before checksum inheritance.
* Removed SMART health check section.
* Improved sanity-check terminology and documentation.

### Round 4

* **Fixed hard-link verification** for filenames containing spaces.
* **Fixed dry-run cleanup logic.**
* **Added `sources.conf` support** for configurable source folders.
* **Added sanity-check verification** using random file sampling.
* Improved drive detection fallback locations.

### Round 3

* **Added drive selection table** showing path, filesystem, and free space.
* **Added free-space estimation** using `rsync --dry-run` statistics.
* **Added `LC_ALL=C` enforcement** for reliable rsync output parsing.
* Moved rsync logs into the snapshot directory.

### Round 2

* **Added per-folder `.backupignore` support** using rsync merge filters.
* **Added hard-link verification** against the previous snapshot.
* **Added retention safety guards** around snapshot deletion.
* Improved deleted-file reporting.

### Initial v5 Release

* **Added dry-run mode** (`--dry-run`).
* **Added `rsync -aH` support** to preserve hard links within source trees.
* **Added snapshot retention management.**
* **Added source/destination overlap protection.**
* **Added concurrent-run protection** using file locking.
* **Added per-file rsync error reporting.**
* **Added desktop notifications.**
* **Added completion markers** for successful snapshots.

## v4

* **Introduced snapshot-based backups** using `rsync --link-dest`.
* **Added automatic retention cleanup.**
* **Added filesystem compatibility checks.**
* **Added available-space verification.**
* **Added snapshot completion markers.**
* **Added snapshot statistics reporting.**

## v3

* **Added lock-file protection** to prevent concurrent runs.
* **Added source/destination overlap protection.**
* **Added snapshot completion markers.**
* Improved snapshot detection logic.

## v2

* Improved snapshot handling reliability.
* Improved validation and error handling.
* Refined backup workflow.

## v1

*Initial public release.*

**Features:**

* Snapshot-style backups using `rsync`.
* Hard-link deduplication.
* Timestamped snapshot directories.
* Manual file restoration.
* External drive support.
