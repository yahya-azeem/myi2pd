#!/bin/bash
# run_pair_test.sh - Headless pair test runner
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
VPS_SERIAL="/tmp/myi2pd-vps-serial.log"
CLIENT_SERIAL="/tmp/myi2pd-client-serial.log"
VPS_DISK="/tmp/myi2pd_vps_disk.img"
CLIENT_DISK="/tmp/myi2pd_client_disk.img"
SOCKET_DIR="/tmp/myi2pd-pair"

cleanup() {
    echo "Cleaning up..."
    kill $VPS_PID $CLIENT_PID 2>/dev/null || true
    rm -rf "$SOCKET_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== myi2pd Pair Test (headless) ==="

rm -f "$VPS_SERIAL" "$CLIENT_SERIAL"
for disk in "$VPS_DISK" "$CLIENT_DISK"; do
    [ -f "$disk" ] || qemu-img create -f raw "$disk" 1G >/dev/null
done

KVM=""
[ -w /dev/kvm ] && KVM="-enable-kvm -cpu host"

echo "Starting VPS..."
qemu-system-x86_64 -m 512M \
  -cdrom "$SCRIPT_DIR/../myi2pd-vps.iso" -boot d \
  -drive "file=$VPS_DISK,format=raw" \
  -vga std -display none \
  -nic user,model=virtio-net-pci,hostfwd=tcp::4444-:4444,hostfwd=tcp::4447-:4447,hostfwd=tcp::7070-:7070 \
  -nic socket,model=virtio-net-pci,listen=:12345 \
  -serial "file:$VPS_SERIAL" \
  $KVM &
VPS_PID=$!

echo "Wait 60s for VPS boot..."
sleep 60

echo "Starting Client..."
qemu-system-x86_64 -m 2G \
  -cdrom "$SCRIPT_DIR/../myi2pd-amnesiac.iso" -boot d \
  -drive "file=$CLIENT_DISK,format=raw" \
  -vga std -display none \
  -nic socket,model=virtio-net-pci,connect=127.0.0.1:12345 \
  -serial "file:$CLIENT_SERIAL" \
  $KVM &
CLIENT_PID=$!

echo "=== Both VMs running ==="
echo "VPS PID: $VPS_PID  Client PID: $CLIENT_PID"
echo "VPS serial:  tail -f $VPS_SERIAL"
echo "Client serial: tail -f $CLIENT_SERIAL"
echo "Press Ctrl+C to stop."

wait
