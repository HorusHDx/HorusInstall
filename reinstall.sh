#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2086
# =============================================================================
# reinstall.sh
# HorusInstall - Linux to Windows reinstall tool
# Based on: github.com/bin456789/reinstall (GPL-3.0)
# Modified by: HorusHDx
# Repository: https://github.com/HorusHDx/HorusInstall
#
# Purpose: One-command reinstall from any Linux distribution to Windows.
#          Downloads the official Windows ISO, injects drivers automatically,
#          configures the bootloader (GRUB/syslinux) to boot into WinPE,
#          and launches the unattended Windows installer.
#
# Usage:
#   bash reinstall.sh windows \
#       --image-name "Windows 11 Enterprise LTSC 2024" \
#       --lang en-us \
#       [--password PASSWORD] \
#       [--ssh-port PORT] \
#       [--rdp-port PORT] \
#       [--allow-ping] \
#       [--add-driver /path/to/driver.inf]
#
#   bash reinstall.sh windows \
#       --image-name "Windows Server 2025 SERVERDATACENTER" \
#       --iso "https://example.com/server2025.iso"
#
# Requirements (source Linux system):
#   - Root privileges
#   - curl or wget
#   - bash 4+
#   - x86_64 or aarch64 architecture
#   - Minimum 1 GB RAM, 25 GB disk
#   - KVM, XEN, VMware, Hyper-V, bare metal (NOT OpenVZ or LXC)
# =============================================================================

set -eE

# =============================================================================
# Configuration — point to your own fork if you have modified support files
# =============================================================================
confhome=https://raw.githubusercontent.com/HorusHDx/HorusInstall/main

# Temporary working directory (avoid /tmp — may be a RAM disk with limited space)
tmp=/reinstall-tmp

# Force English output from all Linux commands (prevents grep failures)
export LC_ALL=C

# Ensure sbin directories are in PATH (handles 'su' without login shell)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# Script version — must match trans.sh if used
SCRIPT_VERSION=HORUS-2026-LTW-001

BOOT_ENTRY_START_MARK='### BEGIN HorusInstall ###'
BOOT_ENTRY_END_MARK='### END HorusInstall ###'

THIS_SCRIPT=$(readlink -f "$0")
trap 'trap_err $LINENO $?' ERR

# =============================================================================
# Logging helpers
# =============================================================================
trap_err() {
    local line_no=$1
    local ret_no=$2
    error "Line $line_no returned exit code $ret_no"
    sed -n "${line_no}p" "$THIS_SCRIPT"
}

info() {
    local msg
    if [ "$1" = false ]; then shift; msg="$*"
    else msg="***** $(echo "$*" | tr '[:lower:]' '[:upper:]') *****"; fi
    echo_color '\e[32m' "$msg" >&2
}

warn() {
    local msg
    if [ "$1" = false ]; then shift; msg="$*"
    else msg="Warning: $*"; fi
    echo_color '\e[33m' "$msg" >&2
}

error() {
    echo_color '\e[31m' "***** ERROR *****" >&2
    echo_color '\e[31m' "$*" >&2
}

echo_color() {
    local color="$1"; shift
    echo -e "${color}$*\e[0m"
}

error_and_exit() { error "$@"; exit 1; }

# =============================================================================
# Usage
# =============================================================================
usage_and_exit() {
    cat <<EOF

HorusInstall — Linux to Windows reinstaller
============================================

Usage:
  bash reinstall.sh windows \\
      --image-name "Windows 11 Pro" \\
      --lang en-us

  bash reinstall.sh windows \\
      --image-name "Windows Server 2025 SERVERDATACENTER" \\
      --iso "https://example.com/server2025.iso"

  bash reinstall.sh reset    (cancel before reboot)

Options:
  --image-name  NAME    Windows edition to install (required)
  --lang        LOCALE  Language code, e.g. en-us, es-es, pt-br (default: en-us)
  --iso         URL     Direct ISO URL or magnet link (optional)
  --password    PASS    Administrator password (prompted if omitted)
  --ssh-port    PORT    SSH port for log monitoring during install (default: 22)
  --rdp-port    PORT    RDP port after installation (default: 3389)
  --web-port    PORT    Web log viewer port (default: 80)
  --allow-ping          Open ICMP firewall rule after installation
  --add-driver  PATH    Add extra driver (.inf or directory); repeatable

Common image names:
  "Windows 11 Pro"
  "Windows 11 Enterprise LTSC 2024"
  "Windows 10 Enterprise LTSC 2021"
  "Windows Server 2025 SERVERDATACENTER"
  "Windows Server 2022 SERVERSTANDARDCORE"

Supported languages:
  en-us  en-gb  es-es  es-mx  pt-br  pt-pt  fr-fr  fr-ca
  de-de  it-it  ja-jp  ko-kr  zh-cn  zh-tw  zh-hk  ru-ru
  ar-sa  nl-nl  pl-pl  sv-se  tr-tr  uk-ua  (and more)

More info: https://github.com/HorusHDx/HorusInstall

EOF
    exit 1
}

# =============================================================================
# Utility functions
# =============================================================================

is_digit() { [[ "$1" =~ ^[0-9]+$ ]]; }

is_port_valid() {
    is_digit "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

to_lower() { tr '[:upper:]' '[:lower:]'; }
to_upper() { tr '[:lower:]' '[:upper:]'; }

get_host_by_url()            { cut -d/ -f3 <<<"$1"; }
get_scheme_and_host_by_url() { cut -d/ -f1-3 <<<"$1"; }

is_absolute_path() { [[ "$1" = /* ]]; }

# Detect if running inside a container (OpenVZ, LXC) — not supported
is_in_container() {
    { command -v systemd-detect-virt &>/dev/null && systemd-detect-virt -qc; } ||
        [ -d /proc/vz ] ||
        { [ -f /proc/1/environ ] && grep -q container=lxc /proc/1/environ; }
}

is_efi() {
    [ -d /sys/firmware/efi ]
}

is_boot_in_separate_partition() {
    mount | grep -q ' on /boot type '
}

is_os_in_btrfs() {
    mount | grep -q ' on / type btrfs '
}

get_os_part() {
    awk '($2 == "/") { print $1 }' /proc/mounts
}

# Convert subnet mask to CIDR prefix length
mask2cidr() {
    local x=${1##*255.}
    set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x}) * 2 )) ${x%%.*}
    x=${1%%"$3"*}
    echo $(( $2 + (${#x} / 4) ))
}

# Unmount all bind-mounts under a path
umount_all() {
    local mount_lists
    if mount_lists=$(mount | grep -w "on $1" | awk '{print $3}' | grep .); then
        if umount --help 2>&1 | grep -wq -- '-R'; then
            umount -R "$1"
        else
            echo "$mount_lists" | tac | xargs -n1 umount
        fi
    fi
}

# Install a package using the distro's package manager
install_pkg() {
    if command -v apt-get &>/dev/null; then
        apt-get install -y "$@"
    elif command -v dnf &>/dev/null; then
        dnf install -y "$@"
    elif command -v yum &>/dev/null; then
        yum install -y "$@"
    elif command -v apk &>/dev/null; then
        apk add "$@"
    elif command -v zypper &>/dev/null; then
        zypper install -y "$@"
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm "$@"
    else
        error_and_exit "Cannot install packages: no supported package manager found."
    fi
}

is_have_cmd() { command -v "$1" &>/dev/null; }

# curl wrapper with retry and fail-on-error
curl_download() {
    is_have_cmd curl || install_pkg curl
    for i in $(seq 5); do
        if command curl --connect-timeout 10 -fL "$@"; then
            return 0
        else
            local ret=$?
            [ $ret -eq 22 ] && return $ret   # 403/404 — don't retry
            [ $i -eq 5 ]    && return $ret
            sleep 2
        fi
    done
}

# =============================================================================
# Platform / architecture detection
# =============================================================================

detect_basearch() {
    basearch=$(uname -m)
    case "$basearch" in
        x86_64)  basearch_alt=amd64 ;;
        aarch64) basearch_alt=arm64 ;;
        *)
            error_and_exit "Unsupported architecture: $basearch. Only x86_64 and aarch64 are supported."
            ;;
    esac
    echo "Architecture: $basearch ($basearch_alt)"
}

# Detect if running inside a VM (used to select kernel flavour, driver sets, etc.)
detect_virt() {
    if [ -n "$_is_virt" ]; then $_is_virt; return; fi

    if command -v systemd-detect-virt &>/dev/null && systemd-detect-virt -v 2>/dev/null; then
        _is_virt=true
    fi

    if [ -z "$_is_virt" ]; then
        install_pkg dmidecode virt-what 2>/dev/null || true
        if command -v virt-what &>/dev/null && [ -n "$(virt-what 2>/dev/null)" ]; then
            _is_virt=true
        fi
    fi

    [ -z "$_is_virt" ] && _is_virt=false
    echo "VM detected: $_is_virt"
    $_is_virt
}

# =============================================================================
# Windows ISO auto-discovery (via massgrave.dev)
# =============================================================================

# Map lang code to English name used in VLSC ISO filenames
lang_to_english() {
    case "$lang" in
    ar-sa) echo Arabic ;;       bg-bg) echo Bulgarian ;;
    cs-cz) echo Czech ;;        da-dk) echo Danish ;;
    de-de) echo German ;;       el-gr) echo Greek ;;
    en-gb) echo Eng_Intl ;;     en-us) echo English ;;
    es-es) echo Spanish ;;      es-mx) echo Spanish_Latam ;;
    et-ee) echo Estonian ;;     fi-fi) echo Finnish ;;
    fr-ca) echo FrenchCanadian ;; fr-fr) echo French ;;
    he-il) echo Hebrew ;;       hr-hr) echo Croatian ;;
    hu-hu) echo Hungarian ;;    it-it) echo Italian ;;
    ja-jp) echo Japanese ;;     ko-kr) echo Korean ;;
    lt-lt) echo Lithuanian ;;   lv-lv) echo Latvian ;;
    nb-no) echo Norwegian ;;    nl-nl) echo Dutch ;;
    pl-pl) echo Polish ;;       pt-pt) echo Portuguese ;;
    pt-br) echo Brazilian ;;    ro-ro) echo Romanian ;;
    ru-ru) echo Russian ;;      sk-sk) echo Slovak ;;
    sl-si) echo Slovenian ;;    sv-se) echo Swedish ;;
    th-th) echo Thai ;;         tr-tr) echo Turkish ;;
    uk-ua) echo Ukrainian ;;    zh-cn) echo ChnSimp ;;
    zh-hk|zh-tw) echo ChnTrad ;;
    sr-latn|sr-latn-rs) echo Serbian_Latin ;;
    esac
}

# Build fallback language list for ISO search
get_lang_fallbacks() {
    local base="${lang%%-*}"
    local region="${lang##*-}"
    echo "$lang"
    echo "${base}-${base}"   # e.g. fr-fr
    echo "$base"
    [ "$lang" = zh-hk ] && echo zh-tw
    [ "$lang" = en-gb ] && echo en-us
}

is_ltsc() { echo "$image_name" | grep -Eiwq 'ltsb|ltsc'; }

find_windows_iso() {
    info "Searching for Windows ISO"

    local version edition server arch_win
    local image_lower
    image_lower=$(echo "$image_name" | tr '[:upper:]' '[:lower:]')

    # Detect server vs desktop
    echo "$image_lower" | grep -q 'server' && server=server || server=

    # Architecture string for ISO filenames
    case "$basearch" in
        x86_64)  arch_win=x64  ;;
        aarch64) arch_win=arm64 ;;
    esac

    # Select massgrave.dev page
    local page_url
    if [ -n "$server" ]; then
        page_url=https://massgrave.dev/windows-server-links
    elif echo "$image_lower" | grep -q 'windows 11'; then
        page_url=https://massgrave.dev/windows_11_links
    elif echo "$image_lower" | grep -q 'windows 10'; then
        page_url=https://massgrave.dev/windows_10_links
    else
        page_url=https://massgrave.dev/windows_11_links
    fi

    echo "ISO source list: $page_url"

    local full_lang
    full_lang=$(lang_to_english)

    local http_base
    http_base=$(get_scheme_and_host_by_url "$page_url")
    local http_dir
    http_dir=$(dirname "$page_url")

    # Download and parse the page for ISO links
    curl_download -s "$page_url" \
        | tr -d '\n' \
        | sed -e 's,<a ,\n<a ,g' -e 's,</a>,</a>\n,g' \
        | grep -Ei '\.(iso|img)</a>$' \
        | sed -E \
            -e 's,<a href="?([^" ]+)"?.+>(.+)</a>,\2 \1,' \
            -e "s, (/), $http_base\1," \
        | awk '{if ($2 !~ /^https?:\/\//) $2 = "'"$http_dir/"'" $2; print}' \
        > "$tmp/win.list" 2>/dev/null || true

    # Remove or keep LTSC entries based on the requested edition
    if is_ltsc; then
        sed -Ei '/ltsc|ltsb/!d' "$tmp/win.list"
    else
        sed -Ei '/ltsc|ltsb/d' "$tmp/win.list"
    fi

    # Try to match by language and architecture
    local found=false
    for try_lang in $(get_lang_fallbacks); do
        local pattern
        pattern="${try_lang}_windows.*${arch_win}.*\.(iso|img)"
        pattern="${pattern// /_}"

        echo "Trying pattern: $pattern" >&2
        local line
        if line=$(grep -Ei "^$pattern " "$tmp/win.list" | head -1) && [ -n "$line" ]; then
            iso=$(awk '{print $2}' <<<"$line")
            echo "Found ISO: $iso"
            found=true
            break
        fi
    done

    if ! $found; then
        error_and_exit "Could not find ISO for: $image_name ($lang / $arch_win)
Try setting --iso manually with a direct URL from:
  https://massgrave.dev/genuine-installation-media
  https://msdl.gravesoft.dev"
    fi
}

# =============================================================================
# Network configuration collection
# =============================================================================

collect_net_conf() {
    info "Collecting network configuration"

    # Source the dedicated network helper
    # shellcheck source=initrd-network.sh
    source "$(dirname "$THIS_SCRIPT")/initrd-network.sh" 2>/dev/null \
        || { warn "initrd-network.sh not found locally, downloading..."; \
             curl_download -o "$tmp/initrd-network.sh" "$confhome/initrd-network.sh"; \
             source "$tmp/initrd-network.sh"; }

    collect_network_info
}

# =============================================================================
# Encode password for unattend.xml (Windows expects Base64 of "pass\nAdministratorPassword")
# =============================================================================
encode_password() {
    local pass="$1"
    local suffix="$2"   # e.g. "AdministratorPassword" or "Password"
    echo -n "${pass}${suffix}" | iconv -t UTF-16LE | base64 -w 0
}

# =============================================================================
# Prompt for password if not set
# =============================================================================
prompt_password() {
    if [ -n "$password" ]; then return; fi

    while true; do
        read -rsp "Enter Windows administrator password: " password
        echo
        read -rsp "Confirm password: " password2
        echo
        if [ "$password" = "$password2" ]; then
            break
        fi
        echo "Passwords do not match. Try again."
    done
}

# =============================================================================
# Build the unattend XML by replacing placeholders in windows.xml
# =============================================================================
build_unattend_xml() {
    info "Building unattend.xml"

    local xml_src="$tmp/windows.xml"

    # Download windows.xml template
    curl_download -o "$xml_src" "$confhome/windows.xml"

    # Determine architecture string for the XML
    local arch_xml
    case "$basearch" in
        x86_64)  arch_xml=amd64 ;;
        aarch64) arch_xml=arm64 ;;
    esac

    # Encode passwords (Windows unattend uses UTF-16LE Base64)
    local admin_pass_enc user_pass_enc
    admin_pass_enc=$(encode_password "$password" "AdministratorPassword")
    user_pass_enc=$(encode_password "$password" "Password")

    # Determine RDP firewall rule state
    local use_default_rdp=true
    [ "${rdp_port:-3389}" != "3389" ] && use_default_rdp=false

    # Enable administrator account when username is "administrator"
    local enable_admin=0
    echo "$username" | grep -qi '^administrator$' && enable_admin=1

    # Replace all placeholders
    sed \
        -e "s|%arch%|${arch_xml}|g" \
        -e "s|%key%||g" \
        -e "s|%image_name%|${image_name}|g" \
        -e "s|%disk_id%|0|g" \
        -e "s|%installto_partitionid%|3|g" \
        -e "s|%locale%|${lang:-en-us}|g" \
        -e "s|%enable_administrator%|${enable_admin}|g" \
        -e "s|%use_default_rdp_port%|${use_default_rdp}|g" \
        -e "s|%administrator_password%|${admin_pass_enc}|g" \
        -e "s|%user_username%|${username:-administrator}|g" \
        -e "s|%user_password%|${user_pass_enc}|g" \
        "$xml_src" > "$tmp/windows_final.xml"

    echo "Unattend XML ready: $tmp/windows_final.xml"
}

# =============================================================================
# Build windows-set-netconf.bat by injecting network variables
# =============================================================================
build_netconf_bat() {
    info "Building windows-set-netconf.bat"

    local bat_src="$tmp/windows-set-netconf.bat"
    curl_download -o "$bat_src" "$confhome/windows-set-netconf.bat"

    # Get MAC address of the primary NIC
    local mac_addr
    mac_addr=$(ip link show "${NET_IPV4_IFACE:-$(ip route | awk '/default/{print $5;exit}')}" \
        | awk '/ether/{print $2}' | head -1 | tr ':' ':' | tr '[:lower:]' '[:upper:]')

    # Inject variables at the top of the .bat file
    local inject=""
    [ -n "$mac_addr" ]       && inject+="set mac_addr=${mac_addr}\r\n"
    [ -n "$NET_IPV4_ADDR" ]  && inject+="set ipv4_addr=${NET_IPV4_ADDR}/${NET_IPV4_PREFIX}\r\n"
    [ -n "$NET_IPV4_GW" ]    && inject+="set ipv4_gateway=${NET_IPV4_GW}\r\n"
    [ -n "$NET_IPV6_ADDR" ]  && inject+="set ipv6_addr=${NET_IPV6_ADDR}/${NET_IPV6_PREFIX}\r\n"
    [ -n "$NET_IPV6_GW" ]    && inject+="set ipv6_gateway=${NET_IPV6_GW}\r\n"

    # DNS servers
    local dns_count=0
    for ns in $NET_DNS; do
        dns_count=$(( dns_count + 1 ))
        if echo "$ns" | grep -q ':'; then
            inject+="set ipv6_dns${dns_count}=${ns}\r\n"
        else
            inject+="set ipv4_dns${dns_count}=${ns}\r\n"
        fi
        [ $dns_count -ge 2 ] && break
    done

    # RDP port
    [ "${rdp_port:-3389}" != "3389" ] && inject+="set rdp_port=${rdp_port}\r\n"

    # Allow ping
    [ "$allow_ping" = 1 ] && inject+="set allow_ping=1\r\n"

    # Prepend variables to .bat file
    printf "%b\n" "$inject" | cat - "$bat_src" > "$tmp/windows-set-netconf-final.bat"

    echo "Network config bat ready."
}

# =============================================================================
# Download drivers
# =============================================================================
download_drivers() {
    info "Downloading drivers"

    # Source or download the driver utility
    local drv_script="$(dirname "$THIS_SCRIPT")/windows-driver-utils.sh"
    if [ ! -f "$drv_script" ]; then
        curl_download -o "$tmp/windows-driver-utils.sh" "$confhome/windows-driver-utils.sh"
        drv_script="$tmp/windows-driver-utils.sh"
    fi

    export DRIVER_TMP="$tmp/drivers"
    # shellcheck source=windows-driver-utils.sh
    source "$drv_script"
    download_required_drivers "$image_name" "$basearch_alt"
}

# =============================================================================
# Download Windows ISO
# =============================================================================
download_iso() {
    info "Downloading Windows ISO"

    local iso_dest="$tmp/windows.iso"

    if echo "$iso" | grep -q '^magnet:'; then
        # Magnet link — use aria2c
        if ! is_have_cmd aria2c; then
            install_pkg aria2
        fi
        aria2c --dir="$tmp" --out="windows.iso" "$iso"
    else
        curl_download -o "$iso_dest" "$iso"
    fi

    echo "ISO downloaded: $iso_dest"
    WIN_ISO="$iso_dest"
}

# =============================================================================
# Download Alpine netboot kernel + initrd (transitional environment)
# =============================================================================
download_alpine_netboot() {
    info "Downloading Alpine netboot (transitional environment)"

    local alpine_ver=3.21
    local flavour=lts
    detect_virt 2>/dev/null && flavour=virt || true

    local mirror="http://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}"
    local nb_dir="$mirror/releases/${basearch}/netboot"

    mkdir -p "$tmp/alpine"
    curl_download -o "$tmp/alpine/vmlinuz"  "${nb_dir}/vmlinuz-${flavour}"
    curl_download -o "$tmp/alpine/initrd"   "${nb_dir}/initramfs-${flavour}"
    curl_download -o "$tmp/alpine/modloop"  "${nb_dir}/modloop-${flavour}"

    echo "Alpine netboot files ready."
}

# =============================================================================
# Inject scripts and files into the Alpine initrd
# =============================================================================
build_initrd() {
    info "Building custom initrd"

    local initrd_src="$tmp/alpine/initrd"
    local initrd_dir="$tmp/initrd-work"
    local initrd_out="$tmp/alpine/initrd-custom"

    mkdir -p "$initrd_dir"

    # Decompress initrd
    cd "$initrd_dir"
    zcat "$initrd_src" | cpio -idm 2>/dev/null || \
        xzcat "$initrd_src" | cpio -idm 2>/dev/null

    # Download trans.sh (handles the Windows installation inside Alpine)
    curl_download -o "$initrd_dir/trans.sh" "$confhome/trans.sh" 2>/dev/null \
        || warn "trans.sh not found in confhome — skipping"

    # Copy network config
    source "$(dirname "$THIS_SCRIPT")/initrd-network.sh" 2>/dev/null \
        || source "$tmp/initrd-network.sh"
    collect_network_info
    write_initrd_network_config "$initrd_dir/etc/network/interfaces"
    write_dns_config "$initrd_dir/etc/resolv.conf"

    # Repack initrd
    find . | cpio -o -H newc 2>/dev/null | gzip > "$initrd_out"
    cd - >/dev/null

    echo "Custom initrd ready: $initrd_out"
}

# =============================================================================
# Configure GRUB to boot into Alpine (EFI)
# =============================================================================
setup_grub_efi() {
    info "Configuring GRUB EFI boot entry"

    local grub_dir="/boot/efi/EFI/horusinstall"
    mkdir -p "$grub_dir"

    cp "$tmp/alpine/vmlinuz"       "$grub_dir/vmlinuz"
    cp "$tmp/alpine/initrd-custom" "$grub_dir/initrd"

    local grub_cfg="/boot/efi/EFI/horusinstall/grub.cfg"
    cat > "$grub_cfg" <<EOF
${BOOT_ENTRY_START_MARK}
set timeout=5
set default=0

menuentry "HorusInstall - Windows Setup" {
    search --no-floppy --file --set=root /EFI/horusinstall/vmlinuz
    linux  /EFI/horusinstall/vmlinuz \\
        alpine_repo=http://dl-cdn.alpinelinux.org/alpine/v3.21/main \\
        modloop=http://dl-cdn.alpinelinux.org/alpine/v3.21/releases/${basearch}/netboot/modloop-lts \\
        console=tty0 console=ttyS0,115200 \\
        quiet
    initrd /EFI/horusinstall/initrd
}
${BOOT_ENTRY_END_MARK}
EOF

    # Add GRUB boot entry
    if is_have_cmd grub2-mkconfig; then
        grub2-reboot "HorusInstall - Windows Setup" 2>/dev/null || true
    elif is_have_cmd grub-reboot; then
        grub-reboot "HorusInstall - Windows Setup" 2>/dev/null || true
    fi

    # Register with EFI boot manager
    if is_have_cmd efibootmgr; then
        local disk part
        disk=$(get_xda 2>/dev/null || echo /dev/sda)
        part=$(ls /boot/efi/.. | head -1)
        efibootmgr -c \
            -d "$disk" \
            -L "HorusInstall" \
            -l "\\EFI\\horusinstall\\grub.cfg" 2>/dev/null || true
    fi

    echo "GRUB EFI entry configured."
}

# =============================================================================
# Configure GRUB to boot into Alpine (BIOS/Legacy)
# =============================================================================
setup_grub_bios() {
    info "Configuring GRUB BIOS boot entry"

    local grub_cfg
    # Find the main GRUB config file
    for f in /boot/grub2/grub.cfg /boot/grub/grub.cfg; do
        [ -f "$f" ] && grub_cfg="$f" && break
    done

    if [ -z "$grub_cfg" ]; then
        error_and_exit "Could not find GRUB config file."
    fi

    local vmlinuz_dest=/boot/horusinstall-vmlinuz
    local initrd_dest=/boot/horusinstall-initrd

    cp "$tmp/alpine/vmlinuz"       "$vmlinuz_dest"
    cp "$tmp/alpine/initrd-custom" "$initrd_dest"

    # Inject a menu entry before the first existing entry
    local entry
    entry=$(cat <<EOF

${BOOT_ENTRY_START_MARK}
menuentry "HorusInstall - Windows Setup" {
    search --no-floppy --file --set=root /boot/horusinstall-vmlinuz
    linux  /boot/horusinstall-vmlinuz \\
        alpine_repo=http://dl-cdn.alpinelinux.org/alpine/v3.21/main \\
        modloop=http://dl-cdn.alpinelinux.org/alpine/v3.21/releases/${basearch}/netboot/modloop-lts \\
        console=tty0 console=ttyS0,115200 \\
        quiet
    initrd /boot/horusinstall-initrd
}
${BOOT_ENTRY_END_MARK}
EOF
)

    # Remove any previous HorusInstall entry
    reset_grub_entry "$grub_cfg"

    # Prepend new entry
    local tmp_grub="$tmp/grub.cfg"
    echo "$entry" | cat - "$grub_cfg" > "$tmp_grub"
    cp "$tmp_grub" "$grub_cfg"

    # Set this entry as the next boot (grub-reboot)
    if is_have_cmd grub-reboot; then
        grub-reboot 0
    elif is_have_cmd grub2-reboot; then
        grub2-reboot 0
    fi

    echo "GRUB BIOS entry configured."
}

# =============================================================================
# Remove HorusInstall GRUB entry (used by 'reset' command)
# =============================================================================
reset_grub_entry() {
    local cfg="${1:-}"
    if [ -z "$cfg" ]; then
        for f in /boot/grub2/grub.cfg /boot/grub/grub.cfg /boot/efi/EFI/horusinstall/grub.cfg; do
            [ -f "$f" ] && cfg="$f" && break
        done
    fi
    [ -z "$cfg" ] && return 0

    # Remove lines between the markers
    sed -i "/${BOOT_ENTRY_START_MARK}/,/${BOOT_ENTRY_END_MARK}/d" "$cfg" 2>/dev/null || true

    # Remove copied kernel/initrd files
    rm -f /boot/horusinstall-vmlinuz /boot/horusinstall-initrd
    rm -rf /boot/efi/EFI/horusinstall
}

# =============================================================================
# Main install flow
# =============================================================================

# Source the disk detection helper
source_get_xda() {
    local xda_script="$(dirname "$THIS_SCRIPT")/get-xda.sh"
    if [ ! -f "$xda_script" ]; then
        curl_download -o "$tmp/get-xda.sh" "$confhome/get-xda.sh"
        xda_script="$tmp/get-xda.sh"
    fi
    # shellcheck source=get-xda.sh
    source "$xda_script"
}

install_windows() {
    info "HorusInstall — Starting Linux to Windows installation"

    # Pre-flight checks
    if is_in_container; then
        error_and_exit "OpenVZ and LXC containers are not supported. Use a KVM or XEN VPS."
    fi

    if [ "$(id -u)" != "0" ]; then
        error_and_exit "This script must be run as root."
    fi

    detect_basearch
    mkdir -p "$tmp"

    # Collect network info early (needed for netconf.bat)
    collect_net_conf

    # Disk detection and size check
    source_get_xda
    XDA=$(get_xda)
    export XDA
    print_disk_info "$XDA"
    assert_disk_size "$XDA"

    # Password
    prompt_password

    # ISO: find or use provided URL
    if [ -z "$iso" ]; then
        find_windows_iso
    fi

    # Build configuration files
    build_unattend_xml
    build_netconf_bat

    # Download drivers
    download_drivers

    # Custom drivers (--add-driver)
    if [ ${#add_drivers[@]} -gt 0 ]; then
        # shellcheck source=windows-driver-utils.sh
        source "$tmp/windows-driver-utils.sh" 2>/dev/null || true
        for drv in "${add_drivers[@]}"; do
            add_custom_driver "$drv"
        done
    fi

    # Download Alpine netboot environment
    download_alpine_netboot

    # Build custom initrd with embedded scripts/config
    build_initrd

    # Download the Windows ISO
    download_iso

    # Configure bootloader
    info "Configuring bootloader"
    if is_efi; then
        setup_grub_efi
    else
        setup_grub_bios
    fi

    info "All done — rebooting into Windows installer"
    echo ""
    echo "============================================================"
    echo "  HorusInstall is ready."
    echo "  The system will reboot into the Windows installer."
    echo ""
    echo "  You can monitor installation progress via:"
    echo "    SSH  : ssh root@<ip> -p ${ssh_port:-22}"
    echo "    Web  : http://<ip>:${web_port:-80}"
    echo ""
    echo "  To CANCEL before rebooting:"
    echo "    bash reinstall.sh reset"
    echo "============================================================"
    echo ""

    read -rp "Press Enter to reboot now, or Ctrl+C to cancel... "
    reboot
}

# =============================================================================
# Argument parsing
# =============================================================================
parse_args() {
    [ $# -eq 0 ] && usage_and_exit

    distro="$1"
    shift

    case "$distro" in
        windows) ;;
        reset)
            info "Resetting HorusInstall boot entries"
            reset_grub_entry
            rm -rf "$tmp"
            echo "Reset complete. Reboot normally."
            exit 0
            ;;
        *)
            echo "Error: HorusInstall only supports 'windows' as the target."
            echo "       This is a Linux-to-Windows only tool."
            usage_and_exit
            ;;
    esac

    # Defaults
    lang=en-us
    username=administrator
    ssh_port=22
    web_port=80
    rdp_port=3389
    allow_ping=0
    add_drivers=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --image-name)  image_name="$2";  shift 2 ;;
            --image-name=*) image_name="${1#*=}"; shift ;;
            --lang)        lang="$2";        shift 2 ;;
            --lang=*)      lang="${1#*=}";   shift ;;
            --iso)         iso="$2";         shift 2 ;;
            --iso=*)       iso="${1#*=}";    shift ;;
            --password)    password="$2";    shift 2 ;;
            --password=*)  password="${1#*=}"; shift ;;
            --username)    username="$2";    shift 2 ;;
            --username=*)  username="${1#*=}"; shift ;;
            --ssh-port)    ssh_port="$2";    shift 2 ;;
            --ssh-port=*)  ssh_port="${1#*=}"; shift ;;
            --web-port)    web_port="$2";    shift 2 ;;
            --web-port=*)  web_port="${1#*=}"; shift ;;
            --rdp-port)    rdp_port="$2";    shift 2 ;;
            --rdp-port=*)  rdp_port="${1#*=}"; shift ;;
            --allow-ping)  allow_ping=1;     shift ;;
            --add-driver)  add_drivers+=("$2"); shift 2 ;;
            --add-driver=*) add_drivers+=("${1#*=}"); shift ;;
            --help|-h)     usage_and_exit ;;
            *)
                echo "Unknown option: $1"
                usage_and_exit
                ;;
        esac
    done

    # Validation
    [ -z "$image_name" ] && error_and_exit "--image-name is required. Example: --image-name \"Windows 11 Pro\""

    if ! is_port_valid "$ssh_port"; then
        error_and_exit "Invalid SSH port: $ssh_port"
    fi
    if ! is_port_valid "$rdp_port"; then
        error_and_exit "Invalid RDP port: $rdp_port"
    fi

    # Normalize lang to lowercase
    lang=$(echo "$lang" | tr '[:upper:]' '[:lower:]')
    # Normalize image_name
    image_name=$(echo "$image_name" | tr '[:upper:]' '[:lower:]')

    echo "Configuration:"
    echo "  Image    : $image_name"
    echo "  Language : $lang"
    echo "  Username : $username"
    echo "  SSH port : $ssh_port"
    echo "  RDP port : $rdp_port"
    echo "  ISO      : ${iso:-auto-detect}"
    echo ""
}

# =============================================================================
# Entry point
# =============================================================================
parse_args "$@"
install_windows
