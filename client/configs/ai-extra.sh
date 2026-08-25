#!/bin/bash
# client/configs/ai-extra.sh - On-demand AI stack for the amnesiac client.
#
# The amnesiac ISO boots diskless into 4G of tmpfs root. Tensor/GPU workloads
# (Ollama, FreeToken) and agent harness (DeepSeek Harness) must therefore NOT
# be baked into the root at boot. This script, run ONCE when the user wants
# local inference, assembles the stack. Everything non-persistent: reboot or
# unplug the stick returns the system to a clean amnesiac state.
#
#   sudo /usr/local/bin/ai-extra.sh [start|stop|status] [ollama|freetoken|dsh|all]
#
# What it does:
#   1. apk-add the lazy docker + bun + python/uv stack from the live ISO repo (offline).
#   2. Locate + loop-mount the on-disk Ollama squashfs (myi2pd-ollama.squashfs).
#   3. Start dockerd, docker-load the Ollama image, run it with GPU detection
#      (NVIDIA via --gpus all, AMD via /dev/kfd+/dev/dri, else CPU) on port 11434.
#   4. (Optional) Install FreeToken via uv, run MoE server on port 1919.
#   5. Run DeepSeek Harness (dsh) via `bunx @deepseek-ai/dsh web` on port 3080.
#   6. Lay down the ingrained agent context (~/.deepseek-harness/CLAUDE.md) + config
#      that points at local Ollama (11434) and FreeToken (1919).

set -euo pipefail

ACTION="${1:-start}"
SERVICE="${2:-all}"
TAG="myi2pd-ollama:latest"
IMG_TAR="ollama-image.tar"
SQUASHFS="myi2pd-ollama.squashfs"
OLLAMA_URL="http://127.0.0.1:11434"
OLLAMA_API="/v1"
FREETOKEN_URL="http://127.0.0.1:1919"
FREETOKEN_API="/v1"
DSH_PORT=3080
FREETOKEN_VENV="/tmp/freetoken-venv"

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

ensure_base_stack() {
    if need docker && need dockerd && need bun && need python3 && need uv; then
        log "base stack (docker+bun+python+uv) already present"
    else
        log "loading base stack from ISO repo (offline)"
        apk add --quiet $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /etc/ai-apks.list)
    fi
    if ! rc-service docker status >/dev/null 2>&1; then
        log "starting dockerd"
        rc-service docker start
    fi
    for i in $(seq 1 20); do
        docker info >/dev/null 2>&1 && break || sleep 1
    done
    log "Bun: $(bun --version), uv: $(uv --version)"
}

ensure_freetoken() {
    log "setting up FreeToken venv at $FREETOKEN_VENV"
    uv venv "$FREETOKEN_VENV" --python python3 --quiet
    source "$FREETOKEN_VENV/bin/activate"
    # Install from PyPI (offline if wheels cached, else needs net)
    # For fully offline: pre-download wheels to ISO repo
    uv pip install --quiet "freetoken[accel]" 2>/dev/null || {
        log "WARN: FreeToken install failed (needs CUDA toolkit + net). Skipping."
        return 1
    }
    log "FreeToken installed: $(ft --version 2>/dev/null || echo 'unavailable')"
    return 0
}

stop() {
    log "stopping ollama + freetoken + dsh + unmounting squashfs"
    docker rm -f myi2pd-ollama >/dev/null 2>&1 || true
    pkill -f "@deepseek-ai/dsh" 2>/dev/null || true
    pkill -f "ft serve" 2>/dev/null || true
    if [ -n "${OLLAMA_MNT:-}" ] && mountpoint -q "$OLLAMA_MNT"; then
        umount "$OLLAMA_MNT" 2>/dev/null || true
    fi
    [ -d "$FREETOKEN_VENV" ] && rm -rf "$FREETOKEN_VENV"
    log "done (RAM freed; agent context remains)"
}

run_ollama() {
    log "loading Ollama image (${OLLAMA_MNT}/$IMG_TAR)"
    docker load -q -i "${OLLAMA_MNT}/$IMG_TAR"
    GPU="$(detect_gpu)"
    log "GPU flags: '${GPU:-CPU-only}'"
    docker rm -f myi2pd-ollama >/dev/null 2>&1 || true
    docker run -d --name myi2pd-ollama --restart unless-stopped \
        $GPU -p 127.0.0.1:11434:11434 \
        -e OLLAMA_HOST=0.0.0.0:11434 \
        "$TAG"
}

run_freetoken() {
    log "starting FreeToken MoE server on port 1919"
    if ! need ft; then
        log "FreeToken not installed; skipping."
        return 1
    fi
    # Allow firewall access to FreeToken API
    nft add rule inet filter output tcp dport 1919 accept 2>/dev/null || true
    # Find a model (prefers MoE models like DeepSeek-V4-Flash, Qwen3.6-35B-A3B)
    local model_dir="${FREETOKEN_MODEL_DIR:-/root/.cache/huggingface/hub}"
    local model="${FREETOKEN_MODEL:-}"
    [ -z "$model" ] && model="Qwen/Qwen3.6-35B-A3B"  # default MoE model
    
    # Run ft serve in background
    FT_SERVER_URL="$FREETOKEN_URL" \
    ft serve --model "$model" --host 127.0.0.1 --port 1919 \
        > /tmp/freetoken.log 2>&1 &
    local ft_pid=$!
    echo $ft_pid > /tmp/freetoken.pid
    sleep 5
    if kill -0 $ft_pid 2>/dev/null; then
        log "FreeToken running: $FREETOKEN_URL$FREETOKEN_API (model: $model)"
    else
        log "ERROR: FreeToken failed, check /tmp/freetoken.log"
        tail -20 /tmp/freetoken.log
        return 1
    fi
}

run_dsh() {
    log "starting DeepSeek Harness (dsh) web UI on port $DSH_PORT"
    nft add rule inet filter output tcp dport $DSH_PORT accept 2>/dev/null || true
    # DSH auto-discovers Ollama + FreeToken via env
    OLLAMA_BASE_URL="$OLLAMA_URL" \
    FREETOKEN_BASE_URL="$FREETOKEN_URL" \
    DSH_HOST=127.0.0.1 \
    DSH_PORT=$DSH_PORT \
    bunx --yes @deepseek-ai/dsh@latest web --host 127.0.0.1 --port $DSH_PORT --no-open \
        > /tmp/dsh.log 2>&1 &
    local dsh_pid=$!
    echo $dsh_pid > /tmp/dsh.pid
    sleep 3
    if kill -0 $dsh_pid 2>/dev/null; then
        log "DeepSeek Harness running: http://127.0.0.1:$DSH_PORT"
    else
        log "ERROR: DSH failed, check /tmp/dsh.log"
        tail -20 /tmp/dsh.log
        return 1
    fi
}

install_agent_context() {
    mkdir -p /root/.deepseek-harness /root/.claude
    install -m 0644 /usr/local/share/myi2pd/CLAUDE.md /root/.claude/CLAUDE.md 2>/dev/null \
        || install -m 0644 /usr/local/share/myi2pd/AGENTS.md /root/.claude/CLAUDE.md
    # DeepSeek Harness config: dual provider (Ollama + FreeToken)
    cat > /root/.deepseek-harness/config.json <<'JSON'
{
  "model": {
    "provider": "ollama",
    "baseUrl": "http://127.0.0.1:11434/v1",
    "model": "qwen2.5-coder:1.5b"
  },
  "freetoken": {
    "provider": "freetoken",
    "baseUrl": "http://127.0.0.1:1919/v1",
    "model": "Qwen3.6-35B-A3B"
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
        if [ -f /tmp/freetoken.pid ] && kill -0 "$(cat /tmp/freetoken.pid)" 2>/dev/null; then
            echo "freetoken running (pid $(cat /tmp/freetoken.pid)) on port 1919"
        else
            echo "freetoken not running"
        fi
        if [ -f /tmp/dsh.pid ] && kill -0 "$(cat /tmp/dsh.pid)" 2>/dev/null; then
            echo "deepseek-harness running (pid $(cat /tmp/dsh.pid)) on port $DSH_PORT"
        else
            echo "deepseek-harness not running"
        fi
        exit 0
        ;;
esac

# Service selection
RUN_OLLAMA=false
RUN_FREETOKEN=false
RUN_DSH=false
case "$SERVICE" in
    ollama) RUN_OLLAMA=true ;;
    freetoken) RUN_FREETOKEN=true ;;
    dsh) RUN_DSH=true ;;
    all) RUN_OLLAMA=true; RUN_FREETOKEN=true; RUN_DSH=true ;;
    *) log "Usage: $0 {start|stop|status} {ollama|freetoken|dsh|all}"; exit 1 ;;
esac

ensure_base_stack

if $RUN_OLLAMA; then
    start_squashfs
    [ -n "${OLLAMA_MNT:-}" ] || exit 1
    run_ollama
fi

if $RUN_FREETOKEN; then
    ensure_freetoken && run_freetoken
fi

if $RUN_DSH; then
    run_dsh
fi

install_agent_context

log "done."
echo "  Ollama API:      $OLLAMA_URL$OLLAMA_API"
$RUN_FREETOKEN && echo "  FreeToken API:   $FREETOKEN_URL$FREETOKEN_API (MoE models)"
$RUN_DSH && echo "  DeepSeek DSH:    http://127.0.0.1:$DSH_PORT (Web UI)"
echo
echo "Quick checks:"
echo "  curl $OLLAMA_URL/v1/models"
$RUN_FREETOKEN && echo "  curl $FREETOKEN_URL/v1/models"
echo "  DSH Web UI: http://127.0.0.1:$DSH_PORT"