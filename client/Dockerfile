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
FROM alpine:edge

# Install image building toolchain dependencies
RUN apk add --no-cache \
    alpine-sdk \
    alpine-conf \
    xorriso \
    syslinux \
    squashfs-tools \
    git \
    bash \
    openssl \
    grub \
    grub-efi

# Copy pre-compiled TrustTunnel client from builder standard location
COPY --from=builder /usr/local/bin/trusttunnel_client /usr/local/bin/

# Clone official Alpine image-building scripts (aports) and patch apk v3 --no-chown compatibility
WORKDIR /usr/src
RUN git clone --depth 1 https://gitlab.alpinelinux.org/alpine/aports.git \
    && sed -i 's/--no-chown//g' aports/scripts/mkimage.sh

WORKDIR /usr/src/aports/scripts

# Copy our custom configuration templates into workspace overlay
# These will be set up by the host runner script
RUN mkdir -p /build/overlay/etc/init.d \
             /build/overlay/etc/runlevels/boot \
             /build/overlay/etc/runlevels/default \
             /build/overlay/etc/nftables \
             /build/overlay/etc/librewolf \
             /build/overlay/etc/river \
             /build/overlay/etc/xdg/waybar \
             /build/overlay/usr/local/bin \
             /build/overlay/root

# Copy the myi2pd ISO profile configuration and the overlay packager script from static host configs
COPY configs/mkimg.myi2pd.sh /usr/src/aports/scripts/mkimg.myi2pd.sh
COPY configs/genapkovl-myi2pd.sh /usr/src/aports/scripts/genapkovl-myi2pd.sh
RUN chmod +x /usr/src/aports/scripts/genapkovl-myi2pd.sh

# Copy the ISO packaging execution script
COPY configs/assemble-iso /usr/local/bin/assemble-iso
RUN chmod +x /usr/local/bin/assemble-iso

CMD ["/usr/local/bin/assemble-iso"]
