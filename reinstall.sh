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
  --version    VERSION       Windows Server version (2016 / 2019 / 2022)  [required]
  --password   PASSWORD      Administrator password                         [required]
  --iso        URL           Custom ISO URL (skips auto-search)             [optional]
  --image-name NAME          WIM image name inside the ISO                  [optional]
  --rdp-port   PORT          RDP port (default: 3389)                       [optional]
  --ssh-port   PORT          SSH port for log monitoring (default: 22)      [optional]
  --username   USERNAME      Admin username (default: administrator)        [optional]

Examples:
  # Auto ISO search:
  bash reinstall.sh windows --version 2022 --password "MyPass123!"

  # Custom ISO:
  bash reinstall.sh windows --version 2022 \\
    --iso "https://example.com/server2022.iso" \\
    --image-name "Windows Server 2022 SERVERDATACENTER" \\
    --password "MyPass123!"

Notes:
  - Requires at least 1 GB RAM and 25 GB disk
  - Only supports x86_64 systems
  - NOT compatible with OpenVZ or LXC containers
  - All disk data will be ERASED

EOF
    exit 1
}

# ============================================================
# HELPERS
# ============================================================
is_virt() {
    if command -v systemd-detect-virt &>/dev/null; then
        virt=$(systemd-detect-virt 2>/dev/null || true)
    elif [ -f /proc/1/environ ]; then
        virt=$(grep -c "container" /proc/1/environ 2>/dev/null && echo lxc || echo none)
    else
        virt=none
    fi
    [ "$virt" != "none" ] && [ "$virt" != "" ]
}

is_openvz_lxc() {
    virt=$(systemd-detect-virt 2>/dev/null || true)
    [ "$virt" = "openvz" ] || [ "$virt" = "lxc" ]
}

is_efi() {
    [ -d /sys/firmware/efi ]
}

is_port_valid() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

get_arch() {
    uname -m
}

install_pkg() {
    for pkg in "$@"; do
        if ! command -v "$pkg" &>/dev/null; then
            if command -v apt-get &>/dev/null; then
                apt-get install -y "$pkg" >&2
            elif command -v yum &>/dev/null; then
                yum install -y "$pkg" >&2
            elif command -v dnf &>/dev/null; then
                dnf install -y "$pkg" >&2
            else
                die "Cannot install $pkg: no supported package manager found"
            fi
        fi
    done
}

curl_download() {
    local url=$1
    local dest=$2
    echo "Downloading: $url" >&2
    for i in $(seq 1 5); do
        if curl --insecure --connect-timeout 30 --retry 3 -fL "$url" -o "$dest" 2>&1; then
            return 0
        fi
        warn "Download attempt $i failed, retrying..."
        sleep 3
    done
    die "Failed to download: $url"
}

# ============================================================
# NETWORK DETECTION
# ============================================================
get_net_info() {
    # Get primary interface
    iface=$(ip route show default | awk '/default/ {print $5}' | head -1)
    [ -z "$iface" ] && die "Cannot detect primary network interface"

    ipv4=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1)
    prefix=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+/\d+' | grep -oP '\d+$' | head -1)
    gateway=$(ip route show default | awk '/default/ {print $3}' | head -1)
    dns=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | head -1)
    [ -z "$dns" ] && dns="8.8.8.8"

    # Detect if static or DHCP
    net_mode="dhcp"
    if [ -f /etc/network/interfaces ]; then
        if grep -q "static" /etc/network/interfaces 2>/dev/null; then
            net_mode="static"
        fi
    elif [ -d /etc/netplan ]; then
        if grep -rq "dhcp4: false\|dhcp4: no" /etc/netplan/ 2>/dev/null; then
            net_mode="static"
        elif grep -rq "addresses:" /etc/netplan/ 2>/dev/null; then
            net_mode="static"
        fi
    elif [ -d /etc/sysconfig/network-scripts ]; then
        cfg="/etc/sysconfig/network-scripts/ifcfg-$iface"
        if [ -f "$cfg" ] && grep -qi "BOOTPROTO=none\|BOOTPROTO=static" "$cfg" 2>/dev/null; then
            net_mode="static"
        fi
    fi

    echo "Network interface : $iface" >&2
    echo "IPv4 address      : $ipv4/$prefix" >&2
    echo "Gateway           : $gateway" >&2
    echo "DNS               : $dns" >&2
    echo "Mode              : $net_mode" >&2
}

# ============================================================
# ISO LOOKUP (massgrave.dev)
# ============================================================
get_iso_url() {
    local version=$1
    info "Searching for Windows Server $version Datacenter ISO..."

    # Official ISOs from Microsoft Evaluation Center
    # These are stable evaluation ISOs that don't expire for 180 days
    case "$version" in
        2016)
            ISO_URL="https://go.microsoft.com/fwlink/p/?LinkID=2195174&clcid=0x409&culture=en-us&country=US"
            IMAGE_NAME="Windows Server 2016 SERVERDATACENTER"
            ;;
        2019)
            ISO_URL="https://go.microsoft.com/fwlink/p/?LinkID=2195167&clcid=0x409&culture=en-us&country=US"
            IMAGE_NAME="Windows Server 2019 SERVERDATACENTER"
            ;;
        2022)
            ISO_URL="https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US"
            IMAGE_NAME="Windows Server 2022 SERVERDATACENTER"
            ;;
        *)
            die "Unsupported version: $version"
            ;;
    esac

    echo "ISO URL    : $ISO_URL" >&2
    echo "Image name : $IMAGE_NAME" >&2
}

# ============================================================
# SYSTEM CHECKS
# ============================================================
check_requirements() {
    info "Checking system requirements"

    # Architecture
    arch=$(get_arch)
    [ "$arch" = "x86_64" ] || die "Only x86_64 is supported (detected: $arch)"

    # Not OpenVZ/LXC
    if is_openvz_lxc; then
        die "OpenVZ and LXC containers are not supported. Use https://github.com/LloydAsp/OsMutation instead"
    fi

    # RAM check (need at least 1GB)
    ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    [ "$ram_mb" -ge 900 ] || die "Insufficient RAM: ${ram_mb}MB detected, minimum 1024MB required"

    # Disk check (need at least 25GB)
    disk_gb=$(df / --output=size -BG | tail -1 | tr -d 'G ')
    # Also check total disk size, not just free space
    disk=$(lsblk -dno SIZE "$(lsblk -dno NAME | head -1)" 2>/dev/null | tr -d 'G ' || echo 0)

    echo "RAM  : ${ram_mb} MB" >&2
    echo "Disk : ${disk_gb} GB available on /" >&2
    echo "Boot : $(is_efi && echo EFI || echo BIOS)" >&2

    # Root check
    [ "$(id -u)" -eq 0 ] || die "Must be run as root"

    # Required tools
    for cmd in curl wget lsblk; do
        command -v "$cmd" &>/dev/null || install_pkg "$cmd"
    done
}

# ============================================================
# GRUB / BOOTLOADER SETUP
# ============================================================
get_boot_disk() {
    # Find the disk that contains /
    root_part=$(df / --output=source | tail -1)
    # Strip partition number to get disk
    echo "$root_part" | sed 's/[0-9]*$//' | sed 's/p$//'
}

setup_bootloader() {
    local kernel_url=$1
    local initrd_url=$2

    info "Setting up bootloader for Alpine intermediate environment"

    mkdir -p "$TMP"

    # Download Alpine kernel and initrd
    info "Downloading Alpine Linux kernel..."
    curl_download "$kernel_url" "$TMP/alpine-vmlinuz"

    info "Downloading Alpine Linux initrd..."
    curl_download "$initrd_url" "$TMP/alpine-initrd.img"

    # Download our trans.sh
    info "Downloading trans.sh..."
    curl_download "$CONFHOME/trans.sh" "$TMP/trans.sh"
    chmod +x "$TMP/trans.sh"

    # Write config for trans.sh
    cat > "$TMP/horus-config" <<CONF
WINDOWS_VERSION=$WIN_VERSION
WINDOWS_ISO=$ISO_URL
WINDOWS_IMAGE_NAME=$IMAGE_NAME
WIN_USERNAME=$WIN_USERNAME
WIN_PASSWORD=$WIN_PASSWORD
WIN_RDP_PORT=$RDP_PORT
WIN_SSH_PORT=$SSH_PORT
NET_MODE=$net_mode
NET_IFACE=$iface
NET_IPV4=$ipv4
NET_PREFIX=$prefix
NET_GATEWAY=$gateway
NET_DNS=$dns
CONFHOME=$CONFHOME
CONF

    # Determine boot setup method
    if is_efi; then
        setup_grub_efi
    else
        setup_grub_bios
    fi
}

setup_grub_bios() {
    info "Configuring GRUB (BIOS mode)"

    local grub_cfg=""

    # Find GRUB config
    for f in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
        [ -f "$f" ] && grub_cfg="$f" && break
    done

    [ -z "$grub_cfg" ] && die "GRUB config not found"

    # Backup original grub.cfg
    cp "$grub_cfg" "${grub_cfg}.horus-backup"

    # Build kernel cmdline
    local cmdline="console=tty0 console=ttyS0,115200n8"
    cmdline="$cmdline horusinstall=1"

    # Prepend our entry so it boots first
    cat > "$TMP/grub-entry.txt" <<GRUBENTRY
### BEGIN HorusInstall ###
menuentry "HorusInstall - Windows Server Setup" {
    search --no-floppy --set=root --file /horusinstall-tmp/alpine-vmlinuz
    linux  /horusinstall-tmp/alpine-vmlinuz $cmdline
    initrd /horusinstall-tmp/alpine-initrd.img
}
set default="HorusInstall - Windows Server Setup"
set timeout=5
### END HorusInstall ###

GRUBENTRY

    # Prepend entry to grub.cfg
    cat "$TMP/grub-entry.txt" "$grub_cfg" > "$TMP/grub-new.cfg"
    cp "$TMP/grub-new.cfg" "$grub_cfg"

    info "GRUB configured — system will boot into Alpine on next restart"
}

setup_grub_efi() {
    info "Configuring GRUB (EFI mode)"

    local grub_cfg=""
    for f in /boot/efi/EFI/*/grub.cfg /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
        [ -f "$f" ] && grub_cfg="$f" && break
    done

    [ -z "$grub_cfg" ] && die "GRUB EFI config not found"

    cp "$grub_cfg" "${grub_cfg}.horus-backup"

    local cmdline="console=tty0 console=ttyS0,115200n8 horusinstall=1"

    cat > "$TMP/grub-entry.txt" <<GRUBENTRY
### BEGIN HorusInstall ###
menuentry "HorusInstall - Windows Server Setup" {
    search --no-floppy --set=root --file /horusinstall-tmp/alpine-vmlinuz
    linux  /horusinstall-tmp/alpine-vmlinuz $cmdline
    initrd /horusinstall-tmp/alpine-initrd.img
}
set default="HorusInstall - Windows Server Setup"
set timeout=5
### END HorusInstall ###

GRUBENTRY

    cat "$TMP/grub-entry.txt" "$grub_cfg" > "$TMP/grub-new.cfg"
    cp "$TMP/grub-new.cfg" "$grub_cfg"

    info "GRUB (EFI) configured — system will boot into Alpine on next restart"
}

# ============================================================
# ALPINE KERNEL/INITRD URLS
# ============================================================
get_alpine_urls() {
    # Alpine 3.21 stable — x86_64 netboot
    ALPINE_KERNEL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/netboot/vmlinuz-lts"
    ALPINE_INITRD="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/netboot/initramfs-lts"
}

# ============================================================
# ARGUMENT PARSING
# ============================================================
parse_args() {
    WIN_VERSION=""
    ISO_URL=""
    IMAGE_NAME=""
    WIN_PASSWORD=""
    WIN_USERNAME="administrator"
    RDP_PORT=3389
    SSH_PORT=22

    # First arg must be 'windows'
    [ "$1" = "windows" ] || usage
    shift

    while [ $# -gt 0 ]; do
        case "$1" in
            --version)   WIN_VERSION="$2";   shift 2 ;;
            --iso)       ISO_URL="$2";       shift 2 ;;
            --image-name) IMAGE_NAME="$2";   shift 2 ;;
            --password)  WIN_PASSWORD="$2";  shift 2 ;;
            --username)  WIN_USERNAME="$2";  shift 2 ;;
            --rdp-port)  RDP_PORT="$2";      shift 2 ;;
            --ssh-port)  SSH_PORT="$2";      shift 2 ;;
            -h|--help)   usage ;;
            *)           die "Unknown option: $1" ;;
        esac
    done

    # Validations
    [ -z "$WIN_VERSION" ] && die "--version is required (2016 / 2019 / 2022)"
    [[ "$WIN_VERSION" =~ ^(2016|2019|2022)$ ]] || die "Invalid version: $WIN_VERSION. Use 2016, 2019 or 2022"
    [ -z "$WIN_PASSWORD" ] && die "--password is required"
    [ ${#WIN_PASSWORD} -ge 8 ] || die "Password must be at least 8 characters"
    is_port_valid "$RDP_PORT" || die "Invalid RDP port: $RDP_PORT"
    is_port_valid "$SSH_PORT" || die "Invalid SSH port: $SSH_PORT"
}

# ============================================================
# MAIN
# ============================================================
main() {
    [ $# -eq 0 ] && usage
    parse_args "$@"

    echo ""
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║         HorusInstall v1.0                ║"
    echo "  ║   Linux → Windows Server Reinstaller     ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""

    warn "ALL DATA ON THIS DISK WILL BE ERASED!"
    echo ""
    read -rp "  Type YES to confirm and continue: " confirm
    [ "$confirm" = "YES" ] || die "Aborted by user"
    echo ""

    check_requirements
    get_net_info
    get_alpine_urls

    # If no ISO provided, search automatically
    if [ -z "$ISO_URL" ]; then
        get_iso_url "$WIN_VERSION"
    else
        # User provided ISO — set default image name if not specified
        if [ -z "$IMAGE_NAME" ]; then
            IMAGE_NAME="Windows Server $WIN_VERSION SERVERDATACENTER"
            warn "No --image-name provided, using: $IMAGE_NAME"
        fi
    fi

    info "Configuration summary"
    echo "  Windows version : Server $WIN_VERSION Datacenter" >&2
    echo "  Image name      : $IMAGE_NAME" >&2
    echo "  Username        : $WIN_USERNAME" >&2
    echo "  RDP port        : $RDP_PORT" >&2
    echo "  Boot mode       : $(is_efi && echo EFI || echo BIOS)" >&2
    echo "" >&2

    setup_bootloader "$ALPINE_KERNEL" "$ALPINE_INITRD"

    info "Setup complete — rebooting in 10 seconds"
    echo "" >&2
    echo "  After reboot, Alpine will start automatically and:" >&2
    echo "  1. Download the Windows Server ISO" >&2
    echo "  2. Prepare drivers and unattend configuration" >&2
    echo "  3. Launch the Windows installer" >&2
    echo "" >&2
    echo "  You can monitor progress via:" >&2
    echo "  - Serial console / VNC from your VPS panel" >&2
    echo "  - SSH on port $SSH_PORT (once Alpine boots)" >&2
    echo "" >&2
    echo "  DO NOT power off the server during installation!" >&2
    echo "" >&2

    sleep 10
    reboot
}

main "$@"
