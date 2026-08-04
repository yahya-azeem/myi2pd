#!/bin/bash
# client/configs/ai-extra.sh - On-demand AI stack for the amnesiac client.
#
# The amnesiac ISO boots diskless into 4G of tmpfs root. Tensor/GPU workloads
# (Ollama) and coding agents (Claurst) must therefore NOT be baked into the
# root at boot - that would blow the RAM budget and they need a glibc container
# we ship on disk. This script, run ONCE when the user wants local inference,
# assembles the stack. Everything non-persistent: reboot or unplug the stick
# returns the system to a clean amnesiac state.
#
#   sudo /usr/local/bin/ai-extra.sh [start|stop|status]
#
# What it does:
#   1. apk-add the lazy docker stack from the live ISO repo (offline, no net).
#   2. Locate + loop-mount the on-disk Ollama squashfs (myi2pd-ollama.squashfs,
#      shipped next to the ISO / on the same USB media).
#   3. Start dockerd, docker-load the Ollama image, run it with GPU detection
#      (NVIDIA via nvidia-container-toolkit --gpus all, AMD via /dev/kfd+/dev/dri,
#      else CPU).
#   4. Install the Claurst coding agent binary (native, NOT containerized).
#   5. Lay down the ingrained agent context (~/.claude/CLAUDE.md) + a
#      Claurst settings.json that points at the local Ollama server, so the
#      agent knows the amnesiac environment, every tool, and its restraints.

set -euo pipefail

ACTION="${1:-start}"
TAG="myi2pd-ollama:latest"
IMG_TAR="ollama-image.tar"
SQUASHFS="myi2pd-ollama.squashfs"
OLLAMA_URL="http://127.0.0.1:11434"
API_BASE="/v1"               # OpenAI-compatible endpoint Claurst uses
CLAURST_VER_LINUX="claurst-linux-x86_64.tar.gz"

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
log() { echo "[ai] $*"; }
need() { command -v "$1" >/dev/null 2>&1; }

start_squashfs() {
    # The squashfs is shipped beside the ISO / on the boot media. Find any
    # block device containing it. Covers USB stick (vfat/ext), loop files.
    local mnt="${MNT:-/mnt/ollama}"
    mkdir -p "$mnt"
    local dev
    for dev in /dev/${SQUASHFS_DEV:-} \
               /dev/mapper/* /dev/sd[a-z]* /dev/nvme* /dev/mmcblk*; do
        [ -b "$dev" ] || continue
        if mountpoint -q "$mnt" && mount -t squashfs -o remount,ro "$dev" "$mnt" 2>/dev/null; then
            [ -f "$mnt/$IMG_TAR" ] && { OLLAMA_MNT="$mnt"; return 0; }
        elif mountpoint -q "$mnt"; then
            continue
        elif [ -f "$dev" ]; then
            # loop / file-backed squashfs path passed via SQUASHFS_DEV=file
            mount -o loop,ro "$dev" "$mnt" 2>/dev/null \
                && [ -f "$mnt/$IMG_TAR" ] && { OLLAMA_MNT="$mnt"; return 0; }
        else
            mount -o ro "$dev" "$mnt" 2>/dev/null \
                && [ -f "$mnt/$IMG_TAR" ] && { OLLAMA_MNT="$mnt"; return 0; }
            mountpoint -q "$mnt" && umount "$mnt" 2>/dev/null || true
        fi
    done
    # Fall back to the repo-root copy (useful for local/VM testing).
    for cand in "$SQUASHFS" "/media/$SQUASHFS" "/root/$SQUASHFS"; do
        if [ -f "$cand" ]; then
            mount -o loop,ro "$cand" "$mnt" 2>/dev/null \
                && [ -f "$mnt/$IMG_TAR" ] && { OLLAMA_MNT="$mnt"; return 0; }
        fi
    done
    log "ERROR: could not find/mount $SQUASHFS on any block device."
    log "Reboot with the stick containing the squashfs, or export MNT=/path and"
    log "SQUASHFS_DEV=/path/to/squashfs to point at a file-backed copy."
    return 1
}

detect_gpu() {
    # Returns the docker device/GPU flags. NVIDIA preferred, then AMD, else CPU.
    if ls /dev/nvidiactl >/dev/null 2>&1; then
        echo "--gpus all"
    elif [ -e /dev/kfd ] && [ -e /dev/dri/renderD128 ]; then
        echo "--device /dev/kfd --device /dev/dri"
    else
        echo ""
    fi
}

ensure_docker() {
    # Load the docker stack from the ISO on-disk apk repo (offline). These are
    # NOT in world, so they install to RAM only when this script runs.
    if need docker && need dockerd; then
        log "docker already present"
    else
        log "loading docker stack from ISO repo (offline)"
        apk add --quiet $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /etc/ai-apks.list)
    fi
    if ! rc-service docker status >/dev/null 2>&1; then
        log "starting dockerd"
        rc-service docker start
    fi
    for i in $(seq 1 20); do
        docker info >/dev/null 2>&1 && break || sleep 1
    done
}

stop() {
    log "stopping ollama container + unmounting squashfs"
    docker rm -f myi2pd-ollama >/dev/null 2>&1 || true
    if [ -n "${OLLAMA_MNT:-}" ] && mountpoint -q "$OLLAMA_MNT"; then
        umount "$OLLAMA_MNT" 2>/dev/null || true
    fi
    log "done (RAM freed; agent binary + context remain)"
}

install_claurst() {
    if need claurst; then
        log "claurst already installed"
        return 0
    fi
    # Native binary download (single file, no telemetry). Use the on-media copy
    # if present, else fetch from GitHub releases.
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    if [ -f "${OLLAMA_MNT:-/nonexistent}/$CLAURST_VER_LINUX" ]; then
        cp "${OLLAMA_MNT}/$CLAURST_VER_LINUX" "$tmp/"
    else
        local ver
        ver="$(curl -fsSL https://api.github.com/repos/Kuberwastaken/claurst/releases/latest \
                 | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed -E 's/.*"v?([^"]+)"/\1/')"
        log "downloading claurst v$ver"
        curl -fsSL "https://github.com/Kuberwastaken/claurst/releases/download/v${ver}/${CLAURST_VER_LINUX}" \
            -o "$tmp/$CLAURST_VER_LINUX"
    fi
    tar -xzf "$tmp/$CLAURST_VER_LINUX" -C "$tmp"
    install -m 0755 "$tmp/claurst" /usr/local/bin/claurst
    log "claurst installed: $(command -v claurst)"
}

install_agent_context() {
    # "Ingrained" context: Claurst auto-loads CLAUDE.md walked up from cwd and
    # ~/.claude/CLAUDE.md. We layer it so no matter where the agent opens, it
    # knows this is an amnesiac box (see client/configs/CLAUDE.md) and is pinned
    # to its tool catalog + restraints.
    mkdir -p /root/.claude /root/.claurst
    install -m 0644 /usr/local/share/myi2pd/CLAUDE.md /root/.claude/CLAUDE.md 2>/dev/null \
        || install -m 0644 /usr/local/share/myi2pd/AGENTS.md /root/.claude/CLAUDE.md
    # Point Claurst at the local Ollama server (OpenAI-compatible /v1) by default.
    cat > /root/.claurst/settings.json <<'JSON'
{
  "provider": "ollama",
  "config": {
    "model": "qwen2.5-coder:1.5b",
    "permission_mode": "default",
    "auto_compact": true,
    "compact_threshold": 0.8
  }
}
JSON
    log "agent context installed: /root/.claude/CLAUDE.md + /root/.claurst/settings.json"
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
case "$ACTION" in
    stop) stop; exit 0 ;;
    status)
        docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep myi2pd-ollama \
            || echo "ollama not running"
        command -v claurst || echo "claurst not installed"
        exit 0
        ;;
esac

ensure_docker
start_squashfs
[ -n "${OLLAMA_MNT:-}" ] || exit 1

log "loading Ollama image (${OLLAMA_MNT}/$IMG_TAR)"
docker load -q -i "${OLLAMA_MNT}/$IMG_TAR"

GPU="$(detect_gpu)"
log "GPU flags: '${GPU:-CPU-only}'"
docker rm -f myi2pd-ollama >/dev/null 2>&1 || true
docker run -d --name myi2pd-ollama --restart unless-stopped \
    $GPU -p 127.0.0.1:11434:11434 \
    -e OLLAMA_HOST=0.0.0.0:11434 \
    "$TAG"

install_claurst
install_agent_context

log "done. Ollama: $OLLAMA_URL  |  Claurst: claurst"
echo
echo "Quick check: curl $OLLAMA_URL/v1/models"
echo "Start Claurst with Ollama:  claurst --provider ollama --model qwen2.5-coder:1.5b"