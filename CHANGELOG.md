# Changelog

*All notable changes to this project are documented here.*

## v5.1 (Engine)

### Round 25

- **Made sanity-check file sampling NUL-safe** — the last remaining newline-delimited pipeline in the script. *A pathological filename (one containing an embedded newline) could previously split into fragments and get silently discarded by the existing skip-guards, understating the reported `CHECKED` count without any indication anything was wrong. Verified side-by-side: with a pathological filename present, the old code reported 4/5 sampled files checked; the corrected code reports 5/5.*

### Round 24

- **Retention and quarantine-trash deletions now check `rm -rf`'s exit status** and warn instead of silently proceeding on failure. *Not treated as fatal — a lingering old snapshot left on disk is safe — but a failed deletion is now surfaced rather than swallowed.*
- **Corrected dry-run messaging.** *"No completed snapshot will be written" replaces the previous wording, which overstated things on a first-ever run — the empty `Backups/` folder itself is still created unconditionally even in dry-run mode.*
- Considered and declined adding `head`/`tail` to the required-dependency list — they ship in the same coreutils package as already-required commands like `sha256sum`/`sort`/`wc`/`tr`, so an explicit check adds no real safety margin.

### Round 23

- **The completion-marker `touch` call now checks its own exit status.** *A write failure at that exact moment (read-only filesystem, disk error) would previously print a false "success" message even though the marker was never actually written. The next run would still correctly distrust the snapshot either way, but the false success report itself violated the project's "fail loudly" principle. Now caught and reported, verified against a genuine unbypassable write failure.*

### Round 22

- **Excluded macOS `.DS_Store` files** from backups. *Pure Finder metadata with no content value that regenerates itself automatically — found flickering into the Added report on a real run.*

### Round 21

- **Made the Added/Removed file report and the Modified-file detection pipeline both NUL-safe end to end**, closing two real bugs found via a user's actual archival photo filenames (captions with embedded newlines used as filenames). *(1) The Added/Removed report previously used a plain newline-delimited `find | sort | comm` pipeline, which silently split one such filename into phantom extra "files" and inflated the counts — now NUL-safe throughout (`-print0`/`sort -z`/`comm -z`/`head -z`). (2) The Modified report's own `printf "%s\0"` silently emitted no separator at all under `mawk` — confirmed empirically that a literal `\0` inside a format string collides with the C string-terminator convention some `awk` implementations use internally — switched to `printf "%s%c", path, 0`, which reliably works under both `mawk` and `gawk`.*

### Round 20

- **Every "First few:" preview list now says "First N of M" instead.** *Twice now, a user assumed a file's absence from a 5-item preview meant it wasn't backed up, when it was simply outside the shown sample. Spelling out the total removes that ambiguity outright rather than relying on the reader to infer it. Applies to the Added, Removed, and Modified reports, and the per-file error list.*

### Round 19

- **Excluded LibreOffice/OpenOffice lock files (`.~lock.*#`).** *Transient session-state that only exists while a document is open — found flickering in and out of the Added report on a real run.*

### Round 18

- **Added a "Modified since last snapshot" report.** *A file rewritten in place (same path, new content — a log file, an application's autosave, etc.) was previously invisible everywhere in the output except as an unexplained transferred-file count, since the added/removed report only tracks whether a path appears or disappears, not whether its content changed.*

### Round 17

- **Hard-link verification now excludes the script's own bookkeeping files** (transfer log, manifest, completion marker) from its deduplication count, matching what the added/removed report already excluded. *Previously the transfer log — which is unique every single run by design — was always counted as "not hard-linked," permanently understating the true deduplication percentage.*

### Round 16

- **Added a named "Added since last snapshot" report**, alongside the existing "Removed since last snapshot" report. *Previously, new files only showed up as an unexplained raw count in rsync's stats output, with no way to confirm by name that a specific new file was actually backed up.*

### Round 15

- **Retention switched from a fixed snapshot count to a time-based cutoff.** *A fixed count is a poor proxy for calendar time under irregular, non-daily usage — real usage data showed a count-based limit was covering barely six weeks of history despite the number suggesting far more. Retention now keeps every snapshot newer than a configurable number of days, regardless of how many that turns out to be.*

### Round 14

- **Consolidated duplicate y/N confirmation prompts and duplicate section-header banners** into shared helper functions.
- **Marked true constant configuration values as read-only.**
- **Renamed to "Engine v5.1,"** dropping "Verified" from the project title.

### Round 13

- **Readability refactor with no behavior change:** repeated error, warning, and notification code consolidated into shared helper functions; dependency checking and drive detection extracted into their own functions.
- **Fixed a real bug this surfaced** — a file count could be silently corrupted when the true count was legitimately zero, breaking manifest validation on *ordinary* runs, not just edge cases.
- **Expanded the startup dependency check from just `rsync` to everything the script cannot function without** (~20 commands including `sha256sum`, `xargs`, `find`, `comm`, etc.). *A missing tool other than rsync previously slipped through the front door and failed deep inside the manifest stage with a much less obvious error — this now fails fast at launch with one clear list.*

### Round 12

- **A file with a backslash or newline in its filename no longer forces a full re-hash of the entire manifest on every future run** — only that one file is rehashed, everything else continues to inherit normally.
- **Hashing now shows live progress** instead of the terminal appearing to hang during a large rehash.
- **Strengthened previous-manifest validation.** *The old guard only proved that one line in the previous manifest looked like a valid checksum record — a truncated or corrupted manifest with a single intact line could pass. Now requires every non-empty line to match a valid (plain or escaped) format AND the line count to match the previous snapshot's actual file count; anything else is treated as corruption and falls back to a full rehash.*

### Round 11

- **Interrupted or incomplete snapshots are no longer deleted immediately on the next run.** *They're quarantined into a separate folder instead, with their own retention limit, so partial data from an interrupted run stays recoverable for a while instead of being wiped the moment the script runs again.*

### Round 10

- **Free-space estimation now checks its own exit code.** *A failed preflight check aborts the run instead of silently continuing with an "unknown GB" estimate and proceeding into the real backup anyway.*

## v5 (Verified Engine)

### Round 9

- **Refined temporary file lifecycle management and documentation.**
- **Improved inline documentation** throughout the script for maintainability.
- **Added automatic execution guard** (`main "$@"`) allowing the script to be safely sourced without immediately starting a backup.
- **Improved retention safety comments** and internal code documentation.
- Minor code cleanup and consistency improvements.

### Round 8

- **Refactored the script into a `main()` function.**
- **Added trap-based cleanup** for temporary files created with `mktemp`.
- **Improved interrupt safety** — Ctrl+C, SIGTERM, and abnormal exits no longer leave temporary files behind.
- Applied minor ShellCheck-driven code quality improvements.

### Round 7

- **Clarified in the README** that this project creates directory-based snapshots using rsync and hard links, *not* filesystem snapshots (Btrfs, ZFS, LVM, etc.).

### Round 6

- **Fixed deletion report false positives** caused by internal snapshot metadata files.
- **Added total script duration timer** (previously only rsync runtime was shown).
- **Improved manifest baseline messaging** when no previous manifest exists.

### Round 5

- **Fixed basename collision detection** for source directories.
- **Added incremental snapshot manifests** (`.snapshot_manifest.sha256`) — *every snapshot can be independently verified at any point in the future via `sha256sum --check`, without needing to re-hash unchanged files on each run.*
- **Added manifest integrity guard** before checksum inheritance.
- Removed SMART health check section.
- Improved sanity-check terminology and documentation.

### Round 4

- **Fixed hard-link verification** for filenames containing spaces.
- **Fixed dry-run cleanup logic.**
- **Added `sources.conf` support** for configurable source folders.
- **Added sanity-check verification** using random file sampling.
- Improved drive detection fallback locations.

### Round 3

- **Added drive selection table** showing path, filesystem, and free space.
- **Added free-space estimation** using `rsync --dry-run` statistics.
- **Added `LC_ALL=C` enforcement** for reliable rsync output parsing.
- Moved rsync logs into the snapshot directory.

### Round 2

- **Added per-folder `.backupignore` support** using rsync merge filters.
- **Added hard-link verification** against the previous snapshot.
- **Added retention safety guards** around snapshot deletion.
- Improved deleted-file reporting.

### Initial v5 Release

- **Added dry-run mode** (`--dry-run`).
- **Added `rsync -aH` support** to preserve hard links within source trees.
- **Added snapshot retention management.**
- **Added source/destination overlap protection.**
- **Added concurrent-run protection** using file locking.
- **Added per-file rsync error reporting.**
- **Added desktop notifications.**
- **Added a battery-discharge warning.** *Checks for a discharging battery on launch via `upower` and warns (non-fatal) rather than blocking the run.*
- **Added completion markers** for successful snapshots.

## v4

- **Introduced snapshot-based backups** using `rsync --link-dest`.
- **Added automatic retention cleanup.**
- **Added filesystem compatibility checks.**
- **Added available-space verification.**
- **Added snapshot completion markers.**
- **Added snapshot statistics reporting.**

## v3

- **Added lock-file protection** to prevent concurrent runs.
- **Added source/destination overlap protection.**
- **Added snapshot completion markers.**
- Improved snapshot detection logic.

## v2

- Improved snapshot handling reliability.
- Improved validation and error handling.
- Refined backup workflow.

## v1

*Initial public release.*

**Features:**

- Snapshot-style backups using `rsync`.
- Hard-link deduplication.
- Timestamped snapshot directories.
- Manual file restoration.
- External drive support.
