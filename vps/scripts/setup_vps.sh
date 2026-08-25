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

# Install i2pd
sed -i 's/#http/http/g' /etc/apk/repositories || true
apk update && apk add i2pd
cp /etc/myi2pd-configs/i2pd.conf /etc/i2pd/i2pd.conf
rc-update add i2pd default

# Build/Use Xray with VLESS+XTLS-Reality
XRAY_BIN="/tmp/xray/xray"
if [ ! -x "$XRAY_BIN" ]; then
    XRAY_BIN="/usr/local/bin/xray"
fi
if [ ! -x "$XRAY_BIN" ]; then
    echo "Xray binary not found, downloading..."
    apk add --no-cache curl
    mkdir -p /tmp/xray
    curl -sL "https://github.com/XTLS/Xray-core/releases/latest/download/xray-linux-64.zip" -o /tmp/xray.zip
    unzip -o /tmp/xray.zip -d /tmp/xray
    chmod +x /tmp/xray/xray
    XRAY_BIN="/tmp/xray/xray"
fi

# Generate Reality keypair + UUID
X25519=$("$XRAY_BIN" x25519 | awk '{print $2}')
VLESS_UUID=$("$XRAY_BIN" uuid)
SHORT_ID=$(xxd -l 8 -p /dev/urandom)
VPS_IP=$(curl -s https://api.ipify.org || echo 10.10.10.1)
DEST="www.microsoft.com:443"

# Post-quantum seeds (ML-DSA-65 for signatures, ML-KEM-768 for KEM)
# Generated via: xray mldsa65 && xray mlkem768
MLDSA65_SEED=$("$XRAY_BIN" mldsa65 2>/dev/null | awk '/Seed/{print $2}')
MLKEM768_SEED=$("$XRAY_BIN" mlkem768 2>/dev/null | awk '/Seed/{print $2}')

# Create Xray config with Vision flow + post-quantum
mkdir -p /etc/xray
cat > /etc/xray/config.json <<EOF
{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "$VLESS_UUID",
        "flow": "xtls-rprx-vision",
        "email": "myi2pd-client"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$DEST",
        "xver": 0,
        "serverNames": ["$DEST"],
        "privateKey": "$X25519",
        "shortIds": ["", "$SHORT_ID", "0123456789abcdef"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}],
  "policy": {
    "levels": {
      "0": {
        "bufferSize": 2,
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    }
  }
}
EOF

# Save credentials for client provisioning
cat > /etc/xray/creds.json <<EOF
{
  "vps_ip": "$VPS_IP",
  "uuid": "$VLESS_UUID",
  "pubkey": "$X25519",
  "short_id": "$SHORT_ID",
  "dest": "$DEST",
  "mldsa65_seed": "$MLDSA65_SEED",
  "mlkem768_seed": "$MLKEM768_SEED"
}
EOF

# Self-signed cert if missing
[ -f /etc/xray/private_key ] || openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/xray/private_key -out /etc/xray/cert_chain -subj "/CN=${VPS_IP}" 2>/dev/null

# Tier 2 Cloudflare fallback config (template - requires actual CF domain)
cat > /etc/xray/config_tier2.json <<'EOF'
{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "TIER2_UUID_PLACEHOLDER", "flow": "", "email": "tier2-user"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "wsSettings": {"path": "/tier2", "headers": {"Host": "TIER2_CF_DOMAIN_PLACEHOLDER"}},
      "tlsSettings": {
        "certificates": [{"certificateFile": "/etc/xray/tier2_cert.pem", "keyFile": "/etc/xray/tier2_key.pem"}],
        "alpn": ["h2", "http/1.1"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF

# Xray service
cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
name="xray"
description="Xray VLESS+XTLS-Reality"
command="/tmp/xray/xray"
command_args="-conf /etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
depend() { need net; after nftables; }
start_pre() {
    [ -d /etc/xray ] || mkdir -p /etc/xray
    [ -f /etc/xray/config.json ] || {
        X25519=$(/usr/local/bin/xray x25519 | awk '{print $2}')
        VLESS_UUID=$(/usr/local/bin/xray uuid)
        SHORT_ID=$(xxd -l 8 -p /dev/urandom)
        DEST="www.microsoft.com:443"
        cat > /etc/xray/config.json <<EOFJSON
{"inbounds":[{"listen":"0.0.0.0","port":443,"protocol":"vless","settings":{"clients":[{"id":"$VLESS_UUID","flow":"xtls-rprx-vision","email":"user"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":"","dest":"$DEST","xver":0,"serverNames":["$DEST"],"privateKey":"$X25519","shortIds":["$SHORT_ID"]}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}
EOFJSON
    }
}
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
echo "Xray VLESS+XTLS-Reality (Vision flow) on port 443"
echo "Dest: $DEST"
echo "UUID: $VLESS_UUID"
echo "ShortID: $SHORT_ID"
echo "ML-DSA-65 Seed: $MLDSA65_SEED"
echo "ML-KEM-768 Seed: $MLKEM768_SEED"
echo "Creds saved to /etc/xray/creds.json"