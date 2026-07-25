#!/bin/sh
# Launch qBittorrent with myi2pd I2P SOCKS proxy
export ALL_PROXY=socks5://10.10.10.1:4447
export SOCKS5_PROXY=socks5://10.10.10.1:4447
exec qbittorrent "$@"
