#!/usr/bin/env sh
# HorusInstall - trans.sh
# Runs inside Alpine Linux (in RAM) as the intermediate environment
set -eE
export LC_ALL=C
TMP=/horusinstall-tmp
LOGFILE=/var/log/horusinstall.log

log()   { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE" >&2; }
info()  { log "INFO  >>> $*"; }
warn()  { log "WARN  !!! $*"; }
error() { log "ERROR *** $*"; }
die()   { error "$@"; exit 1; }

trap 'error "Unexpected exit at line $LINENO (exit $?)"' ERR

load_config() {
    local cfg="$TMP/horus-config"
    [ -f "$cfg" ] || die "Config not found at $cfg"
    . "$cfg"
    info "Config loaded. OS: Server $WINDOWS_VERSION, Net: $NET_MODE ($NET_IPV4/$NET_PREFIX)"
}

setup_alpine() {
    info "Updating Alpine repositories"
    local attempts=0
    while ! ping -c 1 -w 3 8.8.8.8 >/dev/null 2>&1; do
        warn "Waiting for network connection..."
        sleep 2
        attempts=$((attempts + 1))
        [ "$attempts" -gt 15 ] && die "Network timeout inside Alpine."
    done
    apk update
    apk add wget curl ntfs-3g wimlib parted e2fsprogs util-linux sfdisk lsblk >/dev/null
}

detect_disk() {
    TARGET_DISK=$(lsblk -dn -o NAME,TYPE | awk '$2=="disk" && $1!="loop" && $1!="ram" && $1!~/sr[0-9]/ {print "/dev/"$1; exit}')
    [ -z "$TARGET_DISK" ] && die "Could not identify any installation target disk."
    info "Target disk: $TARGET_DISK"
}

detect_boot_mode() {
    if [ -d /sys/firmware/efi ]; then BOOT_MODE="EFI"; else BOOT_MODE="BIOS"; fi
    info "Boot mode: $BOOT_MODE"
}

detect_drivers() {
    if dmesg | grep -iqE "virtio|kvm|qemu"; then NEED_VIRTIO=true; else NEED_VIRTIO=false; fi
}

download_iso() {
    info "Downloading Windows ISO"
    wget --no-check-certificate -q --show-progress -O "$TMP/windows.iso" "$WINDOWS_ISO_URL" || die "ISO download failed."
}

download_virtio() {
    if [ "$NEED_VIRTIO" = true ]; then
        info "Downloading VirtIO drivers ISO"
        wget --no-check-certificate -q --show-progress -O "$TMP/virtio-win.iso" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" || die "VirtIO download failed."
    fi
}

prepare_disk() {
    info "Partitioning disk ($BOOT_MODE)"
    for part in $(lsblk -ln -o NAME "$TARGET_DISK"); do umount "/dev/$part" 2>/dev/null || true; done
    dd if=/dev/zero of="$TARGET_DISK" bs=512 count=2048 conv=notrunc >/dev/null 2>&1
    
    if [ "$BOOT_MODE" = "EFI" ]; then
        parted -s "$TARGET_DISK" mklabel gpt
        parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 513MiB
        parted -s "$TARGET_DISK" set 1 esp on
        parted -s "$TARGET_DISK" mkpart primary ntfs 513MiB 100%
        mkfs.vfat -F32 "${TARGET_DISK}1" >/dev/null || mkfs.vfat -F32 "${TARGET_DISK}p1" >/dev/null
        mkfs.ntfs -f -q "${TARGET_DISK}2" >/dev/null 2>&1 || mkfs.ntfs -f -q "${TARGET_DISK}p2" >/dev/null 2>&1
        WIN_PART="${TARGET_DISK}2"; [ -b "${TARGET_DISK}p2" ] && WIN_PART="${TARGET_DISK}p2"
        EFI_PART="${TARGET_DISK}1"; [ -b "${TARGET_DISK}p1" ] && EFI_PART="${TARGET_DISK}p1"
    else
        parted -s "$TARGET_DISK" mklabel msdos
        parted -s "$TARGET_DISK" mkpart primary ntfs 1MiB 100%
        parted -s "$TARGET_DISK" set 1 boot on
        mkfs.ntfs -f -q "${TARGET_DISK}1" >/dev/null 2>&1 || mkfs.ntfs -f -q "${TARGET_DISK}p1" >/dev/null 2>&1
        WIN_PART="${TARGET_DISK}1"; [ -b "${TARGET_DISK}p1" ] && WIN_PART="${TARGET_DISK}p1"
    fi
}

extract_and_deploy() {
    WIN_MOUNT="/mnt/win"; ISO_MOUNT="/mnt/iso"; mkdir -p "$WIN_MOUNT" "$ISO_MOUNT"
    mount -t ntfs-3g "$WIN_PART" "$WIN_MOUNT"
    mount -o loop "$TMP/windows.iso" "$ISO_MOUNT"

    local wim_file="$ISO_MOUNT/sources/install.wim"
    [ ! -f "$wim_file" ] && wim_file="$ISO_MOUNT/sources/install.esd"
    [ -f "$wim_file" ] || die "Could not locate installation image."

    info "Applying WIM"
    wimapply "$wim_file" "$WINDOWS_IMAGE_NAME" "$WIN_MOUNT" --check

    if [ "$BOOT_MODE" = "EFI" ]; then
        local efi_mount="/mnt/efi"; mkdir -p "$efi_mount"; mount -t vfat "$EFI_PART" "$efi_mount"
        mkdir -p "$efi_mount/EFI/Boot" "$efi_mount/EFI/Microsoft/Boot"
        cp -r "$WIN_MOUNT/Windows/Boot/EFI/"* "$efi_mount/EFI/Microsoft/Boot/" 2>/dev/null || true
        cp "$efi_mount/EFI/Microsoft/Boot/bootmgfw.efi" "$efi_mount/EFI/Boot/bootx64.efi"
        umount "$efi_mount"
    fi

    local setup_dir="$WIN_MOUNT/Windows/Setup/Scripts"
    mkdir -p "$setup_dir"
    cp "$TMP/windows.xml"                  "$WIN_MOUNT/autounattend.xml"
    cp "$TMP/windows-setup-bat.txt"        "$setup_dir/windows-setup.bat"
    cp "$TMP/windows-set-netconf -bat.txt" "$setup_dir/windows-set-netconf.bat"

    sed -i "s/__WIN_PASSWORD__/$WIN_PASSWORD/g" "$WIN_MOUNT/autounattend.xml"
    sed -i "s/__WIN_USERNAME__/$WIN_USERNAME/g" "$WIN_MOUNT/autounattend.xml"
    sed -i "s/__RDP_PORT__/$RDP_PORT/g"         "$setup_dir/windows-setup.bat"
    sed -i "s/__NET_IPV4__/$NET_IPV4/g"         "$setup_dir/windows-set-netconf.bat"
    sed -i "s/__NET_PREFIX__/$NET_PREFIX/g"     "$setup_dir/windows-set-netconf.bat"
    sed -i "s/__NET_GATEWAY__/$NET_GATEWAY/g"   "$setup_dir/windows-set-netconf.bat"
    sed -i "s/__NET_DNS__/$NET_DNS/g"           "$setup_dir/windows-set-netconf.bat"

    { echo "@echo off"; [ "$NET_MODE" = "static" ] && echo "call C:\\Windows\\Setup\\Scripts\\windows-set-netconf.bat"; } > "$setup_dir/SetupComplete.cmd"

    if [ "$NEED_VIRTIO" = true ]; then
        info "Injecting VirtIO Drivers"
        local virtio_mount="/mnt/virtio"; mkdir -p "$virtio_mount"; mount -o loop "$TMP/virtio-win.iso" "$virtio_mount"
        local drv_ver="2k22"; [ "$WINDOWS_VERSION" = "2016" ] && drv_ver="2k16"; [ "$WINDOWS_VERSION" = "2019" ] && drv_ver="2k19"
        
        # Destino crítico para la lectura de PnpCustomizations en Windows PE
        mkdir -p "$WIN_MOUNT/Drivers/VirtIO"
        cp -r "$virtio_mount/NetKVM/$drv_ver/amd64/"* "$WIN_MOUNT/Drivers/VirtIO/" 2>/dev/null || true
        cp -r "$virtio_mount/viostor/$drv_ver/amd64/"* "$WIN_MOUNT/Drivers/VirtIO/" 2>/dev/null || true
        cp -r "$virtio_mount/vioscsi/$drv_ver/amd64/"* "$WIN_MOUNT/Drivers/VirtIO/" 2>/dev/null || true
        umount "$virtio_mount"
    fi
}

cleanup_and_reboot() {
    info "Rebooting into Windows"
    umount "$WIN_MOUNT" 2>/dev/null || true; umount "$ISO_MOUNT" 2>/dev/null || true
    rm -f "$TMP/windows.iso" "$TMP/virtio-win.iso" 2>/dev/null || true
    sleep 5
    reboot
}

main() {
    exec > >(tee -a "$LOGFILE") 2>&1
    load_config; setup_alpine; detect_disk; detect_boot_mode; detect_drivers
    download_iso; download_virtio; prepare_disk; extract_and_deploy; cleanup_and_reboot
}
main "$@"