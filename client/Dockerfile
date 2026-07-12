# Multi-stage Dockerfile to compile TrustTunnel and build custom myi2pd ISO under 1 GB footprint
FROM alpine:3.20 AS builder

# Install build dependencies for TrustTunnel client compilation
RUN apk add --no-cache \
    build-base \
    git \
    rust \
    cargo \
    openssl-dev \
    cmake \
    clang-dev \
    llvm-dev \
    perl

# Clone and compile TrustTunnel static binaries
WORKDIR /tmp/trusttunnel-build
RUN git clone --depth 1 https://github.com/TrustTunnel/TrustTunnel.git . \
    && cargo build --release --bins

# Create final image assembler
FROM alpine:3.20

# Install image building toolchain dependencies
RUN apk add --no-cache \
    alpine-sdk \
    xorriso \
    syslinux \
    squashfs-tools \
    git \
    bash \
    openssl

# Copy pre-compiled TrustTunnel binaries from builder
COPY --from=builder /tmp/trusttunnel-build/target/release/trusttunnel_client /usr/local/bin/
COPY --from=builder /tmp/trusttunnel-build/target/release/setup_wizard /usr/local/bin/

# Clone official Alpine image-building scripts (aports)
WORKDIR /usr/src
RUN git clone --depth 1 https://gitlab.alpinelinux.org/alpine/aports.git

WORKDIR /usr/src/aports/scripts

# Copy our custom configuration templates into workspace overlay
# These will be set up by the host runner script
RUN mkdir -p /build/overlay/etc/init.d \
             /build/overlay/etc/runlevels/boot \
             /build/overlay/etc/runlevels/default \
             /build/overlay/etc/nftables \
             /build/overlay/etc/i2pd \
             /build/overlay/etc/librewolf \
             /build/overlay/etc/river \
             /build/overlay/etc/xdg/waybar \
             /build/overlay/usr/local/bin \
             /build/overlay/root

# Configure the myi2pd ISO profile
RUN cat <<'EOF' > mkimg.myi2pd.sh
profile_myi2pd() {
    profile_standard
    name="myi2pd"
    desc="Amnesiac TrustTunnel Network Gateway Client"
    arch="x86_64"
    kernel_flavors="virt"
    # Bundles the offline packages directory on the ISO
    apks="$apks nftables i2pd bash openssl wireless-tools wpa_supplicant e2fsprogs river fuzzel waybar foot font-dejavu seatd librewolf dbus mesa-dri-gallium udev"
    initfs_features="base ext4 squashfs kms network wireless"
}
EOF

# Build execution script
RUN cat <<'EOF' > /usr/local/bin/assemble-iso
#!/bin/bash
set -e

echo "=== Packaging myi2pd Amnesiac ISO ==="

# Copy the compiled trusttunnel_client binary into the overlay usr/local/bin directory
cp /usr/local/bin/trusttunnel_client /build/overlay/usr/local/bin/

# Set execution permissions on overlay files
chmod +x /build/overlay/usr/local/bin/*
chmod +x /build/overlay/etc/init.d/*

# Enable OpenRC services in the boot and default runlevels on the client
ln -sf /etc/init.d/hdd-isolation /build/overlay/etc/runlevels/boot/hdd-isolation
ln -sf /etc/init.d/dbus /build/overlay/etc/runlevels/default/dbus
ln -sf /etc/init.d/seatd /build/overlay/etc/runlevels/default/seatd

# Run Alpine image builder
sh mkimage.sh --profile myi2pd --output /build/myi2pd-amnesiac.iso --overlay /build/overlay

echo "=== ISO built successfully! ==="
EOF
RUN chmod +x /usr/local/bin/assemble-iso

CMD ["/usr/local/bin/assemble-iso"]
