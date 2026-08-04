# myi2pd amnesiac client - minimal Ollama GPU-inference container.
#
# The goal is a *bare-minimum* container that can serve local LLM inference to
# the Claurst coding agent, with one image that supports all three runtimes
# (CPU, NVIDIA CUDA, AMD via Vulkan). The clients boot diskless into 4G of
# tmpfs, so the Ollama image must be as small as possible and is shipped ON DISK
# inside an on-demand squashfs (myi2pd-ollama.squashfs), never extracted into
# root RAM.
#
# Strategy - build WITHOUT pulling the multi-GB official ollama image:
#   Ollama ships a standalone release tarball (ollama-linux-amd64.tar.zst ~1.4GB)
#   that already contains the `ollama` server binary AND the llama-server
#   runtime libs under lib/ollama/ (CPU ggml, cuda_v12, cuda_v13, vulkan).
#   We download exactly that, extract only what we need, and drop it onto
#   cgr.dev/chainguard/wolfi-base (a ~40 MB glibc base). The GPU *drivers* never
#   ship in the image: they are passed in from the host at run time (NVIDIA via
#   nvidia-container-toolkit --gpus all; AMD/Intel via Vulkan + /dev/dri). That
#   is what keeps the final image truly light while still supporting every
#   runtime.
#
#   Why Wolfi and not the alpine host's musl? GPU (CUDA/Vulkan) llama-server
#   libs are built for glibc. A glibc base (Wolfi) runs them; the diskless
#   Alpine/musl host alone cannot do GPU inference - hence the container.
#
#   Vulkan is the lightweight cross-vendor backend: it drives AMD + Intel + (via
#   the NVIDIA driver) NVIDIA cards through one API, so we do NOT need the much
#   larger ROCm tarball for AMD. Add ROCm only if you specifically want it.
#
# Build (the tarball is fetched once and cached by the buildkit layer):
#   docker build -t myi2pd-ollama:latest -f client/ai/ollama/Dockerfile .
#
# Backend pruning via build arg OLLAMA_BACKENDS (space-separated subdirectories
# under lib/ollama/ that are KEPT; ggml base + cpu libs are always kept):
#   false  = keep everything the base tarball ships (cpu + cuda_v12 + cuda_v13 + vulkan)
#   cpu    = CPU only (smallest)
#   "cpu cuda_v13" = CPU + one CUDA major
#
# Serve (host must expose GPU devices; nvidia-container-toolkit for CUDA):
#   docker run --rm --gpus all -p 127.0.0.1:11434:11434 myi2pd-ollama:latest          # NVIDIA
#   docker run --rm --device /dev/dri -p 127.0.0.1:11434:11434 myi2pd-ollama:latest    # AMD/Intel (Vulkan)
#   docker run --rm -p 127.0.0.1:11434:11434 myi2pd-ollama:latest                      # CPU

FROM cgr.dev/chainguard/wolfi-base:latest AS base
RUN apk add --no-cache ca-certificates tzdata curl zstd

# Fetch the standalone Ollama release tarball (NOT the 8GB docker image).
# Pin to the latest GitHub release. ~1.4 GB compressed, ~2.5 GB unpacked.
ARG OLLAMA_VERSION=latest
RUN curl -fsSLo /tmp/ollama.tar.zst \
      "https://github.com/ollama/ollama/releases/${OLLAMA_VERSION}/download/ollama-linux-amd64.tar.zst" \
    && zstd -dc /tmp/ollama.tar.zst | tar -x -C /tmp && rm -f /tmp/ollama.tar.zst

# Everything we need is now under /tmp/{bin,lib}. Stage it for copy.
FROM scratch AS payload
COPY --from=base /tmp/bin/ollama /bin/ollama
COPY --from=base /tmp/lib/ollama /lib/ollama

FROM cgr.dev/chainguard/wolfi-base:latest AS final
RUN apk add --no-cache ca-certificates tzdata

COPY --from=payload /bin/ollama /usr/bin/ollama
COPY --from=payload /lib/ollama /usr/lib/ollama

# Prune unselected GPU backends. The ggml base + cpu libs are kept always.
# Many are tiny; only cuda_v12/cuda_v13/vulkan are heavy, so pruning those is
# how you shrink the image when you only need CPU.
ARG OLLAMA_BACKENDS=false
RUN if [ -n "$OLLAMA_BACKENDS" ] && [ "$OLLAMA_BACKENDS" != "false" ]; then \
      cut=""; \
      for d in /usr/lib/ollama/cuda_v12 /usr/lib/ollama/cuda_v13 /usr/lib/ollama/vulkan; do \
        case " $OLLAMA_BACKENDS " in \
          *" $(basename "$d") "*) ;; \
          *) cut="$cut $d" ;; \
        esac; \
      done; \
      [ -n "$cut" ] && rm -rf $cut || true; \
    fi

ENV OLLAMA_HOST=0.0.0.0:11434 \
    OLLAMA_KEEP_ALIVE=5m \
    PATH=/usr/bin
EXPOSE 11434
ENTRYPOINT ["/usr/bin/ollama"]
CMD ["serve"]