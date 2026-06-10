#!/usr/bin/env bash
# HorusInstall - trans.sh
# Runs inside Alpine Linux (in RAM) as the intermediate environment.
# Downloads the Windows ISO, partitions the disk, applies the WIM,
# injects drivers, writes boot entries, then reboots into Windows Setup.

set -eE
export LC_ALL=C

TMP=/horusinstall-tmp
LOGFILE=/var/log/horusinstall.log

# Version that must match reinstall.sh — prevents running mismatched files
EXPECTED_SCRIPT_VERSION="2"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()   { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE" >&2; }
info()  { log "INFO >>> $*"; }
warn()  { log "WARN !!! $*"; }
error() { log "ERROR *** $*"; }
die()   { error "$@"; exit 1; }

# Log a line masking any password values
log_safe() {
    local msg
    msg=$(echo "$*" | sed 's/WIN_PASSWORD=[^ ]*/WIN_PASSWORD=***/g')
    log "$msg"
}

trap 'error "Unexpected exit at line $LINENO (exit $?)"' ERR

# ---------------------------------------------------------------------------
# Load and validate config written by reinstall.sh into the initrd
# ---------------------------------------------------------------------------
load_config() {
    local cfg="$TMP/horus-config"
    [ -f "$cfg" ] || die "Config not found at $cfg"
    # shellcheck source=/dev/null
    . "$cfg"

    # Version check — catch mismatched reinstall.sh / trans.sh
    if [ "${SCRIPT_VERSION:-0}" != "$EXPECTED_SCRIPT_VERSION" ]; then
        die "Version mismatch: reinstall.sh wrote config v${SCRIPT_VERSION:-0}, trans.sh expects v${EXPECTED_SCRIPT_VERSION}. Re-run reinstall.sh."
    fi

    # Validate required fields are present
    for var in WINDOWS_VERSION WINDOWS_ISO_URL WIN_PASSWORD WIN_USERNAME \
               RDP_PORT NET_MODE NET_IFACE NET_IPV4 NET_PREFIX NET_GATEWAY NET_DNS; do
        eval "val=\$$var"
        [ -z "$val" ] && die "Config is missing required field: $var"
    done

    # Log config without exposing password
    info "Config loaded (v${SCRIPT_VERSION}):"
    info "  OS      : Windows Server $WINDOWS_VERSION"
    info "  Net     : $NET_MODE — $NET_IPV4/$NET_PREFIX via $NET_GATEWAY"
    info "  RDP     : port $RDP_PORT | user $WIN_USERNAME"
}

# ---------------------------------------------------------------------------
# Ensure network is up and install required Alpine packages
# ---------------------------------------------------------------------------
setup_alpine() {
    info "Ensuring default route is present"
    if ! ip route show | grep -q default; then
        ip route add default via "$NET_GATEWAY" dev "$NET_IFACE" 2>/dev/null || true
    fi

    info "Waiting for internet connectivity"
    local attempts=0
    until ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; do
        warn "No connectivity yet — retrying ($((attempts+1))/20)..."
        ip route add default via "$NET_GATEWAY" dev "$NET_IFACE" 2>/dev/null || true
        sleep 3
        attempts=$((attempts + 1))
        [ "$attempts" -ge 20 ] && die "Network timeout inside Alpine after 60 s."
    done
    info "Network OK"

    info "Installing required packages"
    apk update -q
    apk add -q wget curl ntfs-3g wimlib parted e2fsprogs util-linux sfdisk lsblk
}

# ---------------------------------------------------------------------------
# Identify the target installation disk.
# Skips loop/ram/CD-ROM devices and disks under 8 GB.
# Selects the LARGEST eligible disk (safest for VPS environments).
# ---------------------------------------------------------------------------
detect_disk() {
    info "Scanning for eligible disks"

    local best_disk="" best_size=0
    while read -r name size; do
        echo "$name" | grep -qE '^(loop|ram|sr)' && continue
        [ "$size" -lt 8589934592 ] && continue
        if [ "$size" -gt "$best_size" ]; then
            best_size="$size"
            best_disk="/dev/$name"
        fi
    done < <(lsblk -dn -b -o NAME,SIZE 2>/dev/null)

    [ -z "$best_disk" ] && die "No eligible disk found (>=8 GB, non-removable)."

    # Safety: warn if the detected disk appears to be the current root
    local root_dev
    root_dev=$(df / | awk 'NR==2{print $1}' | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
    if [ "$best_disk" = "$root_dev" ]; then
        warn "Target disk $best_disk appears to be the current root device — this is expected on single-disk VPS."
    fi

    TARGET_DISK="$best_disk"
    info "Target disk: $TARGET_DISK ($(( best_size / 1073741824 )) GB)"
}

# ---------------------------------------------------------------------------
# Detect EFI vs legacy BIOS
# ---------------------------------------------------------------------------
detect_boot_mode() {
    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE="EFI"
    else
        BOOT_MODE="BIOS"
    fi
    info "Boot mode: $BOOT_MODE"
}

# ---------------------------------------------------------------------------
# Detect KVM/QEMU hypervisor to decide on VirtIO driver injection
# ---------------------------------------------------------------------------
detect_drivers() {
    if dmesg | grep -iqE "virtio|kvm|qemu"; then
        NEED_VIRTIO=true
        info "Hypervisor: KVM/QEMU detected — VirtIO drivers will be injected"
    else
        NEED_VIRTIO=false
        info "No KVM/QEMU detected — skipping VirtIO injection"
    fi
}

# ---------------------------------------------------------------------------
# Check free RAM before attempting ISO download + WIM apply
# WIM apply is RAM-intensive; warn if under 512 MB free
# ---------------------------------------------------------------------------
check_resources() {
    local free_mem_kb
    free_mem_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$free_mem_kb" -lt 524288 ]; then
        warn "Less than 512 MB RAM available (${free_mem_kb} kB). WIM apply may fail on low-memory systems."
    else
        info "Available RAM: $((free_mem_kb / 1024)) MB OK"
    fi

    # Check that TMP has enough space for the ISO (rough estimate: 6 GB)
    local free_tmp_kb
    free_tmp_kb=$(df -k "$TMP" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
    if [ "$free_tmp_kb" -lt 6291456 ]; then
        warn "Less than 6 GB free in $TMP (${free_tmp_kb} kB). ISO download may fail."
    else
        info "Free space in $TMP: $((free_tmp_kb / 1024 / 1024)) GB OK"
    fi
}

# ---------------------------------------------------------------------------
# Download the Windows ISO with resume support
# ---------------------------------------------------------------------------
download_iso() {
    info "Downloading Windows ISO"
    info "  URL: $WINDOWS_ISO_URL"
    wget --no-check-certificate -c -q --show-progress \
         --tries=5 --waitretry=10 \
         -O "$TMP/windows.iso" "$WINDOWS_ISO_URL" \
         || die "ISO download failed after retries."

    [ -s "$TMP/windows.iso" ] || die "Downloaded ISO is empty."
    info "ISO download complete: $(du -sh "$TMP/windows.iso" | cut -f1)"
}

# ---------------------------------------------------------------------------
# Download VirtIO drivers ISO (only when needed)
# ---------------------------------------------------------------------------
download_virtio() {
    [ "$NEED_VIRTIO" = true ] || return 0

    local VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    info "Downloading VirtIO drivers ISO"
    wget --no-check-certificate -c -q --show-progress \
         --tries=5 --waitretry=10 \
         -O "$TMP/virtio-win.iso" "$VIRTIO_URL" \
         || die "VirtIO ISO download failed."

    [ -s "$TMP/virtio-win.iso" ] || die "VirtIO ISO is empty."
    info "VirtIO ISO download complete: $(du -sh "$TMP/virtio-win.iso" | cut -f1)"
}

# ---------------------------------------------------------------------------
# Helper: resolve partition device node (sdX1 vs nvme0n1p1)
# ---------------------------------------------------------------------------
part_dev() {
    local disk="$1" num="$2"
    [ -b "${disk}p${num}" ] && echo "${disk}p${num}" || echo "${disk}${num}"
}

# ---------------------------------------------------------------------------
# Partition and format the target disk
#   EFI  -> GPT: part 1 = EFI System (FAT32, 512 MiB), part 2 = Windows (NTFS)
#   BIOS -> MBR: part 1 = Windows (NTFS, 100%)
# ---------------------------------------------------------------------------
prepare_disk() {
    info "Wiping and partitioning $TARGET_DISK ($BOOT_MODE layout)"

    for part in $(lsblk -ln -o NAME "$TARGET_DISK" 2>/dev/null); do
        umount "/dev/$part" 2>/dev/null || true
    done

    # Wipe first 2 MiB — clears old partition tables, MBR, GPT header
    dd if=/dev/zero of="$TARGET_DISK" bs=1M count=2 conv=notrunc,fsync >/dev/null 2>&1
    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2

    if [ "$BOOT_MODE" = "EFI" ]; then
        parted -s "$TARGET_DISK" mklabel gpt
        parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 513MiB
        parted -s "$TARGET_DISK" set 1 esp on
        parted -s "$TARGET_DISK" mkpart primary ntfs 513MiB 100%
        partprobe "$TARGET_DISK"; sleep 2

        EFI_PART=$(part_dev "$TARGET_DISK" 1)
        WIN_PART=$(part_dev "$TARGET_DISK" 2)

        mkfs.vfat -F32 -n EFI "$EFI_PART" >/dev/null \
            || die "Failed to format EFI partition"
        mkfs.ntfs -f -q -L Windows "$WIN_PART" >/dev/null 2>&1 \
            || die "Failed to format Windows partition"
    else
        parted -s "$TARGET_DISK" mklabel msdos
        parted -s "$TARGET_DISK" mkpart primary ntfs 1MiB 100%
        parted -s "$TARGET_DISK" set 1 boot on
        partprobe "$TARGET_DISK"; sleep 2

        WIN_PART=$(part_dev "$TARGET_DISK" 1)
        EFI_PART=""

        mkfs.ntfs -f -q -L Windows "$WIN_PART" >/dev/null 2>&1 \
            || die "Failed to format Windows partition"
    fi

    info "Disk ready -> WIN_PART=$WIN_PART | EFI_PART=${EFI_PART:-none}"
}

# ---------------------------------------------------------------------------
# Auto-detect the correct Windows image name from the WIM.
# Priority: Datacenter Desktop Experience > any Datacenter > first image.
# ---------------------------------------------------------------------------
resolve_image_name() {
    local wim_file="$1"

    if [ -n "$WINDOWS_IMAGE_NAME" ]; then
        if wiminfo "$wim_file" 2>/dev/null | grep -qi "^Name.*:.*${WINDOWS_IMAGE_NAME}"; then
            info "Using supplied image name: $WINDOWS_IMAGE_NAME"
            return
        fi
        warn "Supplied image name '$WINDOWS_IMAGE_NAME' not found — auto-detecting..."
    fi

    local detected
    # 1st choice: Datacenter with Desktop Experience (full GUI)
    detected=$(wiminfo "$wim_file" 2>/dev/null \
        | grep -i "^Name" | grep -i "datacenter" | grep -i "desktop" \
        | head -1 | sed 's/^Name[[:space:]]*:[[:space:]]*//')

    # 2nd choice: any Datacenter edition
    if [ -z "$detected" ]; then
        detected=$(wiminfo "$wim_file" 2>/dev/null \
            | grep -i "^Name" | grep -i "datacenter" \
            | head -1 | sed 's/^Name[[:space:]]*:[[:space:]]*//')
    fi

    # Last resort: first available image
    if [ -z "$detected" ]; then
        detected=$(wiminfo "$wim_file" 2>/dev/null \
            | grep -i "^Name" \
            | head -1 | sed 's/^Name[[:space:]]*:[[:space:]]*//')
    fi

    [ -z "$detected" ] && die "Could not determine any Windows edition from the WIM."
    WINDOWS_IMAGE_NAME="$detected"
    info "Auto-detected image: $WINDOWS_IMAGE_NAME"
}

# ---------------------------------------------------------------------------
# Apply WIM, configure boot, place scripts, inject drivers
# ---------------------------------------------------------------------------
extract_and_deploy() {
    WIN_MOUNT="/mnt/win"
    ISO_MOUNT="/mnt/iso"
    mkdir -p "$WIN_MOUNT" "$ISO_MOUNT"

    # Mount with retry — NTFS-3g occasionally needs a moment after mkfs
    local mount_attempts=0
    until mount -t ntfs-3g "$WIN_PART" "$WIN_MOUNT" 2>/dev/null; do
        mount_attempts=$((mount_attempts + 1))
        [ "$mount_attempts" -ge 5 ] && die "Failed to mount Windows partition $WIN_PART after 5 attempts."
        warn "Mount attempt $mount_attempts failed — retrying in 3s..."
        sleep 3
    done

    mount -o loop,ro "$TMP/windows.iso" "$ISO_MOUNT" \
        || die "Failed to mount ISO"

    local wim_file="$ISO_MOUNT/sources/install.wim"
    [ ! -f "$wim_file" ] && wim_file="$ISO_MOUNT/sources/install.esd"
    [ -f "$wim_file" ] || die "Could not locate install.wim / install.esd in the ISO."

    info "Available editions in WIM:"
    wiminfo "$wim_file" 2>/dev/null | grep -i "^Name" | sed 's/^/  /' \
        | tee -a "$LOGFILE" >&2 || true

    resolve_image_name "$wim_file"

    info "Applying image '$WINDOWS_IMAGE_NAME' — this may take several minutes"
    # --check omitted intentionally: eval ISOs often have missing checksums
    wimapply "$wim_file" "$WINDOWS_IMAGE_NAME" "$WIN_MOUNT" \
        || die "wimapply failed."
    info "WIM applied successfully"

    # --- EFI boot -----------------------------------------------------------
    if [ "$BOOT_MODE" = "EFI" ]; then
        info "Configuring EFI boot files"
        local efi_mount="/mnt/efi"
        mkdir -p "$efi_mount"
        mount -t vfat "$EFI_PART" "$efi_mount" \
            || die "Failed to mount EFI partition"

        mkdir -p "$efi_mount/EFI/Boot" "$efi_mount/EFI/Microsoft/Boot"

        if [ -d "$WIN_MOUNT/Windows/Boot/EFI" ]; then
            cp -r "$WIN_MOUNT/Windows/Boot/EFI/." \
                  "$efi_mount/EFI/Microsoft/Boot/" 2>/dev/null || true
        fi

        # Fallback: pull bootmgfw.efi from the ISO
        if [ ! -f "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
            find "$ISO_MOUNT" -iname "bootmgfw.efi" -exec cp {} \
                "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" \; 2>/dev/null || true
        fi

        [ -f "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" ] \
            || die "bootmgfw.efi not found — cannot create EFI boot entry."

        cp "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" \
           "$efi_mount/EFI/Boot/bootx64.efi"

        info "EFI files placed. Windows Setup will rebuild BCD on first boot."
        umount "$efi_mount"

    # --- BIOS boot ----------------------------------------------------------
    else
        info "Configuring BIOS boot"
        if [ -f "$WIN_MOUNT/Windows/Boot/PCAT/bootmgr" ]; then
            cp "$WIN_MOUNT/Windows/Boot/PCAT/bootmgr" "$WIN_MOUNT/bootmgr"
        elif [ -f "$ISO_MOUNT/bootmgr" ]; then
            cp "$ISO_MOUNT/bootmgr" "$WIN_MOUNT/bootmgr"
        fi
        info "BIOS boot: VBR written by mkfs.ntfs, MBR finalized by Windows Setup."
    fi

    # --- Post-install scripts -----------------------------------------------
    # Path MUST match FirstLogonCommands in windows.xml
    local setup_dir="$WIN_MOUNT/Windows/Setup/Scripts"
    mkdir -p "$setup_dir"

    cp "$TMP/windows.xml"             "$WIN_MOUNT/autounattend.xml"
    cp "$TMP/windows-setup.bat"       "$setup_dir/windows-setup.bat"
    cp "$TMP/windows-set-netconf.bat" "$setup_dir/windows-set-netconf.bat"

    # Use | as sed delimiter — avoids conflicts with / in IPs and paths
    sed -i "s|__WIN_PASSWORD__|${WIN_PASSWORD}|g"   "$WIN_MOUNT/autounattend.xml"
    sed -i "s|__WIN_USERNAME__|${WIN_USERNAME}|g"   "$WIN_MOUNT/autounattend.xml"
    sed -i "s|__RDP_PORT__|${RDP_PORT}|g"           "$setup_dir/windows-setup.bat"
    sed -i "s|__NET_IPV4__|${NET_IPV4}|g"           "$setup_dir/windows-set-netconf.bat"
    sed -i "s|__NET_PREFIX__|${NET_PREFIX}|g"       "$setup_dir/windows-set-netconf.bat"
    sed -i "s|__NET_GATEWAY__|${NET_GATEWAY}|g"     "$setup_dir/windows-set-netconf.bat"
    sed -i "s|__NET_DNS__|${NET_DNS}|g"             "$setup_dir/windows-set-netconf.bat"

    # SetupComplete.cmd — runs at system level after Setup finishes
    {
        echo "@echo off"
        echo "call C:\\Windows\\Setup\\Scripts\\windows-setup.bat"
        [ "$NET_MODE" = "static" ] && \
            echo "call C:\\Windows\\Setup\\Scripts\\windows-set-netconf.bat"
    } > "$setup_dir/SetupComplete.cmd"

    info "Post-install scripts placed in $setup_dir"

    # --- VirtIO driver injection --------------------------------------------
    if [ "$NEED_VIRTIO" = true ]; then
        info "Injecting VirtIO drivers"
        local virtio_mount="/mnt/virtio"
        mkdir -p "$virtio_mount"
        mount -o loop,ro "$TMP/virtio-win.iso" "$virtio_mount" \
            || die "Failed to mount VirtIO ISO"

        local drv_ver
        case "$WINDOWS_VERSION" in
            2016) drv_ver="2k16" ;;
            2019) drv_ver="2k19" ;;
            2022) drv_ver="2k22" ;;
            2025) drv_ver="2k25" ;;
            *)    drv_ver="2k22" ;;
        esac

        local drv_dest="$WIN_MOUNT/Drivers/VirtIO"
        mkdir -p "$drv_dest"

        local injected=0
        for component in NetKVM viostor vioscsi vioserial balloon; do
            local src="$virtio_mount/$component/$drv_ver/amd64"
            if [ -d "$src" ]; then
                cp -r "$src/." "$drv_dest/" 2>/dev/null \
                    && injected=$((injected+1)) \
                    && info "  Injected: $component ($drv_ver)" \
                    || warn "  Copy failed: $component"
            else
                warn "  Not found: $component/$drv_ver/amd64 — skipped"
            fi
        done

        [ "$injected" -eq 0 ] && \
            warn "No VirtIO drivers injected — ISO layout may differ from expected."

        # Expose drivers via INF path for Windows Setup auto-detection
        local inf_dest="$WIN_MOUNT/Windows/INF/VirtIO"
        mkdir -p "$inf_dest"
        cp -r "$drv_dest/." "$inf_dest/" 2>/dev/null || true

        umount "$virtio_mount"
        info "VirtIO injection complete ($injected component(s))"
    fi

    umount "$ISO_MOUNT" || true
    info "extract_and_deploy complete"
}

# ---------------------------------------------------------------------------
# Sync, unmount, remove ISOs, reboot
# ---------------------------------------------------------------------------
cleanup_and_reboot() {
    info "Syncing filesystems"
    sync

    info "Unmounting partitions"
    umount "$WIN_MOUNT" 2>/dev/null || true
    umount "$ISO_MOUNT"  2>/dev/null || true

    info "Removing temporary ISO files"
    rm -f "$TMP/windows.iso" "$TMP/virtio-win.iso" 2>/dev/null || true

    info "========================================================"
    info "All done. Rebooting into Windows Setup in 5 seconds..."
    info "Connect via RDP to $NET_IPV4:$RDP_PORT after ~20-30 min."
    info "========================================================"
    sleep 5
    reboot
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    mkdir -p "$TMP"
    info "=== HorusInstall trans.sh v${EXPECTED_SCRIPT_VERSION} started ==="
    load_config
    setup_alpine
    detect_disk
    detect_boot_mode
    detect_drivers
    check_resources
    download_iso
    download_virtio
    prepare_disk
    extract_and_deploy
    cleanup_and_reboot
}

main "$@"
