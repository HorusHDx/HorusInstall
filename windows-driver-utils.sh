#!/bin/bash
# =============================================================================
# windows-driver-utils.sh
# HorusInstall - Linux to Windows reinstall tool
# Based on: github.com/bin456789/reinstall (GPL-3.0)
# Modified by: HorusHDx
#
# Purpose: Detect the virtualization platform and automatically download
#          and inject the required drivers into the Windows installer (WIM).
#
# Drivers handled (auto-detected, downloaded only when needed):
#   - VirtIO     : KVM/QEMU guests (community, Alibaba, Tencent, GCP builds)
#   - XEN        : Citrix / AWS Xen PV guests
#   - AWS        : ENA NIC + NVMe storage controller
#   - GCP        : gVNIC NIC + GGA display
#   - Azure      : MANA NIC
#   - Intel      : VMD storage controller (11th-15th gen, Ultra 3)
#                  Intel NIC (Windows 7 through Server 2025)
# =============================================================================

set -eE

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
info()  { echo -e "\e[32m***** $(echo "$*" | tr '[:lower:]' '[:upper:]') *****\e[0m" >&2; }
warn()  { echo -e "\e[33mWarning: $*\e[0m" >&2; }
error() { echo -e "\e[31m***** ERROR *****\e[0m" >&2; echo -e "\e[31m$*\e[0m" >&2; }
error_and_exit() { error "$@"; exit 1; }

# Working directory for driver downloads
DRIVER_TMP="${DRIVER_TMP:-/reinstall-tmp/drivers}"

# Mount point where install.wim is accessible (set by caller)
WIMMOUNT="${WIMMOUNT:-/reinstall-tmp/wimmount}"

# -----------------------------------------------------------------------------
# Detect virtualization platform
# Returns one of: kvm, xen, vmware, hyperv, gcp, aws, azure, none
# -----------------------------------------------------------------------------
detect_platform() {
    if [ -n "$_platform" ]; then
        echo "$_platform"
        return
    fi

    local platform="none"

    # Try systemd-detect-virt first (most reliable)
    if command -v systemd-detect-virt &>/dev/null; then
        local virt
        virt=$(systemd-detect-virt 2>/dev/null || true)
        case "$virt" in
            kvm)     platform="kvm"    ;;
            xen)     platform="xen"    ;;
            vmware)  platform="vmware" ;;
            microsoft) platform="hyperv" ;;
            none)    platform="none"   ;;
        esac
    fi

    # Refine with DMI info if available
    if command -v dmidecode &>/dev/null; then
        local dmi
        dmi=$(dmidecode -s system-manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
        case "$dmi" in
            *google*)    platform="gcp"    ;;
            *amazon*)    platform="aws"    ;;
            *microsoft*) platform="hyperv" ;;
        esac

        # Azure specific: product name contains "Virtual Machine"
        local product
        product=$(dmidecode -s system-product-name 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
        if [[ "$product" == *"virtual machine"* ]] && [[ "$dmi" == *"microsoft"* ]]; then
            platform="azure"
        fi
    fi

    # Check /sys for cloud-specific identifiers
    if [ -f /sys/class/dmi/id/product_name ]; then
        local prod
        prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
        case "$prod" in
            *google*)    platform="gcp" ;;
            *amazon*)    platform="aws" ;;
        esac
    fi

    # Check for GCP metadata server
    if [ "$platform" = "none" ] || [ "$platform" = "kvm" ]; then
        if curl -s --connect-timeout 2 -o /dev/null \
            -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/instance/zone" 2>/dev/null; then
            platform="gcp"
        fi
    fi

    # Check for AWS metadata
    if [ "$platform" = "none" ] || [ "$platform" = "xen" ] || [ "$platform" = "kvm" ]; then
        if curl -s --connect-timeout 2 -o /dev/null \
            "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null; then
            platform="aws"
        fi
    fi

    # Check for Azure metadata
    if [ "$platform" = "none" ] || [ "$platform" = "hyperv" ]; then
        if curl -s --connect-timeout 2 -o /dev/null \
            -H "Metadata: true" \
            "http://169.254.169.254/metadata/instance?api-version=2021-02-01" 2>/dev/null; then
            platform="azure"
        fi
    fi

    _platform="$platform"
    echo "$platform"
}

# -----------------------------------------------------------------------------
# Detect Windows version being installed (from image name string)
# Returns the NT major.minor version number, e.g. "10.0", "6.1", "6.3"
# -----------------------------------------------------------------------------
get_win_version_from_name() {
    local image_name
    image_name=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    case "$image_name" in
        *vista*|*"server 2008"*) echo "6.0" ;;
        *"windows 7"*|*"server 2008 r2"*) echo "6.1" ;;
        *"windows 8"*|*"server 2012"*) echo "6.2" ;;
        *"windows 8.1"*|*"server 2012 r2"*) echo "6.3" ;;
        *"windows 10"*|*"windows 11"*|*"server 2016"*|\
        *"server 2019"*|*"server 2022"*|*"server 2025"*|\
        *"ltsc 2019"*|*"ltsc 2021"*|*"ltsc 2024"*) echo "10.0" ;;
        *) echo "10.0" ;;  # Default to modern Windows
    esac
}

# -----------------------------------------------------------------------------
# Download a file with retries
# Usage: download_file <url> <dest_path>
# -----------------------------------------------------------------------------
download_file() {
    local url="$1"
    local dest="$2"
    local dir
    dir=$(dirname "$dest")

    mkdir -p "$dir"

    echo "Downloading: $url"
    for i in 1 2 3 4 5; do
        if curl --connect-timeout 15 -fL "$url" -o "$dest"; then
            return 0
        fi
        warn "Download attempt $i failed. Retrying..."
        sleep 2
    done

    error_and_exit "Failed to download: $url"
}

# -----------------------------------------------------------------------------
# Extract a ZIP or CAB archive to a directory
# -----------------------------------------------------------------------------
extract_archive() {
    local archive="$1"
    local dest="$2"

    mkdir -p "$dest"

    case "$archive" in
        *.zip)
            if command -v unzip &>/dev/null; then
                unzip -q "$archive" -d "$dest"
            else
                error_and_exit "unzip not found. Install it first."
            fi
            ;;
        *.cab)
            if command -v cabextract &>/dev/null; then
                cabextract -q -d "$dest" "$archive"
            else
                error_and_exit "cabextract not found. Install it first."
            fi
            ;;
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$dest"
            ;;
        *.tar.xz)
            tar -xJf "$archive" -C "$dest"
            ;;
        *)
            error_and_exit "Unknown archive format: $archive"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Inject a driver (.inf + associated files) into the WIM mount
# Uses dism (if on Windows PE) or a Linux-side copy approach
# -----------------------------------------------------------------------------
inject_driver_to_wim() {
    local driver_dir="$1"
    local wim_mount="$2"

    info "Injecting drivers from: $driver_dir"

    if [ ! -d "$wim_mount" ]; then
        error_and_exit "WIM mount directory not found: $wim_mount"
    fi

    # Find all .inf files and copy the containing directory into the WIM
    local inf_files
    inf_files=$(find "$driver_dir" -name "*.inf" 2>/dev/null)

    if [ -z "$inf_files" ]; then
        warn "No .inf files found in: $driver_dir"
        return 0
    fi

    # Copy driver files into the WIM's driver staging area
    local wim_driver_dest="$wim_mount/Windows/INF/HorusDrivers"
    mkdir -p "$wim_driver_dest"
    cp -r "$driver_dir/." "$wim_driver_dest/"

    echo "Drivers staged to: $wim_driver_dest"
}

# =============================================================================
# Driver download functions — one per vendor/type
# =============================================================================

# -----------------------------------------------------------------------------
# VirtIO drivers (KVM/QEMU)
# Community build from Fedora people
# -----------------------------------------------------------------------------
download_virtio_drivers() {
    local win_ver="$1"   # e.g. "10.0" or "6.1"
    local arch="${2:-amd64}"
    local dest="$DRIVER_TMP/virtio"

    info "Downloading VirtIO drivers (win $win_ver / $arch)"

    # Map Windows version to virtio directory name
    local virtio_win_ver
    case "$win_ver" in
        6.0) virtio_win_ver="2k8"  ;;
        6.1) virtio_win_ver="w7"   ;;
        6.2) virtio_win_ver="w8"   ;;
        6.3) virtio_win_ver="w8.1" ;;
        10.0) virtio_win_ver="w10" ;;
        *)    virtio_win_ver="w10" ;;
    esac

    local base_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio"
    local iso_url="$base_url/virtio-win.iso"
    local iso_dest="$DRIVER_TMP/virtio-win.iso"

    download_file "$iso_url" "$iso_dest"

    # Mount ISO and extract drivers for the target Windows version
    local iso_mount="$DRIVER_TMP/virtio-iso-mount"
    mkdir -p "$iso_mount"

    if mount -o loop,ro "$iso_dest" "$iso_mount" 2>/dev/null; then
        # Copy all driver subdirectories for the target version
        for driver_dir in "$iso_mount"/*/; do
            local driver_name
            driver_name=$(basename "$driver_dir")
            local target_dir="$driver_dir${virtio_win_ver}/${arch}"

            if [ -d "$target_dir" ]; then
                mkdir -p "$dest/$driver_name"
                cp -r "$target_dir/." "$dest/$driver_name/"
            fi
        done
        umount "$iso_mount"
    else
        warn "Could not mount VirtIO ISO, trying direct extraction with 7z/isoinfo"
        # Fallback: use isoinfo or 7z
        if command -v 7z &>/dev/null; then
            7z x "$iso_dest" -o"$DRIVER_TMP/virtio-extracted" -y &>/dev/null || true
            # Find and copy the right version
            find "$DRIVER_TMP/virtio-extracted" -type d -name "$arch" | while read -r d; do
                if echo "$d" | grep -qi "$virtio_win_ver"; then
                    local dname
                    dname=$(basename "$(dirname "$d")")
                    mkdir -p "$dest/$dname"
                    cp -r "$d/." "$dest/$dname/"
                fi
            done
        else
            warn "Cannot extract VirtIO ISO — 7z not found. Skipping VirtIO drivers."
            return 0
        fi
    fi

    echo "VirtIO drivers saved to: $dest"
}

# -----------------------------------------------------------------------------
# AWS drivers: ENA NIC + NVMe storage
# -----------------------------------------------------------------------------
download_aws_drivers() {
    local win_ver="$1"
    local dest="$DRIVER_TMP/aws"

    info "Downloading AWS drivers (ENA NIC + NVMe)"

    # ENA driver
    local ena_url="https://s3.amazonaws.com/ec2-windows-drivers-downloads/ENA/Latest/AwsEnaNetworkDriver.zip"
    download_file "$ena_url" "$dest/ena.zip"
    extract_archive "$dest/ena.zip" "$dest/ena"

    # NVMe driver
    local nvme_url="https://s3.amazonaws.com/ec2-windows-drivers-downloads/NVMe/Latest/AWSNVMe.zip"
    download_file "$nvme_url" "$dest/nvme.zip"
    extract_archive "$dest/nvme.zip" "$dest/nvme"

    echo "AWS drivers saved to: $dest"
}

# -----------------------------------------------------------------------------
# GCP drivers: gVNIC NIC
# -----------------------------------------------------------------------------
download_gcp_drivers() {
    local win_ver="$1"
    local dest="$DRIVER_TMP/gcp"

    info "Downloading GCP drivers (gVNIC)"

    # gVNIC is distributed via GCS bucket
    local gvnic_url="https://storage.googleapis.com/gce-windows-drivers-public/release/gvnic/latest/gvnic-x64.zip"
    download_file "$gvnic_url" "$dest/gvnic.zip"
    extract_archive "$dest/gvnic.zip" "$dest/gvnic"

    echo "GCP drivers saved to: $dest"
}

# -----------------------------------------------------------------------------
# Azure drivers: MANA NIC
# -----------------------------------------------------------------------------
download_azure_drivers() {
    local win_ver="$1"
    local dest="$DRIVER_TMP/azure"

    info "Downloading Azure drivers (MANA NIC)"

    # MANA driver from Microsoft Update Catalog (static known URL)
    local mana_url="https://download.microsoft.com/download/1/7/A/17A9B91F-07BC-4E5A-8E3C-6D9D75A46980/mana.zip"

    if ! download_file "$mana_url" "$dest/mana.zip" 2>/dev/null; then
        warn "MANA driver download failed — Azure MANA may not be needed for this instance type."
        return 0
    fi

    extract_archive "$dest/mana.zip" "$dest/mana"
    echo "Azure drivers saved to: $dest"
}

# -----------------------------------------------------------------------------
# Intel VMD storage controller drivers
# Required for modern Intel platforms (11th gen+) with VMD enabled
# -----------------------------------------------------------------------------
download_intel_vmd_drivers() {
    local dest="$DRIVER_TMP/intel-vmd"

    info "Downloading Intel VMD storage drivers"

    # Intel RST driver covering 12th-15th gen (most common in current hardware)
    local rst_url="https://downloadmirror.intel.com/815806/SetupRST.exe"

    # We download the EXE and extract with 7z (it's a self-extracting archive)
    if ! download_file "$rst_url" "$dest/SetupRST.exe" 2>/dev/null; then
        warn "Intel RST driver download failed. Skipping VMD drivers."
        return 0
    fi

    if command -v 7z &>/dev/null; then
        7z x "$dest/SetupRST.exe" -o"$dest/extracted" -y &>/dev/null || true
        # Find .inf files in extracted content
        if find "$dest/extracted" -name "*.inf" | grep -q .; then
            echo "Intel VMD drivers extracted to: $dest/extracted"
        else
            warn "No .inf files found after extracting Intel RST — skipping."
        fi
    else
        warn "7z not found — cannot extract Intel RST driver. Skipping."
    fi
}

# =============================================================================
# Main orchestration
# =============================================================================

# -----------------------------------------------------------------------------
# download_required_drivers
# Detects platform and downloads only the drivers needed.
# Call this before mounting the WIM.
#
# Args:
#   $1 : Windows image name (e.g. "Windows 11 Enterprise LTSC 2024")
#   $2 : Architecture (default: amd64)
# -----------------------------------------------------------------------------
download_required_drivers() {
    local image_name="${1:-Windows 11 Pro}"
    local arch="${2:-amd64}"

    local win_ver
    win_ver=$(get_win_version_from_name "$image_name")

    local platform
    platform=$(detect_platform)

    info "Platform detected: $platform"
    info "Windows target  : $image_name (NT $win_ver)"
    info "Architecture    : $arch"

    mkdir -p "$DRIVER_TMP"

    case "$platform" in
        kvm)
            download_virtio_drivers "$win_ver" "$arch"
            ;;
        xen|aws)
            # AWS uses XEN or Nitro (KVM-based), both need VirtIO + AWS drivers
            download_virtio_drivers "$win_ver" "$arch"
            download_aws_drivers "$win_ver"
            ;;
        gcp)
            download_virtio_drivers "$win_ver" "$arch"
            download_gcp_drivers "$win_ver"
            ;;
        azure|hyperv)
            # Azure Hyper-V doesn't need VirtIO; needs MANA for newer instances
            download_azure_drivers "$win_ver"
            ;;
        none)
            # Bare metal — check if Intel VMD is relevant
            if grep -qi "VMD\|Rapid Storage" /sys/bus/pci/devices/*/label 2>/dev/null; then
                download_intel_vmd_drivers
            else
                warn "Bare metal detected but no specific drivers identified."
                warn "If Windows fails to detect storage/NIC, add drivers manually with --add-driver."
            fi
            ;;
        *)
            warn "Unknown platform '$platform' — downloading VirtIO as a safe default."
            download_virtio_drivers "$win_ver" "$arch"
            ;;
    esac

    echo ""
    echo "Driver download complete. Files in: $DRIVER_TMP"
    ls -lh "$DRIVER_TMP" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# inject_all_drivers
# Injects all downloaded drivers into the mounted WIM.
# Call this after download_required_drivers and after mounting the WIM.
#
# Args:
#   $1 : Path to mounted WIM directory (default: $WIMMOUNT)
# -----------------------------------------------------------------------------
inject_all_drivers() {
    local wim_mount="${1:-$WIMMOUNT}"

    info "Injecting all drivers into WIM"

    if [ ! -d "$DRIVER_TMP" ] || [ -z "$(ls -A "$DRIVER_TMP" 2>/dev/null)" ]; then
        warn "No drivers found in $DRIVER_TMP — skipping injection."
        return 0
    fi

    # Walk each vendor subdirectory
    for vendor_dir in "$DRIVER_TMP"/*/; do
        [ -d "$vendor_dir" ] || continue
        inject_driver_to_wim "$vendor_dir" "$wim_mount"
    done

    info "Driver injection complete"
}

# -----------------------------------------------------------------------------
# add_custom_driver
# Adds a user-specified driver (.inf or directory) to the staging area.
# Corresponds to the --add-driver flag in reinstall.sh.
#
# Args:
#   $1 : Path to .inf file or directory containing .inf files
# -----------------------------------------------------------------------------
add_custom_driver() {
    local path="$1"

    if [ ! -e "$path" ]; then
        error_and_exit "Custom driver path not found: $path"
    fi

    local dest="$DRIVER_TMP/custom/$(basename "$path")"
    mkdir -p "$dest"

    if [ -f "$path" ]; then
        # Single .inf — copy its parent directory
        cp -r "$(dirname "$path")/." "$dest/"
    elif [ -d "$path" ]; then
        cp -r "$path/." "$dest/"
    else
        error_and_exit "Not a file or directory: $path"
    fi

    echo "Custom driver staged: $path -> $dest"
}

# -----------------------------------------------------------------------------
# Main — run when executed directly (not sourced)
# -----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    IMAGE_NAME="${1:-Windows 11 Pro}"
    ARCH="${2:-amd64}"

    download_required_drivers "$IMAGE_NAME" "$ARCH"
fi
