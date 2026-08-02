#!/bin/bash
# tests/test_configs.sh - Static syntax/config validation for every shell
# script, nftables ruleset, and inittab that ships in the ISOs.
# No VM boot required.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

group "Config syntax: client shell scripts"
for f in "$REPO_ROOT"/client/configs/*.sh "$REPO_ROOT"/client/configs/start-river \
         "$REPO_ROOT"/client/configs/assemble-iso "$REPO_ROOT"/client/configs/hdd-isolation \
         "$REPO_ROOT"/client/configs/autologin "$REPO_ROOT"/client/configs/genapkovl-myi2pd.sh \
         "$REPO_ROOT"/client/configs/i2p-keepalive.sh; do
    [ -f "$f" ] || continue
    case "$f" in
        *.sh|start-river|assemble-iso|hdd-isolation|autologin) assert_shell_syntax "$f" "sh syntax: $(basename "$f")" ;;
    esac
done

group "Config syntax: VPS shell scripts"
for f in "$REPO_ROOT"/vps/configs/*.sh "$REPO_ROOT"/vps/configs/assemble-vps-iso \
         "$REPO_ROOT"/vps/configs/genapkovl-myi2pd-vps.sh; do
    [ -f "$f" ] || continue
    case "$f" in
        *.sh|assemble-vps-iso) assert_shell_syntax "$f" "sh syntax: $(basename "$f")" ;;
    esac
done

group "Config syntax: shared scripts"
for f in "$REPO_ROOT"/shared/*.sh "$REPO_ROOT"/shared/test_vm.sh \
         "$REPO_ROOT"/shared/test_pair.sh "$REPO_ROOT"/shared/test_vm_pair.sh \
         "$REPO_ROOT"/shared/test_vps_only.sh "$REPO_ROOT"/shared/deploy_or_restore.sh \
         "$REPO_ROOT"/test-it.sh; do
    [ -f "$f" ] || continue
    assert_shell_syntax "$f" "sh syntax: $(basename "$f")"
done

group "Config syntax: nftables rulesets"
# nft -c needs CAP_NET_ADMIN; run it only when we can, otherwise fall back to
# a structural check so the test is usable in unprivileged CI too.
if command -v nft >/dev/null 2>&1 && nft -c -f "$REPO_ROOT/client/configs/nftables.nft" 2>/dev/null; then
    pass "client nftables.nft parses with nft -c"
else
    assert_file "$REPO_ROOT/client/configs/nftables.nft" "client nftables.nft exists"
    assert_contains "$REPO_ROOT/client/configs/nftables.nft" 'table inet filter' "client nft has filter table"
    assert_contains "$REPO_ROOT/client/configs/nftables.nft" 'chain input' "client nft has input chain"
fi
if command -v nft >/dev/null 2>&1 && nft -c -f "$REPO_ROOT/vps/configs/nftables.nft" 2>/dev/null; then
    pass "vps nftables.nft parses with nft -c"
else
    assert_file "$REPO_ROOT/vps/configs/nftables.nft" "vps nftables.nft exists"
    assert_contains "$REPO_ROOT/vps/configs/nftables.nft" 'table inet filter' "vps nft has filter table"
    assert_contains "$REPO_ROOT/vps/configs/nftables.nft" 'chain input' "vps nft has input chain"
fi

group "Config syntax: inittab"
assert_file "$REPO_ROOT/client/configs/inittab" "client inittab exists"
assert_contains "$REPO_ROOT/client/configs/inittab" "::sysinit:/sbin/openrc sysinit" \
    "inittab has openrc sysinit"
assert_contains "$REPO_ROOT/client/configs/inittab" "::wait:/sbin/openrc default" \
    "inittab runs openrc default runlevel"
assert_contains "$REPO_ROOT/client/configs/inittab" "tty1::respawn:/sbin/agetty --autologin root" \
    "inittab autologins root on tty1"

group "Config syntax: i2pd.conf"
assert_file "$REPO_ROOT/vps/configs/i2pd.conf" "vps i2pd.conf exists"
assert_contains "$REPO_ROOT/vps/configs/i2pd.conf" '\[httpproxy\]' "i2pd httpproxy section"
assert_contains "$REPO_ROOT/vps/configs/i2pd.conf" 'port = 4444' "i2pd httpproxy on 4444"
assert_contains "$REPO_ROOT/vps/configs/i2pd.conf" '\[socksproxy\]' "i2pd socksproxy section"
assert_contains "$REPO_ROOT/vps/configs/i2pd.conf" 'port = 4447' "i2pd socksproxy on 4447"
assert_contains "$REPO_ROOT/vps/configs/i2pd.conf" '\[reseed\]' "i2pd reseed section"

group "Config syntax: profile/autologin wiring"
assert_contains "$REPO_ROOT/client/configs/start-river" 'river &>/tmp/river.log' \
    "start-river launches river"
assert_contains "$REPO_ROOT/client/configs/start-river" 'WLR_RENDERER=pixman' \
    "start-river uses pixman renderer (no GPU in VM)"

group "Config syntax: apk world packages"
# World file must be non-empty and list agetty (autologin) + river (GUI).
WORLD="$REPO_ROOT/client/configs/assemble-iso"
assert_contains "$WORLD" 'river-classic' "world includes river-classic"
assert_contains "$WORLD" 'agetty' "world includes agetty"
assert_contains "$WORLD" 'seatd' "world includes seatd"
assert_contains "$WORLD" 'librewolf' "world includes librewolf"

summary
exit $?

