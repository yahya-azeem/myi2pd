#!/bin/bash
# build_vps_iso.sh - Build myi2pd VPS Gateway ISO
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
OVERLAY_TMP="$SCRIPT_DIR/overlay-tmp"
OUT_DIR="$SCRIPT_DIR/out"

echo "=== Building myi2pd VPS Gateway ISO ==="

echo "Cleaning up..."
# Remove root-owned apk files that may persist from previous builds
rm -f "$OVERLAY_TMP/etc/apk/world" 2>/dev/null || true
rmdir "$OVERLAY_TMP/etc/apk" 2>/dev/null || true
rm -rf "$OVERLAY_TMP" "$OUT_DIR" 2>/dev/null || true
mkdir -p "$OVERLAY_TMP" "$OUT_DIR"

echo "Structuring overlay directories..."
mkdir -p "$OVERLAY_TMP/etc/init.d" \
         "$OVERLAY_TMP/etc/runlevels/boot" \
         "$OVERLAY_TMP/etc/runlevels/default" \
         "$OVERLAY_TMP/etc/i2pd" \
         "$OVERLAY_TMP/etc/network" \
         "$OVERLAY_TMP/etc/sysctl.d" \
         "$OVERLAY_TMP/usr/local/bin" \
         "$OVERLAY_TMP/root"

echo "Copying binaries..."
# Use Xray binary (pre-built or from path)
if [ -x /tmp/xray/xray ]; then
    cp /tmp/xray/xray "$OVERLAY_TMP/usr/local/bin/"
elif [ -x /usr/local/bin/xray ]; then
    cp /usr/local/bin/xray "$OVERLAY_TMP/usr/local/bin/"
else
    echo "WARNING: Xray binary not found, overlay will include placeholder"
fi
cp "$SCRIPT_DIR/bin/setup_wizard" "$OVERLAY_TMP/usr/local/bin/"
chmod +x "$OVERLAY_TMP/usr/local/bin/"*

echo "Copying configs..."
cp "$SCRIPT_DIR/configs/i2pd.conf" "$OVERLAY_TMP/etc/i2pd/i2pd.conf"
cp "$SCRIPT_DIR/configs/nftables.nft" "$OVERLAY_TMP/etc/nftables.nft"

echo "Populating i2pd netDb with reseed data..."
cp -r "$SCRIPT_DIR/netDb/"* "$OVERLAY_TMP/var/lib/i2pd/netDb/"

# Create xray init script with VLESS+XTLS-Reality configuration
cat > "$OVERLAY_TMP/etc/init.d/xray" << 'INITEOF'
#!/sbin/openrc-run
name="xray"
description="Xray VLESS + XTLS-Reality Endpoint Daemon"
command="/usr/local/bin/xray"
command_args="-conf /etc/xray/config.json"
command_background=true
pidfile="/run/RC_SVCNAME.pid"
depend() { need net; after nftables; }
start_pre() {
    [ -d /etc/xray ] || mkdir -p /etc/xray
    [ -f /etc/xray/config.json ] || {
        X25519=$(/usr/local/bin/xray x25519 | awk '{print $2}')
        VLESS_UUID=$(/usr/local/bin/xray uuid)
        SHORT_ID=$(xxd -l 8 -p /dev/urandom)
        DEST="microsoft.com:443"
        cat > /etc/xray/config.json << EOFJSON
{"inbounds":[{"listen":"0.0.0.0","port":443,"protocol":"vless","settings":{"clients":[{"id":"$VLESS_UUID","flow":"","email":"user@example.com"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":"","dest":"$DEST","xver":0,"serverNames":["$DEST"],"privateKey":"$X25519","shortIds":["$SHORT_ID"]}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}
EOFJSON
    }
}
INITEOF
chmod +x "$OVERLAY_TMP/etc/init.d/xray"

# Create eth1-lan init script - fixes i2pd data dir perms, then configures private LAN IP
cat > "$OVERLAY_TMP/etc/init.d/eth1-lan" << 'LANEOF'
#!/sbin/openrc-run
description="Private LAN interface for client VMs"
depend() { need net; }
start() {
    ebegin "Fixing i2pd data directory permissions"
    chmod 0777 /var/lib/i2pd 2>/dev/null || true
    chmod -R 0777 /var/lib/i2pd/netDb 2>/dev/null || true
    eend 0
    ebegin "Setting up eth1 private LAN"
    ip addr add 10.10.10.1/24 dev eth1 2>/dev/null || true
    ip link set eth1 up 2>/dev/null || true
    eend 0
}
LANEOF
chmod +x "$OVERLAY_TMP/etc/init.d/eth1-lan"

# Create /root/.profile
cat > "$OVERLAY_TMP/root/.profile" << 'PROFEOF'
[ -f /etc/profile ] && . /etc/profile
echo "=== myi2pd VPS Gateway ==="
echo "Xray status: $(rc-service xray status 2>/dev/null | grep -o 'started\|stopped' || echo 'unknown')"
echo "eth0: $(ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)"
PROFEOF

# VPS inittab with autologin on serial console
cat > "$OVERLAY_TMP/etc/inittab" << 'INITEOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
ttyS0::respawn:/sbin/getty -L 38400 -l /usr/local/bin/autologin -n ttyS0
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
INITEOF

# dnsmasq config for eth1 LAN
cat > "$OVERLAY_TMP/etc/dnsmasq.conf" << 'DNSEOF'
interface=eth1
dhcp-range=10.10.10.10,10.10.10.20,255.255.255.0,12h
dhcp-option=3,10.10.10.1
dhcp-option=6,1.1.1.1
DNSEOF

# hostname
echo "myi2pd-gateway" > "$OVERLAY_TMP/etc/hostname"

# Kernel hardening (anti-forensics)
mkdir -p "$OVERLAY_TMP/etc/sysctl.d"
cat > "$OVERLAY_TMP/etc/sysctl.d/hardening.conf" << 'SYSCTLEOF'
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
vm.swappiness = 0
SYSCTLEOF

# network interfaces
cat > "$OVERLAY_TMP/etc/network/interfaces" << 'INTFEOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
INTFEOF

# APK world file - tells initramfs which packages to install at boot
# Without this file, only alpine-base is installed and all other packages
# (river, librewolf, etc.) sit unused on the ISO media.
mkdir -p "$OVERLAY_TMP/etc/apk"
cat > "$OVERLAY_TMP/etc/apk/world" << 'WORLDF'
alpine-base
ca-certificates
nftables
bash
openssl
wireless-tools
wpa_supplicant
e2fsprogs
river-classic
fuzzel
waybar
foot
font-dejavu
seatd
seatd-launch
dbus
dbus-x11
dbus-openrc
mesa-dri-gallium
mesa-gbm
mesa-egl
swaybg
librewolf
libdrm-tests
udev
fontconfig
ncneofetch
neomutt
util-linux
util-linux-misc
EOF

# Build the custom vps-builder Docker image if not present
if ! docker image inspect myi2pd-builder:vps >/dev/null 2>&1; then
    echo "Building vps-builder Docker image..."
    docker build -t myi2pd-builder:vps -f "$SCRIPT_DIR/vps-builder.Dockerfile" "$SCRIPT_DIR"
fi

# Run the build inside Docker
echo "Running Docker build..."
docker run --rm --privileged \
  --tmpfs /tmp:size=4G \
  -v "$OVERLAY_TMP:/build/overlay" \
  -v "$OUT_DIR:/build" \
  -v "$SCRIPT_DIR/configs/mkimg.myi2pd-vps.sh:/usr/src/aports/scripts/mkimg.myi2pd-vps.sh" \
  -v "$SCRIPT_DIR/configs/genapkovl-myi2pd-vps.sh:/usr/src/aports/scripts/genapkovl-myi2pd-vps.sh" \
  myi2pd-builder:vps sh -c '
set -e
if [ ! -f /root/.abuild/abuild.conf ]; then
    mkdir -p /root/.abuild
    abuild-keygen -a -n
    cp /root/.abuild/*.pub /etc/apk/keys/
fi

chmod +x /build/overlay/usr/local/bin/* /build/overlay/etc/init.d/*


# Ensure runlevel symlinks are created (targets exist in Alpine)
mkdir -p /build/overlay/etc/runlevels/boot /build/overlay/etc/runlevels/default
ln -sf /etc/init.d/hostname /build/overlay/etc/runlevels/boot/hostname
ln -sf /etc/init.d/udev /build/overlay/etc/runlevels/boot/udev
ln -sf /etc/init.d/nftables /build/overlay/etc/runlevels/default/nftables
ln -sf /etc/init.d/xray /build/overlay/etc/runlevels/default/xray
ln -sf /etc/init.d/i2pd /build/overlay/etc/runlevels/default/i2pd
ln -sf /etc/init.d/dnsmasq /build/overlay/etc/runlevels/default/dnsmasq
# eth1-lan is in overlay, symlink into default runlevel (after networking)
ln -sf /etc/init.d/eth1-lan /build/overlay/etc/runlevels/default/eth1-lan
echo "=== OVERLAY RUNLEVELS ==="
ls -la /build/overlay/etc/runlevels/default/
ls -la /build/overlay/etc/runlevels/boot/
echo "=== OVERLAY INIT.D ==="
ls /build/overlay/etc/init.d/

cd /usr/src/aports/scripts
sh mkimage.sh --profile myi2pd-vps \
  --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
  --repository https://dl-cdn.alpinelinux.org/alpine/edge/community \
  --outdir /build --hostkeys

rm -f /build/myi2pd-vps.iso
for f in /build/*.iso; do
    [ -f "$f" ] && mv "$f" /build/myi2pd-vps.iso && break
done
echo "=== VPS ISO built inside container ==="
'

echo "Moving VPS ISO to project root..."
mv "$OUT_DIR/myi2pd-vps.iso" "$SCRIPT_DIR/../myi2pd-vps.iso"

echo "Cleaning up..."
rm -rf "$OVERLAY_TMP" "$OUT_DIR" 2>/dev/null || true

echo "=== VPS ISO build finished! ==="