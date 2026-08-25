# AGENTS.md / CLAUDE.md - myi2pd amnesiac client

You are running inside **myi2pd**, a hardened, anti-forensic, double-tunnel
network gateway that boots a diskless Alpine Linux live OS into **RAM only**.
Everything below is context you must respect. This file is the single source of
truth for your operating environment and capabilities.

---

## 1. THE MOST IMPORTANT FACT: THIS SYSTEM IS AMNESIAC

- The OS boots into an **ephemeral tmpfs root**. There is NO local persistent
  disk in use. The working root lives entirely in RAM (`/dev/nvme0n1p8` is the
  *host* disk, do not assume it is yours).
- **Pulling the USB stick (or reboot/power-off) permanently wipes everything.**
  Nothing you write to `/`, `/tmp`, `/root`, or `/home` survives a reboot.
- Assumption: assume any session is **single-shot** and non-persistent.
  - Save any work you must keep to an explicit, user-sanctioned target
    (a scratch mount the user points you at, or git push). Otherwise treat
    everything as disposable.
  - Do not install packages you do not need. Do not leave daemons running when
    the task is done.
- The block devices are **locked read-only** by the `hdd-isolation` boot
  service (`blockdev --setro`). Do not try to write to raw block devices; you
  will get I/O errors and you are defeating a deliberate safeguard.

## 2. NETWORKING: DOUBLE TUNNEL + KILL-SWITCH

- Two tunnels carry all egress:
  - **Outer**: VLESS + XTLS-Reality (TCP 443) from client → VPS — Reality "steal" impersonates microsoft.com TLS handshake, no domain registration, active probes forwarded to real microsoft.com.
  - **Inner**: I2P garlic routing via SOCKS5 through i2pd on the VPS.
- `nftables` is set to **default-drop**. Outbound is *only* permitted toward the
  VPS IP on port 443; everything else routes via `tun0` into the tunnel.
- Consequences you MUST respect:
  - Plain cleartext egress to arbitrary hosts is **blocked by the firewall**.
    Do not assume generic internet access; expect it to fail.
  - **All traffic is observable at the VPS** (it is the exit). The client has
    zero transit tunnels, so outbound HTTP/HTTPS must go through the tunnel
    (e.g. the browser is pointed at the local SOCKS proxy `127.0.0.1:4447`).
  - Tools that make conventional direct connections (curl to the open internet)
    may hang or fail. Prefer routing through the tunnel, or ask the user how
    they want egress handled for a given task.
- Local services:
  - SOCKS5 proxy: `127.0.0.1:4447` (i2p tunnel; also the browser's proxy).
  - I2P HTTP proxy: `127.0.0.1:4444`.
  - Ollama (when started): `127.0.0.1:11434` (OpenAI-compatible at `/v1`).

## 3. HARDWARE / PERFORMANCE REALITY

- Boots into **~4 GB of RAM**, diskless. Memory is the scarcest resource.
  - Root can occupy up to 80% of RAM (rootflags=size=80%). Keep additions small.
  - Prefer launching the smallest useful model; larger models will OOM.
  - Ollama's model cache lives in tmpfs - a model you pull is ephemeral and
    occupies working RAM while loaded. Pull only what is needed.
- No stable GPU in the default VM (basic framebuffer). On real hardware NVIDIA
  (CUDA) and AMD (ROCm) are supported for inference via the container, but a GPU
  is an on-demand extra - never assume fast inference is available.

## 4. DESKTOP / UI

- Session uses the `river` tiling Wayland compositor on tty1 (auto-login root).
- Waybar status bar, `foot` terminal, `fuzzel` app launcher, `swaybg` wallpaper.
- Browser: **LibreWolf** (hardened: Tor-style letterboxing, remote DNS via the
  SOCKS proxy, uBlock/NoScript, JIT disabled, dark theme). It is the principal
  client UI and is already configured - do not "fix" it.
- Wallpaper/theme are system-managed; do not alter desktop configuration files.

## 5. ALL AVAILABLE TOOLS (YOUR TOOLKIT)

Alpine-packaged CLI tools ship on the ISO. Heavy/non-Alpine tooling is loaded
ON DEMAND and lives in RAM only until reboot:

- **Browser / mail / torrents**
  - `librewolf-launcher` - hardened browser launcher (use for web work)
  - `neomutt-i2p` - email client routed over I2P
  - `aria2c` with `qbittorrent-i2p` - torrent client; all traffic forced through
    the I2P SOCKS proxy (DHT/peer-exchange disabled)
- **Networking / tunnels**
  - `wifi-connect.sh` - Wi-Fi setup (takes creds in RAM, pins firewall to VPS)
  - `i2p-keepalive.sh` - keeps the i2p tunnel alive
  - `xray` - VLESS + XTLS-Reality tunnel binary (client)
  - `nftables` - firewall config (default-drop kill switch)
- **Pentest / security** (Alpine `.apk` on the ISO; load via
  `/usr/local/bin/pentest-extra.sh`): `ffuf`, `sqlmap`, `hashcat`, `gitleaks`,
  `nuclei`, `httpx`, `naabu`, `katana`, `rustscan`, `mitmproxy`, `rizin`,
  `py3-impacket`, `clang20`, `python3`, `py3-pip`
- **Pentest non-Alpine / on-demand** (also via `pentest-extra.sh`, via pip/go):
  `kerbrute`, `ligolo-agent`/`ligolo-proxy`, `sliver`, `netexec`, `certipy`,
  `coercer`, `evil-winrm`, `pypykatz`
- **AI agent / local inference** (load via `/usr/local/bin/ai-extra.sh`):
  - `claurst` - the coding agent (you). Native single binary, no telemetry.
  - Ollama container - local LLM inference (CPU + NVIDIA + AMD), OpenAI
    compatible at `http://127.0.0.1:11434/v1`, loaded from an on-disk squashfs.
- **Desktop / system**: `fuzzel`, `foot`, `waybar`, `river`, `swaybg`,
  `ncneofetch`, `agetty`, `bash`, `openssl`, `udev`, `util-linux`
- VPS-side (not on the client): `i2pd`, `xray` (VLESS+Reality server), `dnsmasq`.

Check what is present with `command -v <tool>` or `ls /usr/local/bin` before
assuming a tool is installed - many are on-demand only.

## 6. ON-DEMAND TOOL LOADING (READ BEFORE USING)

- **Pentest tools**: `sudo /usr/local/bin/pentest-extra.sh`
  - Installs the heavy Alpine pentest pack from the ISO repo (offline) + the
    Go/pip/gem tools (needs tunnel for egress). Requires `curl` + `zstd`.
- **AI / Ollama / Claurst**: `sudo /usr/local/bin/ai-extra.sh`
  - Starts dockerd (on-demand), mounts the Ollama squashfs, docker-loads the
    image, runs it with GPU detection, installs `claurst`. Subcommands:
    `start|stop|status`.
  - Say `sudo /usr/local/bin/ai-extra.sh start` if local inference is needed.
- Loading tools is a **one-way door for RAM**: installed copies live in tmpfs
  and are gone on reboot. Do not run these scripts speculatively.

## 7. YOUR CONSTRAINTS / RESTRAINTS (HARD RULES)

1. **Never write to block devices or the host disk** (`/dev/nvme0n1p8`, raw
   block ops). The boot layer read-locks them on purpose.
2. **No speculative package installation.** Only install what the task needs,
   via the on-demand scripts above, not assorted ad-hoc `apk add`.
3. **Do not assume internet access.** Egress is default-drop + tunneled. If a
   task needs the open internet, say so and ask how the user wants it routed.
4. **Respect memory.** Prefer small models, close what you are not using, and
   avoid launching the whole stack when a lighter tool suffices.
5. **No persistence assumptions.** Do not leave state you expect to be there on
   the next boot. If the user needs something preserved, ask where to put it.
6. **Do not re-configure the desktop/browser/firewall defaults** - they are
   deliberate hardening. Change them only if explicitly asked, and say exactly
   what you changed.
7. **Be explicit about egress.** Any tool that phones home or relies on
   external APIs must be called out; default to the tunneled proxy.
8. **Clean up after yourself.** Stop daemons you started, unmount squashfs, and
   free RAM when the task completes (state how in your summary).

## 8. WHEN IN DOUBT

This is an amnesiac, hardened, tunnel-only, memory-constrained environment.
When your plan conflicts with the above, state the conflict explicitly and ask
before proceeding - do not silently work around the kill-switch or persistence
model. If a tooling assumption is wrong (a tool is not installed, egress is
blocked, OOM), report it rather than guessing.