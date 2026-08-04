#!/bin/bash
# tests/test_configs.sh - Static syntax/config validation for every shell
# script, nftables ruleset, and inittab that ships in the ISOs.
# No VM boot required.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

group "Config syntax: client shell scripts"
for f in "$REPO_ROOT"/client/configs/*.sh "$REPO_ROOT"/client/configs/start-river \
         "$REPO_ROOT"/client/configs/assemble-iso "$REPO_ROOT"/client/configs/hdd-isolation \
         "$REPO_ROOT"/client/configs/autologin "$REPO_ROOT"/client/configs/genapkovl-myi2pd.sh \
         "$REPO_ROOT"/client/configs/i2p-keepalive.sh "$REPO_ROOT"/client/configs/pentest-extra.sh; do
    [ -f "$f" ] || continue
    case "$f" in
        *.sh|start-river|assemble-iso|hdd-isolation|autologin|pentest-extra.sh) assert_shell_syntax "$f" "sh syntax: $(basename "$f")" ;;
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

group "Config syntax: LibreWolf dark mode"
# The GUI ships dark-by-default. Two layers must both be asserted: the
# config must force the browser chrome/theme to dark (ui.systemUsesDarkTheme)
# AND darken web content (prefers-color-scheme + Dark Reader). A config that
# only sets the Dark Reader extension pref leaves the chrome rendering light.
OVERRIDES="$REPO_ROOT/client/configs/librewolf.overrides.cfg"
assert_contains "$OVERRIDES" 'ui.systemUsesDarkTheme", 1' \
    "LibreWolf forces the browser chrome to the dark theme"
assert_contains "$OVERRIDES" 'layout.css.prefers-color-scheme.content", 3' \
    "LibreWolf forces web content to prefers-color-scheme: dark"
assert_contains "$OVERRIDES" 'extensions.darkreader.enableByDefault", true' \
    "Dark Reader is enabled by default"
# The Dark Reader extension must actually ship on the ISO, not just be
# referenced in prefs.
if [ -f "$REPO_ROOT/client/extensions/addon@darkreader.org.xpi" ]; then
    pass "Dark Reader xpi ships in client/extensions"
else
    fail "Dark Reader xpi missing from client/extensions"
fi
assert_contains "$REPO_ROOT/client/configs/policies.json" 'addon@darkreader.org' \
    "policies.json force-installs Dark Reader"
assert_contains "$REPO_ROOT/client/configs/librewolf-launcher" 'librewolf.overrides.cfg' \
    "librewolf-launcher copies overrides into session profile"

group "Config syntax: wallpaper wiring"
assert_contains "$REPO_ROOT/client/configs/river_init" 'swaybg -i /etc/wallpaper/wallpaper.png' \
    "river_init references wallpaper.png (not .avif - GdkPixbuf can't decode AVIF)"
assert_contains "$REPO_ROOT/client/configs/river_init" '-m fill' \
    "river_init fills screen with wallpaper"

group "Config syntax: apk world packages"
# World file must be non-empty and list agetty (autologin) + river (GUI).
WORLD="$REPO_ROOT/client/configs/assemble-iso"
assert_contains "$WORLD" 'river-classic' "world includes river-classic"
assert_contains "$WORLD" 'agetty' "world includes agetty"
assert_contains "$WORLD" 'seatd' "world includes seatd"
assert_contains "$WORLD" 'librewolf' "world includes librewolf"

group "Config syntax: pentest build pipeline"
# Most pentest packages live in edge/testing; the build must add that repo.
assert_contains "$WORLD" 'alpine/edge/testing' "assemble-iso adds edge/testing repo"
assert_contains "$WORLD" 'pentest-apks.list' "assemble-iso appends pentest-apks.list to world"
assert_contains "$WORLD" 'pentest-lazy.list' "assemble-iso excludes pentest-lazy.list from world"
# The mkimg profile reads the pentest apk list into the ISO apk cache.
assert_contains "$REPO_ROOT/client/configs/mkimg.myi2pd.sh" 'pentest-apks.list' \
    "mkimg profile bakes pentest apks into ISO cache"
# It MUST strip comments when reading the list - apk treats each world token as
# a package and "#" comment words fail the build (seen in CI).
assert_contains "$REPO_ROOT/client/configs/mkimg.myi2pd.sh" "sed -e 's/#.*//'" \
    "mkimg profile strips comments from pentest-apks.list"
assert_contains "$REPO_ROOT/client/configs/assemble-iso" "sed -e 's/#.*//'" \
    "assemble-iso strips comments when appending to world"
# Build scripts (local + CI) must ship the three pentest files into the overlay.
for f in "$REPO_ROOT/client/build_iso.sh" "$REPO_ROOT/.github/workflows/build.yml"; do
    assert_contains "$f" 'pentest-apks.list' "$(basename "$f") copies pentest-apks.list"
    assert_contains "$f" 'pentest-lazy.list' "$(basename "$f") copies pentest-lazy.list"
    assert_contains "$f" 'pentest-extra.sh' "$(basename "$f") copies pentest-extra.sh"
done
# gcc must never be requested; clang20 is the compiler (lazy-loaded).
if grep -E '^gcc$' "$REPO_ROOT/client/configs/pentest-apks.list"; then
    fail "pentest-apks.list must not contain gcc"
else
    pass "pentest-apks.list has no gcc (uses clang20)"
fi
assert_contains "$REPO_ROOT/client/configs/pentest-apks.list" '^clang20$' "pentest list pins clang20"
# Every lazy-loaded package must exist in the full ISO-cache list (else the apk
# add at runtime would fail - the .apk would not be on the ISO).
if [ -f "$REPO_ROOT/client/configs/pentest-lazy.list" ]; then
    while IFS= read -r pkg; do
        case "$pkg" in ''|\#*) continue ;; esac
        if grep -qx "$pkg" "$REPO_ROOT/client/configs/pentest-apks.list"; then
            pass "lazy pkg $pkg present in pentest-apks.list (ISO cache)"
        else
            fail "lazy pkg $pkg missing from pentest-apks.list - not on ISO, cannot lazy-load"
        fi
    done < "$REPO_ROOT/client/configs/pentest-lazy.list"
else
    fail "pentest-lazy.list missing"
fi
# pypykatz: pure-Python Mimikatz, pip-installed (Alpine package pins old python).
assert_contains "$REPO_ROOT/client/configs/pentest-extra.sh" 'pypykatz' \
    "pentest-extra.sh pip-installs pypykatz"

group "Config syntax: on-demand AI stack (Docker/Ollama/Claurst)"
AI_EXTRA="$REPO_ROOT/client/configs/ai-extra.sh"
assert_file "$AI_EXTRA" "ai-extra.sh exists"
# The AI runtime stack (docker toolbox) ships as a lazy apk list so it installs
# ONLY on demand, never into the 4G tmpfs root at boot.
assert_file "$REPO_ROOT/client/configs/ai-apks.list" "ai-apks.list exists"
assert_contains "$REPO_ROOT/client/configs/ai-apks.list" 'docker' "ai list loads docker"
# The mkimg profile bakes the docker apks into the ISO on-disk cache (offline).
assert_contains "$REPO_ROOT/client/configs/mkimg.myi2pd.sh" 'ai-apks.list' \
    "mkimg profile bakes ai-apks into ISO cache"
# assemble-iso strips comments when it reads apk lists (Comment handling).
assert_contains "$REPO_ROOT/client/configs/assemble-iso" "ai-apks.list" \
    "assemble-iso references ai-apks.list"
# Crucially it must NOT append the docker stack to world (would break the 4G boot).
assert_not_contains "$REPO_ROOT/client/configs/assemble-iso" 'ai-apks.list.*>>.*world' \
    "assemble-iso keeps ai-apks lazy (never appended to world)"
# ai-extra.sh must load docker from the ISO repo, not assume internet.
assert_contains "$AI_EXTRA" 'ai-apks.list' "ai-extra.sh reads ai-apks.list (offline docker)"
assert_contains "$AI_EXTRA" '"myi2pd-ollama.squashfs"' "ai-extra.sh references the squashfs"
assert_contains "$AI_EXTRA" 'docker load' "ai-extra.sh docker-loads the Ollama image"
assert_contains "$AI_EXTRA" '--gpus all' "ai-extra.sh supports NVIDIA CUDA"
assert_contains "$AI_EXTRA" '/dev/kfd' "ai-extra.sh supports AMD ROCm (kfd/dri)"
assert_contains "$AI_EXTRA" 'install_claurst' "ai-extra.sh installs the Claurst agent"
assert_contains "$AI_EXTRA" 'CLAUDE.md' "ai-extra.sh installs the ingrained agent context"
# The agent context (CLAUDE.md/AGENTS.md) must prescribe the amnesiac restraints.
AGENTS="$REPO_ROOT/client/configs/AGENTS.md"
assert_file "$AGENTS" "agent context AGENTS.md exists"
assert_contains "$AGENTS" 'amnesiac' "agent context knows it is amnesiac"
assert_contains "$AGENTS" 'tmpfs' "agent context knows the root is tmpfs"
assert_contains "$AGENTS" 'default-drop' "agent context knows the firewall is default-drop"
assert_contains "$AGENTS" 'RAM' "agent context warns about memory limits"
# Build script + CI must ship the AI files into the overlay.
for f in "$REPO_ROOT/client/build_iso.sh" "$REPO_ROOT/.github/workflows/build.yml"; do
    assert_contains "$f" 'ai-apks.list' "$(basename "$f") copies ai-apks.list"
    assert_contains "$f" 'ai-extra.sh' "$(basename "$f") copies ai-extra.sh"
    assert_contains "$f" 'AGENTS.md' "$(basename "$f") ships agent context"
done
# The Ollama container Dockerfile must use the tiny glibc base, not the Ubuntu one.
OLL_DOCKER="$REPO_ROOT/client/ai/ollama/Dockerfile"
assert_file "$OLL_DOCKER" "Ollama container Dockerfile exists"
assert_contains "$OLL_DOCKER" 'chainguard/wolfi-base' "Ollama Dockerfile uses Wolfi glibc base"
assert_not_contains "$OLL_DOCKER" 'ubuntu:24.04' "Ollama Dockerfile avoids the heavy ubuntu base"
# It must fetch the standalone release tarball, NOT the 8GB official docker
# image - pulling that was what pinned the runner disk in CI.
assert_contains "$OLL_DOCKER" 'ollama-linux-amd64.tar.zst' \
    "Ollama Dockerfile downloads the standalone tar.zst release"
assert_contains "$OLL_DOCKER" 'zstd -dc' "Ollama Dockerfile extracts the zst tarball"
assert_not_contains "$OLL_DOCKER" 'FROM ollama/ollama' \
    "Ollama Dockerfile never pulls the 8GB official image"
# The tarball's lib/ollama/ tree is what we layer onto Wolfi.
assert_contains "$OLL_DOCKER" 'cuda_v12' "Ollama Dockerfile keeps NVIDIA CUDA v12 backend"
assert_contains "$OLL_DOCKER" 'vulkan' "Ollama Dockerfile keeps Vulkan backend (AMD/Intel)"
# Squashfs builder script exists and calls mksquashfs.
assert_file "$REPO_ROOT/client/ai/build_ollama_squashfs.sh" "squashfs builder exists"
assert_contains "$REPO_ROOT/client/ai/build_ollama_squashfs.sh" 'mksquashfs' \
    "squashfs builder invokes mksquashfs"
# CI produces + uploads the on-demand squashfs artifact.
assert_contains "$REPO_ROOT/.github/workflows/build.yml" 'myi2pd-ollama.squashfs' \
    "CI builds + uploads the Ollama squashfs artifact"

summary
exit $?

