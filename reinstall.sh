#!/usr/bin/env bash
# HorusInstall - reinstall.sh
# Runs on the CURRENT Linux system. Downloads Alpine netboot files,
# builds a custom initrd that contains trans.sh and all config,
# injects a GRUB entry, then reboots into Alpine to perform the
# Windows Server installation unattended.
#
# Usage:
#   bash reinstall.sh windows --version <2016|2019|2022|2025> [OPTIONS]
#
# Options:
#   --version   <2016|2019|2022|2025>   Windows Server version  (required)
#   --password  <pass>                  Administrator password  (default: HorusInstall123!)
#   --username  <user>                  Administrator username  (default: Administrator)
#   --port      <port>                  RDP port                (default: 3389)
#   --iso       <url>                   Custom ISO URL          (overrides massgrave lookup)
#   --image     <name>                  Exact WIM image name    (auto-detected if omitted)
#   --lang      <locale>                ISO language            (default: en-us)

set -eE
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# ---------------------------------------------------------------------------
# Script version — must match the value expected by trans.sh.
# Bump both when making breaking changes to horus-config format.
# ---------------------------------------------------------------------------
SCRIPT_VERSION="2"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONF_HOME="https://raw.githubusercontent.com/HorusHDx/HorusInstall/main"
TMP="/horusinstall-tmp"

# Alpine netboot
ALPINE_BRANCH="v3.19"
ALPINE_ARCH="x86_64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_KERNEL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/netboot/vmlinuz-virt"
ALPINE_INITRD="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/netboot/initramfs-virt"
ALPINE_MODLOOP="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/netboot/modloop-virt"

# massgrave.dev — source of verified official Microsoft ISOs
# API: https://massgrave.dev/api/list returns JSON with product keys
MASSGRAVE_API="https://massgrave.dev/api/list"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\e[32m[INFO]  $*\e[0m" >&2; }
warn()  { echo -e "\e[33m[WARN]  $*\e[0m" >&2; }
error() { echo -e "\e[31m[ERROR] $*\e[0m" >&2; }
die()   { error "$@"; exit 1; }

# Log without exposing sensitive values
log_safe() {
    local msg="$1"
    # Mask anything that looks like a password placeholder or value
    msg=$(echo "$msg" | sed 's/WIN_PASSWORD=[^ ]*/WIN_PASSWORD=***/g')
    echo "[$(date '+%H:%M:%S')] $msg" >&2
}

trap 'error "Line $LINENO exited with code $?"' ERR

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
HorusInstall - Reinstall Linux VPS to Windows Server Datacenter

Usage:
  bash reinstall.sh windows --version VERSION [OPTIONS]

Versions:  2016 | 2019 | 2022 | 2025

Options:
  --password  <pass>    Administrator password  (default: HorusInstall123!)
  --username  <user>    Administrator username  (default: Administrator)
  --port      <port>    RDP port                (default: 3389)
  --lang      <locale>  ISO language code       (default: en-us)
  --iso       <url>     Custom ISO URL          (skips massgrave lookup)
  --image     <name>    Exact WIM image name    (auto-detected when omitted)

Examples:
  bash reinstall.sh windows --version 2022
  bash reinstall.sh windows --version 2025 --password "MyP@ss!" --port 33890
  bash reinstall.sh windows --version 2019 --lang pt-br
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
[ "${1:-}" = "windows" ] || usage
shift

WIN_PASSWORD="HorusInstall123!"
WIN_USERNAME="Administrator"
RDP_PORT="3389"
ISO_LANG="en-us"
CUSTOM_ISO_URL=""
WINDOWS_IMAGE_NAME=""
WINDOWS_VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version)  WINDOWS_VERSION="$2";    shift 2 ;;
        --password) WIN_PASSWORD="$2";       shift 2 ;;
        --username) WIN_USERNAME="$2";       shift 2 ;;
        --port)     RDP_PORT="$2";           shift 2 ;;
        --lang)     ISO_LANG="$2";           shift 2 ;;
        --iso)      CUSTOM_ISO_URL="$2";     shift 2 ;;
        --image)    WINDOWS_IMAGE_NAME="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[ -z "$WINDOWS_VERSION" ] && usage

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------
validate_env() {
    info "Validating environment"

    [ "$(id -u)" -eq 0 ] || die "This script must be run as root."

    # Block containers without kernel control
    if [ -f /proc/user_beancounters ]; then
        die "OpenVZ containers are not supported."
    fi
    if grep -qE "lxc|docker" /proc/1/cgroup 2>/dev/null; then
        die "LXC/Docker containers are not supported."
    fi

    # GRUB required
    command -v grub-mkconfig >/dev/null 2>&1 || \
    command -v grub2-mkconfig >/dev/null 2>&1 || \
        die "GRUB not found. A GRUB-based bootloader is required."

    # Minimum 1 GB RAM for Windows Server Datacenter
    local mem_kb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    if [ "$mem_kb" -lt 1048576 ]; then
        die "Windows Server Datacenter requires at least 1 GB RAM. Detected: $((mem_kb/1024)) MB."
    fi
    info "RAM: $((mem_kb/1024)) MB OK"

    # curl required (wget fallback handled in fetch())
    command -v curl >/dev/null 2>&1 || \
    command -v wget >/dev/null 2>&1 || \
        die "Neither curl nor wget found. Please install one first."

    # Minimum disk: 25 GB on the largest disk
    local max_disk_gb=0
    while read -r name size; do
        echo "$name" | grep -qE '^(loop|ram|sr)' && continue
        local gb=$(( size / 1073741824 ))
        [ "$gb" -gt "$max_disk_gb" ] && max_disk_gb=$gb
    done < <(lsblk -dn -b -o NAME,SIZE 2>/dev/null)
    if [ "$max_disk_gb" -lt 25 ]; then
        die "Windows Server Datacenter requires at least 25 GB disk. Largest disk: ${max_disk_gb} GB."
    fi
    info "Disk: ${max_disk_gb} GB OK"

    info "Environment OK"
}

# ---------------------------------------------------------------------------
# Detect current network configuration
# ---------------------------------------------------------------------------
get_net_info() {
    info "Gathering network settings"

    NET_IFACE=$(ip route show | awk '/default/{print $5; exit}')
    [ -z "$NET_IFACE" ] && NET_IFACE=$(ip -4 route show | awk '{print $5; exit}')
    [ -z "$NET_IFACE" ] && die "Could not detect active network interface."

    local ipcidr
    ipcidr=$(ip -4 addr show dev "$NET_IFACE" | awk '/inet /{print $2; exit}')
    [ -z "$ipcidr" ] && die "Could not detect local IP address on $NET_IFACE."
    NET_IPV4="${ipcidr%%/*}"
    NET_PREFIX="${ipcidr##*/}"

    NET_GATEWAY=$(ip route show default dev "$NET_IFACE" | awk '/via/{print $3; exit}')
    [ -z "$NET_GATEWAY" ] && NET_GATEWAY=$(ip route show | awk '/default/{print $3; exit}')
    [ -z "$NET_GATEWAY" ] && die "Network gateway could not be found."

    NET_DNS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
    if [ -z "$NET_DNS" ] || echo "$NET_DNS" | grep -qE '^127\.'; then
        NET_DNS="8.8.8.8"
        warn "Loopback or missing DNS — using 8.8.8.8 as fallback"
    fi

    NET_MODE="dhcp"
    if [ -f /etc/network/interfaces ] && grep -q "static" /etc/network/interfaces; then
        NET_MODE="static"
    elif command -v nmcli >/dev/null 2>&1; then
        if nmcli -t -f IP4.ADDRESS dev show "$NET_IFACE" 2>/dev/null | grep -q "$NET_IPV4"; then
            nmcli dev show "$NET_IFACE" 2>/dev/null | grep -qi "dhcp" && NET_MODE="dhcp" || NET_MODE="static"
        fi
    elif [ -d /etc/netplan ]; then
        grep -rq "dhcp4: no\|dhcp4: false" /etc/netplan/ 2>/dev/null && NET_MODE="static"
    fi

    info "Interface : $NET_IFACE"
    info "IP/Prefix : $NET_IPV4/$NET_PREFIX"
    info "Gateway   : $NET_GATEWAY"
    info "DNS       : $NET_DNS"
    info "Mode      : $NET_MODE"
}

# ---------------------------------------------------------------------------
# Download helper — curl first, wget fallback, with retries
# ---------------------------------------------------------------------------
fetch() {
    local url="$1" dest="$2" label="${3:-$1}"
    info "Downloading: $label"
    if command -v curl >/dev/null 2>&1; then
        curl -sSL -k --retry 5 --retry-delay 3 --connect-timeout 15 \
             -o "$dest" "$url" \
             || die "Failed to download: $label"
    else
        wget --no-check-certificate -q --tries=5 --waitretry=3 \
             -O "$dest" "$url" \
             || die "Failed to download: $label"
    fi
    [ -s "$dest" ] || die "Downloaded file is empty: $label"
}

# ---------------------------------------------------------------------------
# Validate a URL is reachable before committing to a full download
# ---------------------------------------------------------------------------
validate_url() {
    local url="$1" label="${2:-$url}"
    info "Validating URL: $label"
    local http_code
    if command -v curl >/dev/null 2>&1; then
        http_code=$(curl -sSLk -o /dev/null -w "%{http_code}" \
                    --max-time 15 --connect-timeout 10 \
                    --retry 3 "$url" 2>/dev/null || echo "000")
    else
        http_code=$(wget --no-check-certificate -q --spider \
                    --server-response "$url" 2>&1 \
                    | awk '/HTTP\//{print $2}' | tail -1 || echo "000")
    fi

    case "$http_code" in
        200|301|302|303|307|308) info "URL OK (HTTP $http_code)" ;;
        000) warn "Could not reach $label — proceeding anyway (network may be restricted)" ;;
        404) die "ISO URL returned 404 Not Found. The link may be outdated: $url" ;;
        *)   warn "Unexpected HTTP $http_code for $label — proceeding anyway" ;;
    esac
}

# ---------------------------------------------------------------------------
# Resolve ISO URL from massgrave.dev
# massgrave.dev hosts a JSON catalog of verified Microsoft ISO links.
# We query it and extract the URL matching our version + edition + language.
# Falls back to hardcoded URLs if the API is unreachable.
# ---------------------------------------------------------------------------
resolve_iso_url() {
    [ -n "$CUSTOM_ISO_URL" ] && {
        info "Using custom ISO URL (massgrave lookup skipped)"
        return
    }

    info "Querying massgrave.dev for Windows Server $WINDOWS_VERSION ISO..."

    # Build search terms
    local search_version search_edition
    case "$WINDOWS_VERSION" in
        2016) search_version="2016" ;;
        2019) search_version="2019" ;;
        2022) search_version="2022" ;;
        2025) search_version="2025" ;;
    esac
    search_edition="Datacenter"

    # Try massgrave.dev API
    local api_response=""
    if command -v curl >/dev/null 2>&1; then
        api_response=$(curl -sSLk --max-time 20 --retry 3 "$MASSGRAVE_API" 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
        api_response=$(wget --no-check-certificate -qO- --timeout=20 "$MASSGRAVE_API" 2>/dev/null || true)
    fi

    if [ -n "$api_response" ]; then
        # Parse JSON — extract URL matching version + edition + language
        # massgrave API returns objects with "title" and "url" fields
        local found_url
        found_url=$(echo "$api_response" \
            | grep -oi '"url":"[^"]*"' \
            | grep -i "server" \
            | grep -i "$search_version" \
            | grep -i "$search_edition" \
            | grep -i "$ISO_LANG" \
            | head -1 \
            | sed 's/"url":"//;s/"//')

        # Fallback: try without language filter (some entries vary)
        if [ -z "$found_url" ]; then
            found_url=$(echo "$api_response" \
                | grep -oi '"url":"[^"]*"' \
                | grep -i "server" \
                | grep -i "$search_version" \
                | grep -i "$search_edition" \
                | head -1 \
                | sed 's/"url":"//;s/"//')
        fi

        if [ -n "$found_url" ]; then
            CUSTOM_ISO_URL="$found_url"
            info "massgrave.dev resolved ISO URL for Server $WINDOWS_VERSION $search_edition"
            return
        fi
        warn "massgrave.dev API response did not contain a matching URL — using fallback"
    else
        warn "Could not reach massgrave.dev API — using fallback ISO URLs"
    fi

    # ---------------------------------------------------------------------------
    # Hardcoded fallback URLs (en-us evaluation ISOs from Microsoft)
    # These are backup only — massgrave.dev is the preferred source.
    # ---------------------------------------------------------------------------
    case "$WINDOWS_VERSION" in
        2016)
            CUSTOM_ISO_URL="https://software-static.download.prss.microsoft.com/pr/download/14393.0.160715-1616.RS1_RELEASE_SERVER_EVAL_X64FRE_EN-US.ISO"
            ;;
        2019)
            CUSTOM_ISO_URL="https://software-static.download.prss.microsoft.com/dbazure/download/17763.737.190906-2324.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
            ;;
        2022)
            CUSTOM_ISO_URL="https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso"
            ;;
        2025)
            CUSTOM_ISO_URL="https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66750/SERVER_EVAL_x64FRE_en-us.iso"
            ;;
    esac

    warn "Using fallback ISO URL for Server $WINDOWS_VERSION"
}

# ---------------------------------------------------------------------------
# Set default WIM image name hint (trans.sh auto-detects if this is wrong)
# ---------------------------------------------------------------------------
set_image_name_hint() {
    [ -n "$WINDOWS_IMAGE_NAME" ] && return
    case "$WINDOWS_VERSION" in
        2016) WINDOWS_IMAGE_NAME="Windows Server 2016 SERVERDATACENTEREVAL" ;;
        2019) WINDOWS_IMAGE_NAME="Windows Server 2019 SERVERDATACENTEREVAL" ;;
        2022) WINDOWS_IMAGE_NAME="Windows Server 2022 SERVERDATACENTEREVAL" ;;
        2025) WINDOWS_IMAGE_NAME="Windows Server 2025 SERVERDATACENTEREVAL" ;;
    esac
    info "WIM image name hint: $WINDOWS_IMAGE_NAME (trans.sh will auto-detect if needed)"
}

# ---------------------------------------------------------------------------
# Write horus-config — read by trans.sh inside Alpine
# Passwords are never written to the main system log
# ---------------------------------------------------------------------------
write_config() {
    cat > "$TMP/horus-config" <<EOF
SCRIPT_VERSION="$SCRIPT_VERSION"
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
    # Log config summary WITHOUT the password
    info "Config written:"
    grep -v "WIN_PASSWORD" "$TMP/horus-config" | while read -r line; do
        info "  $line"
    done
}

# ---------------------------------------------------------------------------
# Build a custom Alpine initrd that auto-runs trans.sh on boot
# ---------------------------------------------------------------------------
inject_into_initrd() {
    info "Building custom Alpine initrd"
    local initrd_dir="$TMP/initrd-root"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"

    mkdir -p "$initrd_dir/etc/local.d" \
             "$initrd_dir${TMP}" \
             "$initrd_dir/etc/network"

    cp "$TMP/horus-config"              "$initrd_dir${TMP}/horus-config"
    cp "$TMP/trans.sh"                  "$initrd_dir${TMP}/trans.sh"
    cp "$TMP/windows.xml"               "$initrd_dir${TMP}/windows.xml"
    cp "$TMP/windows-setup.bat"         "$initrd_dir${TMP}/windows-setup.bat"
    cp "$TMP/windows-set-netconf.bat"   "$initrd_dir${TMP}/windows-set-netconf.bat"

    local common_ifaces="eth0 ens3 ens4 ens18 enp0s3 enp0s4 enp0s18 enp1s0 $NET_IFACE"
    {
        echo "auto lo"
        echo "iface lo inet loopback"
        echo ""
        echo "auto $common_ifaces"
        for ifc in $common_ifaces; do
            if [ "$NET_MODE" = "static" ]; then
                echo "iface $ifc inet static"
                echo "  address $NET_IPV4/$NET_PREFIX"
                echo "  gateway $NET_GATEWAY"
                echo "  hostname horusinstall"
            else
                echo "iface $ifc inet dhcp"
            fi
        done
    } > "$initrd_dir/etc/network/interfaces"

    echo "nameserver $NET_DNS"  > "$initrd_dir/etc/resolv.conf"
    echo "nameserver 8.8.4.4"  >> "$initrd_dir/etc/resolv.conf"

    cat > "$initrd_dir/etc/local.d/trans.start" <<STARTSCRIPT
#!/usr/bin/env sh
rc-service networking start || true
exec sh ${TMP}/trans.sh
STARTSCRIPT
    chmod +x "$initrd_dir/etc/local.d/trans.start"

    mkdir -p "$initrd_dir/etc/runlevels/default"
    ln -sf /etc/init.d/local "$initrd_dir/etc/runlevels/default/local"

    cd "$initrd_dir"
    find . | cpio -o -H newc | gzip -9 >> "$TMP/alpine-initrd.img"
    cd "$TMP"
    rm -rf "$initrd_dir"
    info "Custom initrd built"
}

# ---------------------------------------------------------------------------
# Add a GRUB menu entry and set it as next-boot default
# ---------------------------------------------------------------------------
setup_grub() {
    info "Configuring GRUB boot entry"

    local boot_prefix="/boot"
    mountpoint -q /boot && boot_prefix=""

    local cmdline="alpine_repo=${ALPINE_MIRROR}/${ALPINE_BRANCH}/main"
    cmdline+=" modloop=${boot_prefix}/horusinstall/modloop"
    cmdline+=" alpine_commands=local:default"
    cmdline+=" horusinstall=1"
    cmdline+=" console=tty0 console=ttyS0,115200"

    mkdir -p /boot/horusinstall
    cp "$TMP/alpine-vmlinuz"    /boot/horusinstall/vmlinuz
    cp "$TMP/alpine-initrd.img" /boot/horusinstall/initrd.img
    cp "$TMP/alpine-modloop"    /boot/horusinstall/modloop

    local boot_uuid
    boot_uuid=$(grub-probe --target=fs_uuid /boot/horusinstall/vmlinuz 2>/dev/null || true)

    cat > /etc/grub.d/40_custom <<GRUBEOF
#!/bin/sh
exec tail -n +3 \$0
menuentry "HorusInstall (Windows Server Reinstallation)" --class windows {
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    insmod fat
    $([ -n "$boot_uuid" ] && echo "search --no-floppy --fs-uuid --set=root $boot_uuid")
    linux  ${boot_prefix}/horusinstall/vmlinuz ${cmdline}
    initrd ${boot_prefix}/horusinstall/initrd.img
}
GRUBEOF
    chmod +x /etc/grub.d/40_custom

    local entry_name="HorusInstall (Windows Server Reinstallation)"
    if [ -f /etc/default/grub ]; then
        sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${entry_name}\"|"  /etc/default/grub || true
        sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=10|'                 /etc/default/grub || true
        sed -i 's|^GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=menu|'   /etc/default/grub || true
        sed -i 's|^GRUB_SAVEDEFAULT=.*|GRUB_SAVEDEFAULT=false|'      /etc/default/grub || true
    fi

    local updated=false
    for cmd in "update-grub" \
               "grub-mkconfig -o /boot/grub/grub.cfg" \
               "grub-mkconfig -o /boot/efi/EFI/ubuntu/grub.cfg" \
               "grub-mkconfig -o /boot/efi/EFI/debian/grub.cfg" \
               "grub2-mkconfig -o /boot/grub2/grub.cfg" \
               "grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg" \
               "grub2-mkconfig -o /boot/efi/EFI/rocky/grub.cfg"; do
        local bin="${cmd%% *}"
        if command -v "$bin" >/dev/null 2>&1; then
            eval "$cmd" 2>/dev/null && updated=true && break
        fi
    done

    for cfg in /boot/grub/grub.cfg /boot/grub2/grub.cfg /boot/efi/EFI/*/grub.cfg; do
        [ -f "$cfg" ] || continue
        grub-mkconfig  -o "$cfg" 2>/dev/null || \
        grub2-mkconfig -o "$cfg" 2>/dev/null || true
        updated=true
    done

    "$updated" || warn "Could not find grub-mkconfig — verify GRUB entry manually."

    # grub-reboot: boots our entry exactly ONCE (reverts on next boot if something fails)
    local rebooted=false
    if command -v grub-reboot >/dev/null 2>&1; then
        grub-reboot "$entry_name" 2>/dev/null && rebooted=true || true
    elif command -v grub2-reboot >/dev/null 2>&1; then
        grub2-reboot "$entry_name" 2>/dev/null && rebooted=true || true
    fi
    "$rebooted" \
        && info "grub-reboot set: HorusInstall entry will boot exactly once" \
        || warn "grub-reboot unavailable — entry is in menu but may not auto-select"

    info "GRUB configured"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "=== HorusInstall v${SCRIPT_VERSION} started ==="
    info "Target: Windows Server $WINDOWS_VERSION Datacenter"

    validate_env
    get_net_info
    resolve_iso_url
    set_image_name_hint

    # Validate ISO URL is reachable before doing anything destructive
    validate_url "$CUSTOM_ISO_URL" "Windows Server $WINDOWS_VERSION ISO"

    mkdir -p "$TMP"

    info "Downloading Alpine netboot files"
    fetch "$ALPINE_KERNEL"  "$TMP/alpine-vmlinuz"   "Alpine kernel"
    fetch "$ALPINE_INITRD"  "$TMP/alpine-initrd.img" "Alpine initrd"
    fetch "$ALPINE_MODLOOP" "$TMP/alpine-modloop"    "Alpine modloop"

    info "Downloading HorusInstall helper scripts"
    fetch "$CONF_HOME/trans.sh"                "$TMP/trans.sh"                "trans.sh"
    fetch "$CONF_HOME/windows.xml"             "$TMP/windows.xml"             "windows.xml"
    fetch "$CONF_HOME/windows-setup.bat"       "$TMP/windows-setup.bat"       "windows-setup.bat"
    fetch "$CONF_HOME/windows-set-netconf.bat" "$TMP/windows-set-netconf.bat" "windows-set-netconf.bat"
    chmod +x "$TMP/trans.sh"

    write_config
    inject_into_initrd
    setup_grub

    info "================================================================"
    info "Setup complete. Rebooting in 10 seconds..."
    info "Windows Server $WINDOWS_VERSION installation will begin automatically."
    info "Connect via RDP to $NET_IPV4:$RDP_PORT after ~20-30 minutes."
    info "================================================================"
    sleep 10
    reboot
}

main "$@"
