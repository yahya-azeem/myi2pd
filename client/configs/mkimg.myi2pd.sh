profile_myi2pd() {
    profile_standard
    name="myi2pd"
    desc="Amnesiac TrustTunnel Network Gateway Client"
    arch="x86_64"
    kernel_flavors="virt"
    kernel_addons=""
    apks="$apks nftables bash openssl wireless-tools wpa_supplicant e2fsprogs river-classic fuzzel waybar foot font-dejavu fontconfig seatd seatd-launch dbus dbus-x11 dbus-openrc librewolf mesa-dri-gallium swaybg udev util-linux util-linux-misc agetty libdrm-tests ncneofetch neomutt linux-firmware-none $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /build/overlay/etc/pentest-apks.list 2>/dev/null || echo)"
    apkovl="genapkovl-myi2pd.sh"
    hostname="myi2pd"
    modloop_sign="no"
    syslinux_timeout=1
    grub_timeout=0
    syslinux_serial="0 38400"
    kernel_cmdline="console=tty0 console=ttyS0,38400 net.ifnames=0 bochs.defx=1024 bochs.defy=768 modules=usbhid,evdev,hid_generic,af_packet,psmouse,xhci-hcd,xhci-pci,ehci-hcd,ehci-pci,uhci-hcd,virtio_input,virtio_net,bochs"
}
