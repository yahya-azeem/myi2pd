#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "=== Starting VPS gateway (background) ==="
qemu-img create -f raw /tmp/vps-disk.img 1G 2>/dev/null
qemu-system-x86_64 -m 512M -enable-kvm -cpu host \
  -cdrom myi2pd-vps.iso -boot d \
  -drive file=/tmp/vps-disk.img,format=raw \
  -nic user,model=virtio-net-pci,hostfwd=tcp::4444-:4444,hostfwd=tcp::4447-:4447,hostfwd=tcp::7070-:7070 \
  -nic socket,model=virtio-net-pci,listen=:12345 \
  -serial file:/tmp/vps-serial.log \
  -nographic &
VPS_PID=$!

echo "Waiting for VPS socket :12345..."
for i in $(seq 1 30); do
  ss -tlnp | grep -q :12345 && break
  sleep 2
done

echo "=== Starting Client GUI ==="
qemu-img create -f raw /tmp/client-disk.img 1G 2>/dev/null
qemu-system-x86_64 -m 2G -enable-kvm -cpu host \
  -cdrom myi2pd-amnesiac.iso -boot d \
  -drive file=/tmp/client-disk.img,format=raw \
  -vga std -display gtk -usb -device usb-tablet \
  -nic socket,model=virtio-net-pci,connect=127.0.0.1:12345

echo "=== Client closed, shutting down VPS ==="
kill $VPS_PID 2>/dev/null || true
