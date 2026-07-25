FROM alpine:edge
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
WORKDIR /usr/src
RUN git clone --depth 1 https://gitlab.alpinelinux.org/alpine/aports.git \
    && sed -i 's/--no-chown//g' aports/scripts/mkimage.sh
WORKDIR /usr/src/aports/scripts
