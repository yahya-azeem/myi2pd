#!/bin/sh
set -e

echo "=== Starting myi2pd VPS Gateway Setup ==="

# 1. Dynamic Swap Disabling
echo "Disabling swap to prevent forensic leakage..."
swapoff -a || true
# Remove swap lines from fstab
sed -i '/swap/d' /etc/fstab

# 2. Kernel Hardening and IP Forwarding
echo "Applying kernel hardening parameters and enabling IP forwarding..."
mkdir -p /etc/sysctl.d
cat <<EOF > /etc/sysctl.d/hardening.conf
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
EOF

cat <<EOF > /etc/sysctl.d/ipv4.conf
net.ipv4.ip_forward = 1
EOF

sysctl -p /etc/sysctl.d/hardening.conf || true
sysctl -p /etc/sysctl.d/ipv4.conf || true

# 3. nftables Firewall Setup
echo "Configuring nftables whitelist firewall..."
# Copy configuration to standard location
cp /etc/myi2pd-configs/nftables.nft /etc/nftables.nft
rc-update add nftables default || true

# 4. Install and Tune i2pd (low resource constraints)
echo "Installing and tuning i2pd daemon..."
# Ensure community repo is enabled
sed -i 's/#http/http/g' /etc/apk/repositories || true
apk update
apk add i2pd

# Copy tuned low-resource configurations
cp /etc/myi2pd-configs/i2pd.conf /etc/i2pd/i2pd.conf
chown i2pd:i2pd /etc/i2pd/i2pd.conf

# Start i2pd service
rc-update add i2pd default

# 5. Build and Configure TrustTunnel Server
if [ ! -x /usr/local/bin/trusttunnel_endpoint ] || [ ! -x /usr/local/bin/setup_wizard ]; then
    echo "Building TrustTunnel from source (binaries not found)..."
    apk add build-base git rust cargo openssl-dev cmake clang-dev llvm-dev

    git clone --depth 1 https://github.com/TrustTunnel/TrustTunnel.git /tmp/trusttunnel-build
    cd /tmp/trusttunnel-build
    cargo build --release --bins

    cp target/release/trusttunnel_endpoint /usr/local/bin/
    cp target/release/setup_wizard /usr/local/bin/

    cd /
    rm -rf /tmp/trusttunnel-build
    apk del build-base git rust cargo clang-dev llvm-dev
    apk add openssl libgcc libstdc++
else
    echo "TrustTunnel binaries already present, skipping build..."
fi

# Generate self-signed TLS certificates
echo "Generating self-signed TLS certificates..."
mkdir -p /etc/trusttunnel
VPS_IP=$(curl -s https://api.ipify.org || hostname -i || echo "127.0.0.1")
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/trusttunnel/server.key \
  -out /etc/trusttunnel/server.crt \
  -subj "/CN=${VPS_IP}"

# Run setup_wizard to generate base config templates
echo "Initializing TrustTunnel configurations..."
setup_wizard -m non-interactive \
  -a 0.0.0.0:443 \
  -c "myi2pduser:myi2pdsecurepassword" \
  -n "${VPS_IP}" \
  --lib-settings /etc/trusttunnel/vpn.toml \
  --hosts-settings /etc/trusttunnel/hosts.toml \
  --client-settings /etc/trusttunnel/client.toml

# Override hosts.toml to point to our self-signed TLS certificates
cat <<EOF > /etc/trusttunnel/hosts.toml
[[main_hosts]]
hostname = "${VPS_IP}"
cert_chain_path = "/etc/trusttunnel/server.crt"
private_key_path = "/etc/trusttunnel/server.key"
EOF

# Enable skip_verification in the client configuration template
echo "skip_verification = true" >> /etc/trusttunnel/client.toml

# 6. Create OpenRC service script for TrustTunnel Endpoint
echo "Creating TrustTunnel daemon service..."
cat <<'EOF' > /etc/init.d/trusttunnel
#!/sbin/openrc-run

name="trusttunnel"
description="TrustTunnel VPN Endpoint Daemon"
command="/usr/local/bin/trusttunnel_endpoint"
command_args="/etc/trusttunnel/vpn.toml /etc/trusttunnel/hosts.toml"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after nftables
}
EOF
chmod +x /etc/init.d/trusttunnel

# Start TrustTunnel
rc-update add trusttunnel default

echo "=== myi2pd VPS Gateway Setup Completed Successfully! ==="
