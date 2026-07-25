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
         "$OVERLAY_TMP/usr/local/bin" \
         "$OVERLAY_TMP/root"

echo "Setting up i2pd netDb overlay (world-writable for i2pd daemon)..."
mkdir -p "$OVERLAY_TMP/var/lib/i2pd/netDb"
chmod 0755 "$OVERLAY_TMP/var/lib/i2pd"
chmod 0755 "$OVERLAY_TMP/var/lib/i2pd/netDb"
find "$OVERLAY_TMP/var/lib/i2pd/netDb" -type d -exec chmod 0755 {} \;

echo "Copying binaries..."
cp "$SCRIPT_DIR/bin/trusttunnel_endpoint" "$OVERLAY_TMP/usr/local/bin/"
cp "$SCRIPT_DIR/bin/setup_wizard" "$OVERLAY_TMP/usr/local/bin/"

chmod +x "$OVERLAY_TMP/usr/local/bin/"*

echo "Copying configs..."
cp "$SCRIPT_DIR/configs/i2pd.conf" "$OVERLAY_TMP/etc/i2pd/i2pd.conf"
cp "$SCRIPT_DIR/configs/nftables.nft" "$OVERLAY_TMP/etc/nftables.nft"

echo "Populating i2pd netDb with reseed data..."
cp -r "$SCRIPT_DIR/netDb/"* "$OVERLAY_TMP/var/lib/i2pd/netDb/"

# Create trusttunnel init script
cat > "$OVERLAY_TMP/etc/init.d/trusttunnel" << 'INITEOF'
#!/sbin/openrc-run
name="trusttunnel"
description="TrustTunnel VPN Endpoint Daemon"
command="/usr/local/bin/trusttunnel_endpoint"
command_args="/etc/trusttunnel/vpn.toml /etc/trusttunnel/hosts.toml"
command_background=true
pidfile="/run/RC_SVCNAME.pid"
depend() { need net; after nftables; }
start_pre() {
    [ -d /etc/trusttunnel ] || mkdir -p /etc/trusttunnel
    [ -f /etc/trusttunnel/server.crt ] || openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/trusttunnel/server.key -out /etc/trusttunnel/server.crt -subj "/CN=10.10.10.1" 2>/dev/null
    [ -f /etc/trusttunnel/hosts.toml ] || cat > /etc/trusttunnel/hosts.toml << TOMLEOF
[[main_hosts]]
hostname = "10.10.10.1"
cert_chain_path = "/etc/trusttunnel/server.crt"
private_key_path = "/etc/trusttunnel/server.key"
TOMLEOF
    [ -f /etc/trusttunnel/vpn.toml ] || setup_wizard -m non-interactive -a 0.0.0.0:443 -c "myi2pduser:myi2pdsecurepassword" -n "10.10.10.1" --lib-settings /etc/trusttunnel/vpn.toml --hosts-settings /etc/trusttunnel/hosts.toml --client-settings /etc/trusttunnel/client.toml 2>/dev/null || true
}
INITEOF
chmod +x "$OVERLAY_TMP/etc/init.d/trusttunnel"

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
echo "i2pd status: $(rc-service i2pd status 2>/dev/null | grep -o 'started\|stopped' || echo 'unknown')"
echo "eth0: $(ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)"
PROFEOF

# Create autologin helper
cat > "$OVERLAY_TMP/usr/local/bin/autologin" << 'ALEOF'
#!/bin/sh
exec /bin/login -f root
ALEOF
chmod +x "$OVERLAY_TMP/usr/local/bin/autologin"

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
mkdir -p "$OVERLAY_TMP/etc/apk"
cat > "$OVERLAY_TMP/etc/apk/world" << 'WORLDF'
alpine-base
alpine-baselayout
alpine-conf
alpine-release
apk-tools
busybox
busybox-openrc
bash
ca-certificates-bundle
chrony
chrony-openrc
dhcpcd
dhcpcd-openrc
dnsmasq
dnsmasq-openrc
e2fsprogs
eudev
i2pd
i2pd-openrc
nftables
nftables-openrc
openssh
openssh-server
openssh-server-common
openssl
WORLDF

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
chmod +x /usr/src/aports/scripts/*.sh



# Ensure runlevel symlinks are created (targets exist in Alpine)
mkdir -p /build/overlay/etc/runlevels/boot /build/overlay/etc/runlevels/default
ln -sf /etc/init.d/hostname /build/overlay/etc/runlevels/boot/hostname
ln -sf /etc/init.d/udev /build/overlay/etc/runlevels/boot/udev
ln -sf /etc/init.d/networking /build/overlay/etc/runlevels/default/networking
ln -sf /etc/init.d/nftables /build/overlay/etc/runlevels/default/nftables
ln -sf /etc/init.d/i2pd /build/overlay/etc/runlevels/default/i2pd
ln -sf /etc/init.d/trusttunnel /build/overlay/etc/runlevels/default/trusttunnel
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
