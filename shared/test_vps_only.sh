#!/bin/bash
# test_vps_only.sh - Run just the VPS ISO for long enough to check tunnel building
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
VPS_ISO="$SCRIPT_DIR/../myi2pd-vps.iso"
VPS_DISK="/tmp/myi2pd_vps_disk.img"
DURATION=${1:-1800}  # default 30 minutes
SERIAL_LOG="/tmp/myi2pd-vps-serial.log"

[ -f "$VPS_ISO" ] || { echo "VPS ISO not found"; exit 1; }
[ -f "$VPS_DISK" ] || qemu-img create -f raw "$VPS_DISK" 512M >/dev/null
> "$SERIAL_LOG"

KVM=""
[ -w /dev/kvm ] && KVM="-enable-kvm -cpu host"

echo "=== Starting VPS-only test for ${DURATION}s ==="
date -u

qemu-system-x86_64 -m 384M \
  -cdrom "$VPS_ISO" -boot d \
  -drive "file=$VPS_DISK,format=raw" \
  -vga std -display none \
  -nic user,model=virtio-net-pci,hostfwd=tcp::4444-:4444,hostfwd=tcp::4447-:4447 \
  -serial file:"$SERIAL_LOG" \
  $KVM &
QEMU_PID=$!

echo "VPS PID: $QEMU_PID"
echo "Log: $SERIAL_LOG"

# Monitor for duration
END=$((SECONDS + DURATION))
while [ $SECONDS -lt $END ]; do
  sleep 60
  ELAPSED=$((SECONDS))
  echo "[${ELAPSED}s] Checking..."
  tail -5 "$SERIAL_LOG" 2>/dev/null
done

echo "=== Stopping VPS ==="
kill $QEMU_PID 2>/dev/null
wait $QEMU_PID 2>/dev/null || true

echo "=== Test complete ==="
echo "=== Last 100 lines of log ==="
tail -100 "$SERIAL_LOG"

echo "=== Stats ==="
grep -i "tunnel\|build\|firewall\|peer\|SSU" "$SERIAL_LOG" 2>/dev/null | tail -30
date -u
