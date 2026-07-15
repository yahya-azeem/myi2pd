#!/bin/bash
# test_vm_pair.sh - Boots both the Amnesiac Client ISO and the Hardened VPS Gateway VM locally in QEMU.

set -e

RUN_CLIENT=true
RUN_SERVER=true

for arg in "$@"; do
    case $arg in
        --server-only)
            RUN_CLIENT=false
            RUN_SERVER=true
            ;;
        --client-only)
            RUN_CLIENT=true
            RUN_SERVER=false
            ;;
        *)
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
ISO_PATH="$PROJECT_ROOT/myi2pd-amnesiac.iso"
BASE_QCOW2="/tmp/alpine-cloud-base.qcow2"
VPS_QCOW2="/tmp/myi2pd-vps.qcow2"
CIDATA_DIR="/tmp/myi2pd_cidata_dir"
CIDATA_ISO="/tmp/myi2pd_cidata.iso"

echo "=== myi2pd QEMU Local VM Tester ==="

# 1. Verification checks
if [ "$RUN_CLIENT" = true ]; then
    if [ ! -f "$ISO_PATH" ]; then
        echo "[ERROR] Client ISO not found at: $ISO_PATH. Please run ./client/build_iso.sh first."
        exit 1
    fi
fi

if [ "$RUN_SERVER" = true ]; then
    if [ ! -f "$PROJECT_ROOT/vps/bin/trusttunnel_endpoint" ]; then
        echo "[ERROR] Compiled TrustTunnel host binaries not found."
        exit 1
    fi

    # 2. Download Alpine Cloud Base Image if not present (~18 MB)
    if [ ! -f "$BASE_QCOW2" ]; then
        echo "Downloading Alpine Cloud Base QCOW2 image..."
        curl -sSL "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/cloud/nocloud_alpine-3.20.9-x86_64-bios-tiny-r0.qcow2" -o "$BASE_QCOW2"
    fi

    # 3. Create fresh copy of VPS QCOW2 disk
    echo "Creating fresh copy of VPS guest disk..."
    cp "$BASE_QCOW2" "$VPS_QCOW2"

    # 4. Prepare CIDATA folder
    echo "Preparing automated cloud-init metadata..."
    rm -rf "$CIDATA_DIR"
    mkdir -p "$CIDATA_DIR/bin" "$CIDATA_DIR/vps"

    # Copy binaries and vps folder
    cp "$PROJECT_ROOT/vps/bin/trusttunnel_endpoint" "$CIDATA_DIR/bin/"
    cp "$PROJECT_ROOT/vps/bin/setup_wizard" "$CIDATA_DIR/bin/"
cp -r "$PROJECT_ROOT/vps/configs" "$CIDATA_DIR/vps/"
cp -r "$PROJECT_ROOT/vps/scripts" "$CIDATA_DIR/vps/"

# Write meta-data
cat <<EOF > "$CIDATA_DIR/meta-data"
instance-id: myi2pd-vps-local-test
local-hostname: myi2pd-gateway
EOF

# Write user-data containing setup and interface configuration (Pure shell script for Tiny Cloud)
cat <<'EOF' > "$CIDATA_DIR/user-data"
#!/bin/sh
set -e
echo "=== Starting Automated Local VPS Gateway Setup ==="

# 1. Mount the CIDATA CD-ROM (usually /dev/sr0)
mkdir -p /mnt/cidata
mount /dev/sr0 /mnt/cidata || mount /dev/cdrom /mnt/cidata

# 2. Copy configurations and binaries
mkdir -p /etc/myi2pd-configs
cp -r /mnt/cidata/vps/configs/* /etc/myi2pd-configs/
cp /mnt/cidata/bin/trusttunnel_endpoint /usr/local/bin/
cp /mnt/cidata/bin/setup_wizard /usr/local/bin/
chmod +x /usr/local/bin/*

# 3. Create udhcpd configuration
cat <<CONF > /etc/udhcpd.conf
start 10.10.10.10
end 10.10.10.20
interface eth1
option subnet 255.255.255.0
option router 10.10.10.1
option dns 1.1.1.1
CONF

# 4. Configure local networking on private eth1 interface
ip addr add 10.10.10.1/24 dev eth1 || true
ip link set eth1 up

# 5. Start local DHCP server for Client VM auto-IP assignment
touch /var/lib/misc/udhcpd.leases
udhcpd /etc/udhcpd.conf

# 6. Execute setup_vps.sh to configure nftables and i2pd
cp /mnt/cidata/vps/scripts/setup_vps.sh /tmp/setup_vps.sh
chmod +x /tmp/setup_vps.sh
/tmp/setup_vps.sh

# Start services manually in memory
rc-update add nftables default
rc-update add i2pd default
rc-update add trusttunnel default
rc-service nftables start || true
rc-service i2pd start || true
rc-service trusttunnel start || true

EOF
fi

# Detect KVM availability
ACCEL_ARGS=("-cpu" "qemu64")
if [ -w /dev/kvm ]; then
    echo "[INFO] KVM hardware acceleration detected. Enabling KVM..."
    ACCEL_ARGS=("-enable-kvm" "-cpu" "host")
fi

VPS_PID=""

if [ "$RUN_SERVER" = true ]; then
    # 5. Package CIDATA ISO
    echo "Packaging CIDATA configuration ISO..."
    rm -f "$CIDATA_ISO"
    xorriso -as mkisofs -o "$CIDATA_ISO" -V CIDATA -J -r "$CIDATA_DIR"

    # Launch VM 2 (VPS Gateway)
    if [ "$RUN_CLIENT" = true ]; then
        echo "Starting VPS Gateway VM in background (QEMU 1)..."
        qemu-system-x86_64 \
            "${ACCEL_ARGS[@]}" \
            -m 1G \
            -drive file="$VPS_QCOW2",format=qcow2 \
            -cdrom "$CIDATA_ISO" \
            -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
            -netdev socket,id=net1,listen=:12345 -device virtio-net-pci,netdev=net1 \
            -device virtio-vga-gl -display sdl,gl=on &
        VPS_PID=$!
        
        # Wait 5 seconds for the socket to bind and start listening
        sleep 5
    else
        echo "Starting VPS Gateway VM in foreground (QEMU 1)..."
        qemu-system-x86_64 \
            "${ACCEL_ARGS[@]}" \
            -m 1G \
            -drive file="$VPS_QCOW2",format=qcow2 \
            -cdrom "$CIDATA_ISO" \
            -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
            -netdev socket,id=net1,listen=:12345 -device virtio-net-pci,netdev=net1 \
            -device virtio-vga-gl -display sdl,gl=on
    fi
fi

if [ "$RUN_CLIENT" = true ]; then
    echo "Starting Amnesiac Client ISO VM (QEMU 2)..."
    if [ "$RUN_SERVER" = true ]; then
        # Connect to private socket network
        qemu-system-x86_64 \
            "${ACCEL_ARGS[@]}" \
            -m 1G \
            -cdrom "$ISO_PATH" \
            -boot d \
            -netdev socket,id=net0,connect=127.0.0.1:12345 -device virtio-net-pci,netdev=net0 \
            -device virtio-vga-gl -display sdl,gl=on
    else
        # Standalone client boot (no server network connection)
        qemu-system-x86_64 \
            "${ACCEL_ARGS[@]}" \
            -m 1G \
            -cdrom "$ISO_PATH" \
            -boot d \
            -device virtio-vga-gl -display sdl,gl=on
    fi
fi

# Post-execution cleanup
if [ -n "$VPS_PID" ]; then
    echo "Terminating background VPS Gateway VM (PID: $VPS_PID)..."
    kill -9 "$VPS_PID" || true
fi

if [ "$RUN_SERVER" = true ]; then
    echo "Cleaning up temporary VM files..."
    rm -rf "$CIDATA_DIR"
    rm -f "$CIDATA_ISO"
    rm -f "$VPS_QCOW2"
fi

echo "=== Local testing session ended successfully! ==="
