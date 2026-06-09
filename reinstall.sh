#!/usr/bin/env bash
# HorusInstall - Linux to Windows Server installer
# https://github.com/HorusHDx/HorusInstall
# Based on concepts from bin456789/reinstall (GPL-3.0)

set -eE

# ============================================================
# CONFIG
# ============================================================
CONFHOME=https://raw.githubusercontent.com/HorusHDx/HorusInstall/main
TMP=/horusinstall-tmp
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# ============================================================
# COLORS / OUTPUT
# ============================================================
info()  { echo -e "\e[32m***** $(echo "$*" | tr '[:lower:]' '[:upper:]') *****\e[0m" >&2; }
warn()  { echo -e "\e[33mWarning: $*\e[0m" >&2; }
error() { echo -e "\e[31m***** ERROR *****\e[0m" >&2; echo -e "\e[31m$*\e[0m" >&2; }
die()   { error "$@"; exit 1; }

trap 'error "Line $LINENO exited with code $?"' ERR

# ============================================================
# USAGE
# ============================================================
usage() {
cat <<EOF

HorusInstall - Reinstall Linux VPS to Windows Server
=====================================================

Usage:
  bash reinstall.sh windows --version VERSION [OPTIONS]

Versions:
  2016    Windows Server 2016 Datacenter
  2019    Windows Server 2019 Datacenter
  2022    Windows Server 2022 Datacenter

Options:
  --password PASSWORD   Administrator password (default: HorusInstall123!)
  --username USERNAME   Administrator username (default: Administrator)
  --port PORT           RDP Port (default: 3389)
  --iso URL             Custom Windows ISO URL (optional)
  --image NAME          Specific WIM Image name (optional)

EOF
exit 1
}

# ============================================================
# PARSE ARGUMENTS
# ============================================================
WINDOWS_VERSION=""
WIN_PASSWORD="HorusInstall123!"
WIN_USERNAME="Administrator"
RDP_PORT="3389"
CUSTOM_ISO_URL=""
WINDOWS_IMAGE_NAME=""

if [ "$1" != "windows" ]; then usage; fi
shift

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)  WINDOWS_VERSION="$2"; shift 2 ;;
        --password) WIN_PASSWORD="$2"; shift 2 ;;
        --username) WIN_USERNAME="$2"; shift 2 ;;
        --port)     RDP_PORT="$2"; shift 2 ;;
        --iso)      CUSTOM_ISO_URL="$2"; shift 2 ;;
        --image)    WINDOWS_IMAGE_NAME="$2"; shift 2 ;;
        *)          usage ;;
    esac
done

if [ -z "$WINDOWS_VERSION" ]; then usage; fi

# Set ISO and Image based on version if not custom
case "$WINDOWS_VERSION" in
    2016)
        [ -z "$CUSTOM_ISO_URL" ] && CUSTOM_ISO_URL="https://software-static.download.prss.microsoft.com/pr/page/pv/download/im/14393.0.160715-1616.RS1_RELEASE_SERVER_EVAL_X64FRE_ES-ES.ISO"
        [ -z "$WINDOWS_IMAGE_NAME" ] && WINDOWS_IMAGE_NAME="Windows Server 2016 SERVERDATACENTER"
        ;;
    2019)
        [ -z "$CUSTOM_ISO_URL" ] && CUSTOM_ISO_URL="https://software-static.download.prss.microsoft.com/download/pr/17763.737.190906-2324.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_es-es.iso"
        [ -z "$WINDOWS_IMAGE_NAME" ] && WINDOWS_IMAGE_NAME="Windows Server 2019 SERVERDATACENTER"
        ;;
    2022)
        [ -z "$CUSTOM_ISO_URL" ] && CUSTOM_ISO_URL="https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_es-es.iso"
        [ -z "$WINDOWS_IMAGE_NAME" ] && WINDOWS_IMAGE_NAME="Windows Server 2022 SERVERDATACENTER"
        ;;
    *)
        die "Unsupported Windows version: $WINDOWS_VERSION"
        ;;
esac

# Alpine assets definitions
ALPINE_BRANCH=v3.19
ALPINE_VER=3.19.1
ALPINE_ARCH=x86_64
ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine
ALPINE_KERNEL="$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ALPINE_ARCH/netboot/vmlinuz-virt"
ALPINE_INITRD="$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ALPINE_ARCH/netboot/initramfs-virt"
ALPINE_MODLOOP="$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ALPINE_ARCH/netboot/modloop-virt"

# ============================================================
# DETECT NETWORK INFORMATION
# ============================================================
get_net_info() {
    info "Gathering network settings"
    
    # Primary interface definition
    NET_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
    [ -z "$NET_IFACE" ] && die "Could not detect default network interface."

    # IP v4 and Mask CIDR
    local ip_cidr=$(ip -4 addr show dev "$NET_IFACE" | awk '/inet / {print $2; exit}')
    NET_IPV4=${ip_cidr%/*}
    NET_PREFIX=${ip_cidr#*/}

    # Gateway
    NET_GATEWAY=$(ip route show default | awk '/default/ {print $3; exit}')

    # DNS (read from resolv.conf, fallback to 8.8.8.8)
    NET_DNS=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)
    [ -z "$NET_DNS" ] && NET_DNS="8.8.8.8"

    # Static or DHCP detection based on system network managers
    NET_MODE="dhcp"
    if [ -f /etc/network/interfaces ] && grep -q "static" /etc/network/interfaces; then
        NET_MODE="static"
    elif command -v nmcli >/dev/null 2>&1 && nmcli -t -f IP4.ADDRESS dev show "$NET_IFACE" | grep -q "$NET_IPV4"; then
        # If network manager doesn't state explicit dhcp, treat as safe static fallback if requested
        if nmcli dev show "$NET_IFACE" | grep -i "dhcp" >/dev/null; then NET_MODE="dhcp"; else NET_MODE="static"; fi
    elif [ -d /etc/netplan ] && grep -q "dhcp4: no" /etc/netplan/*.yaml 2>/dev/null; then
        NET_MODE="static"
    fi

    # Safe forced-static evaluation (if no gateway detected via typical DHCP means)
    if [ -z "$NET_GATEWAY" ]; then
        die "Network gateway could not be found."
    fi
}

# ============================================================
# HELPER: DOWNLOAD
# ============================================================
curl_download() {
    local url="$1"
    local dest="$2"
    info "Downloading: $url -> $dest"
    curl -sSL -k --retry 5 --retry-delay 2 -o "$dest" "$url" || die "Failed to download $url"
}

# ============================================================
# WRITE CONFIG FILE FOR TRANS.SH
# ============================================================
write_config() {
    cat <<EOF > "$TMP/horus-config"
WINDOWS_VERSION="$WINDOWS_VERSION"
WINDOWS_IMAGE_NAME="$WINDOWS_IMAGE_NAME"
WIN_PASSWORD="$WIN_PASSWORD"
WIN_USERNAME="$WIN_USERNAME"
RDP_PORT="$RDP_PORT"
WINDOWS_ISO_URL="$CUSTOM_ISO_URL"
NET_MODE="$NET_MODE"
NET_IFACE="$NET_IFACE"
NET_IPV4="$NET_IPV4"
NET_PREFIX="$NET_PREFIX"
NET_GATEWAY="$NET_GATEWAY"
NET_DNS="$NET_DNS"
EOF
}

# ============================================================
# INJECT ARTIFACTS INTO ALPINE INITRD
# ============================================================
inject_into_initrd() {
    info "Preparing and packaging Alpine Linux custom initrd"
    
    local initrd_dir="$TMP/initrd-root"
    rm -rf "$initrd_dir" && mkdir -p "$initrd_dir"

    # 1. Structure basic Alpine Local.d Service
    mkdir -p "$initrd_dir/etc/local.d"
    mkdir -p "$initrd_dir$TMP"

    # Copy files inside the payload
    cp "$TMP/horus-config" "$initrd_dir$TMP/horus-config"
    cp "$TMP/trans.sh" "$initrd_dir$TMP/trans.sh"

    # 2. Write dynamic native Alpine network interfaces layout
    mkdir -p "$initrd_dir/etc/network"
    {
        echo "auto lo"
        echo "iface lo inet loopback"
        echo ""
        echo "auto eth0 ens3 ens4 ens18 enp0s3 enp0s4 enp0s18 enp1s0 $NET_IFACE"
        
        if [ "$NET_MODE" = "static" ]; then
            # We map the network setup statically for every potentially renamed interface interface
            for ifc in eth0 ens3 ens4 ens18 enp0s3 enp0s4 enp0s18 enp1s0 "$NET_IFACE"; do
                echo "iface $ifc inet static"
                echo "    address $NET_IPV4/$NET_PREFIX"
                echo "    gateway $NET_GATEWAY"
                echo "    hostname horusinstall"
            done
        else
            for ifc in eth0 ens3 ens4 ens18 enp0s3 enp0s4 enp0s18 enp1s0 "$NET_IFACE"; do
                echo "iface $ifc inet dhcp"
            done
        fi
    } > "$initrd_dir/etc/network/interfaces"

    # Write resolv.conf inside initrd to immediately unlock dns resolution
    echo "nameserver $NET_DNS" > "$initrd_dir/etc/resolv.conf"

    # 3. Create the execution wrapper
    cat <<EOF > "$initrd_dir/etc/local.d/trans.start"
#!/usr/bin/env sh
# Automated init script
# Bring up network natively via Alpine components
rc-service networking start || true

# Execute transplantation
sh $TMP/trans.sh
EOF
    chmod +x "$initrd_dir/etc/local.d/trans.start"

    # Enable local.d services on default runlevel inside initrd
    mkdir -p "$initrd_dir/etc/runlevels/default"
    ln -sf /etc/init.d/local "$initrd_dir/etc/runlevels/default/local"

    # Pack everything back appending into the original image
    cd "$initrd_dir"
    find . | cpio -o -H newc | gzip -9 >> "$TMP/alpine-initrd.img"
    cd "$TMP"
    rm -rf "$initrd_dir"
}

# ============================================================
# GRUB BOOT LOADER SETUP
# ============================================================
setup_grub() {
    info "Configuring GRUB for automated installation boot"
    
    local cmdline="alpine_repo=$ALPINE_MIRROR/$ALPINE_BRANCH/main modloop=/horusinstall-tmp/alpine-modloop alpine_commands=local:default horusinstall=1 console=tty0 console=ttyS0,1115200"
    
    # Find boot disk and match pathing
    local boot_dev
    boot_dev=$(df /boot | tail -1 | awk '{print $1}')
    
    mkdir -p /boot/horusinstall
    cp "$TMP/alpine-vmlinuz"    /boot/horusinstall/vmlinuz
    cp "$TMP/alpine-initrd.img" /boot/horusinstall/initrd.img
    cp "$TMP/alpine-modloop"    /boot/horusinstall/modloop

    # Add custom entry into grub customizer rules
    cat <<EOF > /etc/grub.d/40_custom
#!/bin/sh
exec tail -n +3 \$0
menuentry "HorusInstall (Automated System Reinstallation)" --class windows {
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    set root='$(grub-probe --target=compatibility_hint /boot/horusinstall/vmlinuz || echo "hd0,msdos1")'
    search --no-floppy --fs-uuid --set=root $(grub-probe --target=fs_uuid /boot/horusinstall/vmlinuz)
    linux /horusinstall/vmlinuz $cmdline
    initrd /horusinstall/initrd.img
}
EOF

    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        die "Could not find grub reconfig command utility."
    fi

    # Set default boot entry to our custom sequence
    sed -i 's/GRUB_DEFAULT=.*/GRUB_DEFAULT="HorusInstall (Automated System Reinstallation)"/' /etc/default/grub || true
    if command -v update-grub >/dev/null 2>&1; then update-grub; else grub2-mkconfig -o /boot/grub2/grub.cfg; fi
}

# ============================================================
# DETECT EFI/BIOS
# ============================================================
is_efi() {
    [ -d /sys/firmware/efi ]
}

# ============================================================
# MAIN INITIALIZATION EXECUTION
# ============================================================
main() {
    get_net_info

    echo "" >&2
    info "Target Configuration Details:"
    echo "  OS OS   : Windows Server $WINDOWS_VERSION" >&2
    echo "  Net Mode: $NET_MODE"                        >&2
    echo "  IP Addr : $NET_IPV4/$NET_PREFIX"            >&2
    echo "  Gateway : $NET_GATEWAY"                     >&2
    echo "  User    : $WIN_USERNAME"                  >&2
    echo "  RDP     : $RDP_PORT"                      >&2
    echo "  Boot    : $(is_efi && echo EFI || echo BIOS)" >&2
    echo "" >&2

    mkdir -p "$TMP"

    # Download Alpine boot files
    info "Downloading Alpine Linux boot files"
    curl_download "$ALPINE_KERNEL"  "$TMP/alpine-vmlinuz"
    curl_download "$ALPINE_INITRD"  "$TMP/alpine-initrd.img"
    curl_download "$ALPINE_MODLOOP" "$TMP/alpine-modloop"

    # Download trans.sh from repo
    info "Downloading trans.sh"
    curl_download "$CONFHOME/trans.sh" "$TMP/trans.sh"
    chmod +x "$TMP/trans.sh"

    # Write config then inject everything into the initrd
    write_config
    inject_into_initrd

    # Configure GRUB to boot Alpine on next restart
    setup_grub

    info "Setup complete — rebooting in 10 seconds"
    echo "" >&2
    echo "  Boot flow:" >&2
    echo "    1. GRUB boots Alpine from $TMP (RAM — no disk write yet)" >&2
    echo "    2. Alpine starts → /etc/local.d/trans.start runs automatically" >&2
    echo "    3. trans.sh downloads ISO, prepares disk, launches Windows installer" >&2
    echo "    4. Windows installer runs unattended via autounattend.xml" >&2
    echo "    5. First boot..."
    sleep 10
    reboot
}

main "$@"