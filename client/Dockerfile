# Multi-stage Dockerfile to compile TrustTunnel C++ Client and build custom myi2pd ISO
FROM alpine:edge AS builder

# Install build dependencies for TrustTunnel C++ client compilation
RUN apk add --no-cache \
    build-base \
    git \
    cmake \
    openssl-dev \
    python3 \
    py3-pip \
    go \
    ninja \
    linux-headers

# Set up Conan package manager
ENV CONAN_HOME=/tmp/.conan
RUN python3 -m venv /opt/conan-env
ENV PATH="/opt/conan-env/bin:$PATH"
RUN pip install --no-cache-dir conan

# Auto-detect default profile settings for Conan compiler detection
RUN conan profile detect --force \
    && echo -e "\n[replace_tool_requires]\ncmake/*: cmake/system\nninja/*: ninja/system\ngo/*: go/system\n\n[platform_tool_requires]\ncmake/system\nninja/system\ngo/system" >> /tmp/.conan/profiles/default


# Clone TrustTunnel C++ Client repository
WORKDIR /tmp/trusttunnel-client-build
RUN git clone --depth 1 https://github.com/TrustTunnel/TrustTunnelClient.git .

# Install dependencies needed by the build/bootstrap scripts
RUN pip install --no-cache-dir -r requirements.txt

# Run the Conan dependency bootstrap process to populate local cache with adguard recipes
RUN python scripts/bootstrap_conan_deps.py

# Install project dependencies via Conan and generate toolchain
RUN conan install . -pr:b default -pr:h default --build=missing -s build_type=Release

# Locate the toolchain, configure/compile using CMake + Ninja, and build the client executable target
RUN TOOLCHAIN=$(find build -name "conan_toolchain.cmake") \
    && cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN -DCMAKE_INSTALL_PREFIX=/opt/conan2 -GNinja \
    && cmake --build build --target trusttunnel_client

# Move the compiled client binary to a standard location in the builder
RUN cp $(find build -name "trusttunnel_client" -type f -executable) /usr/local/bin/trusttunnel_client

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

# Copy pre-compiled TrustTunnel client from builder standard location
COPY --from=builder /usr/local/bin/trusttunnel_client /usr/local/bin/

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
