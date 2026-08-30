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
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
ISO_PATH="$PROJECT_ROOT/myi2pd-amnesiac.iso"
BASE_QCOW2="/tmp/alpine-cloud-base.qcow2"
VPS_QCOW2="/tmp/myi2pd-vps.qcow2"
CIDATA_DIR="/tmp/myi2pd_cidata_dir"
CIDATA_ISO="/tmp/myi2pd_cidata.iso"

echo "=== myi2pd QEMU VM Test ==="

[ "$RUN_CLIENT" = false ] || [ -f "$ISO_PATH" ] || { echo "ERROR: Client ISO not found"; exit 1; }

if [ "$RUN_SERVER" = true ]; then
    # Check for xray binary or download capability
    if [ ! -f "$PROJECT_ROOT/vps/bin/xray" ] && [ ! -f "/tmp/xray/xray" ]; then
        echo "WARNING: Xray binary not found in vps/bin/, will be downloaded at runtime"
    fi

    if [ ! -f "$BASE_QCOW2" ]; then
        echo "Downloading Alpine Cloud Base image..."
        curl -sSL "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/cloud/nocloud_alpine-3.20.9-x86_64-bios-tiny-r0.qcow2" -o "$BASE_QCOW2"
    fi

    cp "$BASE_QCOW2" "$VPS_QCOW2"
    echo "Resizing VPS disk to 2G..."
    qemu-img resize "$VPS_QCOW2" 2G &>/dev/null
    rm -rf "$CIDATA_DIR"
    mkdir -p "$CIDATA_DIR/bin" "$CIDATA_DIR/vps"
    
    # Copy xray binary if available, or it will be downloaded by setup_vps.sh
    if [ -f "$PROJECT_ROOT/vps/bin/xray" ]; then
        cp "$PROJECT_ROOT/vps/bin/xray" "$CIDATA_DIR/bin/"
    elif [ -f "/tmp/xray/xray" ]; then
        cp "/tmp/xray/xray" "$CIDATA_DIR/bin/"
    fi
    cp "$PROJECT_ROOT/vps/bin/setup_wizard" "$CIDATA_DIR/bin/"
    cp -r "$PROJECT_ROOT/vps/configs" "$CIDATA_DIR/vps/"
    cp -r "$PROJECT_ROOT/vps/scripts" "$CIDATA_DIR/vps/"

    cat <<EOF > "$CIDATA_DIR/meta-data"
instance-id: myi2pd-vps-local-test
local-hostname: myi2pd-gateway
EOF

    cat <<'SHEOF' > "$CIDATA_DIR/user-data"
#!/bin/sh
set -e
echo "=== VPS Gateway Setup ==="
# Resize root partition to fill the expanded disk
growpart /dev/sda 1 2>/dev/null || parted -s /dev/sda resizepart 1 100% 2>/dev/null || true
resize2fs /dev/sda1 2>/dev/null || true
mkdir -p /mnt/cidata
mount /dev/sr0 /mnt/cidata || mount /dev/cdrom /mnt/cidata
mkdir -p /etc/myi2pd-configs
cp -r /mnt/cidata/vps/configs/* /etc/myi2pd-configs/
if [ -f /mnt/cidata/bin/xray ]; then
    cp /mnt/cidata/bin/xray /usr/local/bin/
fi
cp /mnt/cidata/bin/setup_wizard /usr/local/bin/
chmod +x /usr/local/bin/*

# Generate pre-built creds.json and config.json for test environment (normally baked into ISO)
mkdir -p /etc/xray
XRAY_BIN="/usr/local/bin/xray"
if [ ! -x "$XRAY_BIN" ] && [ -f /mnt/cidata/bin/xray ]; then
    XRAY_BIN="/mnt/cidata/bin/xray"
fi
X25519=$("$XRAY_BIN" x25519 | awk '{print $2}')
VLESS_UUID=$("$XRAY_BIN" uuid)
SHORT_ID=$(xxd -l 8 -p /dev/urandom)
DEST="www.microsoft.com:443"
cat > /etc/xray/creds.json <<CREEOF
{
  "vps_ip": "10.0.2.15",
  "uuid": "$VLESS_UUID",
  "pubkey": "$X25519",
  "short_id": "$SHORT_ID",
  "dest": "$DEST"
}
CREEOF

# Generate Xray config.json
cat > /etc/xray/config.json <<CONFIGEOF
{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "$VLESS_UUID",
        "flow": "xtls-rprx-vision",
        "email": "myi2pd-client"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$DEST",
        "xver": 0,
        "serverNames": ["$DEST"],
        "privateKey": "$X25519",
        "shortIds": ["", "$SHORT_ID", "0123456789abcdef"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}],
  "policy": {
    "levels": {
      "0": {
        "bufferSize": 2,
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    }
  }
}
CONFIGEOF

echo "Setting up private LAN on eth1..."
ip addr add 10.10.10.1/24 dev eth1 2>/dev/null || true
ip link set eth1 up
echo "Starting DHCP/DNS on eth1..."
apk add dnsmasq curl
dnsmasq --dhcp-range=10.10.10.10,10.10.10.20,255.255.255.0 \
        --interface=eth1 --no-daemon \
        --log-dhcp --dhcp-option=3,10.10.10.1 \
        --dhcp-option=6,1.1.1.1 &
cp /mnt/cidata/vps/scripts/setup_vps.sh /tmp/setup_vps.sh
chmod +x /tmp/setup_vps.sh
sh /tmp/setup_vps.sh
echo "Starting services..."
rc-service i2pd start || true
rc-service xray start || /tmp/xray/xray -conf /etc/xray/config.json &
echo "=== VPS Gateway Setup Complete ==="
SHEOF
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
    echo "Packaging CIDATA ISO..."
    xorriso -as mkisofs -o "$CIDATA_ISO" -V CIDATA -J -r "$CIDATA_DIR" 2>/dev/null

    rm -f "$VPS_LOG"
    if [ "$RUN_CLIENT" = true ]; then
        echo "Starting VPS Gateway (background, logging to $VPS_LOG)..."
        qemu-system-x86_64 "${ACCEL_ARGS[@]}" -m 1G \
            -drive file="$VPS_QCOW2",format=qcow2 \
            -cdrom "$CIDATA_ISO" \
            -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
            -netdev socket,id=net1,listen=:12345 -device virtio-net-pci,netdev=net1 \
            "${DISPLAY_ARGS[@]}" \
            -serial file:"$VPS_LOG" &
        VPS_PID=$!
        echo "Waiting for VPS to finish booting (polling serial log)..."
        for i in $(seq 1 180); do
            grep -q "VPS Gateway Setup Complete" "$VPS_LOG" 2>/dev/null && break
            sleep 2
        done
    else
        echo "Starting VPS Gateway (foreground, logging to $VPS_LOG)..."
        qemu-system-x86_64 "${ACCEL_ARGS[@]}" -m 1G \
            -drive file="$VPS_QCOW2",format=qcow2 \
            -cdrom "$CIDATA_ISO" \
            -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
            -netdev socket,id=net1,listen=:12345 -device virtio-net-pci,netdev=net1 \
            "${DISPLAY_ARGS[@]}" \
            -serial file:"$VPS_LOG"
    fi
fi

if [ "$RUN_CLIENT" = true ]; then
    rm -f "$CLIENT_LOG"
    echo "Starting Client ISO (logging to $CLIENT_LOG)..."
    if [ "$RUN_SERVER" = true ]; then
        qemu-system-x86_64 "${ACCEL_ARGS[@]}" -m 1G \
            -cdrom "$ISO_PATH" -boot d \
            -netdev socket,id=net0,connect=127.0.0.1:12345 -device virtio-net-pci,netdev=net0 \
            "${DISPLAY_ARGS[@]}" \
            -serial file:"$CLIENT_LOG"
    else
        qemu-system-x86_64 "${ACCEL_ARGS[@]}" -m 1G \
            -cdrom "$ISO_PATH" -boot d \
            -vga std -display gtk \
            -serial file:"$CLIENT_LOG"
    fi
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

rm -rf "$CIDATA_DIR" "$CIDATA_ISO" "$VPS_QCOW2" "$VPS_LOG" "$CLIENT_LOG" 2>/dev/null
echo "=== Test ended ==="