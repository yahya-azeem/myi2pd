#!/bin/bash
# test_pair.sh - Run VPS + Client ISOs side-by-side in QEMU with virtual LAN
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
VPS_ISO="$SCRIPT_DIR/../myi2pd-vps.iso"
CLIENT_ISO="$SCRIPT_DIR/../myi2pd-amnesiac.iso"
VPS_DISK="/tmp/myi2pd_vps_disk.img"
CLIENT_DISK="/tmp/myi2pd_client_disk.img"
SOCKET_DIR="/tmp/myi2pd-pair"

cleanup() {
    echo "Cleaning up..."
    kill %1 %2 2>/dev/null || true
    rm -rf "$SOCKET_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== myi2pd Pair Test ==="

if [ ! -f "$VPS_ISO" ]; then
    echo "ERROR: VPS ISO not found at $VPS_ISO"
    exit 1
fi
if [ ! -f "$CLIENT_ISO" ]; then
    echo "ERROR: Client ISO not found at $CLIENT_ISO"
    exit 1
fi

# Create disk images
for disk in "$VPS_DISK" "$CLIENT_DISK"; do
    [ -f "$disk" ] || qemu-img create -f raw "$disk" 1G >/dev/null
done

# Create socket directory
mkdir -p "$SOCKET_DIR"

# Common flags
KVM=""
[ -w /dev/kvm ] && KVM="-enable-kvm -cpu host"

echo "Starting VPS Gateway..."
qemu-system-x86_64 -m 512M \
  -cdrom "$VPS_ISO" -boot d \
  -drive "file=$VPS_DISK,format=raw" \
  -vga std -display none \
  -nic user,model=virtio-net-pci,hostfwd=tcp::4444-:4444,hostfwd=tcp::4447-:4447 \
  -nic socket,model=virtio-net-pci,listen=:12345 \
  -serial file:/tmp/myi2pd-vps-serial.log \
  $KVM &

echo "Waiting 60s for VPS to boot before starting client..."
sleep 60

echo "Starting Client..."
qemu-system-x86_64 -m 2G \
  -cdrom "$CLIENT_ISO" -boot d \
  -drive "file=$CLIENT_DISK,format=raw" \
  -vga std -display gtk \
  -nic socket,model=virtio-net-pci,connect=127.0.0.1:12345 \
  -usb -device usb-tablet -device usb-kbd \
  -serial file:/tmp/myi2pd-client-serial.log \
  $KVM &

echo ""
echo "=== Both VMs running ==="
echo "VPS serial: tail -f /tmp/myi2pd-vps-serial.log"
echo "Client serial: tail -f /tmp/myi2pd-client-serial.log"
echo "Press Ctrl+C to stop both VMs."
echo ""

wait
