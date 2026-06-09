#!/usr/bin/env sh
# HorusInstall - trans.sh
# Runs inside Alpine Linux (in RAM) as the intermediate environment
# Prepares disk, injects drivers, and launches the Windows installer
# https://github.com/HorusHDx/HorusInstall

set -eE
export LC_ALL=C
TMP=/horusinstall-tmp
LOGFILE=/var/log/horusinstall.log

# ============================================================
# OUTPUT
# ============================================================
log()   { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE" >&2; }
info()  { log "INFO  >>> $*"; }
warn()  { log "WARN  !!! $*"; }
error() { log "ERROR *** $*"; }
die()   { error "$@"; exit 1; }

trap 'error "Unexpected exit at line $LINENO"' ERR

# ============================================================
# LOAD CONFIG
# ============================================================
load_config() {
    local cfg="$TMP/horus-config"
    [ -f "$cfg" ] || die "Config file not found at $cfg"
    # shellcheck disable=SC1090
    . "$cfg"
    info "Config loaded"
    info "Windows version : $WINDOWS_VERSION"
    info "Image name      : $WINDOWS_IMAGE_NAME"
    info "Net mode        : $NET_MODE"
}

# ============================================================
# ALPINE SETUP
# ============================================================
setup_alpine() {
    info "Setting up Alpine package repos"

    # Add community repo for wimlib
    cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v3.21/main
https://dl-cdn.alpinelinux.org/alpine/v3.21/community
EOF

    info "Updating package index"
    apk update --quiet

    info "Installing required packages"
    apk add --quiet \
        bash \
        curl \
        wget \
        util-linux \
        parted \
        e2fsprogs \
        dosfstools \
        ntfs-3g \
        wimlib \
        xmlstarlet \
        lsblk \
        sgdisk \
        grub \
        grub-bios \
        grub-efi \
        pciutils \
        usbutils

    info "Packages installed"
}

# ============================================================
# DETECT DISK
# ============================================================
get_main_disk() {
    # Get the largest disk that is not a loop or tmpfs device
    lsblk -dno NAME,SIZE,TYPE | grep disk | sort -k2 -rh | head -1 | awk '{print "/dev/"$1}'
}

detect_disk() {
    DISK=$(get_main_disk)
    [ -n "$DISK" ] || die "Cannot detect main disk"
    DISK_SIZE=$(lsblk -dno SIZE "$DISK" | tr -d 'G ')
    info "Main disk: $DISK ($DISK_SIZE GB)"
}

# ============================================================
# DETECT BOOT MODE
# ============================================================
detect_boot_mode() {
    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE=efi
    else
        BOOT_MODE=bios
    fi
    info "Boot mode: $BOOT_MODE"
}

# ============================================================
# DETECT DRIVERS NEEDED
# ============================================================
detect_drivers() {
    info "Detecting required drivers"
    NEED_VIRTIO=0

    # Check if any virtio devices exist
    if lspci 2>/dev/null | grep -iq "virtio"; then
        NEED_VIRTIO=1
        info "VirtIO devices detected — will inject VirtIO drivers"
    elif ls /sys/bus/virtio/devices/ 2>/dev/null | grep -q .; then
        NEED_VIRTIO=1
        info "VirtIO bus detected — will inject VirtIO drivers"
    else
        info "No VirtIO devices detected — standard drivers only"
    fi
}

# ============================================================
# DOWNLOAD ISO
# ============================================================
download_iso() {
    info "Downloading Windows Server ISO"
    info "URL: $WINDOWS_ISO"

    mkdir -p "$TMP"
    ISO_PATH="$TMP/windows.iso"

    # Use wget with progress for large files
    if command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate --progress=dot:giga \
            -O "$ISO_PATH" "$WINDOWS_ISO" 2>&1 | tee -a "$LOGFILE" || \
        die "ISO download failed"
    else
        curl --insecure -L --progress-bar \
            -o "$ISO_PATH" "$WINDOWS_ISO" 2>&1 | tee -a "$LOGFILE" || \
        die "ISO download failed"
    fi

    info "ISO downloaded: $(du -sh "$ISO_PATH" | cut -f1)"
}

# ============================================================
# DOWNLOAD VIRTIO DRIVERS
# ============================================================
download_virtio() {
    [ "$NEED_VIRTIO" -eq 1 ] || return 0

    info "Downloading VirtIO drivers for Windows Server"
    VIRTIO_ISO="$TMP/virtio-win.iso"

    # Latest stable VirtIO ISO from Fedora
    VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

    wget --no-check-certificate --progress=dot:giga \
        -O "$VIRTIO_ISO" "$VIRTIO_URL" 2>&1 | tee -a "$LOGFILE" || \
    die "VirtIO driver download failed"

    info "VirtIO drivers downloaded"
}

# ============================================================
# PREPARE DISK PARTITIONS
# ============================================================
prepare_disk() {
    info "Preparing disk partitions on $DISK"

    # Unmount everything on this disk
    umount_disk

    if [ "$BOOT_MODE" = "efi" ]; then
        prepare_disk_efi
    else
        prepare_disk_bios
    fi
}

umount_disk() {
    info "Unmounting all partitions on $DISK"
    # Swapoff any swap partitions
    swapoff -a 2>/dev/null || true
    # Unmount any mounted partitions from this disk
    grep "^$DISK" /proc/mounts 2>/dev/null | awk '{print $2}' | sort -r | \
        xargs -r umount -lf 2>/dev/null || true
    sleep 1
}

prepare_disk_bios() {
    info "Creating BIOS partition layout"
    # Layout:
    #   Part 1: BIOS boot partition (1 MB) — for GRUB
    #   Part 2: Windows system partition (rest)

    parted -s "$DISK" -- \
        mklabel msdos \
        mkpart primary ntfs 1MiB 100% \
        set 1 boot on

    partprobe "$DISK" 2>/dev/null || true
    sleep 2

    # Get partition names (handles /dev/sda1, /dev/nvme0n1p1, etc.)
    PART_WIN="${DISK}1"
    if [[ "$DISK" == *nvme* ]] || [[ "$DISK" == *mmcblk* ]]; then
        PART_WIN="${DISK}p1"
    fi

    info "Formatting Windows partition as NTFS"
    mkntfs -f -L "Windows" "$PART_WIN" >/dev/null 2>&1 || \
        mkfs.ntfs -f "$PART_WIN" >/dev/null 2>&1

    info "Disk layout (BIOS):"
    lsblk "$DISK" >&2
}

prepare_disk_efi() {
    info "Creating EFI partition layout"
    # Layout:
    #   Part 1: EFI System Partition (100 MB) — FAT32
    #   Part 2: Windows RE / MSR (16 MB)
    #   Part 3: Windows C: (rest)

    sgdisk -Z "$DISK" >/dev/null 2>&1 || true

    parted -s "$DISK" -- \
        mklabel gpt \
        mkpart ESP fat32 1MiB 101MiB \
        set 1 esp on \
        mkpart MSR 101MiB 117MiB \
        mkpart Windows ntfs 117MiB 100%

    partprobe "$DISK" 2>/dev/null || true
    sleep 2

    if [[ "$DISK" == *nvme* ]] || [[ "$DISK" == *mmcblk* ]]; then
        PART_EFI="${DISK}p1"
        PART_WIN="${DISK}p3"
    else
        PART_EFI="${DISK}1"
        PART_WIN="${DISK}3"
    fi

    info "Formatting EFI partition as FAT32"
    mkfs.fat -F32 -n "EFI" "$PART_EFI" >/dev/null 2>&1

    info "Formatting Windows partition as NTFS"
    mkntfs -f -L "Windows" "$PART_WIN" >/dev/null 2>&1 || \
        mkfs.ntfs -f "$PART_WIN" >/dev/null 2>&1

    info "Disk layout (EFI):"
    lsblk "$DISK" >&2
}

# ============================================================
# EXTRACT AND PREPARE WINDOWS FILES
# ============================================================
mount_iso() {
    info "Mounting Windows ISO"
    ISO_MOUNT="$TMP/iso"
    mkdir -p "$ISO_MOUNT"
    mount -o loop,ro "$ISO_PATH" "$ISO_MOUNT" || die "Failed to mount ISO"
    info "ISO mounted at $ISO_MOUNT"
}

mount_win_partition() {
    info "Mounting Windows partition"
    WIN_MOUNT="$TMP/windows"
    mkdir -p "$WIN_MOUNT"
    mount "$PART_WIN" "$WIN_MOUNT" || die "Failed to mount Windows partition"
}

copy_windows_files() {
    info "Copying Windows installation files to disk"
    info "This may take several minutes..."

    cp -r "$ISO_MOUNT/"* "$WIN_MOUNT/" 2>&1 | tee -a "$LOGFILE" || \
        die "Failed to copy Windows files"

    info "Windows files copied"
}

# ============================================================
# INJECT VIRTIO DRIVERS INTO WIM
# ============================================================
inject_virtio_drivers() {
    [ "$NEED_VIRTIO" -eq 1 ] || return 0

    info "Injecting VirtIO drivers into Windows images"

    VIRTIO_MOUNT="$TMP/virtio"
    mkdir -p "$VIRTIO_MOUNT"
    mount -o loop,ro "$VIRTIO_ISO" "$VIRTIO_MOUNT" || {
        warn "Could not mount VirtIO ISO, skipping driver injection"
        return 0
    }

    local boot_wim="$WIN_MOUNT/sources/boot.wim"
    local install_wim="$WIN_MOUNT/sources/install.wim"

    # Check wimlib is available
    command -v wimupdate >/dev/null 2>&1 || {
        warn "wimlib not available, skipping driver injection"
        umount "$VIRTIO_MOUNT" 2>/dev/null || true
        return 0
    }

    # Determine Windows Server version folder in VirtIO ISO
    # VirtIO driver folder names: 2k16 = Server 2016, 2k19 = Server 2019, 2k22 = Server 2022
    case "$WINDOWS_VERSION" in
        2016) VIRTIO_WIN_DIR="2k16" ;;
        2019) VIRTIO_WIN_DIR="2k19" ;;
        2022) VIRTIO_WIN_DIR="2k22" ;;
        *)    VIRTIO_WIN_DIR="2k22" ;;
    esac

    # Key VirtIO drivers needed: network (NetKVM) and storage (viostor, vioscsi)
    local driver_dirs=""
    for drv in NetKVM viostor vioscsi viofs balloon; do
        local drv_path="$VIRTIO_MOUNT/$drv/amd64/$VIRTIO_WIN_DIR"
        if [ -d "$drv_path" ]; then
            driver_dirs="$driver_dirs $drv_path"
        else
            # Try alternate path structure
            local alt_path="$VIRTIO_MOUNT/$drv/w${WINDOWS_VERSION}/amd64"
            [ -d "$alt_path" ] && driver_dirs="$driver_dirs $alt_path"
        fi
    done

    if [ -z "$driver_dirs" ]; then
        warn "VirtIO driver directories not found for Server $WINDOWS_VERSION, trying generic amd64 path"
        for drv in NetKVM viostor vioscsi; do
            find "$VIRTIO_MOUNT/$drv" -name "*.inf" -path "*/amd64/*" 2>/dev/null | \
                head -1 | xargs -r dirname | while read -r d; do
                driver_dirs="$driver_dirs $d"
            done
        done
    fi

    # Inject into boot.wim (index 2 = WinPE setup environment)
    if [ -f "$boot_wim" ] && [ -n "$driver_dirs" ]; then
        info "Injecting drivers into boot.wim"
        local tmp_bootdir="$TMP/boot-drivers"
        mkdir -p "$tmp_bootdir"

        for dir in $driver_dirs; do
            find "$dir" -name "*.inf" | while read -r inf; do
                local ddir
                ddir=$(dirname "$inf")
                cp -r "$ddir" "$tmp_bootdir/" 2>/dev/null || true
            done
        done

        wimupdate "$boot_wim" 2 --command="add $tmp_bootdir /Windows/System32/drivers/virtio" \
            2>&1 | tee -a "$LOGFILE" || warn "boot.wim driver injection had warnings"
    fi

    # Inject into install.wim
    if [ -f "$install_wim" ] && [ -n "$driver_dirs" ]; then
        info "Injecting drivers into install.wim (this takes a while...)"

        # Get the index for our target image
        local wim_index
        wim_index=$(wiminfo "$install_wim" 2>/dev/null | \
            grep -i "$(echo "$WINDOWS_IMAGE_NAME" | tr '[:upper:]' '[:lower:]')" -B5 | \
            grep "^Index" | awk '{print $3}' | head -1)

        [ -z "$wim_index" ] && wim_index=1
        info "Using WIM index: $wim_index"

        local tmp_drivers="$TMP/win-drivers"
        mkdir -p "$tmp_drivers"
        for dir in $driver_dirs; do
            cp -r "$dir"/* "$tmp_drivers/" 2>/dev/null || true
        done

        wimupdate "$install_wim" "$wim_index" \
            --command="add $tmp_drivers /Windows/System32/drivers/virtio" \
            2>&1 | tee -a "$LOGFILE" || warn "install.wim driver injection had warnings"
    fi

    umount "$VIRTIO_MOUNT" 2>/dev/null || true
    info "VirtIO driver injection complete"
}

# ============================================================
# INJECT UNATTEND.XML
# ============================================================
generate_unattend() {
    info "Generating unattend.xml"

    # Download our base unattend template
    curl --insecure -fsSL "$CONFHOME/windows.xml" -o "$TMP/windows.xml" || \
        die "Failed to download windows.xml from $CONFHOME"

    # Replace placeholders in template
    sed -i "s|__WIN_USERNAME__|$WIN_USERNAME|g"   "$TMP/windows.xml"
    sed -i "s|__WIN_PASSWORD__|$WIN_PASSWORD|g"   "$TMP/windows.xml"
    sed -i "s|__IMAGE_NAME__|$WINDOWS_IMAGE_NAME|g" "$TMP/windows.xml"
    sed -i "s|__RDP_PORT__|$WIN_RDP_PORT|g"       "$TMP/windows.xml"

    # Network config in unattend
    if [ "$NET_MODE" = "static" ]; then
        info "Configuring static IP in unattend: $NET_IPV4/$NET_PREFIX via $NET_GATEWAY"
        sed -i "s|__NET_MODE__|static|g"      "$TMP/windows.xml"
        sed -i "s|__NET_IPV4__|$NET_IPV4|g"   "$TMP/windows.xml"
        sed -i "s|__NET_PREFIX__|$NET_PREFIX|g" "$TMP/windows.xml"
        sed -i "s|__NET_GATEWAY__|$NET_GATEWAY|g" "$TMP/windows.xml"
        sed -i "s|__NET_DNS__|$NET_DNS|g"     "$TMP/windows.xml"
    else
        sed -i "s|__NET_MODE__|dhcp|g" "$TMP/windows.xml"
    fi

    # Place unattend in the correct location on the Windows partition
    mkdir -p "$WIN_MOUNT/sources"
    cp "$TMP/windows.xml" "$WIN_MOUNT/autounattend.xml"

    info "unattend.xml placed at $WIN_MOUNT/autounattend.xml"
}

# ============================================================
# SETUP WINDOWS BOOTLOADER
# ============================================================
setup_windows_boot() {
    info "Setting up Windows bootloader"

    if [ "$BOOT_MODE" = "efi" ]; then
        setup_boot_efi
    else
        setup_boot_bios
    fi
}

setup_boot_bios() {
    info "Installing GRUB to point to Windows installer (BIOS)"

    # Mount Windows partition to access bootmgr
    # Windows installer on MBR disk boots via bootmgr
    # We write the Windows MBR using ms-sys or grub pointing to partition

    install_pkg grub

    # Write MBR + boot sector pointing to Windows partition
    grub-install --target=i386-pc \
        --boot-directory="$WIN_MOUNT/boot" \
        "$DISK" 2>&1 | tee -a "$LOGFILE" || warn "grub-install warning (may be OK)"

    # Create a minimal GRUB config to chainload Windows installer
    mkdir -p "$WIN_MOUNT/boot/grub"
    cat > "$WIN_MOUNT/boot/grub/grub.cfg" <<GRUBCFG
set timeout=3
set default=0

menuentry "Windows Server Installer" {
    insmod ntfs
    insmod part_msdos
    chainloader +1
}
GRUBCFG

    info "BIOS bootloader configured"
}

setup_boot_efi() {
    info "Setting up EFI boot for Windows installer"

    # Mount EFI partition
    EFI_MOUNT="$TMP/efi"
    mkdir -p "$EFI_MOUNT"
    mount "$PART_EFI" "$EFI_MOUNT" || die "Failed to mount EFI partition"

    # Copy Windows EFI boot files
    if [ -d "$WIN_MOUNT/efi" ]; then
        cp -r "$WIN_MOUNT/efi/"* "$EFI_MOUNT/" 2>/dev/null || true
    elif [ -d "$ISO_MOUNT/efi" ]; then
        cp -r "$ISO_MOUNT/efi/"* "$EFI_MOUNT/" 2>/dev/null || true
    fi

    # Also copy boot folder
    if [ -d "$WIN_MOUNT/boot" ]; then
        mkdir -p "$EFI_MOUNT/EFI/Microsoft/Boot"
        cp -r "$WIN_MOUNT/boot/"* "$EFI_MOUNT/EFI/Microsoft/Boot/" 2>/dev/null || true
    fi

    umount "$EFI_MOUNT" 2>/dev/null || true
    info "EFI bootloader configured"
}

# ============================================================
# WRITE NET CONFIG HELPER FOR WINDOWS FIRSTBOOT
# ============================================================
write_netconf_helper() {
    [ "$NET_MODE" = "static" ] || return 0

    info "Writing network config helper for Windows first boot"

    # Download windows-set-netconf.bat and place it for firstboot
    curl --insecure -fsSL "$CONFHOME/windows-set-netconf.bat" \
        -o "$TMP/windows-set-netconf.bat" 2>/dev/null || {
        warn "Could not download windows-set-netconf.bat, network may need manual config"
        return 0
    }

    # Embed values into the bat file
    sed -i "s|__NET_IPV4__|$NET_IPV4|g"         "$TMP/windows-set-netconf.bat"
    sed -i "s|__NET_PREFIX__|$NET_PREFIX|g"      "$TMP/windows-set-netconf.bat"
    sed -i "s|__NET_GATEWAY__|$NET_GATEWAY|g"    "$TMP/windows-set-netconf.bat"
    sed -i "s|__NET_DNS__|$NET_DNS|g"            "$TMP/windows-set-netconf.bat"
    sed -i "s|__NET_IFACE__|$NET_IFACE|g"        "$TMP/windows-set-netconf.bat"

    # Place in Windows\Setup\Scripts\ so it runs at first boot
    mkdir -p "$WIN_MOUNT/Windows/Setup/Scripts"
    cp "$TMP/windows-set-netconf.bat" "$WIN_MOUNT/Windows/Setup/Scripts/SetupComplete.cmd"
}

# ============================================================
# CLEANUP AND REBOOT
# ============================================================
cleanup_and_reboot() {
    info "Cleaning up mounts"

    umount "$WIN_MOUNT" 2>/dev/null || true
    umount "$ISO_MOUNT" 2>/dev/null || true
    umount "$TMP/virtio" 2>/dev/null || true

    # Remove Alpine temp files from memory
    rm -rf "$TMP/iso" "$TMP/virtio" "$TMP/boot-drivers" "$TMP/win-drivers" 2>/dev/null || true

    info "All done! Rebooting into Windows Server installer..."
    info "Installation is fully automatic — do not interrupt the process"
    info "The server will reboot once more after install completes"
    echo ""
    echo "  Estimated install time: 10-30 minutes depending on disk speed" >&2
    echo "" >&2

    sleep 5
    reboot
}

# ============================================================
# MAIN
# ============================================================
main() {
    # Only run if triggered by HorusInstall
    # (checked via kernel cmdline or presence of config file)
    if ! grep -q "horusinstall=1" /proc/cmdline 2>/dev/null; then
        if [ ! -f "$TMP/horus-config" ]; then
            echo "This script is part of HorusInstall and should not be run manually." >&2
            exit 1
        fi
    fi

    exec > >(tee -a "$LOGFILE") 2>&1

    echo "" >&2
    info "HorusInstall trans.sh starting"
    info "Log: $LOGFILE"
    echo "" >&2

    load_config
    setup_alpine
    detect_disk
    detect_boot_mode
    detect_drivers

    download_iso
    download_virtio

    prepare_disk
    mount_iso
    mount_win_partition
    copy_windows_files
    inject_virtio_drivers
    generate_unattend
    write_netconf_helper
    setup_windows_boot

    cleanup_and_reboot
}

main "$@"
