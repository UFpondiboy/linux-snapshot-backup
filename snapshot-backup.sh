#!/bin/bash

# ======================================================
# Snapshot Backup (Verified Engine v5)
# ======================================================
# Patched in v5, round 8 (Reddit feedback):
#   - Added trap-based cleanup for all mktemp temp files. Previously
#     each temp file was removed with an explicit `rm -f` right after
#     use, which left a real gap: if the script was interrupted
#     (Ctrl+C, crash, shutdown) between creating a temp file and
#     reaching its cleanup line, that file would be orphaned in /tmp
#     indefinitely. Now every mktemp result is tracked in a TEMP_FILES
#     array, and a single `trap cleanup_temp_files EXIT` guarantees
#     cleanup on any exit path. Verified against three scenarios
#     (normal exit, `exit 1` error paths, and a simulated SIGTERM
#     interruption) -- all three correctly triggered cleanup.
#
# Patched in v5, round 7 (shellcheck feedback):
#   - Fixed SC2162: all `read -p` prompts changed to `read -rp` so
#     backslash characters in input are treated literally instead of
#     being interpreted as escape sequences. Low real-world risk here
#     (drive number / y-N prompts), but the safer default costs nothing.
#   - Fixed SC2115: the retention rm -rf now uses "${SNAPSHOT_ROOT:?}"
#     instead of a bare "$SNAPSHOT_ROOT". If that variable were ever
#     empty or unset, the old code would silently become `rm -rf "/$old"`
#     -- a root-relative delete. The :? form makes the script abort
#     loudly instead of ever risking that, even though other guards
#     (the SNAPSHOT_NAME_PATTERN regex, SNAPSHOT_ROOT always being set
#     via mkdir -p earlier) already made this unreachable in practice.
#   - Wrapped the entire script body in a main() function, per
#     feedback that a script this size had no functions at all
#     (aside from notify()). Verified line-for-line against the
#     unwrapped version -- only indentation and structure changed,
#     no logic was altered.
#
# Patched in v5, round 6 (reviewer run output):
#   - Fixed deletion report falsely reporting .snapshot_complete as
#     deleted: the comparison ran before the completion marker was
#     written to the new snapshot, so it appeared absent. Internal
#     metadata files (.snapshot_complete, .snapshot_manifest.sha256,
#     rsync.log) are now excluded from both sides of the comm
#     comparison.
#   - Added SCRIPT_START timer at the top; total script duration
#     is now printed at the end. Previously the "Duration" line only
#     covered the rsync transfer itself.
#   - Improved messaging for manifest baseline run: when no previous
#     manifest exists, the output now explains why everything is
#     being hashed and that future runs will be fast.
#
# Patched in v5, round 5 (review feedback):
#   - Fixed the basename collision bug in SOURCE_BASENAME_MAP
#   - Removed the SMART health check section
#   - Renamed spot-check to "sanity check" with corrected framing
#   - Added incremental snapshot manifest with manifest integrity guard
#   - Documented renamed-file efficiency gap and deleted-file non-issue
#
# Patched in v5, round 4 (review feedback):
#   - Fixed hard-link verification space-in-filename bug
#   - Fixed dry-run rmdir -> rm -rf
#   - Deleted-files report uses temp file
#   - Sources configurable via ~/.config/snapshot-backup/sources.conf
#   - Drive detection checks /media/$USER and /media as fallbacks
#   - Added sanity check (20-file random sample vs live source)
#
# Patched in v5, round 3 (review feedback):
#   - Log file lives at $SNAPSHOT/rsync.log
#   - Drive selection shows table (path, filesystem, free space)
#   - Free-space check warns at 80% of available space
#   - Forces LC_ALL=C for consistent rsync --stats output parsing
#
# Patched in v5, round 2 (review feedback):
#   - .backupignore uses rsync's own per-directory merge filter
#   - Hard-link verification compares inodes against specific prev snapshot
#   - All rm -rf calls guarded by exact timestamp-format regex
#   - Hard-link verification uses temp files, not bash variables
#
# Patched in v5:
#   - Dry-run mode (--dry-run flag)
#   - Per-folder .backupignore excludes
#   - rsync -aH (preserves hard links within source tree)
#   - Free-space estimate via rsync --dry-run instead of du
#   - Fixed 0\n0 bug in per-file error count
#   - Deleted-files report in summary
#
# Carried over from v4:
#   - Source/target overlap guard
#   - Lock file (flock) prevents concurrent runs
#   - rsync per-file error parsing and surfacing
#   - Desktop notification (notify-send) on success and failure
#
# Carried over from v3:
#   - Array-based --link-dest
#   - Drive selection input validation
#   - Available-space check (not just total capacity)
#   - Filesystem hard-link support check
#   - Completion marker (.snapshot_complete)
#   - rsync --stats output capture and parsing
#   - --no-inc-recursive for smooth progress bar
#   - Retention: count-based, automatic, with orphan cleanup
#
# Restore: intentionally manual. Browse to
#   <drive>/Backups/Backup_<timestamp>/ and copy files back out.
#   Each snapshot folder is a complete, independent-looking copy.
# To verify integrity of any snapshot at any future point:
#   cd <drive>/Backups/Backup_<timestamp>
#   sha256sum --check .snapshot_manifest.sha256
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

# Tracks every mktemp file created during the run so they can be cleaned
# up reliably even if the script is interrupted (Ctrl+C, crash, system
# shutdown) between creating a temp file and its normal `rm -f`. Without
# this, an interrupted run could leave orphaned files behind in /tmp
# indefinitely.
TEMP_FILES=()

cleanup_temp_files() {
    if [ ${#TEMP_FILES[@]} -gt 0 ]; then
        rm -f "${TEMP_FILES[@]}" 2>/dev/null
    fi
}

main() {
    # Registered once, fires on ANY exit path (normal completion, `exit 1`
    # error paths, or an interrupting signal) -- not just the happy path.
    trap cleanup_temp_files EXIT

    SCRIPT_START=$SECONDS   # total wall-clock timer for the whole script

    clear
    echo "======================================================"
    echo -e " ${BOLD}Snapshot Backup (Verified Engine v5)${NC}"
    echo "======================================================"

    # -----------------------------
    # CONFIG
    # -----------------------------
    BASE_BACKUP="/run/media/$USER"
    MIN_DRIVE_SIZE_GB=50          # filters out tiny/non-backup drives (SD cards, boot sticks)
    RETENTION_COUNT=50            # keep this many completed snapshots; older ones are auto-deleted
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    COMPLETE_MARKER=".snapshot_complete"
    LOCK_FILE="/tmp/snapshot_backup.lock"

    NO_HARDLINK_FS="vfat exfat msdos ntfs fuseblk"

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
        echo -e "${YELLOW}DRY RUN MODE — nothing will be written to the drive.${NC}"
    fi

    # -----------------------------
    # LOCK (prevent concurrent runs)
    # -----------------------------
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo -e "${RED}Another backup run is already in progress (lock: $LOCK_FILE).${NC}"
        notify "Backup blocked" "Another backup run is already in progress." critical
        exit 1
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
                echo -e "${YELLOW}Warning: Running on battery (${PERC}%)${NC}"
            fi
        fi
    fi

    # -----------------------------
    # DRIVE DETECTION
    # -----------------------------
    echo ""
    echo "Detecting external drives..."

    VALID_DRIVES=()
    VALID_DRIVE_FS=()
    VALID_DRIVE_AVAIL=()

    for BASE_CANDIDATE in "$BASE_BACKUP" "/media/$USER" "/media"; do
        [ -d "$BASE_CANDIDATE" ] || continue
        for d in "$BASE_CANDIDATE"/*; do
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
        echo -e "${RED}No valid backup drive found${NC}"
        notify "Backup failed" "No valid backup drive found." critical
        exit 1
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

    # -----------------------------
    # FILESYSTEM CHECK
    # -----------------------------
    FS_TYPE=$(df -T "$BACKUP_ROOT" 2>/dev/null | tail -n1 | awk '{print $2}')

    if [[ " $NO_HARDLINK_FS " == *" $FS_TYPE "* ]]; then
        echo ""
        echo -e "${RED}Warning: '$FS_TYPE' does not reliably support hard links.${NC}"
        echo -e "${YELLOW}Every snapshot on this drive will silently become a full copy instead of an incremental one.${NC}"
        read -rp "Continue anyway? (y/N): " fs_confirm
        if [[ ! "$fs_confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi

    SNAPSHOT_ROOT="$BACKUP_ROOT/Backups"
    mkdir -p "$SNAPSHOT_ROOT" || { echo -e "${RED}Could not create $SNAPSHOT_ROOT${NC}"; notify "Backup failed" "Could not create $SNAPSHOT_ROOT" critical; exit 1; }

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
            notify "Backup failed" "Destination overlaps with source: $s" critical
            exit 1
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

    rsync -aH \
        --dry-run \
        --stats \
        "${LINK_DEST_ARGS[@]}" \
        "${EXCLUDES[@]}" \
        "${FILTER_ARGS[@]}" \
        "${SOURCES[@]}" \
        "$SNAPSHOT/" > "$DRYRUN_LOG" 2>/dev/null

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
        echo -e "${YELLOW}Warning: available space is less than the estimated new data to write.${NC}"
        read -rp "Continue anyway? (y/N): " space_confirm
        if [[ ! "$space_confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    elif [ -n "$EST_TRANSFER_GB" ] && [ -n "$AVAIL_GB" ] && [ "$AVAIL_GB" -gt 0 ] && \
         [ "$((EST_TRANSFER_GB * 100 / AVAIL_GB))" -ge 80 ]; then
        echo -e "${YELLOW}Note: this run would use ${EST_TRANSFER_GB} GB of the ${AVAIL_GB} GB currently free (80%+). Drive is filling up.${NC}"
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

    RSYNC_EXIT=${PIPESTATUS[0]}

    sync

    # -----------------------------
    # SUMMARY
    # -----------------------------
    echo ""
    echo "======================================================"
    echo "Snapshot Summary"
    echo "======================================================"

    if [ "$RSYNC_EXIT" -ne 0 ]; then
        echo -e "${RED}Backup failed (rsync exit code $RSYNC_EXIT)${NC}"
        echo "Log: $LOGFILE"
        notify "Backup failed" "rsync exited with code $RSYNC_EXIT. See $LOGFILE" critical
        exit 1
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
        echo ""
        echo "======================================================"
        echo -e "${YELLOW}Dry run complete — nothing was written. No snapshot, log, or retention changes were made.${NC}"
        echo "======================================================"
        exit 0
    fi

    # -----------------------------
    # PER-FILE ERROR CHECK
    # -----------------------------
    ERROR_LINES=$(grep -c "^rsync: " "$LOGFILE" 2>/dev/null)
    ERROR_LINES=${ERROR_LINES:-0}

    echo ""
    if [ "$ERROR_LINES" -gt 0 ]; then
        echo -e "${YELLOW}Per-file warnings/errors detected: $ERROR_LINES${NC}"
        echo "First few:"
        grep "^rsync: " "$LOGFILE" | head -n 5
        echo "Full details in: $LOGFILE"
        SUMMARY_HAD_WARNINGS=1
    else
        echo -e "${GREEN}No per-file errors detected.${NC}"
        SUMMARY_HAD_WARNINGS=0
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

        echo "Linked specifically to previous snapshot : $LINKED_FILES / $TOTAL_FILES files"

        if [ "$TOTAL_FILES" -gt 0 ] && [ "$LINKED_FILES" -eq 0 ]; then
            echo -e "${YELLOW}Warning: no files were hard-linked. This snapshot may be a full, non-deduplicated copy.${NC}"
            echo -e "${YELLOW}Check that the target filesystem actually supports hard links.${NC}"
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
            echo -e "${YELLOW}Removed since last snapshot: $DELETED_COUNT file(s)${NC}"
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
                echo -e "${YELLOW}  Mismatch: $relpath_clean${NC}"
            fi
        done

        if [ "$CHECKED" -eq 0 ]; then
            echo "Sanity check skipped (no comparable files in the sample)."
        elif [ "$MISMATCHES" -eq 0 ]; then
            echo -e "${GREEN}Sanity check passed: $CHECKED sampled files match the source.${NC}"
        else
            echo -e "${RED}Sanity check found $MISMATCHES/$CHECKED mismatched file(s) -- see above.${NC}"
            echo -e "${YELLOW}Could be a false alarm if those files changed after the backup ran.${NC}"
        fi
    else
        echo ""
        echo "Sanity check skipped (requires sha256sum and shuf)."
    fi

    # -----------------------------
    # SNAPSHOT MANIFEST (incremental)
    # -----------------------------
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

    (cd "$SNAPSHOT" && find . -type f \
        ! -name ".snapshot_manifest.sha256" ! -name "$COMPLETE_MARKER" \
        -printf "%i %s %Ts %P\0") > "$MANIFEST_SNAP_INODE_FILE"

    MANIFEST_REUSED=0
    MANIFEST_COMPUTED=0

    PREV_MANIFEST_PATH="$SNAPSHOT_ROOT/$PREV/.snapshot_manifest.sha256"
    PREV_MANIFEST_OK=0
    if [ -n "$PREV" ] && [ -f "$PREV_MANIFEST_PATH" ]; then
        if grep -qE '^[0-9a-f]{64}  .+$' "$PREV_MANIFEST_PATH" 2>/dev/null; then
            PREV_MANIFEST_OK=1
        else
            echo -e "${YELLOW}Warning: previous manifest appears empty or malformed -- falling back to full baseline hash.${NC}"
        fi
    fi

    if [ "$PREV_MANIFEST_OK" -eq 1 ]; then
        (cd "$SNAPSHOT_ROOT/$PREV" && find . -type f \
            ! -name ".snapshot_manifest.sha256" ! -name "$COMPLETE_MARKER" \
            -printf "%i %s %Ts %P\0") > "$MANIFEST_PREV_INODE_FILE"

        awk '{
            ck   = substr($0, 1, 64)
            path = substr($0, 67)
            sub(/^\.\//, "", path)
            print ck " " path
        }' "$PREV_MANIFEST_PATH" \
            | tr '\n' '\0' > "$MANIFEST_CK_FILE"

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

        [ -s "$MANIFEST_REUSE_FILE" ] && {
            cat "$MANIFEST_REUSE_FILE" >> "$MANIFEST"
            MANIFEST_REUSED=$(wc -l < "$MANIFEST_REUSE_FILE")
        }
        [ -s "$MANIFEST_COMPUTE_FILE" ] && {
            (cd "$SNAPSHOT" && tr '\036' '\0' < "$MANIFEST_COMPUTE_FILE" \
                | xargs -0 sha256sum) >> "$MANIFEST"
            MANIFEST_COMPUTED=$(tr -cd '\036' < "$MANIFEST_COMPUTE_FILE" | wc -c)
        }
    else
        if [ -n "$PREV" ]; then
            echo "(No previous manifest found in $PREV -- generating baseline, future runs will be fast)"
        fi
        (cd "$SNAPSHOT" && find . -type f \
            ! -name ".snapshot_manifest.sha256" ! -name "$COMPLETE_MARKER" \
            -print0 | sort -z | xargs -0 sha256sum) >> "$MANIFEST"
        MANIFEST_COMPUTED=$(wc -l < "$MANIFEST")
    fi

    sort -k2 "$MANIFEST" -o "$MANIFEST"
    rm -f "$MANIFEST_REUSE_FILE" "$MANIFEST_COMPUTE_FILE" \
          "$MANIFEST_PREV_INODE_FILE" "$MANIFEST_SNAP_INODE_FILE" \
          "$MANIFEST_CK_FILE"

    MANIFEST_TOTAL=$(wc -l < "$MANIFEST")
    echo -e "${GREEN}Manifest written: $MANIFEST_TOTAL file(s) total" \
        "(${MANIFEST_REUSED} inherited, ${MANIFEST_COMPUTED} hashed).${NC}"
    echo "To verify later: cd $SNAPSHOT && sha256sum --check .snapshot_manifest.sha256"

    # -----------------------------
    # COMPLETION MARKER
    # -----------------------------
    touch "$SNAPSHOT/$COMPLETE_MARKER"

    echo ""
    echo "======================================================"
    echo -e "${GREEN}Backup Completed Successfully${NC}"
    echo "======================================================"

    # -----------------------------
    # RETENTION (keep last RETENTION_COUNT completed snapshots)
    # -----------------------------
    echo ""
    echo "======================================================"
    echo "Retention"
    echo "======================================================"

    SNAPSHOT_NAME_PATTERN='^Backup_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$'

    for d in "$SNAPSHOT_ROOT"/Backup_*; do
        [ -d "$d" ] || continue
        [ -f "$d/$COMPLETE_MARKER" ] && continue
        name=$(basename "$d")
        if [[ ! "$name" =~ $SNAPSHOT_NAME_PATTERN ]]; then
            echo -e "${YELLOW}Skipping unexpected directory name (not deleting): $name${NC}"
            continue
        fi
        echo "Removing incomplete leftover snapshot: $name"
        rm -rf "${SNAPSHOT_ROOT:?}/$name"
    done

    COMPLETED_SNAPSHOTS=()
    for d in "$SNAPSHOT_ROOT"/Backup_*; do
        [ -d "$d" ] || continue
        [ -f "$d/$COMPLETE_MARKER" ] || continue
        COMPLETED_SNAPSHOTS+=("$(basename "$d")")
    done
    mapfile -t COMPLETED_SNAPSHOTS < <(printf '%s\n' "${COMPLETED_SNAPSHOTS[@]}" | sort)

    TOTAL_COMPLETED=${#COMPLETED_SNAPSHOTS[@]}
    echo "Completed snapshots on drive : $TOTAL_COMPLETED (keeping last $RETENTION_COUNT)"

    if [ "$TOTAL_COMPLETED" -gt "$RETENTION_COUNT" ]; then
        TO_REMOVE=$((TOTAL_COMPLETED - RETENTION_COUNT))
        echo "Removing $TO_REMOVE snapshot(s) beyond the retention limit:"
        for ((i = 0; i < TO_REMOVE; i++)); do
            old="${COMPLETED_SNAPSHOTS[$i]}"
            if [[ ! "$old" =~ $SNAPSHOT_NAME_PATTERN ]]; then
                echo -e "${YELLOW}Skipping unexpected directory name (not deleting): $old${NC}"
                continue
            fi
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
    echo "======================================================"

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
