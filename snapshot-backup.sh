#!/bin/bash

# ======================================================
# Snapshot Backup (Engine v5.1)
# ======================================================
# Changelog (most recent first), 1-2 lines per round:
#
# Round 15: Retention switched from count-based (RETENTION_COUNT=50) to
#   time-based (RETENTION_DAYS=365). A fixed count is a poor proxy for
#   calendar time under irregular usage -- real logs showed ~1/day on
#   average but bursty, so 50 was only covering ~47 days, not "a year."
# Round 14: More readability consolidation: confirm_or_abort() replaces
#   two identical y/N prompts; section()/section_open()/section_close()
#   replace 6 hand-rolled banner blocks; true constants marked readonly.
#   Renamed to Engine v5.1, dropped "Verified" from the title.
# Round 13: Readability pass (no behavior change): fatal()/warn()/
#   notify_and_exit() replace 20+ hand-rolled error/warning blocks;
#   check_dependencies() and detect_drives() pulled out of main(). Also
#   fixed a real bug this surfaced: `grep -c ... || echo 0` doubled its
#   output whenever a count was legitimately zero, corrupting manifest
#   validation on ordinary (non-pathological-filename) runs.
# Round 12: A file with a backslash/newline in its name no longer forces
#   a full rehash on EVERY future run -- only that one file is rehashed,
#   everything else still inherits. Hashing now shows live progress.
# Round 11: Incomplete snapshots are now quarantined to .incomplete_trash
#   instead of deleted outright, with their own count-based retention.
# Round 10: Free-space dry-run exit code is now checked; a failed
#   preflight aborts instead of silently continuing as "unknown GB".
# Round 9:  Added an early rsync dependency check so a fresh/minimal
#   install fails fast instead of deep inside the run.
# Round 8:  All mktemp temp files are tracked and cleaned up via an EXIT
#   trap, not just an inline `rm -f` right after use.
# Round 7:  Shellcheck fixes: `read -rp` everywhere; "${SNAPSHOT_ROOT:?}"
#   guards retention deletes against an ever-empty/unset variable.
# Round 6:  Fixed deletion report false-flagging .snapshot_complete;
#   added total script duration; clearer baseline-manifest messaging.
# Round 5:  Fixed basename collisions in SOURCE_BASENAME_MAP; removed the
#   SMART check; added the incremental manifest + integrity guard.
# Round 4:  Fixed hard-link verification with spaces in filenames;
#   sources now configurable via sources.conf; added the sanity check.
# Round 3:  Log lives at $SNAPSHOT/rsync.log; drive table shows free
#   space and warns at 80% capacity; forces LC_ALL=C for stable parsing.
# Round 2:  .backupignore via rsync's own filter; hard-link verification
#   compares against the specific previous snapshot; safer rm -rf guards.
# Round 1 (v5): Dry-run mode, per-folder .backupignore, rsync -aH,
#   free-space estimate via dry-run, deleted-files report.
#
# Carried over from v4: source/target overlap guard, flock lock file,
#   per-file rsync error surfacing, desktop notifications.
# Carried over from v3: array-based --link-dest, drive validation,
#   available-space check, hard-link FS check, completion marker,
#   count-based retention with orphan cleanup.
#
# Restore: intentionally manual. Browse to
#   <drive>/Backups/Backup_<timestamp>/ and copy files back out.
#   Each snapshot folder is a complete, independent-looking copy.
# To verify integrity of any snapshot at any future point:
#   cd <drive>/Backups/Backup_<timestamp>
#   sha256sum --check .snapshot_manifest.sha256
#
# Incomplete/interrupted runs land in <drive>/Backups/.incomplete_trash/
# instead of being deleted -- browse there manually if a run was ever
# interrupted mid-transfer. Only the last TRASH_RETENTION_COUNT of these
# are kept; older ones are purged automatically on later runs.
#
# Known limitations (documented, not bugs):
#   - Renamed files (same inode, different path) get rehashed rather
#     than inherited. The manifest is still correct, just slightly
#     less efficient in that case.
#   - Manifest sort is O(n log n) on every run. At 36k files this
#     is under a second. At 500k files it becomes noticeable.
#   - mtime resolution is per-second. A file written twice within
#     the same second to the same size could theoretically inherit
#     a stale checksum. Practically negligible on ext4.

set -uo pipefail

# Forces consistent output wording/formatting from rsync, grep, sort,
# etc. regardless of the system's locale. This script greps for
# specific English phrases in rsync's --stats output, which would
# silently break under a non-English locale without this.
export LC_ALL=C

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

notify() {
    command -v notify-send &>/dev/null && notify-send -u "${3:-normal}" "$1" "$2" || true
}

warn() {
    # Standardizes the "yellow, non-fatal" message format used throughout
    # the script (20+ call sites did this by hand before). Purely a
    # formatting consolidation -- doesn't change what gets printed.
    echo -e "${YELLOW}$1${NC}"
}

notify_and_exit() {
    # Common tail of every fatal path: notify the desktop, then exit 1.
    # Kept separate from fatal() below because a few call sites need to
    # print multi-line/instructional output before exiting, not just a
    # single red message -- those call this directly instead of fatal().
    local body="$1"
    local title="${2:-Backup failed}"
    notify "$title" "$body" critical
    exit 1
}

fatal() {
    # The common case: one red message, notified to the desktop, exit.
    # Covers most of this script's error paths in one place instead of
    # each site hand-rolling the same three lines.
    local msg="$1"
    local title="${2:-Backup failed}"
    echo -e "${RED}${msg}${NC}"
    notify_and_exit "$msg" "$title"
}

confirm_or_abort() {
    # Standardizes the "y/N, abort if not confirmed" prompt used at both
    # the filesystem-compatibility warning and the low-space warning --
    # those two were byte-for-byte identical except the variable name.
    local reply
    read -rp "Continue anyway? (y/N): " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
}

section() {
    # Standardizes the repeated blank-line + rule + title + rule banner
    # used for short, self-contained announcements throughout the
    # script's output. Uses `echo -e` so already-colored text (success
    # in green, a warning in yellow) works the same as plain text.
    echo ""
    echo "======================================================"
    echo -e "$1"
    echo "======================================================"
}

section_open() {
    # Same banner, but for sections with a variable-length body between
    # the header and a separate closing rule printed later via
    # section_close (e.g. Retention, which lists removed snapshots
    # in between).
    echo ""
    echo "======================================================"
    echo -e "$1"
}

section_close() {
    echo "======================================================"
}

# Tracks every mktemp file created during the run so they can be cleaned
# up on normal exit and on any catchable termination signal (Ctrl+C /
# SIGTERM) between creating a temp file and its normal `rm -f`. This is
# NOT a guarantee against SIGKILL, sudden power loss, or a kernel crash --
# an EXIT trap cannot run in those cases, so a temp file could still be
# orphaned in /tmp if the process is killed that hard. It closes the
# ordinary interruption gap, not every possible one.
TEMP_FILES=()

cleanup_temp_files() {
    if [ ${#TEMP_FILES[@]} -gt 0 ]; then
        rm -f "${TEMP_FILES[@]}" 2>/dev/null
    fi
}

check_dependencies() {
    # Round 9/10 only checked for rsync, the dependency most likely to be
    # missing on a fresh minimal OS install. But the backup engine and the
    # integrity (manifest/verification) engine also depend unconditionally
    # on a set of other commands -- sha256sum and xargs in particular are
    # used by the manifest builder on every run, not just optionally.
    # Checking only rsync let a missing sha256sum/xargs/etc. slip through
    # the front door and fail deep inside the manifest stage instead, with
    # a much less obvious error. This checks everything the script cannot
    # function without, up front, and fails fast with one clear list.
    #
    # Deliberately does NOT attempt to auto-install anything: that would
    # mean the script escalating privileges (sudo) on its own and
    # detecting/handling different package managers (apt/pacman/dnf/etc.),
    # which is a bigger trust and complexity ask than a backup script
    # should make silently.
    local required_backup_cmds=(rsync flock realpath df mkdir date basename dirname)
    local required_integrity_cmds=(find awk grep sed sort comm tee sync du mktemp xargs sha256sum wc tr)
    # Optional UX-only commands (notify-send, upower, shuf) are probed
    # individually at their point of use and degrade gracefully -- they
    # are not part of this hard-fail list.
    local missing_cmds=()
    local c
    for c in "${required_backup_cmds[@]}" "${required_integrity_cmds[@]}"; do
        command -v "$c" &>/dev/null || missing_cmds+=("$c")
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        echo "This script cannot run correctly without them."
        echo "Install the missing tool(s) with your distro's package manager, e.g.:"
        echo "  sudo eopkg install rsync                                # Solus"
        echo "  sudo apt install rsync coreutils util-linux findutils   # Debian/Ubuntu"
        echo "  sudo pacman -S rsync coreutils util-linux findutils     # Arch/Manjaro"
        echo "  sudo dnf install rsync coreutils util-linux findutils   # Fedora"
        echo "coreutils/findutils/util-linux are base-system packages on virtually"
        echo "every distro (including Solus) and are only ever realistically"
        echo "missing if rsync itself is -- if something else in the list above is"
        echo "genuinely missing, search your distro's package index for it by name."
        fatal "Missing required command(s): ${missing_cmds[*]}"
    fi
}

detect_drives() {
    # Scans candidate mount roots for eligible backup drives, prints the
    # selection table, and prompts for a choice. Reads BASE_BACKUP,
    # RUN_USER, and MIN_DRIVE_SIZE_GB (set by main()'s CONFIG section
    # before this is called) and sets BACKUP_ROOT as its result, the same
    # way the rest of this script shares state -- through plain globals,
    # not return values, since that's what actually fits bash rather than
    # forcing a return-value convention bash doesn't really have.
    echo ""
    echo "Detecting external drives..."

    VALID_DRIVES=()
    VALID_DRIVE_FS=()
    VALID_DRIVE_AVAIL=()

    local base_candidate d real_d existing already_found size i choice

    for base_candidate in "$BASE_BACKUP" "/media/$RUN_USER" "/media"; do
        [ -d "$base_candidate" ] || continue
        for d in "$base_candidate"/*; do
            [ -d "$d" ] || continue

            real_d=$(realpath "$d" 2>/dev/null)
            already_found=0
            for existing in "${VALID_DRIVES[@]}"; do
                [ "$(realpath "$existing" 2>/dev/null)" = "$real_d" ] && already_found=1 && break
            done
            [ "$already_found" -eq 1 ] && continue

            size=$(df -BG "$d" 2>/dev/null | tail -n1 | awk '{print $2}' | tr -d 'G')
            if [ -n "$size" ] && [ "$size" -ge "$MIN_DRIVE_SIZE_GB" ]; then
                VALID_DRIVES+=("$d")
                VALID_DRIVE_FS+=("$(df -T "$d" 2>/dev/null | tail -n1 | awk '{print $2}')")
                VALID_DRIVE_AVAIL+=("$(df -BG "$d" 2>/dev/null | tail -n1 | awk '{print $4}')")
            fi
        done
    done

    if [ ${#VALID_DRIVES[@]} -eq 0 ]; then
        fatal "No valid backup drive found"
    fi

    echo ""
    echo "Available drives:"
    printf "%-4s %-45s %-10s %-10s\n" "  #" "Path" "FS" "Free"
    for i in "${!VALID_DRIVES[@]}"; do
        printf "[%d]  %-45s %-10s %-10s\n" "$i" "${VALID_DRIVES[$i]}" "${VALID_DRIVE_FS[$i]}" "${VALID_DRIVE_AVAIL[$i]}"
    done

    read -rp "Select drive: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -ge "${#VALID_DRIVES[@]}" ]; then
        echo -e "${RED}Invalid selection${NC}"
        exit 1
    fi

    BACKUP_ROOT="${VALID_DRIVES[$choice]}"
}

main() {
    # Registered once, fires on normal completion, `exit 1` error paths,
    # and catchable interrupting signals (e.g. Ctrl+C/SIGTERM) -- not just
    # the happy path. It cannot fire after SIGKILL, a power loss, or a
    # kernel crash; those are outside what any EXIT trap can guarantee.
    trap cleanup_temp_files EXIT

    SCRIPT_START=$SECONDS   # total wall-clock timer for the whole script

    clear
    echo "======================================================"
    echo -e " ${BOLD}Snapshot Backup (Engine v5.1)${NC}"
    echo "======================================================"

    # -----------------------------
    # CONFIG
    # -----------------------------
    # $USER isn't guaranteed to be exported outside an interactive login
    # shell (cron, systemd units, some desktop launchers leave it unset),
    # and with `set -u` an unset $USER would crash the script immediately
    # with "USER: unbound variable" before anything else even ran.
    RUN_USER="${USER:-$(id -un 2>/dev/null)}"
    BASE_BACKUP="/run/media/$RUN_USER"
    readonly MIN_DRIVE_SIZE_GB=50          # filters out tiny/non-backup drives (SD cards, boot sticks)
    readonly RETENTION_DAYS=365            # keep every completed snapshot newer than this many days; older ones are auto-deleted, regardless of how many that turns out to be
    readonly TRASH_RETENTION_COUNT=5       # keep this many quarantined incomplete/interrupted snapshots in .incomplete_trash before they're purged for good
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    readonly COMPLETE_MARKER=".snapshot_complete"
    readonly LOCK_FILE="/tmp/snapshot_backup.lock"

    readonly NO_HARDLINK_FS="vfat exfat msdos ntfs fuseblk"

    # -----------------------------
    # ARGUMENT PARSING
    # -----------------------------
    DRY_RUN=0
    for arg in "$@"; do
        case "$arg" in
            --dry-run)
                DRY_RUN=1
                ;;
            *)
                echo -e "${RED}Unknown argument: $arg${NC}"
                echo "Usage: $0 [--dry-run]"
                exit 1
                ;;
        esac
    done

    if [ "$DRY_RUN" -eq 1 ]; then
        warn "DRY RUN MODE — nothing will be written to the drive."
    fi

    # -----------------------------
    # REQUIRED DEPENDENCY CHECK
    # -----------------------------
    check_dependencies

    # -----------------------------
    # LOCK (prevent concurrent runs)
    # -----------------------------
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        fatal "Another backup run is already in progress (lock: $LOCK_FILE)." "Backup blocked"
    fi

    # -----------------------------
    # BATTERY CHECK (WARN ONLY)
    # -----------------------------
    if command -v upower &>/dev/null; then
        BAT=$(upower -e 2>/dev/null | grep battery | head -n 1 || true)
        if [ -n "$BAT" ]; then
            STATE=$(upower -i "$BAT" 2>/dev/null | grep state | awk '{print $2}')
            PERC=$(upower -i "$BAT" 2>/dev/null | grep percentage | awk '{print $2}' | tr -d '%')
            if [ "$STATE" = "discharging" ]; then
                warn "Warning: Running on battery (${PERC}%)"
            fi
        fi
    fi

    # -----------------------------
    # DRIVE DETECTION
    # -----------------------------
    detect_drives

    # -----------------------------
    # FILESYSTEM CHECK
    # -----------------------------
    FS_TYPE=$(df -T "$BACKUP_ROOT" 2>/dev/null | tail -n1 | awk '{print $2}')

    if [[ " $NO_HARDLINK_FS " == *" $FS_TYPE "* ]]; then
        echo ""
        echo -e "${RED}Warning: '$FS_TYPE' does not reliably support hard links.${NC}"
        warn "Every snapshot on this drive will silently become a full copy instead of an incremental one."
        confirm_or_abort
    fi

    SNAPSHOT_ROOT="$BACKUP_ROOT/Backups"
    mkdir -p "$SNAPSHOT_ROOT" || fatal "Could not create $SNAPSHOT_ROOT"

    # -----------------------------
    # SOURCES
    # -----------------------------
    SOURCES_CONF="$HOME/.config/snapshot-backup/sources.conf"

    if [ -f "$SOURCES_CONF" ]; then
        echo "Using custom source list from $SOURCES_CONF"
        mapfile -t SOURCES < <(grep -vE '^[[:space:]]*(#|$)' "$SOURCES_CONF" | sed "s|^~|$HOME|")
    else
        SOURCES=(
            "$HOME/Desktop"
            "$HOME/Documents"
            "$HOME/Downloads"
            "$HOME/Pictures"
            "$HOME/Videos"
        )
    fi

    EXISTING_SOURCES=()
    for s in "${SOURCES[@]}"; do
        [ -d "$s" ] && EXISTING_SOURCES+=("$s")
    done
    SOURCES=("${EXISTING_SOURCES[@]}")

    if [ ${#SOURCES[@]} -eq 0 ]; then
        echo -e "${RED}None of the configured source folders exist. Nothing to back up.${NC}"
        exit 1
    fi

    # Duplicate basename guard: rsync uses each source folder's basename
    # as its top-level directory name inside the snapshot. If two sources
    # share a basename, rsync merges them into one folder in the snapshot,
    # making the backup ambiguous to restore from.
    declare -A SOURCE_BASENAME_MAP
    for s in "${SOURCES[@]}"; do
        bn="$(basename "$s")"
        if [ -n "${SOURCE_BASENAME_MAP[$bn]+x}" ]; then
            echo -e "${RED}Refusing to run: two source folders share the basename '$bn':${NC}"
            echo "  ${SOURCE_BASENAME_MAP[$bn]}"
            echo "  $s"
            echo "rsync would merge them into a single folder in the snapshot."
            echo "Rename one of them or use sources.conf to pick only one."
            exit 1
        fi
        SOURCE_BASENAME_MAP["$bn"]="$s"
    done

    # -----------------------------
    # SOURCE / TARGET OVERLAP GUARD
    # -----------------------------
    REAL_SNAPSHOT_ROOT=$(realpath "$SNAPSHOT_ROOT")

    for s in "${SOURCES[@]}"; do
        real_s=$(realpath "$s")
        if [ "$real_s" = "$REAL_SNAPSHOT_ROOT" ] || \
           [[ "$real_s" == "$REAL_SNAPSHOT_ROOT"/* ]] || \
           [[ "$REAL_SNAPSHOT_ROOT" == "$real_s"/* ]]; then
            echo -e "${RED}Refusing to run: backup destination overlaps with source '$s'${NC}"
            echo "  Source      : $real_s"
            echo "  Destination : $REAL_SNAPSHOT_ROOT"
            notify_and_exit "Destination overlaps with source: $s"
        fi
    done

    # -----------------------------
    # SNAPSHOT DETECTION (only fully-completed snapshots count)
    # -----------------------------
    PREV=""
    for d in "$SNAPSHOT_ROOT"/Backup_*; do
        [ -d "$d" ] || continue
        [ -f "$d/$COMPLETE_MARKER" ] || continue
        name=$(basename "$d")
        if [ -z "$PREV" ] || [ "$name" \> "$PREV" ]; then
            PREV="$name"
        fi
    done

    SNAPSHOT="$SNAPSHOT_ROOT/Backup_$TIMESTAMP"

    echo ""
    echo "Repository : $SNAPSHOT_ROOT"
    echo "Filesystem : $FS_TYPE"

    LINK_DEST_ARGS=()
    if [ -n "$PREV" ]; then
        echo "Previous   : $PREV"
        LINK_DEST_ARGS=(--link-dest="$SNAPSHOT_ROOT/$PREV")
        echo "Mode       : HARD LINK SNAPSHOT (ACTIVE)"
    else
        echo "Mode       : FULL BASELINE SNAPSHOT"
    fi

    echo ""
    echo "Creating Snapshot:"
    echo "$SNAPSHOT"
    echo "------------------------------------------------------"

    EXCLUDES=(
        "--exclude=.cache"
        "--exclude=.local/share/Trash"
        "--exclude=*~"
        "--exclude=.Trash*"
        "--exclude=.backupignore"
    )

    FILTER_ARGS=(--filter=': .backupignore')

    FOUND_BACKUPIGNORE=0
    for s in "${SOURCES[@]}"; do
        [ -f "$s/.backupignore" ] && FOUND_BACKUPIGNORE=1
    done
    if [ "$FOUND_BACKUPIGNORE" -eq 1 ]; then
        echo "Found .backupignore file(s) in source folders, applying their rules"
    fi

    # -----------------------------
    # FREE SPACE ESTIMATION
    # -----------------------------
    echo "Estimating required space (running rsync dry-run, this can take a moment)..."

    AVAIL_GB=$(df -BG "$BACKUP_ROOT" 2>/dev/null | tail -n1 | awk '{print $4}' | tr -d 'G')
    DRYRUN_LOG=$(mktemp)
    TEMP_FILES+=("$DRYRUN_LOG")

    # Captures stderr into the log too (was previously discarded via
    # 2>/dev/null), so a real rsync error is visible to the user rather
    # than silently disappearing.
    rsync -aH \
        --dry-run \
        --stats \
        "${LINK_DEST_ARGS[@]}" \
        "${EXCLUDES[@]}" \
        "${FILTER_ARGS[@]}" \
        "${SOURCES[@]}" \
        "$SNAPSHOT/" > "$DRYRUN_LOG" 2>&1
    DRYRUN_EXIT=$?

    # This is a preflight check: if the dry-run itself fails (permission
    # error, vanished source, unwritable/disconnected destination, etc.),
    # that is a real signal something is wrong BEFORE any data would be
    # written -- not something to silently paper over as "unknown GB" and
    # continue into the real backup anyway. Abort here, consistent with
    # how a failure of the real backup's own rsync call is already
    # treated further down.
    if [ "$DRYRUN_EXIT" -ne 0 ]; then
        echo -e "${RED}Free-space estimation failed (rsync dry-run exit code $DRYRUN_EXIT).${NC}"
        echo "This is a preflight check -- something is wrong before any data would be written."
        echo "Dry-run output:"
        cat "$DRYRUN_LOG"
        notify_and_exit "Free-space estimation (rsync dry-run) failed with exit code $DRYRUN_EXIT."
    fi

    EST_TRANSFER_BYTES=$(grep "Total transferred file size" "$DRYRUN_LOG" | grep -oE '[0-9,]+' | head -n1 | tr -d ',')
    rm -f "$DRYRUN_LOG"

    if [ -n "$EST_TRANSFER_BYTES" ]; then
        EST_TRANSFER_GB=$(( (EST_TRANSFER_BYTES + 1073741823) / 1073741824 ))
    else
        EST_TRANSFER_GB=""
    fi

    echo "Estimated new data to write : ${EST_TRANSFER_GB:-unknown} GB"
    echo "Available space on target   : ${AVAIL_GB:-unknown} GB"

    if [ -n "$EST_TRANSFER_GB" ] && [ -n "$AVAIL_GB" ] && [ "$AVAIL_GB" -lt "$EST_TRANSFER_GB" ]; then
        warn "Warning: available space is less than the estimated new data to write."
        confirm_or_abort
    elif [ -n "$EST_TRANSFER_GB" ] && [ -n "$AVAIL_GB" ] && [ "$AVAIL_GB" -gt 0 ] && \
         [ "$((EST_TRANSFER_GB * 100 / AVAIL_GB))" -ge 80 ]; then
        warn "Note: this run would use ${EST_TRANSFER_GB} GB of the ${AVAIL_GB} GB currently free (80%+). Drive is filling up."
    fi

    # -----------------------------
    # START
    # -----------------------------
    START=$SECONDS
    mkdir -p "$SNAPSHOT"
    LOGFILE="$SNAPSHOT/rsync.log"

    echo -e "${GREEN}[RUNNING] Backup in progress...${NC}"
    echo ""

    RSYNC_DRY_RUN_ARGS=()
    if [ "$DRY_RUN" -eq 1 ]; then
        RSYNC_DRY_RUN_ARGS=(--dry-run)
    fi

    rsync -aH \
        --info=progress2 \
        --no-inc-recursive \
        --stats \
        "${RSYNC_DRY_RUN_ARGS[@]}" \
        "${LINK_DEST_ARGS[@]}" \
        "${EXCLUDES[@]}" \
        "${FILTER_ARGS[@]}" \
        "${SOURCES[@]}" \
        "$SNAPSHOT/" | tee "$LOGFILE"

    RSYNC_TEE_STATUS=("${PIPESTATUS[@]}")
    RSYNC_EXIT=${RSYNC_TEE_STATUS[0]}
    TEE_EXIT=${RSYNC_TEE_STATUS[1]}

    # rsync succeeding doesn't mean the log was actually written: if tee
    # itself failed (e.g. destination went read-only or filled up right
    # after the transfer), $LOGFILE may be missing or truncated, which
    # would later make stats/error parsing report "unknown" or miss
    # per-file errors. Treated as a warning, not fatal, because the
    # backed-up data itself is governed by RSYNC_EXIT, not by the log.
    TEE_FAILED=0
    if [ "$TEE_EXIT" -ne 0 ]; then
        TEE_FAILED=1
        warn "Warning: log write via tee failed (exit $TEE_EXIT) -- $LOGFILE may be missing or incomplete."
        warn "Stats and per-file error parsing below may be unreliable as a result."
    fi

    sync

    # -----------------------------
    # SUMMARY
    # -----------------------------
    section "Snapshot Summary"

    if [ "$RSYNC_EXIT" -ne 0 ]; then
        echo -e "${RED}Backup failed (rsync exit code $RSYNC_EXIT)${NC}"
        echo "Log: $LOGFILE"
        notify_and_exit "rsync exited with code $RSYNC_EXIT. See $LOGFILE"
    fi

    if [ -n "$PREV" ]; then
        echo "Base snapshot : $PREV"
    else
        echo "Base snapshot : NONE"
    fi

    FILES_TRANSFERRED=$(grep "Number of regular files transferred" "$LOGFILE" | awk -F': ' '{print $2}')
    NEW_DATA=$(grep "Total transferred file size" "$LOGFILE" | awk -F': ' '{print $2}')

    echo ""
    echo "Snapshot created  : $(basename "$SNAPSHOT")"
    echo "Files transferred : ${FILES_TRANSFERRED:-unknown}"
    echo "New data written  : ${NEW_DATA:-unknown}"
    echo "rsync duration    : $((SECONDS - START)) sec"

    if [ "$DRY_RUN" -eq 1 ]; then
        rm -rf "$SNAPSHOT"
        section "${YELLOW}Dry run complete — nothing was written. No snapshot, log, or retention changes were made.${NC}"
        exit 0
    fi

    # -----------------------------
    # PER-FILE ERROR CHECK
    # -----------------------------
    ERROR_LINES=$(grep -c "^rsync: " "$LOGFILE" 2>/dev/null)
    ERROR_LINES=${ERROR_LINES:-0}

    echo ""
    if [ "$ERROR_LINES" -gt 0 ]; then
        warn "Per-file warnings/errors detected: $ERROR_LINES"
        echo "First few:"
        grep "^rsync: " "$LOGFILE" | head -n 5
        echo "Full details in: $LOGFILE"
        SUMMARY_HAD_WARNINGS=1
    else
        echo -e "${GREEN}No per-file errors detected.${NC}"
        SUMMARY_HAD_WARNINGS=0
    fi

    if [ "$TEE_FAILED" -eq 1 ]; then
        SUMMARY_HAD_WARNINGS=1
    fi

    # -----------------------------
    # HARD LINK VERIFICATION
    # -----------------------------
    if [ -n "$PREV" ]; then
        echo ""
        echo "Verifying hard links against previous snapshot..."

        PREV_INODE_FILE=$(mktemp)
        SNAP_INODE_FILE=$(mktemp)
        TEMP_FILES+=("$PREV_INODE_FILE" "$SNAP_INODE_FILE")
        (cd "$SNAPSHOT_ROOT/$PREV" && find . -type f -printf '%i %P\0') > "$PREV_INODE_FILE"
        (cd "$SNAPSHOT" && find . -type f -printf '%i %P\0') > "$SNAP_INODE_FILE"

        read -r TOTAL_FILES LINKED_FILES <<< "$(awk -v RS='\0' '
            NR==FNR {
                if ($0 == "") next
                match($0, /^[0-9]+ /)
                inode = substr($0, 1, RLENGTH - 1)
                path  = substr($0, RLENGTH + 1)
                prev_inode[path] = inode
                next
            }
            {
                if ($0 == "") next
                match($0, /^[0-9]+ /)
                inode = substr($0, 1, RLENGTH - 1)
                path  = substr($0, RLENGTH + 1)
                total++
                if ((path in prev_inode) && prev_inode[path] == inode) linked++
            }
            END { print total+0, linked+0 }
        ' "$PREV_INODE_FILE" "$SNAP_INODE_FILE")"

        rm -f "$PREV_INODE_FILE" "$SNAP_INODE_FILE"

        if [ "$TOTAL_FILES" -gt 0 ]; then
            LINK_PCT=$(awk -v l="$LINKED_FILES" -v t="$TOTAL_FILES" 'BEGIN{printf "%.2f", (l*100)/t}')
            echo "Hard-linked to previous snapshot : $LINKED_FILES / $TOTAL_FILES files (${LINK_PCT}%)"
        else
            echo "Hard-linked to previous snapshot : $LINKED_FILES / $TOTAL_FILES files"
        fi

        if [ "$TOTAL_FILES" -gt 0 ] && [ "$LINKED_FILES" -eq 0 ]; then
            warn "Warning: no files were hard-linked. This snapshot may be a full, non-deduplicated copy."
            warn "Check that the target filesystem actually supports hard links."
        fi

        # -----------------------------
        # DELETED FILES REPORT
        # -----------------------------
        echo ""
        echo "Checking for files removed since previous snapshot..."
        DELETED_FILE=$(mktemp)
        TEMP_FILES+=("$DELETED_FILE")
        comm -23 \
            <(cd "$SNAPSHOT_ROOT/$PREV" && find . -type f \
                ! -name ".snapshot_complete" \
                ! -name ".snapshot_manifest.sha256" \
                ! -name "rsync.log" | sort) \
            <(cd "$SNAPSHOT" && find . -type f \
                ! -name ".snapshot_complete" \
                ! -name ".snapshot_manifest.sha256" \
                ! -name "rsync.log" | sort) > "$DELETED_FILE"
        DELETED_COUNT=$(wc -l < "$DELETED_FILE")

        if [ "$DELETED_COUNT" -gt 0 ]; then
            warn "Removed since last snapshot: $DELETED_COUNT file(s)"
            echo "(still safely present in $PREV — nothing is lost)"
            echo "First few:"
            head -n 5 "$DELETED_FILE" | sed 's|^\./|  - |'
        else
            echo "No files removed since previous snapshot."
        fi
        rm -f "$DELETED_FILE"
    fi

    # -----------------------------
    # SANITY CHECK (random sample, not proof of restoreability)
    # -----------------------------
    VERIFY_SAMPLE_SIZE=20

    if command -v sha256sum &>/dev/null && command -v shuf &>/dev/null; then
        echo ""
        echo "Running sanity check ($VERIFY_SAMPLE_SIZE random files, not exhaustive)..."

        mapfile -t SAMPLE_FILES < <(cd "$SNAPSHOT" && find . -type f \
            ! -name "$(basename "$LOGFILE")" ! -name "$COMPLETE_MARKER" \
            ! -name ".snapshot_manifest.sha256" \
            | shuf -n "$VERIFY_SAMPLE_SIZE" 2>/dev/null)

        CHECKED=0
        MISMATCHES=0
        for relpath in "${SAMPLE_FILES[@]}"; do
            relpath_clean="${relpath#./}"
            top_component="${relpath_clean%%/*}"
            rest="${relpath_clean#*/}"
            source_dir="${SOURCE_BASENAME_MAP[$top_component]:-}"
            [ -z "$source_dir" ] && continue

            src_file="$source_dir/$rest"
            snap_file="$SNAPSHOT/$relpath_clean"
            [ -f "$src_file" ] || continue

            CHECKED=$((CHECKED + 1))
            snap_sum=$(sha256sum "$snap_file" 2>/dev/null | awk '{print $1}')
            src_sum=$(sha256sum "$src_file" 2>/dev/null | awk '{print $1}')

            if [ -n "$snap_sum" ] && [ -n "$src_sum" ] && [ "$snap_sum" != "$src_sum" ]; then
                MISMATCHES=$((MISMATCHES + 1))
                warn "  Mismatch: $relpath_clean"
            fi
        done

        if [ "$CHECKED" -eq 0 ]; then
            echo "Sanity check skipped (no comparable files in the sample)."
        elif [ "$MISMATCHES" -eq 0 ]; then
            echo -e "${GREEN}Sanity check passed: $CHECKED sampled files match the source.${NC}"
        else
            echo -e "${RED}Sanity check found $MISMATCHES/$CHECKED mismatched file(s) -- see above.${NC}"
            warn "Could be a false alarm if those files changed after the backup ran."
        fi
    else
        echo ""
        echo "Sanity check skipped (requires sha256sum and shuf)."
    fi

    # -----------------------------
    # SNAPSHOT MANIFEST (incremental)
    # -----------------------------
    # The completion marker is the trust boundary of this whole design: a
    # marked snapshot is treated as a valid --link-dest base, counted as
    # completed, and kept by retention. Because the script runs under
    # `set -uo pipefail` rather than `set -e`, every command in this stage
    # that could fail (find/awk/tr/xargs/sha256sum/sort) is checked
    # explicitly below, and MANIFEST_OK is the single gate that decides
    # whether the completion marker gets written at all. If anything in
    # here fails, the run stops WITHOUT writing the marker -- the snapshot
    # is left on disk as an incomplete leftover, which the existing
    # retention logic already knows how to clean up on the next run.
    echo ""
    echo "Building snapshot manifest (incremental)..."
    MANIFEST="$SNAPSHOT/.snapshot_manifest.sha256"
    MANIFEST_REUSE_FILE=$(mktemp)
    MANIFEST_COMPUTE_FILE=$(mktemp)
    MANIFEST_PREV_INODE_FILE=$(mktemp)
    MANIFEST_SNAP_INODE_FILE=$(mktemp)
    MANIFEST_CK_FILE=$(mktemp)
    TEMP_FILES+=("$MANIFEST_REUSE_FILE" "$MANIFEST_COMPUTE_FILE" \
        "$MANIFEST_PREV_INODE_FILE" "$MANIFEST_SNAP_INODE_FILE" "$MANIFEST_CK_FILE")

    MANIFEST_OK=1
    manifest_fail() {
        # Centralizes "something in the manifest stage broke" handling so
        # every check point below fails the same way instead of some
        # paths silently falling through to a marker write.
        MANIFEST_OK=0
        echo -e "${RED}Manifest stage failed: $1${NC}"
    }

    manifest_hash_with_progress() {
        # sha256sum over tens of thousands of files (a full baseline
        # rehash, or just a large batch of new/changed files) can take
        # minutes with zero output otherwise -- indistinguishable from a
        # hang. This sits between sha256sum and the manifest file: every
        # line is passed through unchanged (so the manifest content isn't
        # affected at all), while a periodic "Hashed X/Y files" line goes
        # to the terminal (stderr, so it doesn't end up IN the manifest).
        local total="$1"
        awk -v total="$total" '
            {
                print
                c++
                step = (total > 20) ? int(total / 20) : 1
                if (step < 1) step = 1
                if (c % step == 0 || c == total) {
                    printf "\r  Hashed %d/%d files...", c, total > "/dev/stderr"
                    fflush("/dev/stderr")
                }
            }
            END { if (total > 0) printf "\r%*s\r", 60, "" > "/dev/stderr" }
        '
    }

    : > "$MANIFEST" || manifest_fail "could not create manifest file"

    (cd "$SNAPSHOT" && find . -type f \
        ! -name ".snapshot_manifest.sha256" ! -name "$COMPLETE_MARKER" \
        -printf "%i %s %Ts %P\0") > "$MANIFEST_SNAP_INODE_FILE"
    RC=$?
    [ "$RC" -eq 0 ] || manifest_fail "could not list snapshot files"
    SNAP_FILE_COUNT=$(tr -cd '\0' < "$MANIFEST_SNAP_INODE_FILE" | wc -c)

    MANIFEST_REUSED=0
    MANIFEST_COMPUTED=0

    # -----------------------------
    # PREVIOUS MANIFEST VALIDATION
    # -----------------------------
    # The old guard only proved that ONE line in the previous manifest
    # looked like a valid sha256sum record -- a heavily truncated or
    # corrupted manifest with a single intact line could pass. This now
    # requires EVERY non-empty line to match either the plain format or
    # GNU sha256sum's "escaped" format (a leading backslash, used when a
    # filename contains a literal backslash or newline -- see the ck-table
    # build below for why escaped lines are safe to skip rather than
    # needing to invalidate everything), AND the line count to match the
    # previous snapshot's actual file count. Anything else is treated as
    # corruption and falls back to a full rehash.
    PREV_MANIFEST_PATH="$SNAPSHOT_ROOT/$PREV/.snapshot_manifest.sha256"
    PREV_MANIFEST_OK=0
    if [ -n "$PREV" ] && [ -f "$PREV_MANIFEST_PATH" ]; then
        (cd "$SNAPSHOT_ROOT/$PREV" && find . -type f \
            ! -name ".snapshot_manifest.sha256" ! -name "$COMPLETE_MARKER" \
            -printf "%i %s %Ts %P\0") > "$MANIFEST_PREV_INODE_FILE"
        RC=$?
        [ "$RC" -eq 0 ] || manifest_fail "could not list previous snapshot files"
        PREV_FILE_COUNT=$(tr -cd '\0' < "$MANIFEST_PREV_INODE_FILE" | wc -c)

        # NOTE: `grep -c` exits with status 1 whenever it finds zero
        # matches -- that's normal, successful behavior for grep, not an
        # error, but it still trips a naive `|| echo 0` fallback and
        # doubles the output to "0\n0", corrupting the arithmetic below.
        # Capturing the count regardless of exit status and only
        # defaulting on a truly empty result (e.g. an unreadable file)
        # avoids that.
        PREV_TOTAL_LINES=$(grep -c '.' "$PREV_MANIFEST_PATH" 2>/dev/null); PREV_TOTAL_LINES=${PREV_TOTAL_LINES:-0}
        PREV_PLAIN_LINES=$(grep -cE '^[0-9a-f]{64}  .+$' "$PREV_MANIFEST_PATH" 2>/dev/null); PREV_PLAIN_LINES=${PREV_PLAIN_LINES:-0}
        PREV_ESCAPED_LINES=$(grep -cE '^\\[0-9a-f]{64}  .+$' "$PREV_MANIFEST_PATH" 2>/dev/null); PREV_ESCAPED_LINES=${PREV_ESCAPED_LINES:-0}
        PREV_VALID_LINES=$((PREV_PLAIN_LINES + PREV_ESCAPED_LINES))

        if [ "$PREV_TOTAL_LINES" -eq 0 ]; then
            warn "Warning: previous manifest is empty -- falling back to full baseline hash."
        elif [ "$PREV_TOTAL_LINES" -ne "$PREV_VALID_LINES" ]; then
            warn "Warning: previous manifest has $((PREV_TOTAL_LINES - PREV_VALID_LINES)) malformed line(s) -- falling back to full baseline hash."
        elif [ "$PREV_TOTAL_LINES" -ne "$PREV_FILE_COUNT" ]; then
            warn "Warning: previous manifest has $PREV_TOTAL_LINES entries but $PREV_FILE_COUNT files exist in $PREV -- treating as untrustworthy, falling back to full baseline hash."
        else
            PREV_MANIFEST_OK=1
            if [ "$PREV_ESCAPED_LINES" -gt 0 ]; then
                echo "(Previous manifest has $PREV_ESCAPED_LINES escaped filename record(s) -- those specific file(s) will be rehashed, everything else is inherited normally)"
            fi
        fi
    fi

    if [ "$MANIFEST_OK" -eq 1 ] && [ "$PREV_MANIFEST_OK" -eq 1 ]; then
        awk '{
            if ($0 ~ /^\\/) next   # escaped record (backslash/newline in filename) -- fixed-offset parsing below does not apply to these; skipping means that one path has no cached checksum and simply gets rehashed by the correlation step, without affecting any other file
            ck   = substr($0, 1, 64)
            path = substr($0, 67)
            sub(/^\.\//, "", path)
            print ck " " path
        }' "$PREV_MANIFEST_PATH" \
            | tr '\n' '\0' > "$MANIFEST_CK_FILE"
        RC=("${PIPESTATUS[@]}")
        [ "${RC[0]}" -eq 0 ] && [ "${RC[1]}" -eq 0 ] || manifest_fail "could not build checksum lookup table"

        awk -v RS='\0' \
            -v ck_file="$MANIFEST_CK_FILE" \
            -v reuse_file="$MANIFEST_REUSE_FILE" \
            -v compute_file="$MANIFEST_COMPUTE_FILE" '
        BEGIN {
            while ((getline line < ck_file) > 0) {
                if (line == "") continue
                ck   = substr(line, 1, 64)
                path = substr(line, 66)
                prev_ck[path] = ck
            }
            close(ck_file)
        }
        FNR==NR {
            if ($0 == "") next
            match($0, /^[0-9]+ [0-9]+ [0-9]+ /)
            path = substr($0, RLENGTH + 1)
            sub(/^\.\//, "", path)
            prev_attrs[path] = substr($0, 1, RLENGTH - 1)
            next
        }
        {
            if ($0 == "") next
            match($0, /^[0-9]+ [0-9]+ [0-9]+ /)
            snap_attrs = substr($0, 1, RLENGTH - 1)
            path = substr($0, RLENGTH + 1)
            sub(/^\.\//, "", path)
            if ((path in prev_attrs) && prev_attrs[path] == snap_attrs && (path in prev_ck)) {
                print prev_ck[path] "  ./" path >> reuse_file
            } else {
                printf "%s\036", path >> compute_file
            }
        }
        ' "$MANIFEST_PREV_INODE_FILE" "$MANIFEST_SNAP_INODE_FILE"
        [ $? -eq 0 ] || manifest_fail "could not correlate previous/current file attributes"

        if [ -s "$MANIFEST_REUSE_FILE" ]; then
            cat "$MANIFEST_REUSE_FILE" >> "$MANIFEST"
            MANIFEST_REUSED=$(wc -l < "$MANIFEST_REUSE_FILE")
        fi
        if [ -s "$MANIFEST_COMPUTE_FILE" ]; then
            COMPUTE_TOTAL=$(tr -cd '\036' < "$MANIFEST_COMPUTE_FILE" | wc -c)
            echo "Hashing $COMPUTE_TOTAL new/changed/uninheritable file(s)..."
            (cd "$SNAPSHOT" && tr '\036' '\0' < "$MANIFEST_COMPUTE_FILE" \
                | xargs -0 sha256sum) \
                | manifest_hash_with_progress "$COMPUTE_TOTAL" >> "$MANIFEST"
            RC=("${PIPESTATUS[@]}")
            [ "${RC[0]}" -eq 0 ] && [ "${RC[1]}" -eq 0 ] || manifest_fail "hashing new/changed files failed (sha256sum/xargs)"
            MANIFEST_COMPUTED=$COMPUTE_TOTAL
        fi
    elif [ "$MANIFEST_OK" -eq 1 ]; then
        if [ -n "$PREV" ]; then
            echo "(No usable previous manifest in $PREV -- generating baseline, future runs will be fast)"
        fi
        echo "Hashing $SNAP_FILE_COUNT file(s) (full baseline -- this can take a while on a large dataset)..."
        (cd "$SNAPSHOT" && find . -type f \
            ! -name ".snapshot_manifest.sha256" ! -name "$COMPLETE_MARKER" \
            -print0 | sort -z | xargs -0 sha256sum) \
            | manifest_hash_with_progress "$SNAP_FILE_COUNT" >> "$MANIFEST"
        RC=("${PIPESTATUS[@]}")
        [ "${RC[0]}" -eq 0 ] && [ "${RC[1]}" -eq 0 ] || manifest_fail "baseline hashing failed (find/sort/xargs/sha256sum)"
        MANIFEST_COMPUTED=$(wc -l < "$MANIFEST")
    fi

    if [ "$MANIFEST_OK" -eq 1 ]; then
        sort -k2 "$MANIFEST" -o "$MANIFEST" || manifest_fail "final manifest sort failed"
    fi

    rm -f "$MANIFEST_REUSE_FILE" "$MANIFEST_COMPUTE_FILE" \
          "$MANIFEST_PREV_INODE_FILE" "$MANIFEST_SNAP_INODE_FILE" \
          "$MANIFEST_CK_FILE"

    if [ "$MANIFEST_OK" -eq 1 ]; then
        MANIFEST_TOTAL=$(wc -l < "$MANIFEST")
        # Final self-check: the manifest must describe exactly as many
        # files as actually exist in the snapshot. This is the same
        # count-matching principle applied to the manifest we just wrote,
        # not just the inherited one -- it catches a partial write that
        # every individual step above still reported success for.
        if [ "$MANIFEST_TOTAL" -ne "$SNAP_FILE_COUNT" ]; then
            manifest_fail "manifest has $MANIFEST_TOTAL entries but $SNAP_FILE_COUNT files exist in the snapshot"
        fi
    fi

    if [ "$MANIFEST_OK" -ne 1 ]; then
        echo -e "${RED}Refusing to mark this snapshot complete: manifest generation did not finish cleanly.${NC}"
        echo -e "${RED}The transferred files in $SNAPSHOT are intact, but no completion marker will be written,${NC}"
        echo -e "${RED}so this snapshot will NOT be used as a future --link-dest base and will be cleaned up${NC}"
        echo -e "${RED}as an incomplete leftover on the next run.${NC}"
        notify_and_exit "Manifest generation failed for $(basename "$SNAPSHOT") -- snapshot not marked complete."
    fi

    if [ "$MANIFEST_TOTAL" -gt 0 ]; then
        MANIFEST_REUSE_PCT=$(awk -v r="$MANIFEST_REUSED" -v t="$MANIFEST_TOTAL" 'BEGIN{printf "%.2f", (r*100)/t}')
        echo -e "${GREEN}Manifest written: $MANIFEST_TOTAL file(s) total" \
            "(${MANIFEST_REUSED} inherited [${MANIFEST_REUSE_PCT}%], ${MANIFEST_COMPUTED} hashed).${NC}"
    else
        echo -e "${GREEN}Manifest written: $MANIFEST_TOTAL file(s) total" \
            "(${MANIFEST_REUSED} inherited, ${MANIFEST_COMPUTED} hashed).${NC}"
    fi
    echo "To verify later: cd $SNAPSHOT && sha256sum --check .snapshot_manifest.sha256"

    # -----------------------------
    # COMPLETION MARKER
    # -----------------------------
    # Only reached if MANIFEST_OK held all the way through -- see the
    # gate immediately above.
    touch "$SNAPSHOT/$COMPLETE_MARKER"

    section "${GREEN}Backup Completed Successfully${NC}"

    # -----------------------------
    # RETENTION (keep every completed snapshot newer than RETENTION_DAYS)
    # -----------------------------
    section_open "Retention"

    SNAPSHOT_NAME_PATTERN='^Backup_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$'

    # An interrupted run (power loss, unplugged drive, Ctrl+C mid-transfer)
    # leaves a Backup_* directory with no completion marker. Previously
    # this was rm -rf'd immediately on the next launch with no way to
    # look at it first -- if that interruption happened at 99% of a large
    # transfer, whatever partial data existed was gone before anyone
    # could inspect or recover it. It's now quarantined into
    # .incomplete_trash instead of deleted outright. This is cheap: mv
    # within the same filesystem is a rename, not a copy, so it doesn't
    # duplicate any data -- hard links to the previous snapshot (for
    # files that didn't change) stay intact and cost nothing extra; only
    # the newly-transferred/changed data from that one failed run is
    # what's actually being kept around. .incomplete_trash itself has its
    # own count-based retention below so it can't grow forever.
    TRASH_DIR="$SNAPSHOT_ROOT/.incomplete_trash"

    for d in "$SNAPSHOT_ROOT"/Backup_*; do
        [ -d "$d" ] || continue
        [ -f "$d/$COMPLETE_MARKER" ] && continue
        name=$(basename "$d")
        if [[ ! "$name" =~ $SNAPSHOT_NAME_PATTERN ]]; then
            warn "Skipping unexpected directory name (not touching): $name"
            continue
        fi
        mkdir -p "$TRASH_DIR" || { echo -e "${RED}Could not create $TRASH_DIR -- leaving $name in place.${NC}"; continue; }
        if [ -e "$TRASH_DIR/$name" ]; then
            warn "$TRASH_DIR/$name already exists -- leaving $name in place rather than overwriting."
            continue
        fi
        echo "Quarantining incomplete leftover snapshot: $name -> .incomplete_trash/ (not deleted)"
        mv "${SNAPSHOT_ROOT:?}/$name" "$TRASH_DIR/$name" \
            || warn "Could not move $name into quarantine -- leaving it in place."
    done

    # -----------------------------
    # QUARANTINE RETENTION (.incomplete_trash)
    # -----------------------------
    if [ -d "$TRASH_DIR" ]; then
        mapfile -t TRASHED < <(find "$TRASH_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
        TRASH_TOTAL=${#TRASHED[@]}
        if [ "$TRASH_TOTAL" -gt "$TRASH_RETENTION_COUNT" ]; then
            TRASH_TO_REMOVE=$((TRASH_TOTAL - TRASH_RETENTION_COUNT))
            echo "Purging $TRASH_TO_REMOVE oldest quarantined snapshot(s) beyond .incomplete_trash retention (keeping last $TRASH_RETENTION_COUNT):"
            for ((i = 0; i < TRASH_TO_REMOVE; i++)); do
                old_trash="${TRASHED[$i]}"
                if [[ ! "$old_trash" =~ $SNAPSHOT_NAME_PATTERN ]]; then
                    warn "Skipping unexpected directory name in trash (not deleting): $old_trash"
                    continue
                fi
                echo "  - $old_trash"
                rm -rf "${TRASH_DIR:?}/$old_trash"
            done
        elif [ "$TRASH_TOTAL" -gt 0 ]; then
            echo "Quarantined incomplete snapshots on drive : $TRASH_TOTAL (keeping last $TRASH_RETENTION_COUNT, in .incomplete_trash)"
        fi
    fi

    COMPLETED_SNAPSHOTS=()
    for d in "$SNAPSHOT_ROOT"/Backup_*; do
        [ -d "$d" ] || continue
        [ -f "$d/$COMPLETE_MARKER" ] || continue
        COMPLETED_SNAPSHOTS+=("$(basename "$d")")
    done
    mapfile -t COMPLETED_SNAPSHOTS < <(printf '%s\n' "${COMPLETED_SNAPSHOTS[@]}" | sort)

    TOTAL_COMPLETED=${#COMPLETED_SNAPSHOTS[@]}
    echo "Completed snapshots on drive : $TOTAL_COMPLETED (retention: $RETENTION_DAYS days)"

    # Time-based, not count-based: a fixed snapshot COUNT is a poor proxy
    # for calendar time when runs happen irregularly (several in one day,
    # then a multi-day gap) -- the actual coverage a fixed count buys
    # drifts with usage pattern instead of staying anchored to what was
    # actually asked for ("keep a year of history"). Each snapshot's own
    # timestamp is already right there in its folder name, so the cutoff
    # is computed directly from that instead of from how many happen to
    # exist.
    RETENTION_CUTOFF_EPOCH=$(date -d "-${RETENTION_DAYS} days" +%s)
    TO_REMOVE=()
    for name in "${COMPLETED_SNAPSHOTS[@]}"; do
        if [[ ! "$name" =~ $SNAPSHOT_NAME_PATTERN ]]; then
            warn "Skipping unexpected directory name (not touching): $name"
            continue
        fi
        ts="${name#Backup_}"                # YYYY-MM-DD_HH-MM-SS
        date_part="${ts%%_*}"               # YYYY-MM-DD
        time_part="${ts#*_}"                # HH-MM-SS
        time_part="${time_part//-/:}"       # HH:MM:SS
        snap_epoch=$(date -d "$date_part $time_part" +%s 2>/dev/null)
        if [ -n "$snap_epoch" ] && [ "$snap_epoch" -lt "$RETENTION_CUTOFF_EPOCH" ]; then
            TO_REMOVE+=("$name")
        fi
    done

    if [ ${#TO_REMOVE[@]} -gt 0 ]; then
        echo "Removing ${#TO_REMOVE[@]} snapshot(s) older than $RETENTION_DAYS days:"
        for old in "${TO_REMOVE[@]}"; do
            echo "  - $old"
            # ${SNAPSHOT_ROOT:?} aborts the script immediately if SNAPSHOT_ROOT
            # is ever empty/unset, instead of silently deleting from filesystem
            # root ("/$old"). Flagged by shellcheck (SC2115); other guards
            # already made this unreachable in practice, but this closes the
            # gap explicitly rather than relying on those alone.
            rm -rf "${SNAPSHOT_ROOT:?}/$old"
        done
    else
        echo "Nothing to remove."
    fi
    section_close

    FINAL_SIZE=$(du -sh "$SNAPSHOT" | awk '{print $1}')
    echo ""
    echo "Quick integrity signal:"
    echo "Apparent snapshot size (includes hard-linked data): $FINAL_SIZE"
    echo "Total script duration : $((SECONDS - SCRIPT_START)) sec"
    echo "(rsync-only duration shown separately in snapshot summary above)"
    echo "======================================================"

    if [ "$SUMMARY_HAD_WARNINGS" -eq 1 ]; then
        notify "Backup completed with warnings" "Snapshot $(basename "$SNAPSHOT") created ($FINAL_SIZE) but $ERROR_LINES file(s) had issues. Check the log." normal
    else
        notify "Backup completed" "Snapshot $(basename "$SNAPSHOT") created successfully ($FINAL_SIZE)." normal
    fi
}

# Only auto-run when executed directly, not when sourced -- lets this
# script be sourced by another script to reuse its functions without
# immediately kicking off a backup.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
