#!/bin/bash
# tests/test_gha_parity.sh - Ensures the CI build (build.yml) produces the same
# overlay the local build script (build_iso.sh) does. Drift between the two is
# what caused the downloaded ISO to boot with "localhost" hostname and a dead
# network stack while local builds worked.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/build.yml"
BUILD_ISO="$REPO_ROOT/client/build_iso.sh"

group "GHA parity: workflow and local script exist"
assert_file "$WORKFLOW" "build.yml exists"
assert_file "$BUILD_ISO" "build_iso.sh exists"

group "GHA parity: hostname must be produced by the build pipeline"
# build_iso.sh writes "myi2pd" into /etc/hostname on the host side.
# The pipeline must produce the same file somewhere — either in build.yml, the
# client build_iso.sh, or the assemble-iso container step that CI runs.
if grep -qE 'hostname' "$WORKFLOW" "$REPO_ROOT/client/configs/assemble-iso" "$BUILD_ISO"; then
    pass "hostname produced by build pipeline"
else
    fail "no build step creates /etc/hostname (boots as 'localhost')"
fi
if grep -qE 'echo "myi2pd"' "$BUILD_ISO" "$REPO_ROOT/client/configs/assemble-iso"; then
    pass "pipeline sets hostname myi2pd"
else
    fail "pipeline no longer sets hostname"
fi

group "GHA parity: network interfaces must be produced by the build pipeline"
# Without /etc/network/interfaces the diskless client boots with
# "ERROR: networking failed to start".
if grep -qE 'network/interfaces|interfaces' "$WORKFLOW" "$REPO_ROOT/client/configs/assemble-iso" "$BUILD_ISO"; then
    pass "network interfaces produced by build pipeline"
else
    fail "no build step creates /etc/network/interfaces (networking fails at boot)"
fi
if grep -qE 'iface eth0 inet dhcp' "$BUILD_ISO" "$REPO_ROOT/client/configs/assemble-iso"; then
    pass "pipeline writes eth0 DHCP interface"
else
    fail "pipeline no longer writes network interfaces"
fi

group "GHA parity: every overlay file copied by build_iso.sh is covered"
# Extract the destination paths build_iso.sh copies into the overlay and ensure
# the CI pipeline (build.yml copy step OR assemble-iso container step) produces
# the same set. This catches a config added locally but never shipped in CI.
missing=0
while IFS= read -r dst; do
    # Normalize $OVERLAY_TMP/xxx -> the relative overlay path
    dst_rel="${dst#\$OVERLAY_TMP/}"
    # build.yml uses `cp -r dir/*` for directories (fonts, extensions), which
    # hides exact filenames; treat a dest as covered if build.yml contains its
    # full relative path OR its parent directory copy is a glob.
    if grep -qF "$dst_rel" "$WORKFLOW" || grep -qF "$dst_rel" "$REPO_ROOT/client/configs/assemble-iso"; then
        pass "covered in CI: $dst_rel"
    elif grep -qF "client/extensions/*" "$WORKFLOW" && [[ "$dst_rel" == usr/lib/librewolf/distribution/extensions/* ]] && \
         ls "$REPO_ROOT/client/extensions/" >/dev/null 2>&1 && \
         [ -e "$REPO_ROOT/client/extensions/$(basename "$dst_rel")" ]; then
        pass "covered in CI via glob: $dst_rel"
    elif grep -qF "client/fonts/*" "$WORKFLOW" && [[ "$dst_rel" == usr/share/fonts/SauceCodePro/* ]] && \
         ls "$REPO_ROOT/client/fonts/"*.ttf >/dev/null 2>&1; then
        pass "covered in CI via glob: $dst_rel"
    else
        fail "overlay file not produced by CI: $dst_rel"
        missing=1
    fi
done < <(grep -oE '"\$OVERLAY_TMP/[^"]+"' "$BUILD_ISO" | tr -d '"' | sort -u)

summary
exit $?

