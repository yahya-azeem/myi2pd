#!/bin/sh
set -e

echo "=== Starting myi2pd VPS Gateway Setup ==="

# Disable swap
swapoff -a || true; sed -i '/swap/d' /etc/fstab

# Kernel hardening + IP forward
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/hardening.conf <<'EOF'
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
EOF
cat > /etc/sysctl.d/ipv4.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/hardening.conf || true
sysctl -p /etc/sysctl.d/ipv4.conf || true

# i2pd is pre-installed via APK world
mkdir -p /etc/i2pd
cp /etc/myi2pd-configs/i2pd.conf /etc/i2pd/i2pd.conf
# Ensure OpenRC service exists
if [ ! -f /etc/init.d/i2pd ]; then
    printf '#!/sbin/openrc-run\nname="i2pd"\ndescription="I2P Daemon"\ncommand="/usr/bin/i2pd"\ncommand_args="--conf=/etc/i2pd/i2pd.conf"\ncommand_background=true\npidfile="/run/i2pd.pid"\ndepend() { need net; }\n' > /etc/init.d/i2pd
    chmod +x /etc/init.d/i2pd
fi
rc-update add i2pd default

# Xray binary is PRE-INSTALLED at /usr/local/bin/xray (copied during ISO build)
XRAY_BIN="/usr/local/bin/xray"
if [ ! -x "$XRAY_BIN" ]; then
    echo "ERROR: Xray binary not found at $XRAY_BIN (should be pre-installed)"
    exit 1
fi

# Load PRE-BUILT credentials from ISO
CREDS_FILE="/etc/xray/creds.json"
if [ ! -f "$CREDS_FILE" ]; then
    echo "ERROR: Pre-built credentials not found at $CREDS_FILE"
    exit 1
fi
VLESS_UUID=$(grep -o '"uuid"[[:space:]]*:[[:space:]]*"[^"]*"' "$CREDS_FILE" | cut -d'"' -f4)
X25519=$(grep -o '"pubkey"[[:space:]]*:[[:space:]]*"[^"]*"' "$CREDS_FILE" | cut -d'"' -f4)
SHORT_ID=$(grep -o '"short_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$CREDS_FILE" | cut -d'"' -f4)
DEST=$(grep -o '"dest"[[:space:]]*:[[:space:]]*"[^"]*"' "$CREDS_FILE" | cut -d'"' -f4)
VPS_IP=$(curl -s https://api.ipify.org || echo 10.10.10.1)

# PRE-BUILT Xray config already at /etc/xray/config.json (generated at build time)
if [ ! -f /etc/xray/config.json ]; then
    echo "ERROR: Pre-built Xray config not found"
    exit 1
fi

# Update creds.json with actual VPS IP
cat > /etc/xray/creds.json <<EOF
{
  "vps_ip": "$VPS_IP",
  "uuid": "$VLESS_UUID",
  "pubkey": "$X25519",
  "short_id": "$SHORT_ID",
  "dest": "$DEST"
}
EOF

# Self-signed cert if missing
[ -f /etc/xray/private_key ] || openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/xray/private_key -out /etc/xray/cert_chain -subj "/CN=${VPS_IP}" 2>/dev/null

# Xray service
cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
name="xray"
description="Xray VLESS+XTLS-Reality"
command="/usr/local/bin/xray"
command_args="-conf /etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
depend() { need net; after nftables; }
EOF
chmod +x /etc/init.d/xray && rc-update add xray default

# nftables with kill switch
nft flush ruleset
VPS_IP=$(curl -s https://api.ipify.org || echo 10.10.10.1)
cat > /etc/nftables.nft <<'NFT-EOF'
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop
        iif "lo" accept
        ct state established,related accept
        tcp dport 443 accept
        udp dport 443 accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop
        iifname "tun+" accept
        oifname "tun+" ct state established,related accept
    }
    chain output {
        type filter hook output priority 0; policy drop
        oif "lo" accept
        udp dport 53 accept
        ip daddr @vps_ip tcp dport 443 accept
        ip daddr @vps_ip udp dport 443 accept
        ip daddr @vps_ip tcp dport 4447 accept
        ip daddr @vps_ip tcp dport 53 accept
        ip daddr @vps_ip udp dport 53 accept
        oif "tun0" accept
    }
}
table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept
        ip saddr 10.10.10.0/24 masquerade
    }
}
NFT-EOF

nft add set inet filter vps_ip { type ipv4_addr; flags interval }
nft add element inet filter vps_ip { "$VPS_IP" }
rc-update add nftables default

echo "=== Setup Complete ==="
echo "Xray VLESS+XTLS-Reality on port 443 (pre-built config)"
echo "Dest: $DEST"
echo "UUID: $VLESS_UUID"
echo "ShortID: $SHORT_ID"
echo "VPS IP: $VPS_IP"
echo "Creds saved to /etc/xray/creds.json"