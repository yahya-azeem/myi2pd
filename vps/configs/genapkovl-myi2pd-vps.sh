#!/bin/sh
set -e
HOSTNAME="$1"

tar -C /build/overlay -c -z -f "$HOSTNAME.apkovl.tar.gz" .
