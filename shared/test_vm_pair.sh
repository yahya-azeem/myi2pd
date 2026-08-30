#!/bin/bash
set -e

RUN_CLIENT=true
RUN_SERVER=true
CLIENT_LOG="/tmp/client_serial.log"
VPS_LOG="/tmp/vps_serial.log"

for arg in "$@"; do
    case $arg in
        --server-only) RUN_CLIENT=false ;;
        --client-only) RUN_SERVER=false ;;
        --use-prebuilt-vps) USE_PREBUILT_VPS=true ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
ISO_PATH="$PROJECT_ROOT/myi2pd-amnesiac.iso"
VPS_ISO_PATH="$PROJECT_ROOT/myi2pd-vps.iso"
VPS_QCOW2="/tmp/myi2pd-vps.qcow2"

echo "=== myi2pd QEMU VM Test (Pre-built ISOs) ==="

[ "$RUN_CLIENT" = false ] || [ -f "$ISO_PATH" ] || { echo "ERROR: Client ISO not found at $ISO_PATH"; exit 1; }
[ "$RUN_SERVER" = false ] || [ -f "$VPS_ISO_PATH" ] || { echo "ERROR: VPS ISO not found at $VPS_ISO_PATH"; exit 1; }

# Convert VPS ISO to QCOW2 for faster boot
if [ "$RUN_SERVER" = true ]; then
    if [ ! -f "$VPS_QCOW2" ]; then
        echo "Converting VPS ISO to QCOW2..."
        qemu-img convert -f raw -O qcow2 "$VPS_ISO_PATH" "$VPS_QCOW2"
        qemu-img resize "$VPS_QCOW2" 2G &>/dev/null
    fi
fi

ACCEL_ARGS=("-cpu" "qemu64")
if [ -w /dev/kvm ]; then
    echo "KVM enabled"
    ACCEL_ARGS=("-enable-kvm" "-cpu" "host")
fi

# Headless mode for CI/headless environments
DISPLAY_ARGS=("-nographic")
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    DISPLAY_ARGS=("-vga" "std" "-display" "gtk")
fi

VPS_PID=""

if [ "$RUN_SERVER" = true ]; then
    echo "Starting VPS Gateway from pre-built ISO..."
    rm -f "$VPS_LOG"
    qemu-system-x86_64 "${ACCEL_ARGS[@]}" -m 1G \
        -drive file="$VPS_QCOW2",format=qcow2 \
        -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
        -netdev socket,id=net1,listen=:12345 -device virtio-net-pci,netdev=net1 \
        "${DISPLAY_ARGS[@]}" \
        -serial file:"$VPS_LOG" &
    VPS_PID=$!
echo "Waiting for VPS to finish booting (polling serial log)..."
        for i in $(seq 1 180); do
            grep -q "Welcome to Alpine Linux" "$VPS_LOG" 2>/dev/null && break
            sleep 2
        done
        echo "VPS booted, waiting for services to start..."
        sleep 30
fi

if [ "$RUN_CLIENT" = true ]; then
    rm -f "$CLIENT_LOG"
    echo "Starting Client ISO from pre-built ISO..."
    qemu-system-x86_64 "${ACCEL_ARGS[@]}" -m 1G \
        -cdrom "$ISO_PATH" -boot d \
        -netdev socket,id=net0,connect=127.0.0.1:12345 -device virtio-net-pci,netdev=net0 \
        "${DISPLAY_ARGS[@]}" \
        -serial file:"$CLIENT_LOG"
fi

if [ -n "$VPS_PID" ]; then
    echo "Terminating VPS..."
    kill -9 "$VPS_PID" 2>/dev/null || true
fi

echo ""
echo "======= VPS Boot Log ======="
[ -f "$VPS_LOG" ] && cat "$VPS_LOG" || echo "(no log)"
echo "======= End VPS Log ======="
echo ""
echo "======= Client Boot Log ======="
[ -f "$CLIENT_LOG" ] && cat "$CLIENT_LOG" || echo "(no log)"
echo "======= End Client Log ======="

rm -f "$VPS_LOG" "$CLIENT_LOG" 2>/dev/null
echo "=== Test ended ==="