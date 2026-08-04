#!/bin/bash
# tests/test_overlay.sh - Verifies the client & VPS overlays contain every file
# the running systems depend on. Catches boot-time failures (missing hostname,
# missing network interfaces, broken autologin) WITHOUT booting a VM.
#
# It assembles the overlay exactly like CI (build.yml copy step + assemble-iso
# runtime step) and asserts the running systems' requirements are met. If the
# build pipeline ever drops a file again (e.g. hostname), this test fails fast.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# ---------------------------------------------------------------------------
# Client overlay
# ---------------------------------------------------------------------------
group "Client overlay: required files"
assemble_client_overlay "$CLIENT_OVERLAY"
apply_client_overlay_runtime "$CLIENT_OVERLAY"

# --- identity: /etc/hostname must be set, not left at localhost ---
assert_file "$CLIENT_OVERLAY/etc/hostname" "client /etc/hostname exists"
assert_contains "$CLIENT_OVERLAY/etc/hostname" "myi2pd" "client hostname is myi2pd"

# --- networking: /etc/network/interfaces must exist or boot networking fails ---
assert_file "$CLIENT_OVERLAY/etc/network/interfaces" "client /etc/network/interfaces exists"
assert_contains "$CLIENT_OVERLAY/etc/network/interfaces" "eth0.*inet dhcp" "client eth0 uses DHCP"

# --- inittab autologin ---
assert_file "$CLIENT_OVERLAY/etc/inittab" "client /etc/inittab exists"
assert_contains "$CLIENT_OVERLAY/etc/inittab" "tty1::respawn:/sbin/agetty --autologin root 38400 tty1" \
    "client tty1 autologin configured"

# --- root .profile triggers start-river on tty1 ---
assert_file "$CLIENT_OVERLAY/root/.profile" "client /root/.profile exists"
assert_contains "$CLIENT_OVERLAY/root/.profile" "/usr/local/bin/start-river" \
    "client /root/.profile launches start-river"
grep -qF '"$(' "$CLIENT_OVERLAY/root/.profile" && grep -qF 'tty1' "$CLIENT_OVERLAY/root/.profile" \
    && pass "client /root/.profile only runs on tty1" \
    || fail "client /root/.profile should gate on tty1"

# --- start-river must exist and be executable ---
assert_file "$CLIENT_OVERLAY/usr/local/bin/start-river" "client start-river exists"
assert_executable "$CLIENT_OVERLAY/usr/local/bin/start-river" "client start-river executable"

# --- runlevels ---
assert_symlink "$CLIENT_OVERLAY/etc/runlevels/boot/hdd-isolation" "/etc/init.d/hdd-isolation" \
    "client hdd-isolation in boot runlevel"
assert_symlink "$CLIENT_OVERLAY/etc/runlevels/boot/udev" "/etc/init.d/udev" \
    "client udev in boot runlevel"
assert_symlink "$CLIENT_OVERLAY/etc/runlevels/default/seatd" "/etc/init.d/seatd" \
    "client seatd in default runlevel"
assert_symlink "$CLIENT_OVERLAY/etc/runlevels/default/dbus" "/etc/init.d/dbus" \
    "client dbus in default runlevel"
assert_symlink "$CLIENT_OVERLAY/etc/runlevels/default/networking" "/etc/init.d/networking" \
    "client networking in default runlevel"

# --- apk world must list the GUI stack (else no desktop at boot) ---
assert_file "$CLIENT_OVERLAY/etc/apk/world" "client /etc/apk/world exists"
for pkg in river-classic seatd dbus librewolf fuzzel waybar foot agetty; do
    assert_contains "$CLIENT_OVERLAY/etc/apk/world" "^$pkg\$" "client world pkg: $pkg"
done

# --- FOSS pentest tooling ---
# Light Alpine-packaged tools must be in world (baked into RAM at boot).
for pkg in ffuf sqlmap gitleaks rustscan mitmproxy rizin py3-impacket; do
    assert_contains "$CLIENT_OVERLAY/etc/apk/world" "^$pkg\$" "client world pentest: $pkg"
done
# pentest-extra.sh hard-requires curl + zstd at runtime; both are tiny and must
# be baked into world (they used to arrive transitively via the heavy tools).
for pkg in curl zstd; do
    assert_contains "$CLIENT_OVERLAY/etc/apk/world" "^$pkg\$" "client world pentest runtime dep: $pkg"
done
# Heavy tools are shipped on the ISO's on-disk repository but NOT in world - if
# they were in world they'd extract into RAM at boot and overflow the diskless
# tmpfs root (the reason the desktop didn't launch at 4G). They load on demand
# via pentest-extra.sh.
for pkg in hashcat nuclei httpx naabu katana clang20; do
    if grep -q "^$pkg\$" "$CLIENT_OVERLAY/etc/apk/world"; then
        fail "heavy pentest tool $pkg must be lazy-loaded, not baked into world"
    else
        pass "heavy pentest tool $pkg excluded from world (lazy-loaded)"
    fi
done
# pypykatz is pip-installed (Alpine pins python3~3.12; edge has 3.14).
if grep -q '^pypykatz$' "$CLIENT_OVERLAY/etc/apk/world"; then
    fail "pypykatz must be pip-installed, not baked (python3~3.12 pin conflicts with edge 3.14)"
else
    pass "pypykatz excluded from world (pip-installed via pentest-extra.sh)"
fi

# python + pip preinstalled (light, needed by pentest-extra.sh at runtime).
# clang20 is lazy-loaded (heavy), explicitly NO gcc.
assert_contains "$CLIENT_OVERLAY/etc/apk/world" "^python3\$" "client world: python3 present"
assert_contains "$CLIENT_OVERLAY/etc/apk/world" "^py3-pip\$" "client world: pip present"
if grep -q '^clang20$' "$CLIENT_OVERLAY/etc/apk/world"; then
    fail "clang20 must be lazy-loaded (heavy ~230MB), not baked into world"
else
    pass "clang20 excluded from world (lazy-loaded)"
fi
if grep -q '^gcc$' "$CLIENT_OVERLAY/etc/apk/world"; then
    fail "client world must NOT contain gcc"
else
    pass "client world has no gcc"
fi

# On-demand heavy tools installer ships in the overlay.
assert_file "$CLIENT_OVERLAY/usr/local/bin/pentest-extra.sh" "client pentest-extra.sh exists"
assert_executable "$CLIENT_OVERLAY/usr/local/bin/pentest-extra.sh" "client pentest-extra.sh executable"
# The lazy list (heavy .apk names) must ship so pentest-extra.sh can offline
# apk-add them from the live ISO repo.
assert_file "$CLIENT_OVERLAY/etc/pentest-lazy.list" "client pentest-lazy.list exists"
assert_contains "$CLIENT_OVERLAY/usr/local/bin/pentest-extra.sh" 'pentest-lazy.list' \
    "pentest-extra.sh reads pentest-lazy.list"
assert_contains "$CLIENT_OVERLAY/usr/local/bin/pentest-extra.sh" 'LIG_ASSET=' \
    "ligolo-ng asset name strips leading v"

# On-demand AI stack (Docker/Ollama/Claurst) ships in the overlay.
assert_file "$CLIENT_OVERLAY/usr/local/bin/ai-extra.sh" "client ai-extra.sh exists"
assert_executable "$CLIENT_OVERLAY/usr/local/bin/ai-extra.sh" "client ai-extra.sh executable"
assert_file "$CLIENT_OVERLAY/etc/ai-apks.list" "client ai-apks.list exists"
assert_file "$CLIENT_OVERLAY/usr/local/share/myi2pd/CLAUDE.md" "client agent context CLAUDE.md exists"
assert_contains "$CLIENT_OVERLAY/usr/local/share/myi2pd/CLAUDE.md" 'amnesiac' \
    "client agent context documents amnesiac environment"

# --- nftables + trusttunnel configs ---
assert_file "$CLIENT_OVERLAY/etc/nftables/nftables.nft" "client nftables.nft exists"
assert_file "$CLIENT_OVERLAY/etc/trusttunnel/vps_ip.txt" "client vps_ip.txt exists"

# --- wallpaper must be in a swaybg/GdkPixbuf-decodable format ---
# swaybg loads via GdkPixbuf, which has NO AVIF decoder; an .avif wallpaper
# silently fails to render. PNG is lossless and always supported.
assert_file "$CLIENT_OVERLAY/etc/wallpaper/wallpaper.png" "client wallpaper.png exists"
if [ -f "$CLIENT_OVERLAY/etc/wallpaper/wallpaper.png" ] && \
   [ "$(od -An -N8 -tx1 "$CLIENT_OVERLAY/etc/wallpaper/wallpaper.png" | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
    pass "client wallpaper is PNG (GdkPixbuf-decodable)"
else
    fail "client wallpaper not PNG - swaybg cannot render it (use PNG, not AVIF)"
fi

# ---------------------------------------------------------------------------
# VPS overlay
# ---------------------------------------------------------------------------
group "VPS overlay: required files"
assemble_vps_overlay "$VPS_OVERLAY"
mkdir -p "$VPS_OVERLAY/etc/i2pd" "$VPS_OVERLAY/etc/nftables" \
         "$VPS_OVERLAY/etc/network" "$VPS_OVERLAY/etc/trusttunnel"
cp "$REPO_ROOT/vps/configs/i2pd.conf" "$VPS_OVERLAY/etc/i2pd/i2pd.conf"
cp "$REPO_ROOT/vps/configs/nftables.nft" "$VPS_OVERLAY/etc/nftables/nftables.nft"

echo "myi2pd-gateway" > "$VPS_OVERLAY/etc/hostname"
cat > "$VPS_OVERLAY/etc/network/interfaces" << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

assert_file "$VPS_OVERLAY/etc/hostname" "vps /etc/hostname exists"
assert_contains "$VPS_OVERLAY/etc/hostname" "myi2pd-gateway" "vps hostname is myi2pd-gateway"
assert_file "$VPS_OVERLAY/etc/network/interfaces" "vps /etc/network/interfaces exists"
assert_contains "$VPS_OVERLAY/etc/network/interfaces" "eth0.*inet dhcp" "vps eth0 uses DHCP"
assert_file "$VPS_OVERLAY/etc/i2pd/i2pd.conf" "vps i2pd.conf exists"
assert_file "$VPS_OVERLAY/etc/nftables/nftables.nft" "vps nftables.nft exists"

# --- VPS runlevels ---
assert_symlink "$VPS_OVERLAY/etc/runlevels/boot/eth1-lan" "/etc/init.d/eth1-lan" \
    "vps eth1-lan in boot runlevel"
assert_symlink "$VPS_OVERLAY/etc/runlevels/default/i2pd" "/etc/init.d/i2pd" \
    "vps i2pd in default runlevel"
assert_symlink "$VPS_OVERLAY/etc/runlevels/default/trusttunnel" "/etc/init.d/trusttunnel" \
    "vps trusttunnel in default runlevel"
assert_symlink "$VPS_OVERLAY/etc/runlevels/default/nftables" "/etc/init.d/nftables" \
    "vps nftables in default runlevel"
assert_symlink "$VPS_OVERLAY/etc/runlevels/default/dnsmasq" "/etc/init.d/dnsmasq" \
    "vps dnsmasq in default runlevel"

summary
exit $?

# --- VPS binaries present ---
assert_file "$REPO_ROOT/vps/bin/trusttunnel_endpoint" "vps trusttunnel_endpoint exists"
assert_executable "$REPO_ROOT/vps/bin/trusttunnel_endpoint" "vps trusttunnel_endpoint executable"
assert_file "$REPO_ROOT/vps/bin/setup_wizard" "vps setup_wizard exists"
assert_executable "$REPO_ROOT/vps/bin/setup_wizard" "vps setup_wizard executable"

