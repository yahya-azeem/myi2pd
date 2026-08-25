#!/bin/sh
set -e

echo "=========================================="
echo "          myi2pd Wi-Fi Connection         "
echo "=========================================="
echo ""

# Ensure run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Please run this script as root."
    sleep 5
    exit 1
fi

# Discover wireless interface name
WLAN_INTF=$(ip link | awk -F': ' '/state/ {print $2}' | grep -E '^(wlan|wlp|wls)' | head -n 1)
if [ -z "$WLAN_INTF" ]; then
    for dev in /sys/class/net/*; do
        if [ -d "$dev/wireless" ] || [ -d "$dev/phy80211" ]; then
            WLAN_INTF=$(basename "$dev")
            break
        fi
    done
fi
WLAN_INTF=${WLAN_INTF:-wlan0}

echo "Using wireless interface: $WLAN_INTF"
ip link set "$WLAN_INTF" up || true
sleep 1

echo "Scanning for available Wi-Fi networks..."
networks=""
if which iwlist >/dev/null 2>&1; then
    networks=$(iwlist "$WLAN_INTF" scan 2>/dev/null | grep -i "essid" | cut -d':' -f2 | tr -d '"' | sort -u)
elif which iw >/dev/null 2>&1; then
    networks=$(iw dev "$WLAN_INTF" scan 2>/dev/null | grep -i "ssid" | cut -d' ' -f2- | sort -u)
fi

if [ -n "$networks" ]; then
    echo "Available networks:"
    echo "-------------------"
    echo "$networks" | awk '{print NR ") " $0}'
    echo "-------------------"
else
    echo "[WARNING] No networks found or scanning not supported. Enter SSID manually."
fi

echo -n "Enter Wi-Fi SSID: "
read ssid

# Select authentication type
echo ""
echo "Select authentication type:"
echo "  1) WPA2-Personal (PSK) - Home/office WiFi with password"
echo "  2) WPA2-Enterprise (PEAP/MSCHAPv2) - Corporate/University (username+password)"
echo "  3) WPA2-Enterprise (EAP-TLS) - Certificate-based auth"
echo "  4) WPA3-SAE (WPA3-Personal) - Modern home WiFi"
echo "  5) Open (no encryption) - Public hotspot (NOT RECOMMENDED)"
echo -n "Choice [1]: "
read auth_choice
auth_choice=${auth_choice:-1}

# Prepare variables
username=""
identity=""
password=""
ca_cert_path=""
client_cert_path=""
private_key_path=""

case "$auth_choice" in
    1)
        echo -n "Enter Wi-Fi Password: "
        stty -echo
        read password
        stty echo
        echo ""
        ;;
    2)
        echo -n "Enter Username/Identity: "
        read identity
        echo -n "Enter Password: "
        stty -echo
        read password
        stty echo
        echo ""
        echo -n "Enter CA Certificate path (optional, press Enter to skip): "
        read ca_cert_path
        if [ -n "$ca_cert_path" ] && [ ! -f "$ca_cert_path" ]; then
            echo "[ERROR] CA certificate not found at: $ca_cert_path"
            exit 1
        fi
        ;;
    3)
        echo -n "Enter Identity: "
        read identity
        echo -n "Enter Client Certificate path (.pem/.crt): "
        read client_cert_path
        echo -n "Enter Private Key path (.pem/.key): "
        read private_key_path
        echo -n "Enter CA Certificate path: "
        read ca_cert_path
        for f in "$client_cert_path" "$private_key_path" "$ca_cert_path"; do
            if [ ! -f "$f" ]; then
                echo "[ERROR] File not found: $f"
                exit 1
            fi
        done
        ;;
    4)
        echo -n "Enter Wi-Fi Password: "
        stty -echo
        read password
        stty echo
        echo ""
        ;;
    5)
        password=""
        ;;
    *)
        echo "[ERROR] Invalid choice"
        exit 1
        ;;
esac

# Build wpa_supplicant config based on auth type
cat <<EOF > /tmp/wpa_supplicant.conf
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=root
update_config=1
ap_scan=1

network={
    ssid="${ssid}"
EOF

case "$auth_choice" in
    1)
        cat <<EOF >> /tmp/wpa_supplicant.conf
    key_mgmt=WPA-PSK WPA-PSK-SHA256 WPA-SAE
    psk="${password}"
    proto=RSN WPA
    pairwise=CCMP
    group=CCMP
EOF
        ;;
    2)
        cat <<EOF >> /tmp/wpa_supplicant.conf
    key_mgmt=WPA-EAP WPA-EAP-SHA256
    eap=PEAP
    identity="${identity}"
    password="${password}"
    phase2="auth=MSCHAPV2"
    proto=RSN
    pairwise=CCMP
    group=CCMP
EOF
        if [ -n "$ca_cert_path" ]; then
            cat <<EOF >> /tmp/wpa_supplicant.conf
    ca_cert="${ca_cert_path}"
EOF
        fi
        ;;
    3)
        cat <<EOF >> /tmp/wpa_supplicant.conf
    key_mgmt=WPA-EAP WPA-EAP-SHA256
    eap=TLS
    identity="${identity}"
    client_cert="${client_cert_path}"
    private_key="${private_key_path}"
    ca_cert="${ca_cert_path}"
    proto=RSN
    pairwise=CCMP
    group=CCMP
EOF
        ;;
    4)
        cat <<EOF >> /tmp/wpa_supplicant.conf
    key_mgmt=WPA-PSK-SHA256 SAE
    psk="${password}"
    proto=RSN
    pairwise=CCMP
    group=CCMP
    ieee80211w=2
EOF
        ;;
    5)
        cat <<EOF >> /tmp/wpa_supplicant.conf
    key_mgmt=NONE
EOF
        ;;
esac

cat <<EOF >> /tmp/wpa_supplicant.conf
}
EOF

# Install CA cert to system trust store if provided (for PEAP/EAP-TLS)
if [ -n "$ca_cert_path" ] && [ -f "$ca_cert_path" ]; then
    echo "Installing CA certificate to system trust store..."
    cp "$ca_cert_path" /usr/local/share/ca-certificates/ca_wifi_$(basename "$ca_cert_path" .crt).crt 2>/dev/null || \
    cp "$ca_cert_path" /usr/local/share/ca-certificates/ca_wifi_$(basename "$ca_cert_path" .pem).crt 2>/dev/null || true
    update-ca-certificates 2>/dev/null || true
fi

# Kill any active wpa_supplicant instances
killall wpa_supplicant >/dev/null 2>&1 || true

echo "Connecting to '${ssid}' (auth type: ${auth_choice})..."
wpa_supplicant -B -i "$WLAN_INTF" -c /tmp/wpa_supplicant.conf

echo "Acquiring IP address via DHCP..."
udhcpc -q -n -i "$WLAN_INTF" || true

COUNTER=0
HAS_IP=false
while [ $COUNTER -lt 20 ]; do
    if ip addr show dev "$WLAN_INTF" | grep -q "inet "; then
        HAS_IP=true
        break
    fi
    sleep 1
    COUNTER=$((COUNTER + 1))
done

if [ "$HAS_IP" = "false" ]; then
    echo "[ERROR] Failed to acquire an IP address. Wi-Fi connection failed."
    echo "Check wpa_supplicant log: wpa_cli -i $WLAN_INTF status"
    rm -f /tmp/wpa_supplicant.conf
    sleep 10
    exit 1
fi

echo "[OK] Connected! Local IP: $(ip addr show dev "$WLAN_INTF" | grep "inet " | head -n 1 | awk '{print $2}' | cut -d'/' -f1)"
rm -f /tmp/wpa_supplicant.conf
echo ""

# Load VLESS credentials from baked config
CREDS_FILE="/etc/xray/creds.json"
if [ -f "$CREDS_FILE" ]; then
    VPS_IP=$(grep -o '"vps_ip"[[:space:]]*:[[:space:]]*"[^"]*"' "$CREDS_FILE" | cut -d'"' -f4)
    VLESS_UUID=$(grep -o '"uuid"[[:space:]]*:[[:space:]]*"[^"]*"' "$CREDS_FILE" | cut -d'"' -f4)
    REALITY_PUBKEY=$(grep -o '"pubkey"[[:space:]]*:[[:space:]]*"[^"]*"' "$CREDS_FILE" | cut -d'"' -f4)
    SHORT_ID=$(grep -o '"short_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$CREDS_FILE" | cut -d'"' -f4)
    DEST=$(grep -o '"dest"[[:space:]]*:[[:space:]]*"[^"]*"' "$CREDS_FILE" | cut -d'"' -f4)
    [ -z "$DEST" ] && DEST="www.microsoft.com:443"
    echo "Using pre-configured VPS: ${VPS_IP}"
else
    echo -n "Enter your myi2pd VPS Gateway IP: "
    read VPS_IP
    echo -n "Enter VLESS UUID: "
    read VLESS_UUID
    echo -n "Enter Reality Public Key: "
    read REALITY_PUBKEY
    echo -n "Enter Short ID: "
    read SHORT_ID
    DEST="www.microsoft.com:443"
fi

# Tier 2 Cloudflare fallback (optional)
TIER2_CF_DOMAIN=""
TIER2_UUID=""
if [ -f /etc/xray/tier2_creds.json ]; then
    TIER2_CF_DOMAIN=$(grep -o '"cf_domain"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/xray/tier2_creds.json | cut -d'"' -f4)
    TIER2_UUID=$(grep -o '"uuid"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/xray/tier2_creds.json | cut -d'"' -f4)
fi

# Update nftables firewall whitelist for VPS IP
echo "Configuring firewall whitelist for VPS IP: ${VPS_IP}..."
nft flush set inet filter vps_ip || true
nft add element inet filter vps_ip { "${VPS_IP}" } || true

# Function to start Tier 1 (VLESS + Reality)
start_tier1() {
    echo "Initiating Tier 1: VLESS + XTLS-Reality..."
    killall xray >/dev/null 2>&1 || true

    cat > /tmp/vless-tier1.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": 10808,
    "protocol": "socks",
    "settings": {"udp": true},
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"], "routeOnly": true}
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "${VPS_IP}",
        "port": 443,
        "users": [{"id": "${VLESS_UUID}", "flow": "xtls-rprx-vision", "encryption": "none", "level": 0}]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "fingerprint": "chrome",
        "serverName": "${DEST}",
        "publicKey": "${REALITY_PUBKEY}",
        "shortId": "${SHORT_ID}",
        "spiderX": "/"
      }
    },
    "mux": {"enabled": false},
    "tag": "tier1-proxy"
  }]
}
EOF

    if [ -x /usr/local/bin/xray ]; then
        /usr/local/bin/xray -c /tmp/vless-tier1.json > /tmp/xray-tier1.log 2>&1 &
        sleep 2
    else
        echo "[WARNING] Xray binary not found"
        return 1
    fi
}

# Function to start Tier 2 (VLESS + WS via Cloudflare)
start_tier2() {
    if [ -z "$TIER2_CF_DOMAIN" ] || [ -z "$TIER2_UUID" ]; then
        echo "[INFO] Tier 2 credentials not configured, skipping fallback"
        return 1
    fi

    echo "Initiating Tier 2: VLESS + WebSocket via Cloudflare..."
    killall xray >/dev/null 2>&1 || true

    cat > /tmp/vless-tier2.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": 10809,
    "protocol": "socks",
    "settings": {"udp": true},
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"], "routeOnly": true}
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "address": "${TIER2_CF_DOMAIN}",
      "port": 443,
      "id": "${TIER2_UUID}",
      "encryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "wsSettings": {
        "path": "/tier2",
        "headers": {"Host": "${TIER2_CF_DOMAIN}"}
      },
      "tlsSettings": {
        "allowInsecure": false,
        "serverName": "${TIER2_CF_DOMAIN}",
        "alpn": ["h2", "http/1.1"]
      }
    },
    "mux": {"enabled": true, "concurrency": 8},
    "tag": "tier2-proxy"
  }]
}
EOF

    if [ -x /usr/local/bin/xray ]; then
        /usr/local/bin/xray -c /tmp/vless-tier2.json > /tmp/xray-tier2.log 2>&1 &
        sleep 2
    else
        echo "[WARNING] Xray binary not found"
        return 1
    fi
}

# Try Tier 1 first
echo "Attempting Tier 1 (VLESS + XTLS-Reality)..."
if start_tier1; then
    COUNTER=0
    HAS_TUN=false
    while [ $COUNTER -lt 10 ]; do
        if ip link show dev tun0 >/dev/null 2>&1; then
            HAS_TUN=true
            break
        fi
        sleep 1
        COUNTER=$((COUNTER + 1))
    done
    if [ "$HAS_TUN" = "true" ]; then
        echo "[OK] Tier 1 VLESS VPN established!"
        echo ""
        echo "[SUCCESS] myi2pd secure double-tunnel is hot!"
        echo "VPS i2pd proxy available at 10.0.0.1:4447 (SOCKS5)"
        echo "SOCKS5 on 127.0.0.1:10808"
        echo "Press [ENTER] to close..."
        read dummy
        exit 0
    fi
    echo "[WARN] Tier 1 connection failed, attempting Tier 2 fallback..."
fi

# Fallback to Tier 2
if start_tier2; then
    COUNTER=0
    HAS_TUN=false
    while [ $COUNTER -lt 10 ]; do
        if ip link show dev tun0 >/dev/null 2>&1; then
            HAS_TUN=true
            break
        fi
        sleep 1
        COUNTER=$((COUNTER + 1))
    done
    if [ "$HAS_TUN" = "true" ]; then
        echo "[OK] Tier 2 VLESS+WS VPN established!"
        echo ""
        echo "[SUCCESS] myi2pd Tier 2 fallback active!"
        echo "SOCKS5 on 127.0.0.1:10809"
        echo "Press [ENTER] to close..."
        read dummy
        exit 0
    fi
fi

echo "[ERROR] Both Tier 1 and Tier 2 failed to establish connection."
sleep 10
exit 1