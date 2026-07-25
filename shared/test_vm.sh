#!/bin/bash
# test_vm.sh - Automates testing the myi2pd-amnesiac.iso inside a local QEMU Virtual Machine

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ISO_PATH="$SCRIPT_DIR/../myi2pd-amnesiac.iso"
DISK_PATH="/tmp/myi2pd_dummy_disk.img"


echo "=== myi2pd QEMU VM Verification Runner ==="

# 1. Check for QEMU installation
if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "[ERROR] qemu-system-x86_64 is required but not installed."
    exit 1
fi

# 2. Check for target ISO file
if [ ! -f "$ISO_PATH" ]; then
    echo "[ERROR] ISO file not found at: $ISO_PATH"
    echo "Please build the ISO first by running client/build_iso.sh"
    exit 1
fi

# 3. Create dummy raw disk to test hdd-isolation block-level locks
if [ ! -f "$DISK_PATH" ]; then
    echo "Creating a 1 GB dummy raw disk for forensic read-only testing..."
    qemu-img create -f raw "$DISK_PATH" 1G
fi

# 4. QEMU configuration
QEMU_ARGS=("-m" "2G" "-cdrom" "$ISO_PATH" "-boot" "d" "-drive" "file=$DISK_PATH,format=raw" "-vga" "std" "-nic" "user,model=virtio-net-pci" "-display" "gtk" "-usb" "-device" "usb-tablet" "-device" "usb-kbd" "-serial" "file:/tmp/myi2pd-serial.log")

if [ -w /dev/kvm ]; then
    echo "[INFO] KVM hardware acceleration detected. Enabling KVM..."
    QEMU_ARGS+=("-enable-kvm" "-cpu" "host")
else
    echo "[WARNING] KVM is not available. Falling back to software emulation (slower)..."
    QEMU_ARGS+=("-cpu" "qemu64")
fi

echo "Launching virtual machine..."
echo "Press Super+Return in the VM to launch a console if needed."
echo "Press Ctrl+Alt+G to release mouse/keyboard focus from QEMU window."
echo ""

qemu-system-x86_64 "${QEMU_ARGS[@]}"

echo "Virtual machine session ended."
