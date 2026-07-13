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
    # Fallback search in sysfs
    for dev in /sys/class/net/*; do
        if [ -d "$dev/wireless" ] || [ -d "$dev/phy80211" ]; then
            WLAN_INTF=$(basename "$dev")
            break
        fi
    done
fi
WLAN_INTF=${WLAN_INTF:-wlan0}

echo "Using wireless interface: $WLAN_INTF"

# Bring interface up
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
echo -n "Enter Wi-Fi Password: "
# Read password silently
stty -echo
read password
stty echo
echo ""

# Write temp config
cat <<EOF > /tmp/wpa_supplicant.conf
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=root
update_config=1
ap_scan=1

network={
    ssid="${ssid}"
    psk="${password}"
    key_mgmt=WPA-PSK WPA-SAE
    proto=RSN
    pairwise=CCMP
    group=CCMP
}
EOF

# Kill any active instances
killall wpa_supplicant >/dev/null 2>&1 || true

echo "Connecting to '${ssid}'..."
wpa_supplicant -B -i "$WLAN_INTF" -c /tmp/wpa_supplicant.conf

echo "Acquiring IP address via DHCP..."
udhcpc -q -n -i "$WLAN_INTF" || true

COUNTER=0
HAS_IP=false
while [ $COUNTER -lt 15 ]; do
    if ip addr show dev "$WLAN_INTF" | grep -q "inet "; then
        HAS_IP=true
        break
    fi
    sleep 1
    COUNTER=$((COUNTER + 1))
done

if [ "$HAS_IP" = "false" ]; then
    echo "[ERROR] Failed to acquire an IP address. Wi-Fi connection failed."
    rm -f /tmp/wpa_supplicant.conf
    sleep 10
    exit 1
fi

echo "[OK] Connected! Local IP: $(ip addr show dev "$WLAN_INTF" | grep "inet " | head -n 1 | awk '{print $2}' | cut -d'/' -f1)"

# Securely wipe the wpa_supplicant config containing password from RAM
rm -f /tmp/wpa_supplicant.conf

echo ""
# Handle VPS IP dynamically
if [ -f /etc/trusttunnel/vps_ip.txt ]; then
    VPS_IP=$(cat /etc/trusttunnel/vps_ip.txt)
    echo "Using pre-configured VPS IP: ${VPS_IP}"
else
    echo -n "Enter your myi2pd VPS Gateway IP: "
    read VPS_IP
fi

# Update nftables firewall to whitelist this specific VPS IP address
echo "Configuring firewall whitelist for VPS IP: ${VPS_IP}..."
nft flush set inet filter vps_ip || true
nft add element inet filter vps_ip { "${VPS_IP}" } || true

# Write dynamic client config
cat <<EOF > /tmp/trusttunnel-client.toml
[endpoint]
address = "${VPS_IP}:443"
skip_verification = true
username = "myi2pduser"
password = "myi2pdsecurepassword"

[vpn]
mode = "tun"
tunnel_name = "tun0"
EOF

echo "Initiating obfuscated TLS VPN Tunnel via TrustTunnel..."
killall trusttunnel_client >/dev/null 2>&1 || true
/usr/local/bin/trusttunnel_client --config /tmp/trusttunnel-client.toml &

echo "Waiting for virtual 'tun0' VPN interface to mount..."
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

if [ "$HAS_TUN" = "false" ]; then
    echo "[ERROR] TrustTunnel failed to establish connection to VPS."
    sleep 10
    exit 1
fi

echo "[OK] TrustTunnel VPN established!"

# Start local i2pd
echo "Starting local i2pd garlic routing daemon..."
rc-service i2pd start || rc-service i2pd restart

echo ""
echo "[SUCCESS] myi2pd secure double-tunnel is hot!"
echo "You can now safely click the browser button to surf."
echo ""
echo "Press [ENTER] to close this setup window..."
read dummy
