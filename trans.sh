#!/bin/sh
# shellcheck shell=dash
# shellcheck disable=SC2086,SC3047,SC3036,SC3010,SC3001,SC3060,SC3015
# =============================================================================
# trans.sh
# HorusInstall - Linux to Windows reinstall tool
# Based on: github.com/bin456789/reinstall (GPL-3.0)
# Modified by: HorusHDx
#
# Runs ONCE inside the Alpine transitional environment booted by reinstall.sh.
# It reads /configs, finds the target disk by partition-table UUID, partitions
# it, stages the Windows ISO + unattend files, and configures the boot into
# WinPE. POSIX sh (BusyBox ash) only: no arrays, no [[ ]], no process subs.
# =============================================================================

set -eE

SCRIPT_VERSION=HORUS-2026-LTW-002

TRUE=0
FALSE=1
EFI_UUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
error() {
    echo -e "\e[31m***** ERROR *****\e[0m" >&2
    echo -e "\e[31m$*\e[0m" >&2
}
info() {
    if [ "$1" = false ]; then shift; echo -e "\e[32m$*\e[0m" >&2
    else echo -e "\e[32m***** $(echo "$*" | tr '[:lower:]' '[:upper:]') *****\e[0m" >&2; fi
}
warn() { echo -e "\e[33mWarning: $*\e[0m" >&2; }
error_and_exit() {
    error "$@"
    echo "Run '/trans.sh' to retry." >&2
    exit 1
}
trap_err() { error_and_exit "Line $1 returned exit code $2"; }
trap 'trap_err $LINENO $?' ERR

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
is_have_cmd() {
    for bin_dir in /bin /sbin /usr/bin /usr/sbin; do
        [ -f "$bin_dir/$1" ] && return 0
    done
    return 1
}
is_efi() { [ -d /sys/firmware/efi ]; }
to_upper() { tr '[:lower:]' '[:upper:]'; }
to_lower() { tr '[:upper:]' '[:lower:]'; }

retry() {
    local max=$1 interval=5 i ret
    shift
    for i in $(seq "$max"); do
        if "$@"; then return 0; fi
        ret=$?
        [ $ret -eq 141 ] && return 0
        [ "$i" -ge "$max" ] && return $ret
        sleep "$interval"
    done
}

apk() { retry 5 command apk "$@" >&2; }

wget() {
    for arg; do case "$arg" in http://*|https://*) echo "$arg" >&2 ;; esac; done
    if command wget 2>&1 | grep -q BusyBox; then
        retry 5 command wget "$@" -T 10
    else
        command wget --tries=5 --progress=bar:force "$@"
    fi
}

get_config() { cat "/configs/$1" 2>/dev/null; }
set_config() { printf '%s' "$2" > "/configs/$1"; }

# Install every tool this script needs, once, up front.
install_tools() {
    info "Installing transitional tools"
    apk add --no-cache util-linux sfdisk parted dosfstools >/dev/null
    apk add --no-cache openssh-server >/dev/null
}

add_community_repo() {
    local ver mirror
    if grep -q "^http.*/edge/main$" /etc/apk/repositories; then ver=edge
    elif grep -q "^http.*/latest-stable/main$" /etc/apk/repositories; then ver=latest-stable
    else ver=v$(cut -d. -f1,2 </etc/alpine-release); fi
    if ! grep -q "^http.*/$ver/community$" /etc/apk/repositories; then
        mirror=$(grep '^http.*/main$' /etc/apk/repositories | sed 's,/[^/]*/main$,,' | head -1)
        echo "$mirror/$ver/community" >> /etc/apk/repositories
    fi
}

# -----------------------------------------------------------------------------
# Kernel cmdline: finalos_KEY=VALUE / extra_KEY=VALUE
# -----------------------------------------------------------------------------
extract_env_from_cmdline() {
    local prefix line key val
    for prefix in finalos extra; do
        while read -r line; do
            [ -z "$line" ] && continue
            key=$(echo "$line" | cut -d= -f1)
            val=$(echo "$line" | cut -d= -f2-)
            eval "${key}='${val}'"
        done <<CMDEOF
$(xargs -n1 </proc/cmdline | grep "^${prefix}_" | sed "s/^${prefix}_//")
CMDEOF
    done
    username=${username:-administrator}
    ssh_port=${ssh_port:-22}
    rdp_port=${rdp_port:-3389}
    web_port=${web_port:-80}
}

# -----------------------------------------------------------------------------
# Disk detection by partition-table UUID (PTUUID / disk-id)
# -----------------------------------------------------------------------------
get_all_disks() { ls /sys/block/ | grep -Ev '^(loop|sr|nbd|ram|zram)'; }

find_xda() {
    if xda=$(get_config xda) && [ -n "$xda" ]; then return; fi
    [ -z "$main_disk" ] && error_and_exit "cmdline parameter 'main_disk' is empty."

    # Accept a device path too (legacy compatibility).
    case "$main_disk" in
        /dev/*)
            local d=${main_disk#/dev/}
            main_disk=$(sfdisk --disk-id "/dev/$d" 2>/dev/null | sed 's/^0x//')
            ;;
    esac

    local disk
    for disk in $(get_all_disks); do
        if sfdisk --disk-id "/dev/$disk" 2>/dev/null | sed 's/^0x//' | grep -ix "$main_disk"; then
            xda="$disk"
            break
        fi
    done

    [ -z "$xda" ] && error_and_exit "Could not find target disk with PTUUID: $main_disk"
    set_config xda "$xda"
}

# -----------------------------------------------------------------------------
# Partitioning
#   EFI (GPT): 1=ESP(100M) 2=MSR(16M) 3=installer 4=Windows
#   BIOS(MBR): 1=installer 2=Windows
# -----------------------------------------------------------------------------
is_4kn_disk() {
    local ss
    ss=$(cat "/sys/block/${xda}/queue/physical_block_size" 2>/dev/null || echo 512)
    [ "$ss" -ge 4096 ]
}

update_partition_table() {
    sleep 1; sync
    is_have_cmd partprobe && partprobe "/dev/$xda" 2>/dev/null || true
    is_have_cmd partx && partx -u "/dev/$xda" 2>/dev/null || true
    mdev -sf 2>/dev/null || true
    sleep 1
}

partition_disk() {
    info "Partitioning /dev/$xda"

    local disk_size_mb iso_size_mb=0 f sz need_ntfs=0
    disk_size_mb=$(( $(lsblk -b -dn -o SIZE "/dev/$xda") / 1024 / 1024 ))

    if [ -f "$iso_path" ]; then
        iso_size_mb=$(( $(stat -c %s "$iso_path") / 1024 / 1024 + 400 ))
    else
        iso_size_mb=5500
    fi
    [ "$iso_size_mb" -lt 4096 ] && iso_size_mb=4096

    # FAT32 cannot store files >4 GiB (modern install.wim often exceeds that).
    if [ -d "$ISO_MOUNT" ]; then
        for f in "$ISO_MOUNT/sources/install.wim" "$ISO_MOUNT/sources/install.esd"; do
            [ -f "$f" ] || continue
            sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
            if [ "$sz" -gt 4294967295 ]; then need_ntfs=1; fi
        done
    fi

    if is_efi; then
        local esp_end=101
        is_4kn_disk && esp_end=261   # 4Kn needs a 260 MiB ESP

        parted -s "/dev/$xda" -- \
            mklabel gpt \
            mkpart EFI   fat32  1MiB      "${esp_end}MiB" \
            mkpart MSR          "${esp_end}MiB" "$((esp_end+16))MiB" \
            mkpart installer   "$((esp_end+16))MiB" "${iso_size_mb}MiB" \
            mkpart windows     "${iso_size_mb}MiB" 100%
        parted -s "/dev/$xda" set 1 esp on
        parted -s "/dev/$xda" set 2 msftres on

        update_partition_table

        mkfs.fat -F 32 "/dev/${xda}1"
        if [ "$need_ntfs" = 1 ]; then
            apk add --no-cache ntfs-3g >/dev/null
            mkfs.ntfs -f -F "/dev/${xda}3"
            INSTALLER_FSTYPE=ntfs
        else
            mkfs.fat -F 32 "/dev/${xda}3"
            INSTALLER_FSTYPE=fat32
        fi

        EFI_PART=/dev/${xda}1
        INSTALLER_PART=/dev/${xda}3
        WINDOWS_PART=/dev/${xda}4
        INSTALLER_PART_NUM=3
    else
        parted -s "/dev/$xda" -- \
            mklabel msdos \
            mkpart primary fat32 1MiB "${iso_size_mb}MiB" \
            mkpart primary       "${iso_size_mb}MiB" 100%
        parted -s "/dev/$xda" set 1 boot on
        update_partition_table

        if [ "$need_ntfs" = 1 ]; then
            apk add --no-cache ntfs-3g >/dev/null
            mkfs.ntfs -f -F "/dev/${xda}1"
            INSTALLER_FSTYPE=ntfs
        else
            mkfs.fat -F 32 "/dev/${xda}1"
            INSTALLER_FSTYPE=fat32
        fi

        EFI_PART=""
        INSTALLER_PART=/dev/${xda}1
        WINDOWS_PART=/dev/${xda}2
        INSTALLER_PART_NUM=1
    fi

    info false "Installer filesystem: $INSTALLER_FSTYPE"
    lsblk "/dev/$xda"
}

# -----------------------------------------------------------------------------
# ISO
# -----------------------------------------------------------------------------
mount_iso() {
    info "Mounting Windows ISO"
    ISO_MOUNT=/iso
    mkdir -p "$ISO_MOUNT"
    if ! mount -o loop,ro "$iso_path" "$ISO_MOUNT" 2>/dev/null; then
        mount -t iso9660 -o loop,ro "$iso_path" "$ISO_MOUNT"
    fi
}
umount_iso() { umount "$ISO_MOUNT" 2>/dev/null || true; rmdir "$ISO_MOUNT" 2>/dev/null || true; }

download_iso() {
    info "Downloading Windows ISO from $iso"
    iso_path=/iso-download/windows.iso
    mkdir -p "$(dirname "$iso_path")"
    if echo "$iso" | grep -q '^magnet:'; then
        apk add --no-cache aria2 >/dev/null
        aria2c --dir="$(dirname "$iso_path")" --out="$(basename "$iso_path")" "$iso"
    else
        apk add --no-cache aria2 >/dev/null
        retry 5 aria2c \
            --dir="$(dirname "$iso_path")" \
            --out="$(basename "$iso_path")" \
            --max-connection-per-server=4 --split=4 \
            --file-allocation=none --user-agent="curl/7.54.1" \
            "$iso" || wget "$iso" -O "$iso_path"
    fi
    [ -s "$iso_path" ] || error_and_exit "ISO download failed (empty file)."
}

# -----------------------------------------------------------------------------
# Stage the installer partition
# -----------------------------------------------------------------------------
prepare_installer_partition() {
    info "Preparing installer partition"
    local inst_mount=/installer
    mkdir -p "$inst_mount"
    mount "$INSTALLER_PART" "$inst_mount"

    info false "Copying ISO contents (this may take a while)"
    cp -a "$ISO_MOUNT/." "$inst_mount/"

    [ -f "$inst_mount/setup.exe" ] && mv "$inst_mount/setup.exe" "$inst_mount/setup.exe.disabled"

    info false "Copying HorusInstall automation files"
    if [ -f /configs/windows-setup.bat ]; then
        cp /configs/windows-setup.bat "$inst_mount/windows-setup.bat"
    else
        wget "$confhome/windows-setup.bat" -O "$inst_mount/windows-setup.bat"
    fi
    cp /configs/windows.xml              "$inst_mount/windows.xml"
    cp /configs/windows-set-netconf.bat  "$inst_mount/windows-set-netconf.bat"

    if is_4kn_disk; then
        sed -i 's/set is4kn=0/set is4kn=1/' "$inst_mount/windows-setup.bat"
    fi

    [ -d /configs/drivers ] && [ -n "$(ls /configs/drivers 2>/dev/null)" ] && {
        mkdir -p "$inst_mount/drivers"
        cp -r /configs/drivers/. "$inst_mount/drivers/"
    }
    [ -d /configs/custom_drivers ] && [ -n "$(ls /configs/custom_drivers 2>/dev/null)" ] && {
        mkdir -p "$inst_mount/custom_drivers"
        cp -r /configs/custom_drivers/. "$inst_mount/custom_drivers/"
    }

    umount "$inst_mount"
    rmdir "$inst_mount"
}

# -----------------------------------------------------------------------------
# Boot into WinPE
# -----------------------------------------------------------------------------
configure_bootloader_efi() {
    info "Configuring EFI bootloader"
    local efi_mount=/efi inst_mount=/installer_tmp bootmgr_src bcd_src fonts_src disk_dev part_num=1
    mkdir -p "$efi_mount" "$inst_mount"
    mount "$EFI_PART" "$efi_mount"
    mount -o ro "$INSTALLER_PART" "$inst_mount"

    mkdir -p "$efi_mount/EFI/Boot" "$efi_mount/EFI/Microsoft/Boot"

    bootmgr_src=$(find "$inst_mount/efi" -iname 'bootmgfw.efi' 2>/dev/null | head -1)
    [ -z "$bootmgr_src" ] && bootmgr_src=$(find "$inst_mount" -iname 'bootmgfw.efi' 2>/dev/null | head -1)
    [ -n "$bootmgr_src" ] && {
        cp "$bootmgr_src" "$efi_mount/EFI/Boot/bootx64.efi"
        cp "$bootmgr_src" "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi"
    } || error_and_exit "bootmgfw.efi not found in the ISO."

    bcd_src=$(find "$inst_mount" -iname 'BCD' 2>/dev/null | head -1)
    [ -n "$bcd_src" ] && cp "$bcd_src" "$efi_mount/EFI/Microsoft/Boot/BCD"

    fonts_src=$(find "$inst_mount" -type d -iname 'Fonts' 2>/dev/null | head -1)
    [ -n "$fonts_src" ] && cp -r "$fonts_src" "$efi_mount/EFI/Microsoft/Boot/"

    umount "$efi_mount"; umount "$inst_mount"
    rmdir "$efi_mount" "$inst_mount"

    if is_have_cmd efibootmgr; then
        efibootmgr 2>/dev/null | grep -i 'HorusInstall Windows Setup' | grep -oE 'Boot[0-9A-F]{4}' |
            while read -r b; do efibootmgr -b "${b#Boot}" -B 2>/dev/null || true; done

        disk_dev="/dev/${xda}"
        efibootmgr --create-only -d "$disk_dev" -p "$part_num" \
            -L 'HorusInstall Windows Setup' -l '\\EFI\\Boot\\bootx64.efi' 2>/dev/null ||
            warn "efibootmgr failed — set the boot order manually if needed."

        local id
        id=$(efibootmgr 2>/dev/null | grep -i 'HorusInstall Windows Setup' | grep -oE 'Boot[0-9A-F]{4}' | head -1)
        [ -n "$id" ] && efibootmgr --bootnext "${id#Boot}" 2>/dev/null || true
    fi
}

configure_bootloader_bios() {
    info "Configuring BIOS bootloader"
    apk add --no-cache syslinux >/dev/null

    dd if=/usr/share/syslinux/mbr.bin of="/dev/$xda" bs=440 count=1 conv=notrunc
    syslinux --install "/dev/${xda}${INSTALLER_PART_NUM}" 2>/dev/null ||
        syslinux "/dev/${xda}${INSTALLER_PART_NUM}"

    local inst_mount=/installer_syslinux
    mkdir -p "$inst_mount"
    mount "$INSTALLER_PART" "$inst_mount"
    cp /usr/share/syslinux/chain.c32      "$inst_mount/" 2>/dev/null || true
    cp /usr/share/syslinux/libcom32.c32   "$inst_mount/" 2>/dev/null || true
    cp /usr/share/syslinux/libutil.c32    "$inst_mount/" 2>/dev/null || true

    local bootmgr_name="bootmgr"
    bootmgr_name=$(basename "$(find "$inst_mount" -maxdepth 1 -iname 'bootmgr' 2>/dev/null | head -1)" | to_lower)
    [ -z "$bootmgr_name" ] && bootmgr_name=bootmgr

    local chain_args="fs ${bootmgr_name}"
    [ "$INSTALLER_FSTYPE" = ntfs ] && chain_args="boot"

    cat > "$inst_mount/syslinux.cfg" <<EOF
DEFAULT windows
TIMEOUT 30
PROMPT 0

LABEL windows
  MENU LABEL HorusInstall - Windows Setup
  COM32 chain.c32
  APPEND ${chain_args}
EOF
    umount "$inst_mount"; rmdir "$inst_mount"
    apk del syslinux >/dev/null 2>&1 || true
}

configure_bootloader() {
    if is_efi; then configure_bootloader_efi; else configure_bootloader_bios; fi
}

# -----------------------------------------------------------------------------
# Monitoring endpoints
# -----------------------------------------------------------------------------
setup_ssh() {
    info "Setting up SSH monitoring"
    apk add --no-cache shadow >/dev/null 2>&1 || true
    ssh-keygen -A 2>/dev/null || true
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    [ -n "$ssh_port" ] && [ "$ssh_port" != 22 ] &&
        sed -i "s/^#Port 22/Port $ssh_port/" /etc/ssh/sshd_config
    if [ -f /configs/password-plaintext ]; then
        local pass
        pass=$(cat /configs/password-plaintext)
        echo "root:${pass}" | chpasswd 2>/dev/null || true
    fi
    /usr/sbin/sshd 2>/dev/null || rc-service sshd start 2>/dev/null || true
    info false "SSH on port ${ssh_port:-22}"
}

setup_web_log() {
    local total_ram
    total_ram=$(free -m | awk 'NR==2{print $2}')
    if [ "$total_ram" -lt 400 ]; then
        warn "Low RAM (${total_ram}MB) — skipping web log viewer."
        return
    fi
    info "Starting web log viewer on port ${web_port:-80}"
    apk add --no-cache websocketd coreutils >/dev/null 2>&1 || {
        warn "websocketd unavailable — web viewer disabled (SSH still works)."
        return
    }
    if [ ! -s /tmp/index.html ]; then
        wget "$confhome/logviewer.html" -O /tmp/index.html 2>/dev/null || true
    fi
    pkill websocketd 2>/dev/null || true
    websocketd --port "${web_port:-80}" --loglevel=fatal --staticdir=/tmp \
        stdbuf -oL -eL sh -c \
        "tail -fn+0 /reinstall.log | tr '\\r' '\\n' | grep -Fiv password" &
    info false "Web viewer: http://<ip>:${web_port:-80}"
}

# -----------------------------------------------------------------------------
# Config / environment / main
# -----------------------------------------------------------------------------
init_log() {
    # NOTE: process substitution (> >(tee ...)) is NOT supported by ash.
    # We log to a file; monitor it via SSH (tail -f) or the web viewer.
    : > /reinstall.log
    exec > /reinstall.log 2>&1
    echo "============================================"
    echo "  HorusInstall trans.sh started - $(date)"
    echo "============================================"
}

verify_environment() {
    [ -f /etc/alpine-release ] || error_and_exit "trans.sh must run inside Alpine."
    if [ -f /configs/script_version ]; then
        local expected
        expected=$(cat /configs/script_version)
        [ "$expected" = "$SCRIPT_VERSION" ] || error_and_exit "Script version mismatch: expected '$expected', got '$SCRIPT_VERSION'."
    fi
}

load_config() {
    confhome=$(get_config confhome); confhome=${confhome:-https://raw.githubusercontent.com/HorusHDx/HorusInstall/main}
    iso=$(get_config iso_url)
    main_disk=$(get_config main_disk)
    image_name=$(get_config image_name)
    lang=$(get_config lang); lang=${lang:-en-us}
    hold=$(get_config hold); hold=${hold:-0}
}

clear_previous() {
    umount /iso       2>/dev/null || true
    umount /installer 2>/dev/null || true
    umount /efi       2>/dev/null || true
    swapoff -a        2>/dev/null || true
    killall aria2c    2>/dev/null || true
}

main() {
    init_log
    verify_environment
    info "HorusInstall trans.sh starting"
    echo "Alpine: $(cat /etc/alpine-release) / $(uname -m)"

    clear_previous
    extract_env_from_cmdline
    load_config

    if [ "$hold" = 1 ]; then
        info "HOLD=1 — boot environment is ready. Dropping to a shell."
        echo "Run '/trans.sh' manually when you are ready."
        exec /bin/sh
    fi

    add_community_repo
    install_tools

    setup_ssh
    setup_web_log

    find_xda
    info "Target disk: /dev/$xda (PTUUID $main_disk)"
    lsblk "/dev/$xda" 2>/dev/null || true

    if [ -n "$iso" ]; then
        download_iso
    elif [ -f /configs/windows.iso ]; then
        iso_path=/configs/windows.iso
        info "Using pre-staged ISO: $iso_path"
    else
        error_and_exit "No ISO URL and no /configs/windows.iso. Check /configs/iso_url."
    fi

    mount_iso
    partition_disk
    prepare_installer_partition
    umount_iso
    configure_bootloader

    info "trans.sh complete - rebooting into the Windows installer"
    sleep 5
    reboot
}

main "$@"
