#!/bin/sh
set -e
HOSTNAME="$1"

# The structured overlay is located at /build/overlay
# Create the apkovl tarball in the current directory (which is DESTDIR)
tar -C /build/overlay -c -z -f "$HOSTNAME.apkovl.tar.gz" .
