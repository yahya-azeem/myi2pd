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
rm -rf "$OVERLAY_TMP" "$OUT_DIR"
mkdir -p "$OVERLAY_TMP" "$OUT_DIR"

echo "Structuring overlay directories..."
mkdir -p "$OVERLAY_TMP/etc/init.d" \
         "$OVERLAY_TMP/etc/network" \
         "$OVERLAY_TMP/etc/trusttunnel" \
         "$OVERLAY_TMP/etc/nftables" \
         "$OVERLAY_TMP/etc/i2pd" \
         "$OVERLAY_TMP/etc/librewolf" \
         "$OVERLAY_TMP/etc/river" \
         "$OVERLAY_TMP/etc/xdg/waybar" \
         "$OVERLAY_TMP/usr/local/bin" \
         "$OVERLAY_TMP/root"


# Copy configurations into overlay locations
echo "Copying config templates to overlay..."
cp "$WORKSPACE_DIR/configs/wifi-connect.sh"       "$OVERLAY_TMP/usr/local/bin/wifi-connect.sh"
cp "$WORKSPACE_DIR/configs/librewolf-launcher"     "$OVERLAY_TMP/usr/local/bin/librewolf-launcher"
cp "$WORKSPACE_DIR/configs/autologin"              "$OVERLAY_TMP/usr/local/bin/autologin"
cp "$WORKSPACE_DIR/configs/profile"                "$OVERLAY_TMP/root/.profile"
cp "$WORKSPACE_DIR/configs/inittab"                "$OVERLAY_TMP/etc/inittab"
cp "$WORKSPACE_DIR/configs/river_init"              "$OVERLAY_TMP/etc/river/init"
cp "$WORKSPACE_DIR/configs/waybar_config.jsonc"    "$OVERLAY_TMP/etc/xdg/waybar/config.jsonc"
cp "$WORKSPACE_DIR/configs/waybar_style.css"        "$OVERLAY_TMP/etc/xdg/waybar/style.css"
cp "$WORKSPACE_DIR/configs/hdd-isolation"          "$OVERLAY_TMP/etc/init.d/hdd-isolation"
cp "$WORKSPACE_DIR/configs/nftables.nft"            "$OVERLAY_TMP/etc/nftables/nftables.nft"
cp "$WORKSPACE_DIR/configs/i2pd.conf"              "$OVERLAY_TMP/etc/i2pd/i2pd.conf"
cp "$WORKSPACE_DIR/configs/librewolf.overrides.cfg" "$OVERLAY_TMP/etc/librewolf/librewolf.overrides.cfg"

# Create dummy hostname
echo "myi2pd" > "$OVERLAY_TMP/etc/hostname"

# Configure basic loopback and wireless interface config in overlay
cat <<EOF > "$OVERLAY_TMP/etc/network/interfaces"
auto lo
iface lo inet loopback

auto wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF

echo "Building Docker environment (this compiles TrustTunnel statically)..."
docker build -t myi2pd-builder "$WORKSPACE_DIR"

echo "Executing build packaging inside container..."
docker run --rm --privileged \
  -v "$OVERLAY_TMP:/build/overlay" \
  -v "$OUT_DIR:/build" \
  myi2pd-builder

echo "Moving myi2pd-amnesiac.iso to workspace..."
mv "$OUT_DIR/myi2pd-amnesiac.iso" "$WORKSPACE_DIR/../myi2pd-amnesiac.iso"

echo "Cleaning up temporary directories..."
rm -rf "$OVERLAY_TMP" "$OUT_DIR"

echo "=== Build finished successfully! ISO location: /home/yahya/Projects/myi2pd-amnesiac.iso ==="
