# myi2pd - Double-Tunnel Secure Network Gateway & Amnesiac Live OS

`myi2pd` is an Infrastructure-as-Code (IaC) repository to configure and build a hardened, anti-forensic digital routing platform. It is split into two components: an offshore VPS (the entry gateway) and an amnesiac RAM-disk client boot image (the terminal).

## Architecture — Double Tunnel

```
Client (amnesiac ISO)                VPS (long-running)              I2P Network
┌─────────────────────┐    TrustTunnel    ┌──────────────────┐
│  LibreWolf          │    TLS :443       │                  │
│    ↓ SOCKS5 :4447   │ ─────────────────→│  TrustTunnel     │
│  i2p tunnel init    │   outer tunnel    │  endpoint        │
│                     │                   │       ↓          │
│  Outer: TrustTunnel │                   │  i2pd (routing)  │ ─→ I2P nodes
│  Inner: I2P garlic  │                   │  (long uptime)   │
└─────────────────────┘                   └──────────────────┘
```

- **Outer tunnel**: TrustTunnel (TLS on port 443) — client connects to VPS, the amnesiac can reboot at any time
- **Inner tunnel**: I2P garlic routing — tunnel initiation/provisioning originates from the **client** via SOCKS5 through i2pd running on the VPS, giving true double encryption
- **i2pd runs on the VPS** (not the client) because I2P takes significant time to establish routes — this preserves the amnesiac property: the client can be turned off/on without losing i2pd's established state

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
    │   └── setup_vps.sh        # Automates sysctl hardening and TrustTunnel setup
    └── terraform/
        ├── main.tf             # Terraform code to deploy Vultr VPS instance
        ├── variables.tf
        └── outputs.tf
```

---

## Deployed Features

### VPS Gateway (Hardening & Evasion)
- **Zero Swap Space**: The setup script comment-purges swap allocations to avoid sensitive keys touching hypervisor host disk snapshots.
- **Kernel Hardening**: Configures strict limits on dynamic BPF compilation (`net.core.bpf_jit_harden`),conceals kernel pointers (`kernel.kptr_restrict`), and restricts syslog visibility (`kernel.dmesg_restrict`).
- **Stateful Whitelist Firewall**: Restricts incoming traffic to ports 443 (obfuscated VPN) and 25432 (global I2P peers).
- **Self-Signed TLS**: Automates generating self-signed TLS certificates and configures the `TrustTunnel` server endpoint.
- **Tuned local i2pd Node**: Constrains transit bandwidth and netdb replication to prevent Out-Of-Memory (OOM) failures under low resources.

### Amnesiac Client OS
- **Volatile RAM Boot**: Boots Alpine Linux diskless mode entirely to tmpfs. Pulling the USB stick purges the execution environment.
- **HDD Isolation Engine**: Iterates through system blocks (`sd*`, `nvme*`, `mmcblk*`), unmounts active mounts, and executes `blockdev --setro` at the block layer to restrict write requests.
- **Dynamic Wi-Fi & Pinned VPN**: Upon boot, River window manager opens a setup window that scans Wi-Fi, takes credentials in RAM, sets `nftables` to allow *only* outbound traffic to the VPS IP on port 443, and routes everything else via `tun0`.
- **Hardened Browser Profile**: Auto-launches LibreWolf with Tor-style Letterboxing, remote SOCKS5 Sockets DNS routing, uBlock/NoScript controls, and JIT compilation deactivated.

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
