profile_myi2pd() {
    profile_standard
    name="myi2pd"
    desc="Amnesiac TrustTunnel Network Gateway Client"
    arch="x86_64"
    kernel_flavors="virt"
    kernel_addons=""
    # Bundles the offline packages directory on the ISO
    apks="$apks nftables i2pd bash openssl wireless-tools wpa_supplicant e2fsprogs river fuzzel waybar foot font-dejavu seatd librewolf dbus mesa-dri-gallium udev util-linux util-linux-misc"
    apkovl="genapkovl-myi2pd.sh"
    hostname="myi2pd"
    modloop_sign="no"
    syslinux_timeout=1
    grub_timeout=0
}
