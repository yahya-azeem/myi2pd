#!/bin/bash
# client/ai/build_ollama_squashfs.sh - Build the minimal Ollama container image
# and pack it into myi2pd-ollama.squashfs.
#
# The amnesiac client boots diskless into 4G of tmpfs. The Ollama image is
# therefore NOT baked into the ISO root (that would blow the RAM budget); it is
# shipped as a separate, on-demand squashfs that the client loop-mounts only
# when the user asks for local inference (see /usr/local/bin/ai-extra.sh).
#
# Run on any Linux host with Docker (or via CI):
#   ./client/ai/build_ollama_squashfs.sh [--backends cpu|false] [--out FILE]
#
# Produces: myi2pd-ollama.squashfs  (loop-mountable, read-only, on-demand)
#
# This is FAST and light in CI: the Dockerfile fetches the standalone Ollama
# release tarball (~1.4GB) directly via curl, NOT the 8GB official docker
# image, so the pull that once pinned the runner disk no longer happens. The
# tarball layer is cached by buildkit (cache-from: type=gha) across runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="${REPO_ROOT}/myi2pd-ollama.squashfs"
# false = keep everything the base tarball ships (cpu + cuda_v12 + cuda_v13 +
# vulkan); cpu = smallest (CPU only); or "cpu cuda_v13" to keep a subset.
BACKENDS="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --backends) shift; BACKENDS="$1" ;;
        --out) shift; OUT="$1" ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

command -v docker >/dev/null 2>&1 || { echo "docker required"; exit 1; }
command -v mksquashfs >/dev/null 2>&1 || { echo "squashfs-tools required"; exit 1; }

IMG="myi2pd-ollama:latest"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== Building minimal Ollama container (backends=$BACKENDS) ==="
docker build --build-arg "OLLAMA_BACKENDS=$BACKENDS" \
    -t "$IMG" -f "$SCRIPT_DIR/ollama/Dockerfile" "$SCRIPT_DIR"

echo "=== Exporting image tarball ==="
docker save "$IMG" -o "$WORK/ollama-image.tar"

echo "=== Packing squashfs ==="
mksquashfs "$WORK/ollama-image.tar" "$OUT" -noappend -quiet

echo "=== Done: $OUT ==="
ls -lh "$OUT"
