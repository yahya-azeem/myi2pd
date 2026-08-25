# myi2pd - Double-Tunnel Secure Network Gateway & Amnesiac Live OS

`myi2pd` is an Infrastructure-as-Code (IaC) repository to configure and build a hardened, anti-forensic digital routing platform. It is split into two components: an offshore VPS (the entry gateway) and an amnesiac RAM-disk client boot image (the terminal).

## Architecture — Double Tunnel

```
Client (amnesiac ISO)                VPS (long-running)              I2P Network
┌─────────────────────┐    VLESS+Reality  ┌──────────────────┐
│  LibreWolf          │    TCP :443       │                  │
│    ↓ SOCKS5 :4447   │ ─────────────────→│  Xray            │
│  i2p tunnel init    │   outer tunnel    │  VLESS inbound   │
│                     │                   │       ↓          │
│  Outer: VLESS +     │                   │  i2pd (routing)  │ ─→ I2P nodes
│  XTLS-Reality       │                   │  (long uptime)   │
│  Inner: I2P garlic  │                   │                  │
└─────────────────────┘                   └──────────────────┘
```

- **Outer tunnel**: VLESS + XTLS-Reality (TCP port 443) — client connects to VPS using Reality "steal" (impersonates microsoft.com TLS handshake), no domain registration needed, the amnesiac can reboot at any time
- **Inner tunnel**: I2P garlic routing — tunnel initiation/provisioning originates from the **client** via SOCKS5 through i2pd running on the VPS, giving true double encryption
- **i2pd runs on the VPS** (not the client) because I2P takes significant time to establish routes — this preserves the amnesiac property: the client can be turned off/on without losing i2pd's established state
- **Kill Switch**: nftables default-drop policy on client — all egress blocked except to VPS IP:443 and over tun0

---

## Repository Structure

```text
├── .github/workflows/
│   └── build.yml               # GitHub Actions workflow for building the ISO
├── client/
│   ├── Dockerfile              # Dockerized builder compiler environment
│   ├── build_iso.sh            # Host runner script to execute Docker and extract the ISO
│   └── configs/                # Volatile overlay files loaded into client RAM
│       ├── autologin           # Auto-login helper script
│       ├── hdd-isolation       # Block-level read-only disk locking service
│       ├── i2pd.conf           # Local i2pd config (client-only, 0 transit tunnels)
│       ├── inittab             # Getty mapping for custom auto-login
│       ├── librewolf-launcher  # RAM-backed LibreWolf user profile wrapper
│       ├── librewolf.overrides.cfg # Tor-equivalent + JIT disabled overrides
│       ├── nftables.nft        # Default-drop netfilter VPN kill-switch
│       ├── profile             # root profile triggering graphics
│       ├── river_init          #River compositor desktop & shortcut maps
│       ├── waybar_config.jsonc # Status panel config with LibreWolf launch button
│       └── waybar_style.css    # Waybar status bar dark theme
├── shared/
│   └── test_vm.sh              # Local QEMU virtual machine test runner
└── vps/
    ├── configs/
    │   ├── i2pd.conf           # VPS i2pd configuration (low RAM tuned)
    │   └── nftables.nft        # VPS nftables default-drop ingress & egress NAT
    ├── scripts/
    │   └── setup_vps.sh        # Automates sysctl hardening and Xray VLESS+Reality setup
    └── terraform/
        ├── main.tf             # Terraform code to deploy Vultr VPS instance
        ├── variables.tf
        └── outputs.tf
```

---

## Deployed Features

### VPS Gateway (Hardening & Evasion)
- **Zero Swap Space**: The setup script comment-purges swap allocations to avoid sensitive keys touching hypervisor host disk snapshots.
- **Kernel Hardening**: Configures strict limits on dynamic BPF compilation (`net.core.bpf_jit_harden`), conceals kernel pointers (`kernel.kptr_restrict`), and restricts syslog visibility (`kernel.dmesg_restrict`).
- **Stateful Whitelist Firewall**: Restricts incoming traffic to port 443 (VLESS + XTLS-Reality) and 25432 (global I2P peers).
- **VLESS + XTLS-Reality**: Xray server with Reality "steal" (microsoft.com TLS handshake impersonation), X25519 keypair, XTLS-Vision flow (kernel splice for zero-copy), automatic shortId rotation.
- **Active Probe Defense**: Unauthorized connections forwarded to real microsoft.com, returning valid Microsoft TLS certificate (plausible deniability).
- **Tier 2 Fallback**: VLESS + WebSockets via Cloudflare CDN for high-bandwidth scenarios where Tier 1 is throttled.
- **Tuned local i2pd Node**: Constrains transit bandwidth and netdb replication to prevent OOM failures.

### Amnesiac Client OS
- **Volatile RAM Boot**: Boots Alpine Linux diskless mode entirely to tmpfs. Pulling the USB stick purges the execution environment.
- **HDD Isolation Engine**: Iterates through system blocks (`sd*`, `nvme*`, `mmcblk*`), unmounts active mounts, and executes `blockdev --setro` at the block layer to restrict write requests.
- **Dynamic Wi-Fi & Pinned VPN**: Upon boot, River window manager opens a setup window that scans Wi-Fi, takes credentials in RAM, sets `nftables` to allow *only* outbound traffic to the VPS IP on port 443, and routes everything else via `tun0`.
- **Hardened Browser Profile**: Auto-launches LibreWolf with Tor-style Letterboxing, remote SOCKS5 DNS routing, uBlock/NoScript controls, and JIT compilation deactivated.
- **VLESS Client**: Xray with uTLS chrome fingerprint, Reality public key + shortId, Vision flow, Mux enabled, spiderX defense.

---

## How to Build the ISO

### Automatically via GitHub Actions
Since the workflow is configured, any push to `main` starts a build. You can download the generated `myi2pd-amnesiac.iso` directly from the workflow runs page in your GitHub repository.

### Locally on your Host
Run the local build script on any Linux host with Docker:
```bash
chmod +x client/build_iso.sh
./client/build_iso.sh
```
This builds the package dependencies inside container environments and outputs `myi2pd-amnesiac.iso` directly in the project root directory.

### Testing under QEMU VM
Test the ISO locally using QEMU:
```bash
chmod +x shared/test_vm.sh
./shared/test_vm.sh
```
This script attaches a blank dummy drive to verify that `hdd-isolation` successfully locks write permission requests at the OS kernel layer.

---

## Fast Bootless Tests (no VM, no ISO build)

Rebuilding the ISO and booting it under QEMU takes ~30 minutes, so config changes are validated by a sub-second static suite instead. It checks shell syntax, nftables/inittab validity, overlay file integrity (hostname, network interfaces, autologin, river/foot/waybar, nftables, xray), and that the GitHub Actions pipeline produces the exact same overlay as the local `client/build_iso.sh` — catching a "works locally, broken in CI" regression before you ever boot a VM.

```bash
make test        # full suite (validates a built ISO if one is in repo root)
make test-quick  # skip ISO artifact validation (fastest, ~2s)
make test-iso ISO=myi2pd-amnesiac.iso   # validate a built ISO's apkovl only
```

The suite runs automatically on every commit via a pre-commit hook:

```bash
make pre-commit  # installs .githooks/pre-commit (one-time per clone)
```

It is also wired into CI (`.github/workflows/test.yml`): `static-tests` runs the suite on every push/PR, and `iso-validation` builds the ISO and validates its apkovl on push/workflow_dispatch.