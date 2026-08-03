#!/bin/bash
# host build_iso.sh - Prepares overlay directory and executes Docker builder container

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
WORKSPACE_DIR="$SCRIPT_DIR"
OVERLAY_TMP="$WORKSPACE_DIR/overlay-tmp"
OUT_DIR="$WORKSPACE_DIR/out"


echo "=== Pre-Build checks ==="
if ! command -v docker &>/dev/null; then
    echo "[ERROR] Docker is required but not installed on host."
    exit 1
fi

echo "Cleaning up previous builds..."
rm -rf "$OVERLAY_TMP" "$OUT_DIR" 2>/dev/null || true
mkdir -p "$OVERLAY_TMP" "$OUT_DIR"

echo "Structuring overlay directories..."
mkdir -p "$OVERLAY_TMP/etc/init.d" \
         "$OVERLAY_TMP/etc/network" \
         "$OVERLAY_TMP/etc/trusttunnel" \
         "$OVERLAY_TMP/etc/nftables" \
         "$OVERLAY_TMP/etc/librewolf" \
         "$OVERLAY_TMP/etc/river" \
         "$OVERLAY_TMP/etc/xdg/waybar" \
         "$OVERLAY_TMP/etc/xdg/foot" \
         "$OVERLAY_TMP/etc/wallpaper" \
         "$OVERLAY_TMP/etc/ncneofetch" \
         "$OVERLAY_TMP/usr/local/bin" \
         "$OVERLAY_TMP/usr/share/fonts/SauceCodePro" \
         "$OVERLAY_TMP/usr/lib/librewolf/distribution" \
         "$OVERLAY_TMP/usr/lib/librewolf/distribution/extensions" \
         "$OVERLAY_TMP/root" \
         "$OVERLAY_TMP/root/.config/river" \
         "$OVERLAY_TMP/root/.config/foot" \
         "$OVERLAY_TMP/usr/local/share/myi2pd"


# Copy configurations into overlay locations
echo "Copying config templates to overlay..."
cp "$WORKSPACE_DIR/configs/wifi-connect.sh"       "$OVERLAY_TMP/usr/local/bin/wifi-connect.sh"
cp "$WORKSPACE_DIR/configs/librewolf-launcher"     "$OVERLAY_TMP/usr/local/bin/librewolf-launcher"
chmod +x "$OVERLAY_TMP/usr/local/bin/librewolf-launcher"
cp "$WORKSPACE_DIR/configs/autologin"              "$OVERLAY_TMP/usr/local/bin/autologin"
cp "$WORKSPACE_DIR/configs/start-river"            "$OVERLAY_TMP/usr/local/bin/start-river"
chmod +x "$OVERLAY_TMP/usr/local/bin/start-river"
cp "$WORKSPACE_DIR/configs/profile"                "$OVERLAY_TMP/root/.profile"
cp "$WORKSPACE_DIR/configs/inittab"                "$OVERLAY_TMP/etc/inittab"
cp "$WORKSPACE_DIR/configs/river_init"              "$OVERLAY_TMP/etc/river/init"
cp "$WORKSPACE_DIR/configs/river_init"              "$OVERLAY_TMP/root/.config/river/init"
chmod +x "$OVERLAY_TMP/root/.config/river/init"
cp "$WORKSPACE_DIR/configs/waybar_config.jsonc"    "$OVERLAY_TMP/etc/xdg/waybar/config.jsonc"
cp "$WORKSPACE_DIR/configs/waybar_style.css"        "$OVERLAY_TMP/etc/xdg/waybar/style.css"
cp "$WORKSPACE_DIR/configs/foot.ini"                "$OVERLAY_TMP/etc/xdg/foot/foot.ini"
cp "$WORKSPACE_DIR/configs/foot.ini"                "$OVERLAY_TMP/root/.config/foot/foot.ini"
cp "$WORKSPACE_DIR/configs/hdd-isolation"          "$OVERLAY_TMP/etc/init.d/hdd-isolation"
cp "$WORKSPACE_DIR/configs/nftables.nft"            "$OVERLAY_TMP/etc/nftables/nftables.nft"

cp "$WORKSPACE_DIR/configs/librewolf.overrides.cfg" "$OVERLAY_TMP/etc/librewolf/librewolf.overrides.cfg"
cp "$WORKSPACE_DIR/configs/policies.json"           "$OVERLAY_TMP/usr/lib/librewolf/distribution/policies.json"

# Install DarkReader extension for LibreWolf
if [ -f "$WORKSPACE_DIR/extensions/addon@darkreader.org.xpi" ]; then
    echo "Installing DarkReader extension..."
    cp "$WORKSPACE_DIR/extensions/addon@darkreader.org.xpi" \
       "$OVERLAY_TMP/usr/lib/librewolf/distribution/extensions/addon@darkreader.org.xpi"
fi

# Install wallpaper
if [ -f "$WORKSPACE_DIR/wallpaper/wallpaper.png" ]; then
    echo "Installing wallpaper..."
    cp "$WORKSPACE_DIR/wallpaper/wallpaper.png" "$OVERLAY_TMP/etc/wallpaper/wallpaper.png"
fi

# Custom OS release for myi2pd distro identity
cp "$WORKSPACE_DIR/configs/os-release"              "$OVERLAY_TMP/etc/os-release"

# aria2c torrent config for I2P
mkdir -p "$OVERLAY_TMP/root/.config/aria2"
cat > "$OVERLAY_TMP/root/.config/aria2/aria2.conf" << 'ARIA2C'
# aria2c configuration for I2P-routed torrenting
enable-rpc=false
dir=/root/torrents
max-connection-per-server=4
split=4
continue=true
all-proxy=socks5://10.10.10.1:4447
bt-tracker-proxy=socks5://10.10.10.1:4447
dht-disable=true
enable-dht=false
enable-dht6=false
bt-enable-lpd=false
enable-peer-exchange=false
ARIA2C

# NeoMutt I2P launcher wrapper
cp "$WORKSPACE_DIR/configs/neomutt-i2p.sh"          "$OVERLAY_TMP/usr/local/bin/neomutt-i2p"
chmod +x "$OVERLAY_TMP/usr/local/bin/neomutt-i2p"

# Neofetch wrapper for custom myi2pd branding
cp "$WORKSPACE_DIR/configs/neofetch-wrapper"        "$OVERLAY_TMP/usr/local/bin/neofetch"
chmod +x "$OVERLAY_TMP/usr/local/bin/neofetch"
cp "$WORKSPACE_DIR/configs/ascii.txt"               "$OVERLAY_TMP/usr/local/share/myi2pd/ascii.txt"

# Install SauceCodePro Nerd Font for terminal and UI
if [ -d "$WORKSPACE_DIR/fonts" ] && ls "$WORKSPACE_DIR/fonts/"*.ttf &>/dev/null 2>&1; then
    echo "Installing SauceCodePro Nerd Font to overlay..."
    cp "$WORKSPACE_DIR/fonts/"*.ttf "$OVERLAY_TMP/usr/share/fonts/SauceCodePro/"
else
    echo "[WARNING] Fonts not found in $WORKSPACE_DIR/fonts/ — downloading..."
    mkdir -p "$WORKSPACE_DIR/fonts"
    curl -sL -o /tmp/SauceCodePro.zip "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/SourceCodePro.zip"
    unzip -j -o /tmp/SauceCodePro.zip \
        "SauceCodeProNerdFont-Regular.ttf" \
        "SauceCodeProNerdFont-Bold.ttf" \
        "SauceCodeProNerdFont-Italic.ttf" \
        "SauceCodeProNerdFontMono-Regular.ttf" \
        "SauceCodeProNerdFontMono-Bold.ttf" \
        -d "$WORKSPACE_DIR/fonts/" 2>&1
    cp "$WORKSPACE_DIR/fonts/"*.ttf "$OVERLAY_TMP/usr/share/fonts/SauceCodePro/"
fi

# Copy pre-configured VPS IP if it exists
if [ -f "$WORKSPACE_DIR/configs/vps_ip.txt" ]; then
    echo "Pre-configuring ISO with VPS IP: $(cat $WORKSPACE_DIR/configs/vps_ip.txt)"
    cp "$WORKSPACE_DIR/configs/vps_ip.txt" "$OVERLAY_TMP/etc/trusttunnel/vps_ip.txt"
fi

# FOSS pentest tooling: Alpine apk list (baked) + on-demand heavy installer.
# The apk list is appended to /etc/apk/world by assemble-iso inside the
# container; pentest-extra.sh installs the non-Alpine tools at runtime.
cp "$WORKSPACE_DIR/configs/pentest-apks.list" "$OVERLAY_TMP/etc/pentest-apks.list"
cp "$WORKSPACE_DIR/configs/pentest-extra.sh" "$OVERLAY_TMP/usr/local/bin/pentest-extra.sh"
chmod +x "$OVERLAY_TMP/usr/local/bin/pentest-extra.sh"

# Create dummy hostname
echo "myi2pd" > "$OVERLAY_TMP/etc/hostname"

# Create APK world file - Alpine's initramfs reads this to know which
# packages to install from the on-media boot repository at boot time.
# Without this file, only alpine-base is installed and all other packages
# (seatd, river, librewolf, etc.) sit unused on the ISO media.
mkdir -p "$OVERLAY_TMP/etc/apk"
cat <<'EOF' > "$OVERLAY_TMP/etc/apk/world"
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

# Configure basic loopback, ethernet, and wireless interface config in overlay
cat <<EOF > "$OVERLAY_TMP/etc/network/interfaces"
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    udhcpc_opts -b
EOF

if ! docker image inspect myi2pd-builder >/dev/null 2>&1; then
    echo "Building Docker environment (this compiles TrustTunnel statically)..."
    docker build -t myi2pd-builder "$WORKSPACE_DIR"
else
    echo "Using pre-built/cached myi2pd-builder Docker image..."
fi

echo "Executing build packaging inside container... (this takes 5-15 min, mostly package downloads)"
docker run --rm -t --privileged --network host \
  -v "$OVERLAY_TMP:/build/overlay" \
  -v "$OUT_DIR:/build" \
  --tmpfs /tmp:size=4G \
  -v "$WORKSPACE_DIR/configs/mkimg.myi2pd.sh:/usr/src/aports/scripts/mkimg.myi2pd.sh" \
  -v "$WORKSPACE_DIR/configs/assemble-iso:/usr/local/bin/assemble-iso" \
  myi2pd-builder

echo "Moving myi2pd-amnesiac.iso to workspace..."
mv "$OUT_DIR/myi2pd-amnesiac.iso" "$WORKSPACE_DIR/../myi2pd-amnesiac.iso"

echo "Cleaning up temporary directories..."
rm -rf "$OVERLAY_TMP" "$OUT_DIR" 2>/dev/null || true

echo "=== Build finished successfully! ISO location: /home/yahya/Projects/myi2pd-amnesiac.iso ==="
