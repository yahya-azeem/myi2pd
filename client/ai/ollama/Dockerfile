# myi2pd amnesiac client - minimal Ollama GPU-inference container.
#
# The goal is a *bare-minimum* container that can serve local LLM inference to
# the Claurst coding agent, with one image that supports all three runtimes
# (CPU, NVIDIA CUDA, AMD ROCm). The clients boot diskless into 4G of tmpfs, so
# the Ollama image must be as small as possible and is shipped ON DISK inside an
# on-demand squashfs (myi2pd-ollama.squashfs), never extracted into root RAM.
#
# Why not the official ollama/ollama image?
#   - It sits on a multi-GB Ubuntu rootfs (~3.2 GB unpacked).
#   - Our amnesiac client is Alpine/musl: the official static bundle is built
#     for glibc, so GPU (CUDA/ROCm) inference requires a glibc container. But we
#     still want it tiny, so we build on a Chainguard Wolfi glibc base instead.
#
# Strategy:
#   1. Copy ONLY the ollama server binary (/bin/ollama) + the llama-server
#      backends (/usr/lib/ollama) out of the official image.
#   2. Drop them onto cgr.dev/chainguard/wolfi-base (a ~40 MB glibc base) with
#      just ca-certificates. The GPU *drivers* never ship in the image: they are
#      passed in from the host at run time (NVIDIA via nvidia-container-toolkit
#      with --gpus all; AMD via /dev/kfd + /dev/dri). That is what keeps the
#      image truly light while still supporting every runtime.
#
# Backend selection is via build arg OLLAMA_BACKENDS (space-separated subdiretories
# under /usr/lib/ollama/): true=all shipped backends, cpu=CPU only (smallest),
# or a list like "cpu cuda_v13 vulkan". amd64 official bundles: cpu, cuda_v12,
# cuda_v13, vulkan, mlx (and, in the full archive, rocm_v7_2).
#
#   docker build -t myi2pd-ollama:latest \
#     --build-arg OLLAMA_BACKENDS=false \    # or cpu / a list
#     -f client/ai/ollama/Dockerfile .
#
# Serve (host must expose GPU devices + have nvidia-container-toolkit for CUDA):
#   docker run --rm --gpus all -p 127.0.0.1:11434:11434 myi2pd-ollama:latest
#   docker run --rm --device /dev/kfd --device /dev/dri -p 127.0.0.1:11434:11434 myi2pd-ollama:latest  # AMD
#   docker run --rm -p 127.0.0.1:11434:11434 myi2pd-ollama:latest                                    # CPU

FROM ollama/ollama:latest AS ollama-runtime

# Minimal glibc base used by all myi2pd GPU/agent containers. Wolfi (apk-based)
# is glibc-clean, CA-certified, and ~40 MB - a fraction of the Ubuntu base.
FROM cgr.dev/chainguard/wolfi-base:latest AS base
RUN apk add --no-cache ca-certificates tzdata

# Default: copy every backend shipped by the official amd64 runtime so one image
# supports CPU + NVIDIA + AMD. Override to "cpu" for the smallest image.
#   false -> copy everything under /usr/lib/ollama
#   cpu   -> only ggml cpu libs
#   list  -> "cpu cuda_v13 vulkan" etc.
ARG OLLAMA_BACKENDS=false

FROM base AS final
COPY --from=ollama-runtime /bin/ollama /usr/bin/ollama
COPY --from=ollama-runtime /usr/lib/ollama /usr/lib/ollama

# Prune unselected backends (only when a specific subset was requested). The
# ggml base libs + cpu variant are always kept; the common/ helper libs are
# needed by every backend (ggml base, llama, common) and only removed when the
# run request was `cpu` to also shed the unneeded common cuda shims - which are
# shared and harmless, so keep them for correctness.
RUN if [ -n "$OLLAMA_BACKENDS" ] && [ "$OLLAMA_BACKENDS" != "false" ]; then \
      keep="/usr/lib/ollama/llama-server-cpu"; \
      cut=""; \
      for b in $OLLAMA_BACKENDS; do keep="$keep /usr/lib/ollama/llama-server-$b"; done; \
      for d in /usr/lib/ollama/llama-server-*; do \
        case " $keep " in *" $d "*) ;; *) cut="$cut $d" ;; esac; \
      done; \
      [ -n "$cut" ] && rm -rf $cut || true; \
    fi

ENV OLLAMA_HOST=0.0.0.0:11434 \
    OLLAMA_KEEP_ALIVE=5m \
    OLLAMA_NOPRUNE=true \
    PATH=/usr/bin
EXPOSE 11434
ENTRYPOINT ["/usr/bin/ollama"]
CMD ["serve"]