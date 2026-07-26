#!/bin/sh
# i2p-keepalive.sh - Generate periodic I2P traffic to mask metadata timing
SLEEP=${1:-60}
URL="http://i2p-projekt.i2p/"
PROXY="socks5://127.0.0.1:4447"
while true; do
  curl --proxy "$PROXY" --max-time 10 -s -o /dev/null "$URL" 2>/dev/null || true
  sleep "$SLEEP"
done
