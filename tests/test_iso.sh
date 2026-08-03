#!/bin/bash
# tests/test_iso.sh - Validates a BUILT ISO's apkovl without booting it.
# Usage: tests/test_iso.sh [path-to.iso]
# Extracts the embedded apkovl tarball and verifies every boot-critical file is
# present. This is the "smoke test" that catches a bad artifact immediately.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ISO="${1:-}"
# Resolve relative ISO paths against the repo root, not the tests/ CWD.
if [ -n "$ISO" ] && [ ! -f "$ISO" ]; then
    [ -f "$REPO_ROOT/$ISO" ] && ISO="$REPO_ROOT/$ISO"
fi
if [ -z "$ISO" ]; then
    # auto-detect ISOs in repo root
    for cand in "$REPO_ROOT"/myi2pd-amnesiac.iso "$REPO_ROOT"/myi2pd-vps.iso; do
        [ -f "$cand" ] && ISO="$cand" && break
    done
fi

if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
    echo "SKIP  test_iso.sh: no ISO found (pass one as an argument)"
    echo "      $0 /path/to/myi2pd-amnesiac.iso"
    exit 0
fi

command -v 7z >/dev/null 2>&1 || { echo "SKIP  test_iso.sh: 7z not installed"; exit 0; }

TMP="$SCRIPT_DIR/.tmp-iso"
rm -rf "$TMP"
mkdir -p "$TMP"

echo "Using ISO: $ISO ($(du -h "$ISO" | cut -f1))"

# --- basic ISO structure ---
group "ISO structure: $ISO"
7z l "$ISO" > "$TMP/listing.txt" 2>/dev/null
assert_contains "$TMP/listing.txt" "boot/vmlinuz" "ISO has kernel vmlinuz"
assert_contains "$TMP/listing.txt" "boot/initramfs" "ISO has initramfs"
assert_contains "$TMP/listing.txt" "boot/modloop" "ISO has modloop"
assert_contains "$TMP/listing.txt" "apks/x86_64" "ISO has package cache"

# --- find apkovl by name (alpine ISO embeds it at the root) ---
APKOVL=$(grep -oE '[A-Za-z0-9_.~-]+\.apkovl\.tar\.gz' "$TMP/listing.txt" | head -1)
if [ -z "$APKOVL" ]; then
    fail "ISO has no .apkovl.tar.gz"
    rm -rf "$TMP"
    summary
    exit $?
fi
pass "ISO contains apkovl: $APKOVL"

7z e -y "$ISO" "$APKOVL" -o"$TMP" >/dev/null 2>&1
tar -tzf "$TMP/$APKOVL" > "$TMP/apkovl-list.txt" 2>/dev/null

# --- apkovl content checks ---
group "apkovl content: $APKOVL"
case "$ISO" in
    *amnesiac*|*client*)
        # Client (amnesiac) ISO: graphical diskless Alpine client
        assert_contains "$TMP/apkovl-list.txt" "./etc/inittab" "apkovl has inittab"
        assert_contains "$TMP/apkovl-list.txt" "./root/.profile" "apkovl has /root/.profile"
        assert_contains "$TMP/apkovl-list.txt" "start-river" "apkovl has start-river"
        assert_contains "$TMP/apkovl-list.txt" "./etc/apk/world" "apkovl has /etc/apk/world"

        # hostname + interfaces MUST be in the apkovl (they were the missing pieces)
        if grep -q './etc/hostname' "$TMP/apkovl-list.txt"; then
            pass "apkovl has /etc/hostname"
        else
            fail "apkovl MISSING /etc/hostname (ISO will boot as 'localhost')"
        fi
        if grep -q './etc/network/interfaces' "$TMP/apkovl-list.txt"; then
            pass "apkovl has /etc/network/interfaces"
        else
            fail "apkovl MISSING /etc/network/interfaces (networking fails at boot)"
        fi

        # runlevel symlinks must be present
        for l in "./etc/runlevels/default/networking" "./etc/runlevels/default/seatd"; do
            if grep -qF "$l" "$TMP/apkovl-list.txt"; then
                pass "apkovl has $l"
            else
                fail "apkovl MISSING $l"
            fi
        done
        ;;
    *vps*|*gateway*)
        # VPS ISO: headless i2pd gateway (no GUI, no autologin)
        assert_contains "$TMP/apkovl-list.txt" "trusttunnel_endpoint" "apkovl has trusttunnel_endpoint"
        assert_contains "$TMP/apkovl-list.txt" "setup_wizard" "apkovl has setup_wizard"
        assert_contains "$TMP/apkovl-list.txt" "./etc/i2pd/i2pd.conf" "apkovl has i2pd.conf"
        assert_contains "$TMP/apkovl-list.txt" "./etc/nftables.nft" "apkovl has nftables.nft"
        for l in "./etc/runlevels/default/i2pd" "./etc/runlevels/default/networking"; do
            if grep -qF "$l" "$TMP/apkovl-list.txt"; then
                pass "apkovl has $l"
            else
                fail "apkovl MISSING $l"
            fi
        done
        ;;
    *) fail "unknown ISO type: $ISO" ;;
esac

# For the client ISO, verify the autologin + start-river wiring in the actual
# shipped files (not just the source tree).
case "$ISO" in
    *amnesiac*)
        group "Client ISO: autologin wiring"
        tar -xzf "$TMP/$APKOVL" -C "$TMP" ./etc/inittab ./root/.profile 2>/dev/null
        assert_contains "$TMP/etc/inittab" "agetty --autologin root 38400 tty1" \
            "shipped inittab autologins root on tty1"
        assert_contains "$TMP/root/.profile" "/usr/local/bin/start-river" \
            "shipped .profile launches start-river"
        grep -qF 'tty1' "$TMP/root/.profile" \
            && pass "shipped .profile gates on tty1" \
            || fail "shipped .profile should gate on tty1"
        ;;
esac

rm -rf "$TMP"
summary
exit $?

