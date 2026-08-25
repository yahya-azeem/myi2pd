#!/bin/bash
# client/configs/ai-extra.sh - On-demand AI stack for the amnesiac client.
#
# The amnesiac ISO boots diskless into 4G of tmpfs root. Tensor/GPU workloads
# (Ollama) and agent harness (DeepSeek Harness) must therefore NOT be baked into
# the root at boot. This script, run ONCE when the user wants local inference,
# assembles the stack. Everything non-persistent: reboot or unplug the stick
# returns the system to a clean amnesiac state.
#
#   sudo /usr/local/bin/ai-extra.sh [start|stop|status]
#
# What it does:
#   1. apk-add the lazy docker + nodejs stack from the live ISO repo (offline).
#   2. Locate + loop-mount the on-disk Ollama squashfs (myi2pd-ollama.squashfs).
#   3. Start dockerd, docker-load the Ollama image, run it with GPU detection
#      (NVIDIA via --gpus all, AMD via /dev/kfd+/dev/dri, else CPU).
#   4. Install/Run DeepSeek Harness (dsh) via npx (downloads @deepseek-ai/dsh from npm).
#   5. Lay down the ingrained agent context (~/.deepseek-harness/CLAUDE.md) + config
#      that points at the local Ollama server.

set -euo pipefail

ACTION="${1:-start}"
TAG="myi2pd-ollama:latest"
IMG_TAR="ollama-image.tar"
SQUASHFS="myi2pd-ollama.squashfs"
OLLAMA_URL="http://127.0.0.1:11434"
API_BASE="/v1"
DSH_PORT=3080

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
log() { echo "[ai] $*"; }
need() { command -v "$1" >/dev/null 2>&1; }

start_squashfs() {
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
            mount -o loop,ro "$dev" "$mnt" 2>/dev/null \
                && [ -f "$mnt/$IMG_TAR" ] && { OLLAMA_MNT="$mnt"; return 0; }
        else
            mount -o ro "$dev" "$mnt" 2>/dev/null \
                && [ -f "$mnt/$IMG_TAR" ] && { OLLAMA_MNT="$mnt"; return 0; }
            mountpoint -q "$mnt" && umount "$mnt" 2>/dev/null || true
        fi
    done
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
    if ls /dev/nvidiactl >/dev/null 2>&1; then
        echo "--gpus all"
    elif [ -e /dev/kfd ] && [ -e /dev/dri/renderD128 ]; then
        echo "--device /dev/kfd --device /dev/dri"
    else
        echo ""
    fi
}

ensure_docker_and_node() {
    if need docker && need dockerd && need node && need npx; then
        log "docker + node already present"
    else
        log "loading docker + nodejs stack from ISO repo (offline)"
        apk add --quiet $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /etc/ai-apks.list)
    fi
    if ! rc-service docker status >/dev/null 2>&1; then
        log "starting dockerd"
        rc-service docker start
    fi
    for i in $(seq 1 20); do
        docker info >/dev/null 2>&1 && break || sleep 1
    done
    log "Node: $(node --version), npm: $(npm --version), npx: $(npx --version)"
}

stop() {
    log "stopping ollama container + dsh + unmounting squashfs"
    docker rm -f myi2pd-ollama >/dev/null 2>&1 || true
    pkill -f "@deepseek-ai/dsh" 2>/dev/null || true
    if [ -n "${OLLAMA_MNT:-}" ] && mountpoint -q "$OLLAMA_MNT"; then
        umount "$OLLAMA_MNT" 2>/dev/null || true
    fi
    log "done (RAM freed; agent context remains)"
}

run_dsh() {
    log "starting DeepSeek Harness (dsh) web UI on port $DSH_PORT"
    # Allow firewall access to DSH web UI
    nft add rule inet filter output tcp dport $DSH_PORT accept 2>/dev/null || true
    
    # Run DSH via npx - it will download @deepseek-ai/dsh from npm on first run
    # DSH reads OLLAMA_BASE_URL env for the local model server
    OLLAMA_BASE_URL="$OLLAMA_URL" \
    DSH_HOST=127.0.0.1 \
    DSH_PORT=$DSH_PORT \
    npx --yes @deepseek-ai/dsh@latest web --host 127.0.0.1 --port $DSH_PORT --no-open \
        > /tmp/dsh.log 2>&1 &
    local dsh_pid=$!
    echo $dsh_pid > /tmp/dsh.pid
    sleep 3
    if kill -0 $dsh_pid 2>/dev/null; then
        log "DeepSeek Harness running: http://127.0.0.1:$DSH_PORT"
    else
        log "ERROR: DSH failed to start, check /tmp/dsh.log"
        tail -20 /tmp/dsh.log
        return 1
    fi
}

install_agent_context() {
    mkdir -p /root/.deepseek-harness /root/.claude
    # Layer CLAUDE.md for any agent (Claurst, DSH, etc.)
    install -m 0644 /usr/local/share/myi2pd/CLAUDE.md /root/.claude/CLAUDE.md 2>/dev/null \
        || install -m 0644 /usr/local/share/myi2pd/AGENTS.md /root/.claude/CLAUDE.md
    # DeepSeek Harness config: point to local Ollama
    cat > /root/.deepseek-harness/config.json <<'JSON'
{
  "model": {
    "provider": "ollama",
    "baseUrl": "http://127.0.0.1:11434/v1",
    "model": "qwen2.5-coder:1.5b"
  },
  "harness": {
    "host": "127.0.0.1",
    "port": 3080
  }
}
JSON
    log "agent context installed: /root/.claude/CLAUDE.md + /root/.deepseek-harness/config.json"
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
case "$ACTION" in
    stop) stop; exit 0 ;;
    status)
        docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep myi2pd-ollama \
            || echo "ollama not running"
        if [ -f /tmp/dsh.pid ] && kill -0 "$(cat /tmp/dsh.pid)" 2>/dev/null; then
            echo "deepseek-harness running (pid $(cat /tmp/dsh.pid)) on port $DSH_PORT"
        else
            echo "deepseek-harness not running"
        fi
        exit 0
        ;;
esac

ensure_docker_and_node
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

run_dsh
install_agent_context

log "done."
echo "  Ollama API:   $OLLAMA_URL$API_BASE"
echo "  DeepSeek DSH: http://127.0.0.1:$DSH_PORT (Web UI)"
echo
echo "Quick check: curl $OLLAMA_URL/v1/models"
echo "DSH Web UI opens at: http://127.0.0.1:$DSH_PORT"