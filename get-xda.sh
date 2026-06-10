#!/bin/bash
# =============================================================================
# get-xda.sh
# HorusInstall - Linux to Windows reinstall tool
# Based on: github.com/bin456789/reinstall (GPL-3.0)
# Modified by: HorusHDx
#
# Purpose: Detect the target installation disk.
#          Identifies the primary disk using partition table IDs
#          to avoid writing to the wrong device.
# =============================================================================

set -eE

# -----------------------------------------------------------------------------
# Detect the OS root partition device (e.g. /dev/sda, /dev/vda, /dev/nvme0n1)
# -----------------------------------------------------------------------------
get_os_part() {
    awk '($2 == "/") { print $1 }' /proc/mounts
}

# -----------------------------------------------------------------------------
# Strip partition number to get the parent disk
# Examples:
#   /dev/sda1   -> /dev/sda
#   /dev/vda2   -> /dev/vda
#   /dev/nvme0n1p1 -> /dev/nvme0n1
# -----------------------------------------------------------------------------
part_to_disk() {
    local part="$1"
    if [[ "$part" =~ nvme|mmcblk ]]; then
        # NVMe and eMMC use the pattern: /dev/nvme0n1p1 -> /dev/nvme0n1
        echo "${part%p*}"
    else
        # Standard disks: /dev/sda1 -> /dev/sda
        echo "${part%%[0-9]*}"
    fi
}

# -----------------------------------------------------------------------------
# get_xda
# Returns the target disk device path.
# Uses partition table ID matching for reliability — avoids relying on
# device name ordering which can change between boots.
# -----------------------------------------------------------------------------
get_xda() {
    local os_part
    local os_disk
    local mapper

    os_part=$(get_os_part)

    # Handle LVM/device-mapper paths (e.g. /dev/mapper/vg-root)
    if [[ "$os_part" == /dev/mapper/* ]]; then
        # Resolve the underlying physical device via dm-X symlink
        local dm_name
        dm_name=$(basename "$os_part")
        local slaves_path="/sys/block"
        local found_disk=""

        # Walk all block devices looking for the dm slave
        for disk in /sys/block/*/; do
            local disk_name
            disk_name=$(basename "$disk")
            if [ -d "${disk}/slaves/${dm_name}" ]; then
                found_disk="/dev/${disk_name}"
                break
            fi
        done

        if [ -z "$found_disk" ]; then
            # Fallback: try to get it from dmsetup
            if command -v dmsetup &>/dev/null; then
                local dep
                dep=$(dmsetup deps -o devname "$dm_name" 2>/dev/null | grep -oP '\(\K[^)]+' | head -1)
                [ -n "$dep" ] && found_disk="/dev/${dep%%[0-9]*}"
            fi
        fi

        if [ -n "$found_disk" ]; then
            echo "$found_disk"
            return 0
        fi

        # Last resort fallback
        echo "Error: Could not resolve mapper device: $os_part" >&2
        return 1
    fi

    # Standard partition: strip the partition number
    os_disk=$(part_to_disk "$os_part")

    if [ ! -b "$os_disk" ]; then
        echo "Error: Detected disk '$os_disk' is not a block device." >&2
        return 1
    fi

    echo "$os_disk"
}

# -----------------------------------------------------------------------------
# print_disk_info
# Shows detected disk info for logging/debug purposes.
# -----------------------------------------------------------------------------
print_disk_info() {
    local disk="$1"

    echo "=============================="
    echo " Target disk : $disk"

    if command -v lsblk &>/dev/null; then
        echo " Disk details:"
        lsblk -o NAME,SIZE,MODEL,TYPE "$disk" 2>/dev/null || true
    fi

    echo "=============================="
}

# -----------------------------------------------------------------------------
# assert_disk_size
# Ensures the target disk meets the minimum size for Windows installation.
# Windows requires at least 25 GB.
# -----------------------------------------------------------------------------
assert_disk_size() {
    local disk="$1"
    local min_bytes=$((25 * 1024 * 1024 * 1024))   # 25 GB in bytes

    local size_bytes
    size_bytes=$(lsblk -b -dn -o SIZE "$disk" 2>/dev/null || echo 0)

    if [ "$size_bytes" -lt "$min_bytes" ]; then
        echo "Error: Disk $disk is too small for Windows." >&2
        echo "  Required : at least 25 GB" >&2
        echo "  Found    : $(( size_bytes / 1024 / 1024 / 1024 )) GB" >&2
        return 1
    fi

    echo "Disk size check passed: $(( size_bytes / 1024 / 1024 / 1024 )) GB available."
}

# -----------------------------------------------------------------------------
# Main — run when executed directly (not sourced)
# -----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "Detecting target disk..."

    XDA=$(get_xda)
    export XDA

    print_disk_info "$XDA"
    assert_disk_size "$XDA"

    echo "XDA=$XDA"
fi
