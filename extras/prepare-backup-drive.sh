#!/bin/bash
# prepare-backup-drive.sh — Format and prepare a backup drive
# Run as: sudo bash prepare-backup-drive.sh
#
# This script:
#   1. Installs missing dependencies (partclone, pv, restic)
#   2. Validates the target device
#   3. Wipes existing partition table, creates GPT + ext4 partition
#   4. Adds noauto fstab entry for /mnt/backup
#   5. Creates directory structure and restore instructions
#
# Safety: Confirms device identity before any destructive operations.

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
# CHANGE THIS to your backup drive device (run `lsblk` to identify)
TARGET_DEVICE="/dev/sdd"
PARTITION="${TARGET_DEVICE}1"
LABEL="BACKUP"
MOUNT_POINT="/mnt/backup"
# Adjust expected size for your drive (in GB). Used for safety validation.
EXPECTED_SIZE_GB=931   # Approximate size in GB (931.5G for 1TB HDD)
SIZE_TOLERANCE_GB=50   # Allow +/- this variance in GB

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BLUE}${BOLD}── Step $1 ──${NC}"; }

# ─── Preflight ───────────────────────────────────────────────────────────────

# Must be root
[[ $EUID -ne 0 ]] && error "This script must be run as root: sudo bash $0"

# Device must exist
[[ ! -b "$TARGET_DEVICE" ]] && error "Device $TARGET_DEVICE not found. Is the drive connected?"

# ─── Step 1: Install Dependencies ────────────────────────────────────────────
step "1/8: Installing dependencies"

PACKAGES_TO_INSTALL=()
command -v partclone.ext4 &>/dev/null || PACKAGES_TO_INSTALL+=(partclone)
command -v pv             &>/dev/null || PACKAGES_TO_INSTALL+=(pv)
command -v restic         &>/dev/null || PACKAGES_TO_INSTALL+=(restic)
command -v pigz           &>/dev/null || PACKAGES_TO_INSTALL+=(pigz)

if [[ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]]; then
    info "Installing: ${PACKAGES_TO_INSTALL[*]}"
    apt-get update -qq
    apt-get install -y -qq "${PACKAGES_TO_INSTALL[@]}"
    info "Dependencies installed."
else
    info "All dependencies already installed."
fi

# Verify installations
for cmd in partclone.ext4 pv restic pigz; do
    command -v "$cmd" &>/dev/null || error "Failed to install $cmd"
done
info "Verified: partclone $(partclone.ext4 --version 2>&1 | head -1)"
info "Verified: restic $(restic version 2>&1 | head -1)"

# ─── Step 2: Validate Device ─────────────────────────────────────────────────
step "2/8: Validating target device"

# Show device info
echo ""
echo -e "${BOLD}Target device: $TARGET_DEVICE${NC}"
echo "────────────────────────────────────────"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$TARGET_DEVICE"
echo "────────────────────────────────────────"
echo ""

# Check size matches expected
DEVICE_SIZE_BYTES=$(lsblk -b -d -n -o SIZE "$TARGET_DEVICE")
DEVICE_SIZE_GB=$((DEVICE_SIZE_BYTES / 1073741824))

if [[ $DEVICE_SIZE_GB -lt $((EXPECTED_SIZE_GB - SIZE_TOLERANCE_GB)) ]] || \
   [[ $DEVICE_SIZE_GB -gt $((EXPECTED_SIZE_GB + SIZE_TOLERANCE_GB)) ]]; then
    error "Device size ${DEVICE_SIZE_GB}GB doesn't match expected ~${EXPECTED_SIZE_GB}GB. Wrong device?"
fi
info "Device size: ${DEVICE_SIZE_GB}GB (expected ~${EXPECTED_SIZE_GB}GB)"

# Check not mounted
if mount | grep -q "^${TARGET_DEVICE}"; then
    error "$TARGET_DEVICE is currently mounted. Unmount first: sudo umount ${TARGET_DEVICE}*"
fi
if mount | grep -q "^${PARTITION}"; then
    error "$PARTITION is currently mounted. Unmount first: sudo umount ${PARTITION}"
fi
info "Device is not mounted"

# Check it's not the system drive
SYSTEM_DEVICE=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
if [[ "$TARGET_DEVICE" == "$SYSTEM_DEVICE" ]]; then
    error "$TARGET_DEVICE is the system drive! Aborting."
fi
info "Not the system drive"

# ─── Step 3: Confirmation ────────────────────────────────────────────────────
step "3/8: Confirmation"

echo ""
echo -e "${RED}${BOLD}WARNING: ALL DATA ON $TARGET_DEVICE WILL BE DESTROYED${NC}"
echo ""
echo "  This will:"
echo "    1. Wipe the existing partition table"
echo "    2. Create a new GPT partition table"
echo "    3. Create a single ext4 partition labeled '$LABEL'"
echo ""
read -p "Type 'YES' to proceed: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && { echo "Aborted."; exit 0; }

# ─── Step 4: Partition and Format ─────────────────────────────────────────────
step "4/8: Partitioning and formatting"

info "Wiping existing partition table..."
wipefs -a "$TARGET_DEVICE"

info "Creating GPT partition table..."
parted -s "$TARGET_DEVICE" mklabel gpt

info "Creating ext4 partition (full disk)..."
parted -s "$TARGET_DEVICE" mkpart primary ext4 1MiB 100%

# Wait for kernel to recognize new partition
sleep 2
partprobe "$TARGET_DEVICE"
sleep 1

# Verify partition exists
[[ ! -b "$PARTITION" ]] && error "Partition $PARTITION not found after partitioning"

info "Formatting as ext4 with label '$LABEL'..."
mkfs.ext4 -L "$LABEL" "$PARTITION"

info "Partition created and formatted"

# ─── Step 5: Get UUID and Configure fstab ─────────────────────────────────────
step "5/8: Configuring fstab"

# Get the UUID
UUID=$(blkid -s UUID -o value "$PARTITION")
[[ -z "$UUID" ]] && error "Could not determine UUID of $PARTITION"
info "Partition UUID: $UUID"

# Check if fstab already has an entry for /mnt/backup
if grep -q "$MOUNT_POINT" /etc/fstab; then
    warn "fstab already has an entry for $MOUNT_POINT — updating it"
    sed -i "\|$MOUNT_POINT|d" /etc/fstab
fi

# Add noauto fstab entry
FSTAB_LINE="UUID=$UUID  $MOUNT_POINT  ext4  defaults,noauto  0  2"
echo "$FSTAB_LINE" >> /etc/fstab
info "Added fstab entry (noauto — won't mount at boot):"
echo "  $FSTAB_LINE"

# ─── Step 6: Create Mount Point and Mount ─────────────────────────────────────
step "6/8: Mounting drive"

mkdir -p "$MOUNT_POINT"
mount "$MOUNT_POINT"

if mountpoint -q "$MOUNT_POINT"; then
    info "Mounted at $MOUNT_POINT"
else
    error "Failed to mount $MOUNT_POINT"
fi

# ─── Step 7: Create Directory Structure ───────────────────────────────────────
step "7/8: Creating directory structure"

mkdir -p "$MOUNT_POINT"/{images,scripts,logs,recovery}
chown -R ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} "$MOUNT_POINT"
info "Created: images/ scripts/ logs/ recovery/"

# Write restore instructions to the drive
cat > "$MOUNT_POINT/RESTORE-INSTRUCTIONS.md" << 'RESTORE_EOF'
# System Restoration Instructions

**Backup Tool:** dd + pigz (compressed partition images)

---

## Scenario 1: System Drive Failed — Restore to New Drive

### Requirements
- New drive (same size or larger recommended)
- Clonezilla or Rescuezilla live USB (or Ubuntu live USB + partclone)
- This backup drive

### Steps

1. **Boot from live USB** (Clonezilla, Rescuezilla, or Ubuntu)
   - Connect new drive and this backup drive
   - Boot from USB (F12/F2 at startup)

2. **If using Clonezilla/Rescuezilla:**
   - Choose: device-image > local_dev > select this drive
   - Choose: restoredisk > select most recent image
   - Select target: new drive > confirm

3. **If using partclone manually (from Ubuntu live USB):**
   ```bash
   # Install partclone if needed
   sudo apt install partclone pigz pv

   # Mount this backup drive
   sudo mkdir -p /mnt/backup
   sudo mount /dev/sdX1 /mnt/backup   # Replace X with backup drive

   # Find latest backup
   ls -lt /mnt/backup/images/

   # Recreate partition table on new drive
   sudo sfdisk /dev/sdY < /mnt/backup/images/*-partition-table-YYYYMMDD.txt

   # Restore EFI partition
   gunzip -c /mnt/backup/images/*-efi-YYYYMMDD.img.gz | \
     sudo partclone.restore -o /dev/sdY1

   # Restore root partition
   gunzip -c /mnt/backup/images/*-root-YYYYMMDD.img.gz | \
     pv | sudo partclone.restore -o /dev/sdY2
   ```

4. **Fix boot (if needed):**
   ```bash
   sudo mount /dev/sdY2 /mnt
   sudo mount /dev/sdY1 /mnt/boot/efi
   sudo mount --bind /dev /mnt/dev
   sudo mount --bind /proc /mnt/proc
   sudo mount --bind /sys /mnt/sys
   sudo chroot /mnt
   grub-install /dev/sdY
   update-grub
   exit
   sudo umount -R /mnt
   reboot
   ```

5. **Post-restore checks:**
   - Verify Docker services start: `cd /path/to/docker && docker compose up -d`
   - Check all mounts: `mount -a`
   - Verify drives: `lsblk`

---

## Scenario 2: Restore Individual Files

```bash
# Mount the backup image (from running system)
sudo apt install partclone
mkdir /tmp/restore
gunzip -c /mnt/backup/images/*-root-YYYYMMDD.img.gz | \
  sudo partclone.restore -o /tmp/system.img
sudo mount -o loop,ro /tmp/system.img /tmp/restore

# Browse and copy needed files
ls /tmp/restore/home/
ls /tmp/restore/var/lib/docker/

# Cleanup when done
sudo umount /tmp/restore
rm /tmp/system.img
```

---

## Scenario 3: Migrate to New Hardware

Same as Scenario 1, then:

1. Update `/etc/fstab` if drive UUIDs changed
2. Regenerate initramfs: `sudo update-initramfs -u`
3. Update GRUB: `sudo update-grub`
4. Check network interfaces (may have new names)
5. Update any hardware-specific Docker configs

---

## Quick Reference

```bash
# Mount this backup drive
sudo mount /mnt/backup

# List backups (newest first)
ls -lht /mnt/backup/images/

# View latest backup log
cat /mnt/backup/logs/$(ls -t /mnt/backup/logs/ 2>/dev/null | head -1)

# Check drive health
sudo smartctl -a /dev/sdX   # Replace X with backup drive letter
```
RESTORE_EOF

chown ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} "$MOUNT_POINT/RESTORE-INSTRUCTIONS.md"
info "Wrote RESTORE-INSTRUCTIONS.md to drive"

# ─── Step 8: Summary ─────────────────────────────────────────────────────────
step "8/8: Summary"

echo ""
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Backup drive prepared successfully!${NC}"
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  Device:     $TARGET_DEVICE"
echo "  Partition:  $PARTITION"
echo "  Filesystem: ext4"
echo "  Label:      $LABEL"
echo "  UUID:       $UUID"
echo "  Mount:      $MOUNT_POINT"
echo "  fstab:      noauto (mount manually with: sudo mount /mnt/backup)"
echo ""
echo "  Directory structure:"
ls -la "$MOUNT_POINT" | grep -v '^\.\|total'
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "    1. Run initial backup:  sudo /path/to/extras/system-backup.sh"
echo "    2. Set up weekly cron:  see README for cron examples"
echo "    3. Optionally copy Clonezilla/Rescuezilla ISOs to /mnt/backup/recovery/"
echo ""

# Show disk usage
df -h "$MOUNT_POINT"
echo ""

# Verify everything
info "Verification:"
echo "  lsblk:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID "$TARGET_DEVICE"
echo ""
echo "  Installed tools:"
echo "    partclone: $(partclone.ext4 --version 2>&1 | head -1)"
echo "    restic:    $(restic version 2>&1)"
echo "    pigz:      $(pigz --version 2>&1)"
echo "    pv:        $(pv --version 2>&1 | head -1)"
