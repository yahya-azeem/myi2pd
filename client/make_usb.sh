#!/bin/bash
# client/make_usb.sh - Write myi2pd amnesiac boot USB (host tool).
#
# Produces a SINGLE bootable USB stick that carries both pieces of the client:
#   partition 1  -> myi2pd-amnesiac.iso   (hybrid bootable OS image)
#   partition 2  -> myi2pd-ollama.squashfs (on-demand Ollama container image)
#
# The Ollama squashfs is deliberately kept OUT of the ISO: it is ~1.6 GB, far
# too big for the diskless 4G RAM root, so it stays as a plain read-only file
# on the stick, found on demand by /usr/local/bin/ai-extra.sh (which scans all
# /dev/sd* block devices for it). Keeping it as a separate partition means the
# squashfs can be updated/reburned without touching the boot ISO.
#
# Usage:
#   sudo make_usb.sh /dev/sdX <amnesiac.iso> <ollama.squashfs>
#   make_usb.sh --check              # list block devices (safe)
#   make_usb.sh ./usb.img  ...       # write to a regular file = loop device (VM/test)
#
# Will NOT run without an explicit device or --check.

set -euo pipefail

ISO="${2:-}"
SQUASH="${3:-}"

usage() {
    echo "Usage:"
    echo "  sudo $0 /dev/sdX <myi2pd-amnesiac.iso> <myi2pd-ollama.squashfs>"
    echo "  $0 --check"
    echo "  $0 ./usb.img <iso> <squashfs>        # file-backed (VM/test via loop)"
    exit "${1:-0}"
}

list_disks() {
    echo "== Removable / block devices (verify the device you are about to use) =="
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,MODEL 2>/dev/null \
        || lsblk -o NAME,SIZE,TYPE,LABEL
}

check_args() {
    [ "$#" -eq 3 ] || { echo "need device + iso + squashfs"; usage 1; }
    [ -f "$ISO" ]   || { echo "ISO not found: $ISO"; exit 1; }
    [ -f "$SQUASH" ] || { echo "squashfs not found: $SQUASH"; exit 1; }
    [ -f "$1" ] || [ -b "$1" ] \
        || { echo "target must be a block device or an existing file: $1"; exit 1; }
}

make_filesystem_image() {
    # Only used for the file-backed loop-device test path.
    local file="$1" size
    size="$(du -m "$SQUASH" | cut -f1)"
    # partitions: 1 = ~600MB ISO-ish placeholder (real ISO dd'd raw below),
    #             2 = squashfs + slack.
    local iso_mb=700
    local need_mb=$((iso_mb + size + 64))
    if [ -f "$file" ]; then
        truncate -s "${need_mb}M" "$file"
    fi
    # Leave a tiny gap; sgdisk used below.
    echo "$need_mb"
}

if [ "${1:-}" = "--check" ]; then
    list_disks
    exit 0
fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage 0
fi

DEV="$1"
check_args "$@"

echo "!! About to WIPE and repartition: $DEV  ($(du -h "$SQUASH" | cut -f1) squashfs)"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS "$DEV" 2>/dev/null || true
if [ -b "$DEV" ]; then
    echo -n "Type the device name again to confirm (/dev/...): "
    read -r ans
    [ "$ans" = "$DEV" ] || { echo "aborted."; exit 1; }
fi

# Ensure partitioning tools exist.
for t in sgdisk mkfs.vfat dd; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t"; exit 1; }
done

echo "== Wiping partition table =="
if [ -b "$DEV" ]; then
    umount "$DEV"?* 2>/dev/null || true
    sgdisk --zap-all "$DEV"
elif [ -f "$DEV" ]; then
    :
else
    echo "unsupported target"; exit 1
fi

# Create partition 1 (boot) and partition 2 (ollama). Sizes:
#   p1: 1 MiB minimum, but we dd the ISO over the whole first partition so the
#       ISO's own embedded partition table/hybrid MBR becomes authoritative for
#       booting. We size p1 generously to hold the expanded ISO media.
#   p2: squashfs + margin.
ISO_MB="$(du -m "$ISO" | cut -f1)"
P1_MB=$((ISO_MB + 64))
P2_BYTES=$(( ( $(du -m "$SQUASH" | cut -f1) + 64 ) * 1024 * 1024 ))

echo "== Creating partitions =="
sgdisk --clear \
       --new=1:0:+${P1_MB}M --typecode=1:ef00 --change-name=1:"MYI2PD-BOOT" \
       --new=2:0:0            --typecode=2:0700 --change-name=2:"MYI2PD-OLLAMA" \
       "$DEV"

sleep 1
partprobe "$DEV" 2>/dev/null || true

# Resolve partition device names (handles mmcblk0p1, nvme0n1p1, sdX1, and the
# GPT partition helpers for loop devices).
p1=""; p2=""
if [ -b "$DEV" ]; then
    # exact match on the /dev/mapper or partition sub-device
    p1="$(lsblk -lno PATH "$DEV" 2>/dev/null | sed -n '2p')"
    p2="$(lsblk -lno PATH "$DEV" 2>/dev/null | sed -n '3p')"
    p1="${p1:-${DEV}1}"   # fallback
    p2="${p2:-${DEV}2}"
else
    # file-backed loop: partition devices use a 'p' between (loop0p1)
    p1="${DEV}p1"; p2="${DEV}p2"
    losetup -Pf "$DEV" 2>/dev/null || true
    # retry after losetup
    sleep 1
fi

echo "== Writing boot ISO to $p1 (raw) =="
if [ -b "$p1" ]; then
    dd if="$ISO" of="$p1" bs=4M status=progress conv=fsync
else
    echo "WARNING: $p1 not a block device; ISO dd skipped (loop test only re-adds squashfs)"
fi

echo "== Formatting $p2 as vfat =="
if [ -b "$p2" ]; then
    mkfs.vfat -n MYI2PD-OLLAMA "$p2"
else
    echo "WARNING: $p2 not a block device; skipping format"
fi

echo "== Copying myi2pd-ollama.squashfs =="
if [ -b "$p2" ]; then
    md=$(mktemp -d)
    mount "$p2" "$md"
    cp "$SQUASH" "$md/myi2pd-ollama.squashfs"
    sync
    umount "$md"
    rmdir "$md" 2>/dev/null || true
fi

list_disks
echo
echo "Done. USB ready: $DEV"
echo "  Boot:  partitions on the stick (ISO hybrid MBR)."
echo "  AI:    ai-extra.sh will find $SQUASH on /${p2} automatically."