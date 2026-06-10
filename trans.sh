#!/bin/ash
# shellcheck shell=dash
# shellcheck disable=SC2086,SC3047,SC3036,SC3010,SC3001,SC3060,SC3015
# =============================================================================
# trans.sh
# HorusInstall - Linux to Windows reinstall tool
# Based on: github.com/bin456789/reinstall (GPL-3.0)
# Modified by: HorusHDx
#
# Purpose: Runs inside the Alpine Linux initrd transitional environment
#          (booted by GRUB before Windows is installed).
#
#          This script is the bridge between the running Linux system and
#          the Windows installer. It:
#            1. Reads the target configuration from the kernel cmdline
#            2. Identifies the target disk (xda)
#            3. Creates the disk partition layout (EFI or BIOS)
#            4. Downloads or mounts the Windows ISO
#            5. Extracts boot.wim from the ISO and sets up the WinPE partition
#            6. Copies the unattend XML, net config bat, and drivers to the
#               WinPE RAM disk staging area
#            7. Configures the BCD / GRUB to boot into WinPE
#            8. Reboots into Windows setup
#
# This script uses ash (BusyBox), not bash.
# Syntax is POSIX-compatible (no [[ ]], no arrays, no local -n, etc.)
#
# Script version must match reinstall.sh
# =============================================================================

set -eE

SCRIPT_VERSION=HORUS-2026-LTW-001

TRUE=0
FALSE=1
EFI_UUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B

# =============================================================================
# Logging
# =============================================================================
error() {
    echo -e "\e[31m***** ERROR *****\e[0m" >&2
    echo -e "\e[31m$*\e[0m" >&2
}

info() {
    local msg
    if [ "$1" = false ]; then
        shift
        msg="$*"
    else
        msg=$(echo "$*" | tr '[:lower:]' '[:upper:]')
    fi
    echo -e "\e[32m***** $msg *****\e[0m" >&2
}

warn() {
    echo -e "\e[33mWarning: $*\e[0m" >&2
}

error_and_exit() {
    error "$@"
    echo "Run '/trans.sh' to retry." >&2
    exit 1
}

trap_err() {
    local line_no=$1
    local ret_no=$2
    error_and_exit "Line $line_no returned exit code $ret_no"
}

trap 'trap_err $LINENO $?' ERR

# =============================================================================
# Utility
# =============================================================================
is_have_cmd() {
    for bin_dir in /bin /sbin /usr/bin /usr/sbin; do
        [ -f "$bin_dir/$1" ] && return 0
    done
    return 1
}

is_efi() {
    [ -d /sys/firmware/efi ]
}

to_upper() { tr '[:lower:]' '[:upper:]'; }
to_lower() { tr '[:upper:]' '[:lower:]'; }

# Add Alpine community repo if not present
add_community_repo() {
    local ver mirror
    if grep -q "^http.*/edge/main$" /etc/apk/repositories; then
        ver=edge
    elif grep -q "^http.*/latest-stable/main$" /etc/apk/repositories; then
        ver=latest-stable
    else
        ver=v$(cut -d. -f1,2 </etc/alpine-release)
    fi
    if ! grep -q "^http.*/$ver/community$" /etc/apk/repositories; then
        mirror=$(grep '^http.*/main$' /etc/apk/repositories | sed 's,/[^/]*/main$,,' | head -1)
        echo "$mirror/$ver/community" >> /etc/apk/repositories
    fi
}

apk() {
    retry 5 command apk "$@" >&2
}

retry() {
    local max=$1; shift
    local interval=5
    local i ret
    for i in $(seq "$max"); do
        if "$@"; then return 0; fi
        ret=$?
        [ $ret -eq 141 ] && return 0
        [ "$i" -ge "$max" ] && return $ret
        sleep "$interval"
    done
}

wget() {
    # Show URL in logs
    for arg; do
        case "$arg" in
            http://*|https://*) echo "$arg" >&2 ;;
        esac
    done

    if command wget 2>&1 | grep -q BusyBox; then
        retry 5 command wget "$@" -T 10
    else
        command wget --tries=5 --progress=bar:force "$@"
    fi
}

get_config() { cat "/configs/$1"; }
set_config() { printf '%s' "$2" > "/configs/$1"; }

# =============================================================================
# Read kernel cmdline parameters
# Variables are passed as: finalos_KEY=VALUE extra_KEY=VALUE
# =============================================================================
extract_env_from_cmdline() {
    for prefix in finalos extra; do
        while read -r line; do
            if [ -n "$line" ]; then
                local key val
                key=$(echo "$line" | cut -d= -f1)
                val=$(echo "$line" | cut -d= -f2-)
                eval "${key}='${val}'"
            fi
        done <<CMDEOF
$(xargs -n1 </proc/cmdline | grep "^${prefix}_" | sed "s/^${prefix}_//")
CMDEOF
    done

    # Defaults
    username=${username:-administrator}
    ssh_port=${ssh_port:-22}
    rdp_port=${rdp_port:-3389}
    web_port=${web_port:-80}
}

# =============================================================================
# Disk detection
# Finds the target disk (xda) by matching the partition table UUID/ID
# that reinstall.sh recorded in the kernel cmdline as main_disk=...
# =============================================================================
find_xda() {
    # If we already found it in a previous run, reuse it
    if xda=$(get_config xda 2>/dev/null) && [ -n "$xda" ]; then
        return
    fi

    if [ -z "$main_disk" ]; then
        error_and_exit "Kernel cmdline parameter 'main_disk' is empty."
    fi

    apk add sfdisk

    for disk in $(get_all_disks); do
        if sfdisk --disk-id "/dev/$disk" | sed 's/0x//' | grep -ix "$main_disk"; then
            xda="$disk"
            break
        fi
    done

    apk del sfdisk

    if [ -n "$xda" ]; then
        set_config xda "$xda"
    else
        error_and_exit "Could not find target disk matching id: $main_disk"
    fi
}

get_all_disks() {
    ls /sys/block/ | grep -Ev '^(loop|sr|nbd)'
}

# =============================================================================
# Partition and format the target disk
#
# EFI layout (GPT):
#   Part 1 : EFI System Partition  (FAT32, 100 MB)
#   Part 2 : Microsoft Reserved    (16 MB)
#   Part 3 : Installer partition   (FAT32, ISO size + 300 MB overhead)
#   Part 4 : Windows OS partition  (NTFS, remainder)
#
# BIOS layout (MBR):
#   Part 1 : Installer partition   (FAT32, ISO size + 300 MB overhead)
#   Part 2 : Windows OS partition  (NTFS, remainder)
#
# The installer partition holds boot.wim and the Windows setup files.
# Windows will be installed onto the OS partition.
# After installation, the installer partition can be repurposed or deleted.
# =============================================================================
partition_disk() {
    info "Partitioning disk /dev/$xda"

    local disk_size_mb
    disk_size_mb=$(( $(lsblk -b -dn -o SIZE "/dev/$xda") / 1024 / 1024 ))

    # Installer partition size: ISO size + 300 MB for WinPE overhead
    local iso_size_mb=0
    if [ -f "$iso_path" ]; then
        iso_size_mb=$(( $(stat -c %s "$iso_path") / 1024 / 1024 + 300 ))
    else
        # Estimate: typical Windows ISO is ~5 GB
        iso_size_mb=5500
    fi

    # Ensure minimum installer partition size
    [ "$iso_size_mb" -lt 4096 ] && iso_size_mb=4096

    if is_efi; then
        # GPT layout
        parted -s "/dev/$xda" -- \
            mklabel gpt \
            mkpart EFI fat32    1MiB    101MiB \
            mkpart MSR          16MiB   117MiB \
            mkpart installer fat32 117MiB "${iso_size_mb}MiB" \
            mkpart windows  ntfs  "${iso_size_mb}MiB" 100%

        # Set partition flags
        parted -s "/dev/$xda" set 1 esp on
        parted -s "/dev/$xda" set 2 msftres on

        update_partition_table

        # Format
        mkfs.fat -F 32 "/dev/${xda}1"
        mkfs.fat -F 32 "/dev/${xda}3"   # installer — FAT32 for WinPE
        # Part 4 (Windows) will be formatted by Windows setup itself

        EFI_PART="/dev/${xda}1"
        INSTALLER_PART="/dev/${xda}3"
        WINDOWS_PART="/dev/${xda}4"
        INSTALLER_PART_NUM=3
    else
        # MBR layout
        parted -s "/dev/$xda" -- \
            mklabel msdos \
            mkpart primary fat32  1MiB "${iso_size_mb}MiB" \
            mkpart primary ntfs  "${iso_size_mb}MiB" 100%

        parted -s "/dev/$xda" set 1 boot on

        update_partition_table

        mkfs.fat -F 32 "/dev/${xda}1"
        # Part 2 (Windows) formatted by Windows setup

        EFI_PART=""
        INSTALLER_PART="/dev/${xda}1"
        WINDOWS_PART="/dev/${xda}2"
        INSTALLER_PART_NUM=1
    fi

    info "Disk partitioned successfully"
    lsblk "/dev/$xda"
}

update_partition_table() {
    sleep 1
    sync

    if is_have_cmd partprobe; then
        partprobe "/dev/$xda" 2>/dev/null || true
    fi

    if is_have_cmd partx; then
        partx -u "/dev/$xda"
    fi

    # Refresh /dev/disk symlinks via mdev
    mdev -sf 2>/dev/null || true
    sleep 1
}

# =============================================================================
# Mount the Windows ISO and extract files needed for the installer partition
# =============================================================================
mount_iso() {
    info "Mounting Windows ISO"

    ISO_MOUNT=/iso
    mkdir -p "$ISO_MOUNT"

    if ! mount -o loop,ro "$iso_path" "$ISO_MOUNT" 2>/dev/null; then
        # BusyBox mount may need explicit type
        mount -t iso9660 -o loop,ro "$iso_path" "$ISO_MOUNT"
    fi

    echo "ISO mounted at $ISO_MOUNT"
}

umount_iso() {
    umount "$ISO_MOUNT" 2>/dev/null || true
    rmdir "$ISO_MOUNT" 2>/dev/null || true
}

# =============================================================================
# Prepare the installer partition (WinPE staging area)
#
# The installer partition is what Windows PE sees as Y:\
# It must contain:
#   sources/boot.wim  — the WinPE image
#   sources/install.wim (or .esd) — the Windows edition images
#   bootmgr / bootmgr.efi / BCD — boot manager files
#   windows-setup.bat — our setup automation script
#   windows.xml — the unattend answer file
#   windows-set-netconf.bat — static IP configuration
#   drivers/ — injected drivers
#   custom_drivers/ — user-supplied drivers
# =============================================================================
prepare_installer_partition() {
    info "Preparing installer partition"

    local inst_mount=/installer
    mkdir -p "$inst_mount"
    mount "$INSTALLER_PART" "$inst_mount"

    # Copy all ISO content to the installer partition
    # This includes boot.wim, install.wim/esd, bootmgr, and setup files
    info "Copying ISO contents to installer partition (this may take a while)"
    cp -a "$ISO_MOUNT/." "$inst_mount/"

    # Rename setup.exe to prevent auto-launch (windows-setup.bat controls when it runs)
    if [ -f "$inst_mount/setup.exe" ]; then
        mv "$inst_mount/setup.exe" "$inst_mount/setup.exe.disabled"
    fi

    # Copy our automation scripts
    info "Copying HorusInstall scripts"

    # windows-setup.bat — main WinPE automation
    if [ -f "/configs/windows-setup.bat" ]; then
        cp /configs/windows-setup.bat "$inst_mount/windows-setup.bat"
    else
        wget "$confhome/windows-setup.bat" -O "$inst_mount/windows-setup.bat"
    fi

    # windows.xml — unattend answer file (already has placeholders replaced)
    cp /configs/windows.xml "$inst_mount/windows.xml"

    # windows-set-netconf.bat — static IP config (already has vars injected)
    cp /configs/windows-set-netconf.bat "$inst_mount/windows-set-netconf.bat"

    # Inject 4Kn flag into windows-setup.bat
    if is_4kn_disk; then
        sed -i 's/set is4kn=0/set is4kn=1/' "$inst_mount/windows-setup.bat"
    fi

    # Copy drivers
    if [ -d /configs/drivers ] && [ -n "$(ls /configs/drivers 2>/dev/null)" ]; then
        info "Copying drivers"
        mkdir -p "$inst_mount/drivers"
        cp -r /configs/drivers/. "$inst_mount/drivers/"
    fi

    # Copy custom drivers (--add-driver)
    if [ -d /configs/custom_drivers ] && [ -n "$(ls /configs/custom_drivers 2>/dev/null)" ]; then
        info "Copying custom drivers"
        mkdir -p "$inst_mount/custom_drivers"
        cp -r /configs/custom_drivers/. "$inst_mount/custom_drivers/"
    fi

    umount "$inst_mount"
    rmdir "$inst_mount"

    info "Installer partition ready"
}

# =============================================================================
# Check if the target disk uses 4K native sector size (4Kn)
# 4Kn disks require a 260 MB EFI partition instead of 100 MB
# =============================================================================
is_4kn_disk() {
    local sector_size
    sector_size=$(cat "/sys/block/${xda}/queue/physical_block_size" 2>/dev/null || echo 512)
    [ "$sector_size" -ge 4096 ]
}

# =============================================================================
# Configure BCD (Boot Configuration Data) to boot into WinPE on next boot
#
# For EFI: copy bootmgr.efi to the EFI partition and register with efibootmgr
# For BIOS: write the MBR bootloader that points to the installer partition
# =============================================================================
configure_bootloader() {
    info "Configuring bootloader for WinPE"

    if is_efi; then
        configure_bootloader_efi
    else
        configure_bootloader_bios
    fi
}

configure_bootloader_efi() {
    local efi_mount=/efi
    local inst_mount=/installer_tmp

    mkdir -p "$efi_mount" "$inst_mount"
    mount "$EFI_PART" "$efi_mount"
    mount -o ro "$INSTALLER_PART" "$inst_mount"

    # Create EFI directory structure
    mkdir -p "$efi_mount/EFI/Boot"
    mkdir -p "$efi_mount/EFI/Microsoft/Boot"

    # Copy bootmgr.efi
    local bootmgr_src
    # Case-insensitive search for bootmgr.efi
    bootmgr_src=$(find "$inst_mount/efi" -iname "bootmgfw.efi" 2>/dev/null | head -1)

    if [ -z "$bootmgr_src" ]; then
        bootmgr_src=$(find "$inst_mount" -iname "bootmgfw.efi" 2>/dev/null | head -1)
    fi

    if [ -n "$bootmgr_src" ]; then
        cp "$bootmgr_src" "$efi_mount/EFI/Boot/bootx64.efi"
        cp "$bootmgr_src" "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi"
    fi

    # Copy BCD store
    local bcd_src
    bcd_src=$(find "$inst_mount" -iname "BCD" 2>/dev/null | head -1)
    if [ -n "$bcd_src" ]; then
        mkdir -p "$efi_mount/EFI/Microsoft/Boot"
        cp "$bcd_src" "$efi_mount/EFI/Microsoft/Boot/BCD"
    fi

    # Copy boot fonts
    local fonts_src
    fonts_src=$(find "$inst_mount" -type d -iname "Fonts" 2>/dev/null | head -1)
    if [ -n "$fonts_src" ]; then
        cp -r "$fonts_src" "$efi_mount/EFI/Microsoft/Boot/"
    fi

    umount "$efi_mount"
    umount "$inst_mount"
    rmdir "$efi_mount" "$inst_mount"

    # Register with EFI boot manager
    if is_have_cmd efibootmgr; then
        # Remove old HorusInstall entries
        efibootmgr | grep -i HorusInstall | grep -oP 'Boot\K[0-9A-F]+' | while read -r num; do
            efibootmgr -b "$num" -B 2>/dev/null || true
        done

        # Add new entry
        local disk_dev="/dev/${xda}"
        local part_num="1"   # EFI is always partition 1

        efibootmgr -c \
            -d "$disk_dev" \
            -p "$part_num" \
            -L "HorusInstall Windows Setup" \
            -l "\\EFI\\Boot\\bootx64.efi" 2>/dev/null || \
            warn "efibootmgr failed — you may need to manually set boot order."

        # Set as next boot only
        local new_entry
        new_entry=$(efibootmgr | grep -i HorusInstall | grep -oP 'Boot\K[0-9A-F]+' | head -1)
        [ -n "$new_entry" ] && efibootmgr -n "$new_entry" 2>/dev/null || true
    fi

    info "EFI bootloader configured"
}

configure_bootloader_bios() {
    apk add syslinux

    # Install syslinux MBR to the disk
    dd if=/usr/share/syslinux/mbr.bin of="/dev/$xda" bs=440 count=1 conv=notrunc

    # Install syslinux to the installer partition
    syslinux --install "/dev/${xda}${INSTALLER_PART_NUM}" 2>/dev/null || \
        syslinux "/dev/${xda}${INSTALLER_PART_NUM}"

    # Mount installer partition and create syslinux config
    local inst_mount=/installer_syslinux
    mkdir -p "$inst_mount"
    mount "$INSTALLER_PART" "$inst_mount"

    # Copy syslinux files needed for boot
    cp /usr/share/syslinux/chain.c32      "$inst_mount/" 2>/dev/null || true
    cp /usr/share/syslinux/libcom32.c32   "$inst_mount/" 2>/dev/null || true
    cp /usr/share/syslinux/libutil.c32    "$inst_mount/" 2>/dev/null || true

    # Find bootmgr on the installer partition
    local bootmgr_path
    bootmgr_path=$(find "$inst_mount" -maxdepth 1 -iname "bootmgr" 2>/dev/null | head -1)
    local bootmgr_name
    bootmgr_name=$(basename "$bootmgr_path" | tr '[:upper:]' '[:lower:]')

    # Create syslinux.cfg that chainloads Windows bootmgr
    cat > "$inst_mount/syslinux.cfg" <<EOF
DEFAULT windows
TIMEOUT 30
PROMPT 0

LABEL windows
  MENU LABEL HorusInstall - Windows Setup
  COM32 chain.c32
  APPEND fs ${bootmgr_name:-bootmgr}
EOF

    umount "$inst_mount"
    rmdir "$inst_mount"

    apk del syslinux

    info "BIOS/syslinux bootloader configured"
}

# =============================================================================
# Download the Windows ISO
# The URL was set in the kernel cmdline by reinstall.sh as:
#   finalos_iso=https://...
# =============================================================================
download_iso() {
    info "Downloading Windows ISO"
    info false "URL: $iso"

    iso_path=/iso-download/windows.iso
    mkdir -p "$(dirname "$iso_path")"

    if echo "$iso" | grep -q '^magnet:'; then
        apk add aria2
        aria2c --dir="$(dirname "$iso_path")" \
               --out="$(basename "$iso_path")" \
               "$iso"
    else
        # Use aria2c for faster parallel download
        apk add aria2
        retry 5 aria2c \
            --dir="$(dirname "$iso_path")" \
            --out="$(basename "$iso_path")" \
            --max-connection-per-server=4 \
            --split=4 \
            --file-allocation=none \
            --user-agent="curl/7.54.1" \
            "$iso" || \
        wget "$iso" -O "$iso_path"
    fi

    echo "ISO downloaded: $iso_path"
}

# =============================================================================
# Setup SSH for monitoring (allows watching /reinstall.log during installation)
# =============================================================================
setup_ssh() {
    info "Setting up SSH access for monitoring"

    apk add openssh-server

    # Generate host keys if not present
    ssh-keygen -A 2>/dev/null || true

    # Allow root login (password only needed during install)
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

    if [ -n "$ssh_port" ] && [ "$ssh_port" != "22" ]; then
        sed -i "s/#Port 22/Port $ssh_port/" /etc/ssh/sshd_config
    fi

    # Set root password for monitoring access
    if [ -f /configs/password-plaintext ]; then
        local pass
        pass=$(cat /configs/password-plaintext)
        echo "root:${pass}" | chpasswd 2>/dev/null || \
        echo "root:${pass}" | chpasswd -m 2>/dev/null || true
    fi

    # Start SSH daemon
    /usr/sbin/sshd 2>/dev/null || rc-service sshd start 2>/dev/null || true

    echo "SSH available on port ${ssh_port:-22}"
}

# =============================================================================
# Setup web log viewer (lightweight websocket tail of /reinstall.log)
# =============================================================================
setup_web_log() {
    local total_ram
    total_ram=$(free -m | awk 'NR==2{print $2}')

    # Only set up web viewer if there's enough RAM (>= 400 MB)
    if [ "$total_ram" -lt 400 ]; then
        warn "Not enough RAM for web log viewer (${total_ram}MB < 400MB). Skipping."
        return
    fi

    info "Setting up web log viewer on port ${web_port:-80}"

    apk add websocketd coreutils

    wget "$confhome/logviewer.html" -O /tmp/index.html 2>/dev/null || true

    pkill websocketd 2>/dev/null || true

    websocketd \
        --port "${web_port:-80}" \
        --loglevel=fatal \
        --staticdir=/tmp \
        stdbuf -oL -eL sh -c \
        "tail -fn+0 /reinstall.log | tr '\r' '\n' | grep -Fiv password" &

    echo "Web log viewer: http://<ip>:${web_port:-80}"
}

# =============================================================================
# Initialize /reinstall.log
# All output is also tee'd to this file so it can be monitored remotely
# =============================================================================
init_log() {
    exec > >(tee -a /reinstall.log) 2>&1
    echo "============================================"
    echo "  HorusInstall trans.sh started"
    echo "  $(date)"
    echo "============================================"
}

# =============================================================================
# Verify that we are running inside the Alpine transitional environment
# and that the script version matches reinstall.sh
# =============================================================================
verify_environment() {
    if ! [ -f /etc/alpine-release ]; then
        error_and_exit "trans.sh must run inside the Alpine transitional environment."
    fi

    if [ -f /configs/script_version ]; then
        local expected
        expected=$(cat /configs/script_version)
        if [ "$expected" != "$SCRIPT_VERSION" ]; then
            error_and_exit "Script version mismatch.
  Expected: $expected
  Got     : $SCRIPT_VERSION
  Re-run reinstall.sh to regenerate the boot environment."
        fi
    fi
}

# =============================================================================
# Load configuration from /configs/ directory
# reinstall.sh writes all config files to /configs/ before embedding them
# into the initrd that boots this script.
# =============================================================================
load_config() {
    # Load confhome (where to download missing files from)
    if [ -f /configs/confhome ]; then
        confhome=$(cat /configs/confhome)
    else
        confhome=https://raw.githubusercontent.com/HorusHDx/HorusInstall/main
    fi

    # Windows ISO URL
    if [ -f /configs/iso_url ]; then
        iso=$(cat /configs/iso_url)
    fi

    # Disk partition table UUID (set by reinstall.sh)
    if [ -f /configs/main_disk ]; then
        main_disk=$(cat /configs/main_disk)
    fi

    # Image name
    if [ -f /configs/image_name ]; then
        image_name=$(cat /configs/image_name)
    fi
}

# =============================================================================
# Clean up from a previous (possibly failed) run
# =============================================================================
clear_previous() {
    umount /iso         2>/dev/null || true
    umount /installer   2>/dev/null || true
    umount /efi         2>/dev/null || true
    swapoff -a          2>/dev/null || true
    killall aria2c      2>/dev/null || true
}

# =============================================================================
# Main entry point
# =============================================================================
main() {
    init_log
    verify_environment

    info "HorusInstall — trans.sh starting"
    echo "Alpine version: $(cat /etc/alpine-release)"
    echo "Architecture  : $(uname -m)"
    echo ""

    clear_previous

    # Read parameters from kernel cmdline
    extract_env_from_cmdline

    # Load additional config from /configs/
    load_config

    # Setup monitoring (SSH + web log viewer)
    setup_ssh
    setup_web_log

    # Find and verify target disk
    find_xda
    info "Target disk: /dev/$xda"
    lsblk "/dev/$xda" 2>/dev/null || true

    # Ensure Alpine community repo is available (for aria2, syslinux, etc.)
    add_community_repo

    # Download Windows ISO if we have a URL
    if [ -n "$iso" ]; then
        download_iso
    elif [ -f /configs/windows.iso ]; then
        iso_path=/configs/windows.iso
        info "Using pre-downloaded ISO: $iso_path"
    else
        error_and_exit "No ISO URL or pre-downloaded ISO found.
Check that reinstall.sh passed 'finalos_iso=...' in the kernel cmdline."
    fi

    # Mount the ISO
    mount_iso

    # Partition the target disk
    partition_disk

    # Copy ISO contents and our scripts to the installer partition
    prepare_installer_partition

    # Unmount ISO (no longer needed)
    umount_iso

    # Configure the bootloader to boot into WinPE on next reboot
    configure_bootloader

    # All done
    info "trans.sh complete — rebooting into Windows installer"
    echo ""
    echo "============================================"
    echo "  Rebooting in 5 seconds..."
    echo "  Windows installer will start automatically."
    echo "============================================"
    echo ""

    sleep 5
    reboot
}

main "$@"
