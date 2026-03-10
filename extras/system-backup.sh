#!/bin/bash
# system-backup.sh — Weekly full system image backup
# Creates compressed dd images of the system drive to /mnt/backup
#
# Usage:
#   sudo bash system-backup.sh          # Interactive (confirms before stopping Docker)
#   sudo bash system-backup.sh --yes    # Non-interactive (for cron)
#   sudo bash system-backup.sh --dry-run # Show what would happen (no changes)
#
# Schedule: Sunday 4 AM via cron
#   0 4 * * 0 /path/to/system-backup.sh --yes
#
# IMPORTANT: Update SRC_DISK, SRC_EFI, SRC_ROOT to match YOUR system's partitions.
# Run `lsblk` to identify your drive layout.
#
# Example layout (common for UEFI systems):
#   /dev/sda  (512GB SSD)
#   ├─ /dev/sda1 (EFI partition, ~512MB, vfat)
#   └─ /dev/sda2 (root partition, remaining space, ext4)

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
BACKUP_MOUNT="/mnt/backup"
BACKUP_DIR="$BACKUP_MOUNT/images"
LOG_DIR="$BACKUP_MOUNT/logs"
SCRIPT_DIR="$BACKUP_MOUNT/scripts"
DATE=$(date +%Y%m%d-%H%M)
RETENTION_DAYS=21          # Keep 3 weeks of backups
MIN_SPACE_GB=200           # Minimum free space required on backup drive
DOCKER_DIR="${DOCKER_DIR:-/path/to/docker-compose-directory}"
LOCK_FILE="/tmp/system-backup.lock"

# Source drive partitions — CHANGE THESE to match your system
# Run `lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS` to identify your layout
SRC_DISK="/dev/sda"        # Example: your system disk
SRC_EFI="/dev/sda1"        # Example: EFI partition
SRC_ROOT="/dev/sda2"       # Example: root partition

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Logging ─────────────────────────────────────────────────────────────────
log()   { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"; }

die() {
    error "$1"
    cleanup
    exit 1
}

# ─── State tracking ─────────────────────────────────────────────────────────
DOCKER_STOPPED=false
MONITOR_PID=""

# ─── Progress Monitor ──────────────────────────────────────────────────────
# Runs in background, polls dd's read position via /proc to show live progress
progress_monitor() {
    local output_file="$1"
    local total_bytes="$2"
    local dd_pid="$3"
    local start_epoch="$4"
    local label="$5"
    local interval="${6:-30}"

    sleep 10  # Let dd get going

    while kill -0 "$dd_pid" 2>/dev/null; do
        local now elapsed read_pos
        now=$(date +%s)
        elapsed=$((now - start_epoch))
        [[ $elapsed -lt 1 ]] && { sleep "$interval"; continue; }

        # Read dd's file offset from /proc
        read_pos=$(awk '/^pos:/ {print $2}' "/proc/$dd_pid/fdinfo/0" 2>/dev/null) || { sleep "$interval"; continue; }

        local pct read_gb total_gb comp_size speed_mb eta_min elapsed_str
        pct=$(awk "BEGIN {printf \"%.1f\", ($read_pos / $total_bytes) * 100}")
        read_gb=$(awk "BEGIN {printf \"%.1f\", $read_pos / 1073741824}")
        total_gb=$(awk "BEGIN {printf \"%.0f\", $total_bytes / 1073741824}")
        comp_size=$(du -h "$output_file" 2>/dev/null | cut -f1)
        speed_mb=$(awk "BEGIN {printf \"%.0f\", ($read_pos / $elapsed) / 1048576}")

        # ETA from raw bytes remaining
        local bps=$((read_pos / elapsed))
        if [[ $bps -gt 0 ]]; then
            eta_min=$(( (total_bytes - read_pos) / bps / 60 ))
        else
            eta_min="?"
        fi

        elapsed_str="$(( elapsed / 60 ))m$(printf '%02d' $(( elapsed % 60 )))s"

        log "  [$label] ${pct}% (${read_gb}/${total_gb}GB) | ${comp_size} compressed | ${speed_mb} MB/s | ${elapsed_str} elapsed | ETA ~${eta_min}m"

        sleep "$interval"
    done
}

stop_monitor() {
    if [[ -n "${MONITOR_PID:-}" ]]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        MONITOR_PID=""
    fi
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup() {
    stop_monitor
    if [[ "$DOCKER_STOPPED" == "true" ]]; then
        echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] Ensuring Docker services are restarted...${NC}"
        cd "$DOCKER_DIR"
        docker compose up -d 2>&1 | tail -5
        sleep 15
        local running
        running=$(docker ps -q 2>/dev/null | wc -l)
        echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} Docker containers running: $running"
    fi
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# ─── Parse args ──────────────────────────────────────────────────────────────
AUTO_YES=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=true ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

# ─── Preflight checks ───────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "This script must be run as root: sudo $0"

# Lock file to prevent concurrent runs
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        die "Another backup is already running (PID $LOCK_PID)"
    else
        warn "Stale lock file found, removing"
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"

# Verify source drive exists
[[ ! -b "$SRC_DISK" ]] && die "Source drive $SRC_DISK not found"
[[ ! -b "$SRC_EFI" ]]  && die "EFI partition $SRC_EFI not found"
[[ ! -b "$SRC_ROOT" ]] && die "Root partition $SRC_ROOT not found"

# Mount backup drive if not mounted
if ! mountpoint -q "$BACKUP_MOUNT"; then
    log "Mounting backup drive..."
    mount "$BACKUP_MOUNT" || die "Failed to mount $BACKUP_MOUNT — is the drive connected?"
fi

# Create directories
mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$SCRIPT_DIR"

# Start logging to file
LOG_FILE="$LOG_DIR/backup-$DATE.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "═══════════════════════════════════════════════════"
log "  System Backup Started"
log "═══════════════════════════════════════════════════"
log "Source: $SRC_DISK"
log "Target: $BACKUP_DIR"
log "Date:   $DATE"

# Check available space
AVAIL_KB=$(df -k "$BACKUP_MOUNT" | tail -1 | awk '{print $4}')
AVAIL_GB=$((AVAIL_KB / 1048576))
if [[ $AVAIL_GB -lt $MIN_SPACE_GB ]]; then
    die "Insufficient space: ${AVAIL_GB}GB available, ${MIN_SPACE_GB}GB required"
fi
log "Available space: ${AVAIL_GB}GB"

# Check required tools
for cmd in dd pigz sfdisk blockdev; do
    command -v "$cmd" &>/dev/null || die "Missing required tool: $cmd"
done

# ─── Dry Run ──────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
    PART_BYTES=$(blockdev --getsize64 "$SRC_ROOT")
    EFI_BYTES=$(blockdev --getsize64 "$SRC_EFI")
    USED_GB=$(df -BG / | tail -1 | awk '{print $3}' | tr -d 'G')
    PART_GB=$(( PART_BYTES / 1073741824 ))
    DOCKER_COUNT=$(docker ps -q 2>/dev/null | wc -l)
    # Estimate: ~0.68 compression ratio on used data
    EST_ROOT_GB=$(( USED_GB * 68 / 100 ))
    EXISTING=$(find "$BACKUP_DIR" -name "*-root-*.img.gz" 2>/dev/null | wc -l)

    log ""
    log "═══════════════════════════════════════════════════"
    log "  DRY RUN — No changes will be made"
    log "═══════════════════════════════════════════════════"
    log "  Source disk:     $SRC_DISK"
    log "  EFI partition:   $SRC_EFI ($(( EFI_BYTES / 1048576 ))MB)"
    log "  Root partition:  $SRC_ROOT (${PART_GB}GB, ${USED_GB}GB used)"
    log "  Backup target:   $BACKUP_DIR"
    log "  Free space:      ${AVAIL_GB}GB"
    log "  Existing backups: $EXISTING"
    log ""
    log "  Would stop:      $DOCKER_COUNT Docker containers"
    log "  Est. EFI image:  ~5MB compressed"
    log "  Est. root image: ~${EST_ROOT_GB}GB compressed"
    log "  Est. duration:   ~60-90 minutes"
    log "  Retention:       $RETENTION_DAYS days"
    log "═══════════════════════════════════════════════════"
    rm -f "$LOCK_FILE"
    exit 0
fi

# ─── Confirmation (interactive mode only) ────────────────────────────────────
if [[ "$AUTO_YES" != "true" ]]; then
    echo ""
    echo -e "${YELLOW}${BOLD}This will stop ALL Docker containers during the backup.${NC}"
    echo -e "Estimated time: 30-60 minutes (HDD speed)"
    echo ""
    read -p "Proceed? [y/N] " -r
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log "Aborted by user."; exit 0; }
fi

# ─── Stop Docker ─────────────────────────────────────────────────────────────
log "Stopping Docker services..."
DOCKER_START_TIME=$SECONDS

cd "$DOCKER_DIR"
docker compose stop 2>&1 | tail -5
DOCKER_STOPPED=true
sleep 5

# Verify Docker stopped
RUNNING=$(docker ps -q 2>/dev/null | wc -l)
if [[ $RUNNING -gt 0 ]]; then
    warn "$RUNNING containers still running — waiting 10 more seconds..."
    sleep 10
    RUNNING=$(docker ps -q 2>/dev/null | wc -l)
    [[ $RUNNING -gt 0 ]] && warn "$RUNNING containers STILL running — proceeding anyway"
fi
log "Docker stopped (${RUNNING} containers remaining)"

# Sync filesystem caches to disk
log "Syncing filesystem..."
sync

# ─── Backup EFI Partition ────────────────────────────────────────────────────
EFI_LABEL=$(basename "$SRC_EFI")
log "Backing up EFI partition ($SRC_EFI)..."
EFI_START=$SECONDS

dd if="$SRC_EFI" bs=4M status=none 2>>"$LOG_FILE" | pigz -c > "$BACKUP_DIR/${EFI_LABEL}-efi-$DATE.img.gz"

EFI_SIZE=$(ls -lh "$BACKUP_DIR/${EFI_LABEL}-efi-$DATE.img.gz" | awk '{print $5}')
EFI_ELAPSED=$((SECONDS - EFI_START))
log "EFI backup complete: $EFI_SIZE (${EFI_ELAPSED}s)"

# ─── Backup Root Partition ───────────────────────────────────────────────────
ROOT_LABEL=$(basename "$SRC_ROOT")
log "Backing up root partition ($SRC_ROOT)..."
ROOT_START=$SECONDS

# Get full partition size for progress (dd reads all blocks, not just used)
PART_BYTES=$(blockdev --getsize64 "$SRC_ROOT")
PART_GB=$(( PART_BYTES / 1073741824 ))
USED_GB=$(df -BG / | tail -1 | awk '{print $3}' | tr -d 'G')
log "  Partition: ${PART_GB}GB total, ${USED_GB}GB used — expect ~60-90 minutes on HDD"

# Run pipeline in background so we can monitor progress
dd if="$SRC_ROOT" bs=4M status=none 2>>"$LOG_FILE" | pigz -c > "$BACKUP_DIR/${ROOT_LABEL}-root-$DATE.img.gz" &
PIPELINE_PID=$!

# Find dd's PID and start progress monitor
sleep 2
DD_PID=$(pgrep -f "dd if=$SRC_ROOT" 2>/dev/null | head -1) || true
if [[ -n "$DD_PID" ]]; then
    progress_monitor "$BACKUP_DIR/${ROOT_LABEL}-root-$DATE.img.gz" "$PART_BYTES" "$DD_PID" "$(date +%s)" "root" 30 &
    MONITOR_PID=$!
fi

# Wait for pipeline to complete
wait "$PIPELINE_PID"
stop_monitor

ROOT_SIZE=$(ls -lh "$BACKUP_DIR/${ROOT_LABEL}-root-$DATE.img.gz" | awk '{print $5}')
ROOT_ELAPSED=$((SECONDS - ROOT_START))
ROOT_MINS=$((ROOT_ELAPSED / 60))
log "Root backup complete: $ROOT_SIZE (${ROOT_MINS}m ${ROOT_ELAPSED}s total)"

# ─── Save Partition Table ────────────────────────────────────────────────────
DISK_LABEL=$(basename "$SRC_DISK")
log "Saving partition table..."
sfdisk -d "$SRC_DISK" > "$BACKUP_DIR/${DISK_LABEL}-partition-table-$DATE.txt"

# ─── Create Manifest ─────────────────────────────────────────────────────────
log "Creating backup manifest..."
cat > "$BACKUP_DIR/manifest-$DATE.txt" << EOF
System Backup Manifest
======================
Date:     $(date)
Hostname: $(hostname)
Kernel:   $(uname -r)
OS:       $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)

Source Drive: $SRC_DISK ($(lsblk -d -n -o SIZE "$SRC_DISK"))
  $SRC_EFI (EFI):  $(lsblk -n -o SIZE "$SRC_EFI" | tr -d ' ')  UUID=$(lsblk -n -o UUID "$SRC_EFI" | tr -d ' ')
  $SRC_ROOT (root): $(lsblk -n -o SIZE "$SRC_ROOT" | tr -d ' ')  UUID=$(lsblk -n -o UUID "$SRC_ROOT" | tr -d ' ')

Disk Usage at Backup:
$(df -h / /boot/efi | tail -2)

Backup Files:
  EFI:   ${EFI_LABEL}-efi-$DATE.img.gz   ($EFI_SIZE)
  Root:  ${ROOT_LABEL}-root-$DATE.img.gz  ($ROOT_SIZE)
  Table: ${DISK_LABEL}-partition-table-$DATE.txt

Docker Info:
  Containers: $(docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l) total
  Images:     $(docker images -q 2>/dev/null | sort -u | wc -l) unique
  Volumes:    $(docker volume ls -q 2>/dev/null | wc -l)

Backup Duration:
  EFI:    ${EFI_ELAPSED}s
  Root:   ${ROOT_ELAPSED}s (${ROOT_MINS}m)
  Total:  $((SECONDS - DOCKER_START_TIME))s
EOF

# ─── Restart Docker ──────────────────────────────────────────────────────────
log "Restarting Docker services..."
cd "$DOCKER_DIR"
docker compose up -d 2>&1 | tail -5
DOCKER_STOPPED=false
sleep 15

RUNNING=$(docker ps -q 2>/dev/null | wc -l)
log "Docker containers running: $RUNNING"

# ─── Cleanup Old Backups ─────────────────────────────────────────────────────
log "Cleaning up backups older than $RETENTION_DAYS days..."
OLD_COUNT=0
while IFS= read -r -d '' file; do
    rm -f "$file"
    ((OLD_COUNT++)) || true
done < <(find "$BACKUP_DIR" \( -name "*.img.gz" -o -name "manifest-*.txt" -o -name "*-partition-table-*.txt" \) -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)

# Clean old logs too
while IFS= read -r -d '' file; do
    rm -f "$file"
    ((OLD_COUNT++)) || true
done < <(find "$LOG_DIR" -name "backup-*.log" -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)

if [[ $OLD_COUNT -gt 0 ]]; then
    log "Removed $OLD_COUNT old backup files"
else
    log "No old backups to clean up"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
TOTAL_ELAPSED=$((SECONDS))
TOTAL_MINS=$((TOTAL_ELAPSED / 60))
BACKUP_TOTAL=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
AVAIL_AFTER=$(df -h "$BACKUP_MOUNT" | tail -1 | awk '{print $4}')

log ""
log "═══════════════════════════════════════════════════"
log "  Backup Complete!"
log "═══════════════════════════════════════════════════"
log "  EFI image:   $EFI_SIZE"
log "  Root image:  $ROOT_SIZE"
log "  Total used:  $BACKUP_TOTAL"
log "  Space left:  $AVAIL_AFTER"
log "  Duration:    ${TOTAL_MINS}m ${TOTAL_ELAPSED}s"
log "  Docker:      $RUNNING containers running"
log "  Log:         $LOG_FILE"
log "═══════════════════════════════════════════════════"
