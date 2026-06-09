#!/usr/bin/env bash
# HorusInstall - Linux to Windows Server installer
# https://github.com/HorusHDx/HorusInstall
# Fixed for Contabo Network Infrastructure

set -eE

CONFHOME=https://raw.githubusercontent.com/HorusHDx/HorusInstall/main
TMP=/horusinstall-tmp
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

info()  { echo -e "\e[32m***** $(echo "$*" | tr '[:lower:]' '[:upper:]') *****\e[0m" >&2; }
warn()  { echo -e "\e[33mWarning: $*\e[0m" >&2; }
error() { echo -e "\e[31m***** ERROR *****\e[0m" >&2; echo -e "\e[31m$*\e[0m" >&2; }
die()   { error "$@"; exit 1; }

trap 'error "Line $LINENO exited with code $?"' ERR

usage() {
cat <<EOF
HorusInstall - Reinstall Linux VPS to Windows Server
Usage:
  bash reinstall.sh windows --version VERSION [OPTIONS]

Options:
  --password PASSWORD   Administrator password (default: HorusInstall123!)
  --username USERNAME   Administrator username (default: Administrator)
  --port PORT           RDP Port (default: 3389)
  --iso URL             Custom Windows ISO URL
  --image NAME          Specific WIM Image name
EOF
exit 1
}

if [ "$1" != "windows" ]; then usage; fi
shift

WIN_PASSWORD="HorusInstall123!"
WIN_USERNAME="Administrator"
RDP_PORT="3389"
CUSTOM_ISO_URL=""
WINDOWS_IMAGE_NAME=""

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
    *) die "Unsupported Windows version: $WINDOWS_VERSION" ;;
esac

ALPINE_BRANCH=v3.19
ALPINE_VER=3.19.1
ALPINE_ARCH=x86_64
ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine
ALPINE_KERNEL="$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ALPINE_ARCH/netboot/vmlinuz-virt"
ALPINE_INITRD="$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ALPINE_ARCH/netboot/initramfs-virt"
ALPINE_MODLOOP="$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ALPINE_ARCH/netboot/modloop-virt"

get_net_info() {
    info "Gathering network settings"
    
    # Detectar interfaz activa principal
    NET_IFACE=$(ip route show | awk '/default/ {print $5; exit}')
    [ -z "$NET_IFACE" ] && NET_IFACE=$(ip -4 route show | awk '{print $5; exit}')
    [ -z "$NET_IFACE" ] && die "Could not detect active network interface."

    # Detectar IP y Prefijo CIDR
    local ip_cidr=$(ip -4 addr show dev "$NET_IFACE" | awk '/inet / {print $2; exit}')
    [ -z "$ip_cidr" ] && die "Could not detect local IP address."
    NET_IPV4=${ip_cidr%/*}
    NET_PREFIX=${ip_cidr#*/}

    # FIX CONTABO: Extracción robusta de Gateway
    NET_GATEWAY=$(ip route show default dev "$NET_IFACE" | awk '/via/ {print $3; exit}')
    [ -z "$NET_GATEWAY" ] && NET_GATEWAY=$(ip route show | awk '/default/ {print $3; exit}')
    [ -z "$NET_GATEWAY" ] && NET_GATEWAY=$(ip route | grep "$NET_IFACE" | awk '/scope link/ {print $1}' | head -n 1)
    
    # Si todo lo anterior falla, buscar la IP del host de la ruta
    [ -z "$NET_GATEWAY" ] && NET_GATEWAY=$(ip route show proto kernel | awk '{print $1}' | cut -d '/' -f1 | sed 's/\.[0-9]*$/\.1/')
    [ -z "$NET_GATEWAY" ] && die "Network gateway could not be found."

    # Detectar DNS externo
    NET_DNS=$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)
    [ -z "$NET_DNS" ] || echo "$NET_DNS" | grep -qE "127.0.0" && NET_DNS="8.8.8.8"

    NET_MODE="dhcp"
    if [ -f /etc/network/interfaces ] && grep -q "static" /etc/network/interfaces; then
        NET_MODE="static"
    elif command -v nmcli >/dev/null 2>&1 && nmcli -t -f IP4.ADDRESS dev show "$NET_IFACE" | grep -q "$NET_IPV4"; then
        if nmcli dev show "$NET_IFACE" | grep -i "dhcp" >/dev/null; then NET_MODE="dhcp"; else NET_MODE="static"; fi
    elif [ -d /etc/netplan ] && grep -q "dhcp4: no" /etc/netplan/*.yaml 2>/dev/null; then
        NET_MODE="static"
    fi
}

curl_download() {
    curl -sSL -k --retry 5 --retry-delay 2 -o "$2" "$1" || die "Failed to download $1"
}

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

inject_into_initrd() {
    info "Preparing Alpine custom initrd"
    local initrd_dir="$TMP/initrd-root"
    rm -rf "$initrd_dir" && mkdir -p "$initrd_dir"

    mkdir -p "$initrd_dir/etc/local.d" "$initrd_dir$TMP" "$initrd_dir/etc/network"
    cp "$TMP/horus-config" "$initrd_dir$TMP/horus-config"
    cp "$TMP/trans.sh" "$initrd_dir$TMP/trans.sh"

    {
        echo "auto lo"
        echo "iface lo inet loopback"
        echo ""
        echo "auto eth0 ens3 ens4 ens18 enp0s3 enp0s4 enp0s18 enp1s0 $NET_IFACE"
        if [ "$NET_MODE" = "static" ]; then
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

    echo "nameserver $NET_DNS" > "$initrd_dir/etc/resolv.conf"

    cat <<EOF > "$initrd_dir/etc/local.d/trans.start"
#!/usr/bin/env sh
rc-service networking start || true
sh $TMP/trans.sh
EOF
    chmod +x "$initrd_dir/etc/local.d/trans.start"
    mkdir -p "$initrd_dir/etc/runlevels/default"
    ln -sf /etc/init.d/local "$initrd_dir/etc/runlevels/default/local"

    cd "$initrd_dir" && find . | cpio -o -H newc | gzip -9 >> "$TMP/alpine-initrd.img"
    cd "$TMP" && rm -rf "$initrd_dir"
}

setup_grub() {
    info "Configuring GRUB"
    local cmdline="alpine_repo=$ALPINE_MIRROR/$ALPINE_BRANCH/main modloop=/horusinstall-tmp/alpine-modloop alpine_commands=local:default horusinstall=1 console=tty0 console=ttyS0,1115200"
    
    mkdir -p /boot/horusinstall
    cp "$TMP/alpine-vmlinuz"    /boot/horusinstall/vmlinuz
    cp "$TMP/alpine-initrd.img" /boot/horusinstall/initrd.img
    cp "$TMP/alpine-modloop"    /boot/horusinstall/modloop

    cat <<EOF > /etc/grub.d/40_custom
#!/bin/sh
exec tail -n +3 \$0
menuentry "HorusInstall (Automated System Reinstallation)" --class windows {
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    set root='$(grub-probe --target=compatibility_hint /boot/horusinstall/vmlinuz || echo "hd0,msdos1")'
    search --no-floppy --fs-uuid --set=root $(grub-probe --target=fs_uuid /boot/horusinstall/vmlinuz)
    linux /boot/horusinstall/vmlinuz $cmdline
    initrd /boot/horusinstall/initrd.img
}
EOF

    if command -v update-grub >/dev/null 2>&1; then update-grub; else grub2-mkconfig -o /boot/grub2/grub.cfg; fi
    sed -i 's/GRUB_DEFAULT=.*/GRUB_DEFAULT="HorusInstall (Automated System Reinstallation)"/' /etc/default/grub || true
    if command -v update-grub >/dev/null 2>&1; then update-grub; else grub2-mkconfig -o /boot/grub2/grub.cfg; fi
}

main() {
    get_net_info
    mkdir -p "$TMP"
    info "Downloading Alpine elements"
    curl_download "$ALPINE_KERNEL"  "$TMP/alpine-vmlinuz"
    curl_download "$ALPINE_INITRD"  "$TMP/alpine-initrd.img"
    curl_download "$ALPINE_MODLOOP" "$TMP/alpine-modloop"
    curl_download "$CONFHOME/trans.sh" "$TMP/trans.sh"
    chmod +x "$TMP/trans.sh"
    write_config
    inject_into_initrd
    setup_grub
    info "Setup complete — rebooting in 10s"
    sleep 10
    reboot
}

main "$@"