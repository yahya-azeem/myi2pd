profile_myi2pd-vps() {
    profile_standard
    name="myi2pd-vps"
    desc="myi2pd VPS Gateway"
    arch="x86_64"
    kernel_flavors="virt"
    kernel_addons=""
    apks="$apks nftables nftables-openrc bash openssl e2fsprogs dnsmasq dnsmasq-openrc i2pd i2pd-openrc eudev eudev-openrc dhcpcd dhcpcd-openrc"
    apkovl="genapkovl-myi2pd-vps.sh"
    hostname="myi2pd-gateway"
    modloop_sign="no"
    syslinux_timeout=1
    grub_timeout=0
    kernel_cmdline="console=tty0 console=ttyS0,38400 net.ifnames=0 modules=af_packet,nf_tables,nft_chain_nat,nft_masq,nft_redir"
}
