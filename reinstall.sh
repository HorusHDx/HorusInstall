#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2086
# =============================================================================
# reinstall.sh
# HorusInstall - Linux to Windows reinstall tool (Linux -> Windows ONLY)
# Based on: github.com/bin456789/reinstall (GPL-3.0)
# Modified by: HorusHDx
#
# Flow:
#   Linux -> download Alpine netboot -> inject trans.sh + /configs into the
#   initrd -> GRUB boots Alpine once -> trans.sh partitions the disk, stages
#   the Windows ISO and the unattend files -> reboots into Windows setup.
#
# Usage:
#   bash reinstall.sh windows --image-name "Windows 11 Enterprise LTSC 2024" --lang en-us
#   bash reinstall.sh windows --image-name "Windows Server 2022 SERVERSTANDARD" --iso "https://.../server.iso"
#   bash reinstall.sh reset
#
# Requirements: root, curl/wget, bash 4+, x86_64|aarch64, >=1GB RAM, >=25GB disk.
# Virtualization: KVM / XEN / VMware / Hyper-V / bare metal. NOT OpenVZ/LXC.
# =============================================================================

set -eE

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
confhome=https://raw.githubusercontent.com/HorusHDx/HorusInstall/main
tmp=/reinstall-tmp
SCRIPT_VERSION=HORUS-2026-LTW-002

BOOT_ENTRY_START_MARK='### BEGIN HorusInstall ###'
BOOT_ENTRY_END_MARK='### END HorusInstall ###'
BOOT_ENTRY_TITLE='HorusInstall - Windows Setup'

export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

THIS_SCRIPT=$(readlink -f "$0")
trap 'trap_err $LINENO $?' ERR

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
trap_err() {
    local line_no=$1 ret_no=$2
    error "Line $line_no returned exit code $ret_no"
    sed -n "${line_no}p" "$THIS_SCRIPT" >&2
}
info() {
    if [ "$1" = false ]; then shift; echo_color '\e[32m' "$*" >&2
    else echo_color '\e[32m' "***** $(echo "$*" | tr '[:lower:]' '[:upper:]') *****" >&2; fi
}
warn()  { echo_color '\e[33m' "Warning: $*" >&2; }
error() { echo_color '\e[31m' "***** ERROR *****" >&2; echo_color '\e[31m' "$*" >&2; }
echo_color() { local c=$1; shift; echo -e "${c}$*\e[0m"; }
error_and_exit() { error "$@"; exit 1; }

usage_and_exit() {
    cat <<EOF

HorusInstall - Linux to Windows reinstaller
===========================================

Usage:
  bash reinstall.sh windows --image-name "Windows 11 Enterprise LTSC 2024" --lang en-us
  bash reinstall.sh windows --image-name "Windows Server 2022 SERVERSTANDARD" \\
      --iso "https://example.com/server2022.iso"
  bash reinstall.sh reset

Options:
  --image-name NAME   Windows edition to install (required)
  --lang LOCALE       en-us, es-es, pt-br ... (default: en-us)
  --iso URL           Direct ISO URL or magnet link (optional, auto-detected)
  --password PASS     Administrator password (prompted if omitted)
  --username USER     Local account name (default: administrator)
  --ssh-port PORT     SSH port for monitoring during install (default: 22)
  --web-port PORT     Web log viewer port (default: 80)
  --rdp-port PORT     RDP port after install (default: 3389)
  --allow-ping        Allow ICMP through Windows Firewall
  --add-driver PATH   Extra .inf driver (repeatable)
  --hold 1            Boot into Alpine but do NOT run the installer (debug)

More info: https://github.com/HorusHDx/HorusInstall
EOF
    exit 1
}

# -----------------------------------------------------------------------------
# Generic helpers
# -----------------------------------------------------------------------------
is_digit() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_port_valid() { is_digit "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_have_cmd() { command -v "$1" &>/dev/null; }
is_absolute_path() { [[ "$1" = /* ]]; }
get_scheme_and_host_by_url() { cut -d/ -f1-3 <<<"$1"; }
to_lower() { tr '[:upper:]' '[:lower:]'; }

install_pkg() {
    if is_have_cmd apt-get; then      apt-get install -y "$@"
    elif is_have_cmd dnf; then        dnf install -y "$@"
    elif is_have_cmd yum; then        yum install -y "$@"
    elif is_have_cmd apk; then        apk add "$@"
    elif is_have_cmd zypper; then     zypper install -y "$@"
    elif is_have_cmd pacman; then     pacman -Sy --noconfirm "$@"
    else error_and_exit "No supported package manager found."; fi
}

curl_download() {
    is_have_cmd curl || install_pkg curl
    local i ret
    for i in $(seq 5); do
        if command curl --connect-timeout 10 -fL "$@"; then return 0; fi
        ret=$?
        [ $ret -eq 22 ] && return $ret
        [ $i -eq 5 ] && return $ret
        sleep 2
    done
}

is_in_container() {
    { is_have_cmd systemd-detect-virt && systemd-detect-virt -qc; } ||
        [ -d /proc/vz ] ||
        { [ -f /proc/1/environ ] && grep -q container=lxc /proc/1/environ; }
}

is_efi() { [ -d /sys/firmware/efi ]; }

detect_basearch() {
    basearch=$(uname -m)
    case "$basearch" in
        x86_64)  basearch_alt=amd64 ;;
        aarch64) basearch_alt=arm64 ;;
        *) error_and_exit "Unsupported architecture: $basearch (only x86_64/aarch64)." ;;
    esac
    info "Architecture: $basearch ($basearch_alt)"
}

_is_virt=""
is_virt() {
    if [ -n "$_is_virt" ]; then $_is_virt; return; fi
    if is_have_cmd systemd-detect-virt && systemd-detect-virt -v 2>/dev/null; then
        _is_virt=true
    elif is_have_cmd virt-what && [ -n "$(virt-what 2>/dev/null)" ]; then
        _is_virt=true
    else
        _is_virt=false
    fi
    info "Virtualized: $_is_virt"
    $_is_virt
}

# Insert text (from stdin) into a file before/after lines matching a regex.
insert_into_file() {
    local file=$1 pos=$2 pattern=$3
    local insfile="${file}.ins.$$" outfile="${file}.new.$$"
    cat > "$insfile"
    awk -v pos="$pos" -v pat="$pattern" -v insfile="$insfile" '
        { lines[NR] = $0 }
        END {
            ins = ""
            while ((getline l < insfile) > 0) ins = ins l "\n"
            for (i = 1; i <= NR; i++) {
                if (pos == "before" && lines[i] ~ pat) printf "%s", ins
                print lines[i]
                if (pos == "after" && lines[i] ~ pat) printf "%s", ins
            }
        }
    ' "$file" > "$outfile"
    mv "$outfile" "$file"
    rm -f "$insfile"
}

# -----------------------------------------------------------------------------
# Windows ISO auto-discovery (massgrave.dev)
# -----------------------------------------------------------------------------
lang_to_english() {
    case "$lang" in
        ar-sa) echo Arabic ;;      bg-bg) echo Bulgarian ;;   cs-cz) echo Czech ;;
        da-dk) echo Danish ;;      de-de) echo German ;;      el-gr) echo Greek ;;
        en-gb) echo Eng_Intl ;;    en-us) echo English ;;     es-es) echo Spanish ;;
        es-mx) echo Spanish_Latam ;; et-ee) echo Estonian ;;  fi-fi) echo Finnish ;;
        fr-ca) echo FrenchCanadian ;; fr-fr) echo French ;;   he-il) echo Hebrew ;;
        hr-hr) echo Croatian ;;    hu-hu) echo Hungarian ;;   it-it) echo Italian ;;
        ja-jp) echo Japanese ;;    ko-kr) echo Korean ;;      lt-lt) echo Lithuanian ;;
        lv-lv) echo Latvian ;;     nb-no) echo Norwegian ;;   nl-nl) echo Dutch ;;
        pl-pl) echo Polish ;;      pt-pt) echo Portuguese ;;  pt-br) echo Brazilian ;;
        ro-ro) echo Romanian ;;    ru-ru) echo Russian ;;     sk-sk) echo Slovak ;;
        sl-si) echo Slovenian ;;   sv-se) echo Swedish ;;     th-th) echo Thai ;;
        tr-tr) echo Turkish ;;     uk-ua) echo Ukrainian ;;   zh-cn) echo ChnSimp ;;
        zh-hk|zh-tw) echo ChnTrad ;; sr-latn|sr-latn-rs) echo Serbian_Latin ;;
    esac
}

get_lang_fallbacks() {
    local base="${lang%%-*}"
    echo "$lang"
    echo "${base}-${base}"
    echo "$base"
    [ "$lang" = zh-hk ] && echo zh-tw
    [ "$lang" = en-gb ] && echo en-us
}

is_ltsc() { echo "$image_name" | grep -Eiwq 'ltsb|ltsc'; }

find_windows_iso() {
    info "Searching for Windows ISO"

    local server= arch_win page_url full_lang http_base http_dir pattern line found=false try_lang
    echo "$image_name" | tr '[:upper:]' '[:lower:]' | grep -q 'server' && server=1 || server=
    case "$basearch" in x86_64) arch_win=x64 ;; aarch64) arch_win=arm64 ;; esac

    if [ -n "$server" ]; then
        page_url=https://massgrave.dev/windows-server-links
    elif echo "$image_name" | grep -qi 'windows 10'; then
        page_url=https://massgrave.dev/windows_10_links
    else
        page_url=https://massgrave.dev/windows_11_links
    fi
    info false "ISO source: $page_url"

    http_base=$(get_scheme_and_host_by_url "$page_url")
    http_dir=$(dirname "$page_url")

    curl_download -s "$page_url" |
        tr -d '\n' |
        sed -e 's,<a ,\n<a ,g' -e 's,</a>,</a>\n,g' |
        grep -Ei '\.(iso|img)</a>$' |
        sed -E \
            -e 's,<a href="?([^" ]+)"?.+>(.+)</a>,\2 \1,' \
            -e "s, (/), $http_base\1," |
        awk -v d="$http_dir/" '{if ($2 !~ /^https?:\/\//) $2 = d $2; print}' \
        > "$tmp/win.list" 2>/dev/null || true

    if is_ltsc; then sed -Ei '/ltsc|ltsb/!d' "$tmp/win.list"
    else              sed -Ei '/ltsc|ltsb/d' "$tmp/win.list"; fi

    for try_lang in $(get_lang_fallbacks); do
        pattern="${try_lang}_windows.*${arch_win}.*\.(iso|img)"
        pattern="${pattern// /_}"
        info false "Trying: $pattern"
        if line=$(grep -Ei "^$pattern " "$tmp/win.list" | head -1) && [ -n "$line" ]; then
            iso=$(awk '{print $2}' <<<"$line")
            info false "Found ISO: $iso"
            found=true
            break
        fi
    done

    if ! $found; then
        error_and_exit "Could not find an ISO for '$image_name' ($lang / $arch_win).
Set --iso manually with a URL from:
  https://massgrave.dev/genuine-installation-media
  https://msdl.gravesoft.dev"
    fi
}

# -----------------------------------------------------------------------------
# Network collection (sourced from initrd-network.sh)
# -----------------------------------------------------------------------------
collect_net_conf() {
    info "Collecting network configuration"
    local helper="$(dirname "$THIS_SCRIPT")/initrd-network.sh"
    if [ -f "$helper" ]; then
        # shellcheck source=initrd-network.sh
        source "$helper"
    else
        warn "initrd-network.sh not found locally, downloading..."
        curl_download -o "$tmp/initrd-network.sh" "$confhome/initrd-network.sh"
        source "$tmp/initrd-network.sh"
    fi
    collect_network_info
}

# -----------------------------------------------------------------------------
# Disk helpers
# -----------------------------------------------------------------------------
source_get_xda() {
    local helper="$(dirname "$THIS_SCRIPT")/get-xda.sh"
    if [ ! -f "$helper" ]; then
        curl_download -o "$tmp/get-xda.sh" "$confhome/get-xda.sh"
        helper="$tmp/get-xda.sh"
    fi
    # shellcheck source=get-xda.sh
    source "$helper"
}

# trans.sh locates the target disk by comparing sfdisk's disk-id (PTUUID).
get_disk_id() {
    local disk=$1 id=""
    if is_have_cmd sfdisk; then
        id=$(sfdisk --disk-id "$disk" 2>/dev/null | sed 's/^0x//')
    elif is_have_cmd blkid; then
        id=$(blkid -s PTUUID -o value "$disk" 2>/dev/null)
    fi
    if [ -z "$id" ]; then
        install_pkg util-linux >/dev/null 2>&1 || true
        is_have_cmd sfdisk && id=$(sfdisk --disk-id "$disk" 2>/dev/null | sed 's/^0x//')
    fi
    [ -z "$id" ] && error_and_exit "Could not read the partition table UUID of $disk. Install util-linux and retry."
    echo "$id"
}

# -----------------------------------------------------------------------------
# Password / unattend / netconf
# -----------------------------------------------------------------------------
prompt_password() {
    [ -n "$password" ] && return
    local p1 p2
    while true; do
        read -rsp "Enter Windows administrator password: " p1; echo
        [ -z "$p1" ] && { echo "Password cannot be empty."; continue; }
        read -rsp "Confirm password: " p2; echo
        [ "$p1" = "$p2" ] && { password="$p1"; break; }
        echo "Passwords do not match. Try again."
    done
}

encode_password() {
    printf '%s' "${1}${2}" | iconv -f UTF-8 -t UTF-16LE | base64 -w 0
}

build_unattend_xml() {
    info "Building unattend.xml"
    curl_download -o "$tmp/windows.xml" "$confhome/windows.xml" || {
        [ -f "$(dirname "$THIS_SCRIPT")/windows.xml" ] &&
            cp "$(dirname "$THIS_SCRIPT")/windows.xml" "$tmp/windows.xml"
    }

    local arch_xml admin_pass_enc user_pass_enc use_default_rdp=true enable_admin=0
    case "$basearch" in x86_64) arch_xml=amd64 ;; aarch64) arch_xml=arm64 ;; esac

    admin_pass_enc=$(encode_password "$password" "AdministratorPassword")
    user_pass_enc=$(encode_password "$password" "Password")
    [ "${rdp_port:-3389}" != "3389" ] && use_default_rdp=false
    echo "$username" | grep -qi '^administrator$' && enable_admin=1

    # GPT: partition 4 is Windows; MBR: partition 2 is Windows.
    if is_efi; then installto_partitionid=4; else installto_partitionid=2; fi

    sed \
        -e "s|%arch%|${arch_xml}|g" \
        -e "s|%key%||g" \
        -e "s|%image_name%|${image_name}|g" \
        -e "s|%disk_id%|0|g" \
        -e "s|%installto_partitionid%|${installto_partitionid}|g" \
        -e "s|%locale%|${lang:-en-us}|g" \
        -e "s|%enable_administrator%|${enable_admin}|g" \
        -e "s|%use_default_rdp_port%|${use_default_rdp}|g" \
        -e "s|%administrator_password%|${admin_pass_enc}|g" \
        -e "s|%user_username%|${username:-administrator}|g" \
        -e "s|%user_password%|${user_pass_enc}|g" \
        "$tmp/windows.xml" > "$tmp/windows_final.xml"
    info false "Unattend XML ready (InstallTo partition $installto_partitionid)"
}

build_netconf_bat() {
    info "Building windows-set-netconf.bat"
    local bat_src="$tmp/windows-set-netconf.bat"
    curl_download -o "$bat_src" "$confhome/windows-set-netconf.bat" || {
        [ -f "$(dirname "$THIS_SCRIPT")/windows-set-netconf.bat" ] &&
            cp "$(dirname "$THIS_SCRIPT")/windows-set-netconf.bat" "$bat_src"
    }

    local iface="${NET_IPV4_IFACE:-$(ip route | awk '/default/{print $5;exit}')}"
    local mac_addr
    mac_addr=$(ip link show "$iface" 2>/dev/null | awk '/ether/{print $2}' | head -1 | tr '[:lower:]' '[:upper:]')

    local inject=""
    [ -n "$mac_addr" ]      && inject+="set mac_addr=${mac_addr}\r\n"
    [ -n "$NET_IPV4_ADDR" ] && inject+="set ipv4_addr=${NET_IPV4_ADDR}/${NET_IPV4_PREFIX}\r\n"
    [ -n "$NET_IPV4_GW" ]   && inject+="set ipv4_gateway=${NET_IPV4_GW}\r\n"
    [ -n "$NET_IPV6_ADDR" ] && inject+="set ipv6_addr=${NET_IPV6_ADDR}/${NET_IPV6_PREFIX}\r\n"
    [ -n "$NET_IPV6_GW" ]   && inject+="set ipv6_gateway=${NET_IPV6_GW}\r\n"

    local ns count=0
    for ns in $NET_DNS; do
        count=$((count+1))
        if echo "$ns" | grep -q ':'; then inject+="set ipv6_dns${count}=${ns}\r\n"
        else                                inject+="set ipv4_dns${count}=${ns}\r\n"; fi
        [ $count -ge 2 ] && break
    done

    [ "${rdp_port:-3389}" != "3389" ] && inject+="set rdp_port=${rdp_port}\r\n"
    [ "$allow_ping" = 1 ] && inject+="set allow_ping=1\r\n"

    printf "%b\n" "$inject" | cat - "$bat_src" > "$tmp/windows-set-netconf-final.bat"
    info false "Network config bat ready"
}

# -----------------------------------------------------------------------------
# Drivers
# -----------------------------------------------------------------------------
download_drivers() {
    info "Downloading drivers"
    local script="$(dirname "$THIS_SCRIPT")/windows-driver-utils.sh"
    if [ ! -f "$script" ]; then
        curl_download -o "$tmp/windows-driver-utils.sh" "$confhome/windows-driver-utils.sh"
        script="$tmp/windows-driver-utils.sh"
    fi
    export DRIVER_TMP="$tmp/drivers"
    # shellcheck source=windows-driver-utils.sh
    source "$script"
    download_required_drivers "$image_name" "$basearch_alt"

    mkdir -p "$tmp/custom_drivers"
    local drv
    for drv in "${add_drivers[@]}"; do
        [ -e "$drv" ] || { warn "Driver not found: $drv"; continue; }
        add_custom_driver "$drv"
    done
    cp "$script" "$tmp/windows-driver-utils.sh" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Alpine netboot (transitional environment)
# -----------------------------------------------------------------------------
ALPINE_VER=3.21

download_alpine_netboot() {
    info "Downloading Alpine netboot"
    local mirror="http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}"
    local nb_dir="$mirror/releases/${basearch}/netboot"
    local flavour
    mkdir -p "$tmp/alpine"

    # Prefer the cloud/virt kernel, fall back to lts if the mirror lacks it.
    for flavour in virt lts; do
        if curl_download -o "$tmp/alpine/vmlinuz"  "${nb_dir}/vmlinuz-${flavour}" &&
           curl_download -o "$tmp/alpine/initrd"   "${nb_dir}/initramfs-${flavour}" &&
           curl_download -o "$tmp/alpine/modloop"  "${nb_dir}/modloop-${flavour}"; then
            ALPINE_FLAVOUR=$flavour
            break
        fi
    done
    [ -z "${ALPINE_FLAVOUR:-}" ] && error_and_exit "Could not download Alpine netboot files."
    info false "Alpine $ALPINE_VER / $ALPINE_FLAVOUR ready"
}

# IMPORTANT: this is where the two halves of HorusInstall meet.
# trans.sh expects its inputs under /configs and the ISO URL either in
# /configs/iso_url or as finalos_iso=... on the kernel cmdline.
write_initrd_configs() {
    local root=$1
    mkdir -p "$root/configs" "$root/iso-download"

    cp "$tmp/windows_final.xml"             "$root/configs/windows.xml"
    cp "$tmp/windows-set-netconf-final.bat" "$root/configs/windows-set-netconf.bat"

    local setup_bat="$(dirname "$THIS_SCRIPT")/windows-setup.bat"
    if [ -f "$setup_bat" ]; then cp "$setup_bat" "$root/configs/windows-setup.bat"
    else curl_download -o "$root/configs/windows-setup.bat" "$confhome/windows-setup.bat"; fi

    [ -d "$tmp/drivers" ]        && cp -r "$tmp/drivers"        "$root/configs/drivers"
    [ -d "$tmp/custom_drivers" ] && cp -r "$tmp/custom_drivers" "$root/configs/custom_drivers"

    printf '%s' "$confhome"         > "$root/configs/confhome"
    printf '%s' "$SCRIPT_VERSION"   > "$root/configs/script_version"
    printf '%s' "$iso"              > "$root/configs/iso_url"
    printf '%s' "$main_disk"        > "$root/configs/main_disk"
    printf '%s' "$image_name"       > "$root/configs/image_name"
    printf '%s' "$lang"             > "$root/configs/lang"
    printf '%s' "$password"         > "$root/configs/password-plaintext"
    printf '%s' "${hold:-0}"        > "$root/configs/hold"

    info false "Wrote /configs into initrd (trans.sh contract satisfied)"
}

build_initrd() {
    info "Building custom initrd"
    local initrd_dir="$tmp/initrd-work" out="$tmp/alpine/initrd-custom"

    rm -rf "$initrd_dir"; mkdir -p "$initrd_dir"
    (
        cd "$initrd_dir"
        zcat "$tmp/alpine/initrd" 2>/dev/null | cpio -idm 2>/dev/null ||
            xzcat "$tmp/alpine/initrd" 2>/dev/null | cpio -idm 2>/dev/null
    )

    curl_download -o "$initrd_dir/trans.sh" "$confhome/trans.sh" || {
        [ -f "$(dirname "$THIS_SCRIPT")/trans.sh" ] && cp "$(dirname "$THIS_SCRIPT")/trans.sh" "$initrd_dir/trans.sh"
    }
    chmod 755 "$initrd_dir/trans.sh"

    write_initrd_configs "$initrd_dir"

    # Alpine names NICs eth0 when net.ifnames=0 is on the cmdline.
    [ -n "${NET_IPV4_IFACE:-}" ] && NET_IPV4_IFACE=eth0
    [ -n "${NET_IPV6_IFACE:-}" ] && NET_IPV6_IFACE=eth0
    source "$(dirname "$THIS_SCRIPT")/initrd-network.sh" 2>/dev/null || source "$tmp/initrd-network.sh"
    mkdir -p "$initrd_dir/etc/network"
    write_initrd_network_config "$initrd_dir/etc/network/interfaces"
    write_dns_config "$initrd_dir/etc/resolv.conf"

    # Patch Alpine's /init so trans.sh actually RUNS after switch_root.
    if [ -f "$initrd_dir/init" ]; then
        insert_into_file "$initrd_dir/init" before '^exec switch_root' <<'HOOK'
# >>> HorusInstall: hand control to trans.sh inside the booted Alpine system
mkdir -p "$sysroot/etc/local.d" "$sysroot/iso-download"
cp /trans.sh "$sysroot/etc/local.d/trans.start"
chmod 755 "$sysroot/etc/local.d/trans.start"
cp -r /configs "$sysroot/" 2>/dev/null || true
ln -sf /etc/init.d/local "$sysroot/etc/runlevels/default/local" 2>/dev/null || true
# <<< HorusInstall
HOOK
        info false "Patched /init to launch trans.sh"
    else
        warn "Alpine /init not found — cannot hook trans.sh automatically."
    fi

    (cd "$initrd_dir" && find . | cpio -o -H newc 2>/dev/null | gzip > "$out")
    info false "Custom initrd ready"
}

# -----------------------------------------------------------------------------
# Bootloader
# -----------------------------------------------------------------------------
reset_grub_entry() {
    local cfg="${1:-}" f
    for f in /boot/grub2/grub.cfg /boot/grub/grub.cfg /boot/efi/EFI/horusinstall/grub.cfg; do
        [ -f "$f" ] && { cfg="$f"; break; }
    done
    [ -z "$cfg" ] && return 0
    sed -i "/${BOOT_ENTRY_START_MARK}/,/${BOOT_ENTRY_END_MARK}/d" "$cfg" 2>/dev/null || true
    rm -f /boot/horusinstall-vmlinuz /boot/horusinstall-initrd
    rm -rf /boot/efi/EFI/horusinstall

    if is_have_cmd efibootmgr; then
        efibootmgr 2>/dev/null | grep -i 'HorusInstall' | grep -oE 'Boot[0-9A-F]{4}' |
            while read -r b; do efibootmgr -b "${b#Boot}" -B 2>/dev/null || true; done
    fi
}

grub_cmdline() {
    echo "alpine_repo=http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main \
modloop=http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/${basearch}/netboot/modloop-${ALPINE_FLAVOUR} \
console=tty0 console=ttyS0,115200 net.ifnames=0 biosdevname=0 quiet \
finalos_iso=${iso} finalos_main_disk=${main_disk}"
}

setup_grub_bios() {
    info "Configuring GRUB (BIOS)"
    local cfg
    for f in /boot/grub2/grub.cfg /boot/grub/grub.cfg; do [ -f "$f" ] && { cfg="$f"; break; }; done
    [ -z "$cfg" ] && error_and_exit "Could not find GRUB config file."

    # Never overwrite the running kernel's /boot/vmlinuz.
    cp "$tmp/alpine/vmlinuz"       /boot/horusinstall-vmlinuz
    cp "$tmp/alpine/initrd-custom" /boot/horusinstall-initrd

    reset_grub_entry "$cfg"
    local cmdline entry
    cmdline=$(grub_cmdline)
    entry=$(cat <<EOF

${BOOT_ENTRY_START_MARK}
menuentry '${BOOT_ENTRY_TITLE}' {
    search --no-floppy --file --set=root /boot/horusinstall-vmlinuz
    linux  /boot/horusinstall-vmlinuz ${cmdline}
    initrd /boot/horusinstall-initrd
}
${BOOT_ENTRY_END_MARK}
EOF
)
    printf '%s\n' "$entry" | cat - "$cfg" > "$tmp/grub.cfg.new"
    cp "$tmp/grub.cfg.new" "$cfg"

    if is_have_cmd grub2-reboot; then    grub2-reboot "$BOOT_ENTRY_TITLE" 2>/dev/null || grub2-reboot 0
    elif is_have_cmd grub-reboot; then   grub-reboot "$BOOT_ENTRY_TITLE" 2>/dev/null || grub-reboot 0
    else warn "grub-reboot not available — select the entry manually at boot."; fi
}

setup_grub_efi() {
    info "Configuring GRUB (EFI)"
    local dir=/boot/efi/EFI/horusinstall
    mkdir -p "$dir"
    cp "$tmp/alpine/vmlinuz"          "$dir/vmlinuz"
    cp "$tmp/alpine/initrd-custom"    "$dir/initrd"

    local cmdline
    cmdline=$(grub_cmdline)
    cat > "$dir/grub.cfg" <<EOF
${BOOT_ENTRY_START_MARK}
set timeout=5
set default=0
menuentry '${BOOT_ENTRY_TITLE}' {
    search --no-floppy --file --set=root /EFI/horusinstall/vmlinuz
    linux  /EFI/horusinstall/vmlinuz ${cmdline}
    initrd /EFI/horusinstall/initrd
}
${BOOT_ENTRY_END_MARK}
EOF

    if is_have_cmd grub2-reboot; then    grub2-reboot "$BOOT_ENTRY_TITLE" 2>/dev/null || true
    elif is_have_cmd grub-reboot; then   grub-reboot "$BOOT_ENTRY_TITLE" 2>/dev/null || true; fi

    # EFI firmware boots an .efi APPLICATION, never a .cfg.
    # Register the distro's existing grubx64.efi and use BootNext for one shot.
    if is_have_cmd efibootmgr; then
        local efi_app="" d
        # Remove stale one-shot entry from a previous run.
        efibootmgr 2>/dev/null | grep -i 'HorusInstall (one-shot)' | grep -oE 'Boot[0-9A-F]{4}' |
            while read -r b; do efibootmgr -b "${b#Boot}" -B 2>/dev/null || true; done
        for d in /boot/efi/EFI/{debian,ubuntu,centos,redhat,fedora,rocky,almalinux,opensuse,horusinstall}; do
            [ -f "$d/grubx64.efi" ] && { efi_app="$d/grubx64.efi"; break; }
            [ -f "$d/BOOTX64.EFI" ] && { efi_app="$d/BOOTX64.EFI"; break; }
        done
        if [ -n "$efi_app" ]; then
            local rel="\\${efi_app#/boot/efi/}"
            rel="${rel//\//\\}"
            efibootmgr --create-only --disk "$(get_xda)" \
                --label 'HorusInstall (one-shot)' --loader "$rel" >/dev/null 2>&1 || true
            local id
            id=$(efibootmgr 2>/dev/null | grep -i 'HorusInstall (one-shot)' | grep -oE 'Boot[0-9A-F]{4}' | head -1)
            [ -n "$id" ] && efibootmgr --bootnext "${id#Boot}" >/dev/null 2>&1 || true
            info false "EFI BootNext registered -> $rel"
        else
            warn "No grubx64.efi found; rely on grub-reboot instead."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Main install flow
# -----------------------------------------------------------------------------
install_windows() {
    info "HorusInstall - Linux to Windows"
    is_in_container && error_and_exit "OpenVZ/LXC are not supported. Use KVM/XEN/VMware/bare metal."
    [ "$(id -u)" = 0 ] || error_and_exit "Run as root."

    detect_basearch
    mkdir -p "$tmp"
    collect_net_conf

    source_get_xda
    XDA=$(get_xda) || error_and_exit "Could not detect the target disk."
    export XDA
    print_disk_info "$XDA"
    assert_disk_size "$XDA" || error_and_exit "Disk too small."
    main_disk=$(get_disk_id "$XDA")
    info false "Disk: $XDA (PTUUID: $main_disk)"

    prompt_password

    [ -z "$iso" ] && find_windows_iso

    build_unattend_xml
    build_netconf_bat
    download_drivers
    download_alpine_netboot
    build_initrd

    info "Configuring bootloader"
    if is_efi; then setup_grub_efi; else setup_grub_bios; fi

    cat <<EOF

============================================================
  HorusInstall is ready.
  The system will reboot into Alpine, then Windows setup.

  Monitor:  ssh root@<ip> -p ${ssh_port:-22}
            http://<ip>:${web_port:-80}

  Cancel before rebooting:  bash reinstall.sh reset
============================================================
EOF
    read -rp "Press Enter to reboot now, or Ctrl+C to cancel... "
    reboot
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
parse_args() {
    [ $# -eq 0 ] && usage_and_exit
    local distro="$1"; shift

    case "$distro" in
        windows) ;;
        reset)
            info "Removing HorusInstall boot entries"
            reset_grub_entry
            rm -rf "$tmp"
            echo "Reset complete. Reboot normally."
            exit 0 ;;
        *) usage_and_exit ;;
    esac

    lang=en-us
    username=administrator
    ssh_port=22
    web_port=80
    rdp_port=3389
    allow_ping=0
    hold=0
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
            --hold)        hold="$2";        shift 2 ;;
            --hold=*)      hold="${1#*=}";   shift ;;
            --help|-h)     usage_and_exit ;;
            *) echo "Unknown option: $1"; usage_and_exit ;;
        esac
    done

    [ -z "$image_name" ] && error_and_exit "--image-name is required."
    is_port_valid "$ssh_port" || error_and_exit "Invalid SSH port: $ssh_port"
    is_port_valid "$rdp_port" || error_and_exit "Invalid RDP port: $rdp_port"
    is_port_valid "$web_port" || error_and_exit "Invalid web port: $web_port"

    lang=$(echo "$lang" | tr '[:upper:]' '[:lower:]')
    # Keep the original casing of image_name: /IMAGE/NAME matching is
    # case-insensitive, but preserving it avoids surprises on some ISOs.

    cat <<EOF
Configuration:
  Image    : $image_name
  Language : $lang
  Username : $username
  SSH port : $ssh_port
  RDP port : $rdp_port
  Web port : $web_port
  ISO      : ${iso:-auto-detect}
  Hold     : $hold
EOF
}

parse_args "$@"
install_windows
