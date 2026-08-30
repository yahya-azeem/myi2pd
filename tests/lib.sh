#!/bin/bash
# tests/lib.sh - Shared helpers for the myi2pd test suite.
# All tests run statically against the source tree / configs / built ISO.
# No VM boot required.

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_GROUP=""
VERBOSE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." &>/dev/null && pwd)"

CLIENT_OVERLAY="$SCRIPT_DIR/.tmp-overlay-client"
VPS_OVERLAY="$SCRIPT_DIR/.tmp-overlay-vps"

# ---------------------------------------------------------------------------
# Test bookkeeping
# ---------------------------------------------------------------------------

group() {
    CURRENT_GROUP="$1"
    if [ "$VERBOSE" = "1" ]; then
        echo ""
        echo "== $1 =="
    fi
}

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$VERBOSE" = "1" ]; then
        echo "  PASS  $CURRENT_GROUP: $1"
    fi
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL  $CURRENT_GROUP: $1"
}

# assert_file <path> <description>
# Asserts the given file exists and is non-empty.
assert_file() {
    if [ -s "$1" ]; then
        pass "$2 ($1)"
    else
        fail "$2 ($1)"
    fi
}

# assert_file_missing <path> <description>
assert_file_missing() {
    if [ -e "$1" ]; then
        fail "$2 ($1 exists, should not)"
    else
        pass "$2 ($1)"
    fi
}

# assert_executable <path> <description>
assert_executable() {
    if [ -x "$1" ]; then
        pass "$2 ($1)"
    else
        fail "$2 ($1 not executable)"
    fi
}

# assert_symlink <path> <target> <description>
assert_symlink() {
    if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then
        pass "$3 ($1 -> $2)"
    else
        fail "$3 ($1 is not a symlink to $2)"
    fi
}

# assert_contains <path> <pattern> <description>
assert_contains() {
    if grep -qE -- "$2" "$1" 2>/dev/null; then
        pass "$3"
    else
        fail "$3 ($1 missing pattern: $2)"
    fi
}

# assert_not_contains <path> <pattern> <description>
assert_not_contains() {
    if grep -qE -- "$2" "$1" 2>/dev/null; then
        fail "$3 ($1 contains unwanted pattern: $2)"
    else
        pass "$3"
    fi
}

# assert_eq <expected> <actual> <description>
assert_eq() {
    if [ "$1" = "$2" ]; then
        pass "$3 (=$2)"
    else
        fail "$3 (expected '$1', got '$2')"
    fi
}

# assert_shellcheck <path> <description>
# Runs a syntax check without executing. The ISOs run Alpine busybox ash +
# bash, so scripts (including sourced fragments like mkimg profiles, which
# dash rejects for hyphenated function names) are validated against bash.
# Only files with an explicit #!/bin/sh shebang are checked as POSIX sh.
assert_shell_syntax() {
    local syntaxer="bash -n"
    if [ "$(head -1 "$1" 2>/dev/null)" = "#!/bin/sh" ]; then
        syntaxer="sh -n"
    fi
    if $syntaxer "$1" 2>/dev/null; then
        pass "$2 ($1 syntax OK)"
    else
        fail "$2 ($1 has shell syntax errors)"
    fi
}

# ---------------------------------------------------------------------------
# Overlay assembly (dry-run, no docker, no ISO build)
# ---------------------------------------------------------------------------

# clean_overlays: remove any leftover test overlay dirs
clean_overlays() {
    rm -rf "$CLIENT_OVERLAY" "$VPS_OVERLAY"
}

# assemble_client_overlay <dest>
# Replicates the exact steps from .github/workflows/build.yml "Create overlay"
# + "Copy configs to overlay" so a parity gap is caught before the ISO is built.
assemble_client_overlay() {
    local dest="$1"
    rm -rf "$dest"
    mkdir -p "$dest/etc/init.d" \
             "$dest/etc/runlevels/boot" \
             "$dest/etc/runlevels/default" \
             "$dest/etc/nftables" \
             "$dest/etc/librewolf" \
             "$dest/etc/river" \
             "$dest/etc/xdg/waybar" \
             "$dest/etc/xdg/foot" \
             "$dest/etc/wallpaper" \
             "$dest/etc/xray" \
             "$dest/etc/ncneofetch" \
             "$dest/etc/network" \
             "$dest/usr/local/bin" \
             "$dest/usr/local/share/myi2pd" \
             "$dest/usr/lib/librewolf/distribution/extensions" \
             "$dest/usr/share/fonts/SauceCodePro" \
             "$dest/root/.config/river" \
             "$dest/root/.config/foot" \
             "$dest/root/.config/aria2"

    cp "$REPO_ROOT/client/configs/inittab" "$dest/etc/inittab"
    cp "$REPO_ROOT/client/configs/river_init" "$dest/etc/river/init"
    cp "$REPO_ROOT/client/configs/river_init" "$dest/root/.config/river/init"
    cp "$REPO_ROOT/client/configs/start-river" "$dest/usr/local/bin/start-river"
    cp "$REPO_ROOT/client/configs/hdd-isolation" "$dest/etc/init.d/hdd-isolation"
    cp "$REPO_ROOT/client/configs/i2p-keepalive.sh" "$dest/usr/local/bin/i2p-keepalive.sh"
    cp "$REPO_ROOT/client/configs/foot.ini" "$dest/etc/xdg/foot/foot.ini"
    cp "$REPO_ROOT/client/configs/foot.ini" "$dest/root/.config/foot/foot.ini"
    cp "$REPO_ROOT/client/configs/waybar_config.jsonc" "$dest/etc/xdg/waybar/config.jsonc"
    cp "$REPO_ROOT/client/configs/waybar_style.css" "$dest/etc/xdg/waybar/style.css"
    cp "$REPO_ROOT/client/configs/nftables.nft" "$dest/etc/nftables/nftables.nft"
    cp "$REPO_ROOT/client/configs/policies.json" "$dest/usr/lib/librewolf/distribution/policies.json"
    cp "$REPO_ROOT/client/configs/librewolf.overrides.cfg" "$dest/etc/librewolf/librewolf.overrides.cfg"
    cp "$REPO_ROOT/client/configs/neofetch-wrapper" "$dest/usr/local/bin/neofetch"
    cp "$REPO_ROOT/client/configs/ascii.txt" "$dest/usr/local/share/myi2pd/ascii.txt"
    cp "$REPO_ROOT/client/configs/neomutt-i2p.sh" "$dest/usr/local/bin/neomutt-i2p"
    cp "$REPO_ROOT/client/configs/wifi-connect.sh" "$dest/usr/local/bin/wifi-connect.sh"
    cp "$REPO_ROOT/client/configs/autologin" "$dest/usr/local/bin/autologin"
    cp "$REPO_ROOT/client/configs/librewolf-launcher" "$dest/usr/local/bin/librewolf-launcher"
    cp "$REPO_ROOT/client/configs/os-release" "$dest/etc/os-release"
    cp "$REPO_ROOT/client/configs/vps_ip.txt" "$dest/etc/xray/vps_ip.txt"
    cp "$REPO_ROOT/client/configs/pentest-apks.list" "$dest/etc/pentest-apks.list"
    cp "$REPO_ROOT/client/configs/pentest-lazy.list" "$dest/etc/pentest-lazy.list"
    cp "$REPO_ROOT/client/configs/pentest-extra.sh" "$dest/usr/local/bin/pentest-extra.sh"
    cp "$REPO_ROOT/client/configs/ai-apks.list" "$dest/etc/ai-apks.list"
    cp "$REPO_ROOT/client/configs/ai-extra.sh" "$dest/usr/local/bin/ai-extra.sh"
    cp "$REPO_ROOT/client/configs/AGENTS.md" "$dest/usr/local/share/myi2pd/CLAUDE.md"
    if [ -f "$REPO_ROOT/client/wallpaper/wallpaper.png" ]; then
        cp "$REPO_ROOT/client/wallpaper/wallpaper.png" "$dest/etc/wallpaper/wallpaper.png"
    fi
    cat > "$dest/root/.config/aria2/aria2.conf" << 'ARIA2C'
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
    chmod +x "$dest/usr/local/bin/"* 2>/dev/null || true
}

# apply_client_overlay_runtime: run the runtime bits of assemble-iso that the
# Docker container applies on top of the copied overlay (root .profile, apk
# world, runlevels). Replicates client/configs/assemble-iso.
apply_client_overlay_runtime() {
    local dest="$1"
    mkdir -p "$dest/etc/runlevels/boot" "$dest/etc/runlevels/default" "$dest/etc/apk" "$dest/root"

    ln -sf /etc/init.d/hostname "$dest/etc/runlevels/boot/hostname"
    ln -sf /etc/init.d/hdd-isolation "$dest/etc/runlevels/boot/hdd-isolation"
    ln -sf /etc/init.d/udev "$dest/etc/runlevels/boot/udev"
    ln -sf /etc/init.d/seatd "$dest/etc/runlevels/default/seatd"
    ln -sf /etc/init.d/dbus "$dest/etc/runlevels/default/dbus"
    ln -sf /etc/init.d/networking "$dest/etc/runlevels/default/networking"

    cat > "$dest/root/.profile" << 'PROFEOF'
if [ "$(tty)" = "/dev/tty1" ]; then
    /usr/local/bin/start-river
fi
PROFEOF

    # /etc/apk/world - written by assemble-iso inside the container.
    # This is what makes the GUI packages install at boot in diskless mode.
    cat > "$dest/etc/apk/world" << 'WORLDFILE'
alpine-base
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
swaybg
udev
fontconfig
ncneofetch
neomutt
util-linux
util-linux-misc
libinput
librewolf
agetty
WORLDFILE

    # Append FOSS pentest tooling to world (mirrors assemble-iso). Source of
    # truth: client/configs/pentest-apks.list. Comments are stripped because
    # apk's world file does NOT tolerate them. Heavy tools from the lazy list
    # are excluded (kept on ISO disk, loaded on demand by pentest-extra.sh).
    if [ -f "$dest/etc/pentest-apks.list" ]; then
        sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$dest/etc/pentest-apks.list" > /tmp/pw
        if [ -f "$dest/etc/pentest-lazy.list" ]; then
            grep -vxF -f <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$dest/etc/pentest-lazy.list") /tmp/pw > /tmp/pwl
            mv /tmp/pwl /tmp/pw
        fi
        cat /tmp/pw >> "$dest/etc/apk/world"
        rm -f /tmp/pw
        sed -i '/^gcc$/d' "$dest/etc/apk/world" 2>/dev/null || true
    fi

    # /etc/hostname + /etc/network/interfaces - written by assemble-iso inside
    # the container (added to match the VPS flow; without these the diskless
    # client boots as "localhost" and networking fails).
    echo "myi2pd" > "$dest/etc/hostname"
    cat > "$dest/etc/network/interfaces" << 'INTFEOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    udhcpc_opts -b
INTFEOF
}

# assemble_vps_overlay <dest>
# Replicates vps/configs/assemble-vps-iso runlevel + hostname + interfaces
# writing that happens inside the container (hostname + interfaces are created
# in the container, not by the GHA copy step).
assemble_vps_overlay() {
    local dest="$1"
    rm -rf "$dest"
    mkdir -p "$dest/etc/init.d" "$dest/etc/runlevels/boot" "$dest/etc/runlevels/default"

    ln -sf /etc/init.d/hostname "$dest/etc/runlevels/boot/hostname"
    ln -sf /etc/init.d/udev "$dest/etc/runlevels/boot/udev"
    ln -sf /etc/init.d/eth1-lan "$dest/etc/runlevels/boot/eth1-lan"
    ln -sf /etc/init.d/networking "$dest/etc/runlevels/default/networking"
    ln -sf /etc/init.d/nftables "$dest/etc/runlevels/default/nftables"
    ln -sf /etc/init.d/i2pd "$dest/etc/runlevels/default/i2pd"
    ln -sf /etc/init.d/xray "$dest/etc/runlevels/default/xray"
    ln -sf /etc/init.d/dnsmasq "$dest/etc/runlevels/default/dnsmasq"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

summary() {
    echo ""
    echo "-------------------------------------------"
    echo "Tests run: $TESTS_RUN   Passed: $((TESTS_RUN - TESTS_FAILED))   Failed: $TESTS_FAILED"
    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo "ALL TESTS PASSED"
        echo "-------------------------------------------"
        return 0
    else
        echo "SOME TESTS FAILED"
        echo "-------------------------------------------"
        return 1
    fi
}
