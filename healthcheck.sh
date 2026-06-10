#!/usr/bin/env bash
# HorusInstall - healthcheck.sh
# Pre-flight validation script. Run BEFORE reinstall.sh to verify the
# environment is ready for a Windows Server installation.
# Exits 0 if all checks pass, 1 if any critical check fails.
#
# Usage:
#   bash healthcheck.sh [--version 2022] [--port 3389]
#
# All flags are optional — mirrors reinstall.sh flags so you can run:
#   bash healthcheck.sh windows --version 2022 && bash reinstall.sh windows --version 2022

set -eE
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\e[31m'; YEL='\e[33m'; GRN='\e[32m'; CYN='\e[36m'; RST='\e[0m'; BLD='\e[1m'
ok()   { echo -e "${GRN}  [PASS]${RST} $*"; }
warn() { echo -e "${YEL}  [WARN]${RST} $*"; WARN_COUNT=$((WARN_COUNT+1)); }
fail() { echo -e "${RED}  [FAIL]${RST} $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
info() { echo -e "${CYN}  [INFO]${RST} $*"; }

FAIL_COUNT=0
WARN_COUNT=0

# ---------------------------------------------------------------------------
# Defaults (match reinstall.sh defaults)
# ---------------------------------------------------------------------------
WINDOWS_VERSION="2022"
RDP_PORT="3389"
ISO_LANG="en-us"

# Parse args — same interface as reinstall.sh so healthcheck can precede it
[ "${1:-}" = "windows" ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --version)  WINDOWS_VERSION="$2"; shift 2 ;;
        --port)     RDP_PORT="$2";        shift 2 ;;
        --lang)     ISO_LANG="$2";        shift 2 ;;
        *)          shift ;;
    esac
done

MASSGRAVE_API="https://massgrave.dev/api/list"
ALPINE_MIRROR_TEST="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/netboot/vmlinuz-virt"

# ---------------------------------------------------------------------------
echo ""
echo -e "${BLD}${CYN}================================================================${RST}"
echo -e "${BLD}${CYN}  HorusInstall Pre-flight Check${RST}"
echo -e "${BLD}${CYN}  Target: Windows Server ${WINDOWS_VERSION} Datacenter${RST}"
echo -e "${BLD}${CYN}================================================================${RST}"
echo ""

# ---------------------------------------------------------------------------
# 1. Root
# ---------------------------------------------------------------------------
echo -e "${BLD}[1] Privileges${RST}"
if [ "$(id -u)" -eq 0 ]; then
    ok "Running as root"
else
    fail "Must run as root (sudo bash healthcheck.sh)"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Virtualization / Container checks
# ---------------------------------------------------------------------------
echo -e "${BLD}[2] Virtualization${RST}"

# Block OpenVZ
if [ -f /proc/user_beancounters ]; then
    fail "OpenVZ detected — not supported"
else
    ok "Not OpenVZ"
fi

# Block LXC / Docker
if grep -qE "lxc|docker" /proc/1/cgroup 2>/dev/null; then
    fail "LXC/Docker container detected — not supported"
else
    ok "Not LXC/Docker"
fi

# Detect hypervisor (informational)
HYPERVISOR="unknown"
if command -v systemd-detect-virt >/dev/null 2>&1; then
    HYPERVISOR=$(systemd-detect-virt 2>/dev/null || echo "unknown")
fi
if [ "$HYPERVISOR" = "unknown" ]; then
    if dmesg 2>/dev/null | grep -iqE "kvm|qemu"; then
        HYPERVISOR="kvm"
    elif dmesg 2>/dev/null | grep -iq "vmware"; then
        HYPERVISOR="vmware"
    elif dmesg 2>/dev/null | grep -iq "virtualbox"; then
        HYPERVISOR="virtualbox"
    fi
fi
info "Hypervisor: $HYPERVISOR"
if [ "$HYPERVISOR" = "none" ]; then
    warn "Running on bare metal — verify GRUB is installed and accessible"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Boot environment
# ---------------------------------------------------------------------------
echo -e "${BLD}[3] Boot Environment${RST}"

# GRUB check
GRUB_CMD=""
for cmd in grub-mkconfig grub2-mkconfig; do
    command -v "$cmd" >/dev/null 2>&1 && GRUB_CMD="$cmd" && break
done
if [ -n "$GRUB_CMD" ]; then
    ok "GRUB found: $GRUB_CMD"
else
    fail "GRUB not found (grub-mkconfig / grub2-mkconfig missing)"
fi

# /etc/default/grub
if [ -f /etc/default/grub ]; then
    ok "/etc/default/grub exists"
else
    warn "/etc/default/grub not found — GRUB entry injection may need manual steps"
fi

# EFI vs BIOS
if [ -d /sys/firmware/efi ]; then
    info "Boot mode: EFI — GPT layout will be used"
else
    info "Boot mode: BIOS/Legacy — MBR layout will be used"
fi

# /boot is writable
if [ -w /boot ]; then
    ok "/boot is writable"
else
    fail "/boot is not writable — cannot place Alpine boot files"
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Hardware — RAM
# ---------------------------------------------------------------------------
echo -e "${BLD}[4] RAM${RST}"
MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_FREE_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
MEM_TOTAL_MB=$((MEM_TOTAL_KB/1024))
MEM_FREE_MB=$((MEM_FREE_KB/1024))

if [ "$MEM_TOTAL_KB" -ge 1048576 ]; then
    ok "Total RAM: ${MEM_TOTAL_MB} MB (>= 1 GB required)"
else
    fail "Total RAM: ${MEM_TOTAL_MB} MB — Windows Server Datacenter requires at least 1 GB"
fi

if [ "$MEM_FREE_KB" -ge 524288 ]; then
    ok "Available RAM: ${MEM_FREE_MB} MB (>= 512 MB recommended for WIM apply)"
else
    warn "Available RAM: ${MEM_FREE_MB} MB — less than 512 MB free; WIM apply may be slow or fail"
fi
echo ""

# ---------------------------------------------------------------------------
# 5. Hardware — Disk
# ---------------------------------------------------------------------------
echo -e "${BLD}[5] Disk${RST}"
BEST_DISK=""
BEST_SIZE=0
DISK_COUNT=0

while read -r name size; do
    echo "$name" | grep -qE '^(loop|ram|sr)' && continue
    [ "$size" -lt 1073741824 ] && continue
    DISK_COUNT=$((DISK_COUNT+1))
    if [ "$size" -gt "$BEST_SIZE" ]; then
        BEST_SIZE=$size
        BEST_DISK="/dev/$name"
    fi
done < <(lsblk -dn -b -o NAME,SIZE 2>/dev/null)

if [ -z "$BEST_DISK" ]; then
    fail "No eligible disk found (>= 1 GB, non-removable)"
else
    BEST_GB=$((BEST_SIZE/1073741824))
    if [ "$BEST_GB" -ge 25 ]; then
        ok "Largest disk: $BEST_DISK — ${BEST_GB} GB (>= 25 GB required)"
    else
        fail "Largest disk: $BEST_DISK — ${BEST_GB} GB — Windows Server Datacenter requires at least 25 GB"
    fi
    [ "$DISK_COUNT" -gt 1 ] && \
        warn "Multiple disks detected ($DISK_COUNT). Reinstall will target the LARGEST: $BEST_DISK"
fi

# Check free space for ISO download (uses /tmp or /)
FREE_TMP_KB=$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
FREE_ROOT_KB=$(df -k / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
MAX_FREE_KB=$(( FREE_TMP_KB > FREE_ROOT_KB ? FREE_TMP_KB : FREE_ROOT_KB ))
FREE_GB=$(( MAX_FREE_KB / 1048576 ))

if [ "$MAX_FREE_KB" -ge 6291456 ]; then
    ok "Free space for ISO download: ~${FREE_GB} GB (>= 6 GB recommended)"
else
    warn "Free space: ~${FREE_GB} GB — may be insufficient for ISO download (~5 GB needed)"
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Network
# ---------------------------------------------------------------------------
echo -e "${BLD}[6] Network${RST}"

NET_IFACE=$(ip route show 2>/dev/null | awk '/default/{print $5; exit}')
if [ -n "$NET_IFACE" ]; then
    ok "Default interface: $NET_IFACE"
else
    fail "No default network route found"
    NET_IFACE="eth0"
fi

NET_IPV4=$(ip -4 addr show dev "$NET_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
if [ -n "$NET_IPV4" ]; then
    ok "IPv4 address: $NET_IPV4"
else
    fail "Could not detect IPv4 address on $NET_IFACE"
fi

NET_GW=$(ip route show default 2>/dev/null | awk '/via/{print $3; exit}')
if [ -n "$NET_GW" ]; then
    ok "Gateway: $NET_GW"
else
    fail "No default gateway detected"
fi

# DNS
NET_DNS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
if [ -n "$NET_DNS" ] && ! echo "$NET_DNS" | grep -qE '^127\.'; then
    ok "DNS: $NET_DNS"
else
    warn "DNS is loopback or missing ($NET_DNS) — will use 8.8.8.8 as fallback"
fi

# RDP port availability
if command -v ss >/dev/null 2>&1; then
    if ss -tlnp 2>/dev/null | grep -q ":${RDP_PORT}"; then
        warn "Port $RDP_PORT is already in use on this system"
    else
        ok "RDP port $RDP_PORT is free"
    fi
elif command -v netstat >/dev/null 2>&1; then
    if netstat -tlnp 2>/dev/null | grep -q ":${RDP_PORT}"; then
        warn "Port $RDP_PORT is already in use"
    else
        ok "RDP port $RDP_PORT is free"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# 7. Connectivity — external endpoints
# ---------------------------------------------------------------------------
echo -e "${BLD}[7] Connectivity${RST}"

check_url() {
    local label="$1" url="$2" required="${3:-warn}"
    local code
    if command -v curl >/dev/null 2>&1; then
        code=$(curl -sSLk -o /dev/null -w "%{http_code}" --max-time 10 --retry 2 "$url" 2>/dev/null || echo "000")
    else
        code=$(wget --no-check-certificate -q --spider --server-response \
               "$url" 2>&1 | awk '/HTTP\//{print $2}' | tail -1 || echo "000")
    fi
    case "$code" in
        200|301|302|303|307|308) ok "$label (HTTP $code)" ;;
        000)
            [ "$required" = "fail" ] && fail "$label — unreachable (timeout/refused)" \
                                     || warn "$label — unreachable (may work from Alpine)"
            ;;
        404) fail "$label — HTTP 404 Not Found: $url" ;;
        *)   warn "$label — HTTP $code" ;;
    esac
}

check_url "Alpine mirror"    "$ALPINE_MIRROR_TEST"        "fail"
check_url "massgrave.dev API" "$MASSGRAVE_API"            "warn"
check_url "Google DNS (connectivity)" "https://8.8.8.8"  "warn"

# Ping gateway
if [ -n "$NET_GW" ]; then
    if ping -c 1 -W 3 "$NET_GW" >/dev/null 2>&1; then
        ok "Gateway $NET_GW pingable"
    else
        warn "Gateway $NET_GW not responding to ping (ICMP may be filtered)"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# 8. Required tools on current system
# ---------------------------------------------------------------------------
echo -e "${BLD}[8] Required Tools${RST}"

TOOLS_OK=true
for tool in curl wget; do
    command -v "$tool" >/dev/null 2>&1 \
        && ok "$tool found" \
        || warn "$tool not found (need at least one of curl/wget)"
done

for tool in grub-probe cpio gzip; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "$tool found"
    else
        warn "$tool not found — may cause issues during initrd build"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# 9. Disk mount / partition sanity
# ---------------------------------------------------------------------------
echo -e "${BLD}[9] Disk Sanity${RST}"

# Check nothing critical is mounted on target disk
if [ -n "$BEST_DISK" ]; then
    if mount | grep -q "^$BEST_DISK"; then
        MOUNTED_PARTS=$(mount | grep "^$BEST_DISK" | awk '{print $1, "on", $3}')
        warn "Target disk has mounted partitions — they will be unmounted by trans.sh:"
        echo "$MOUNTED_PARTS" | while read -r line; do warn "  $line"; done
    else
        ok "Target disk $BEST_DISK has no active mounts"
    fi
fi

# /boot/horusinstall dir (leftover from previous run)
if [ -d /boot/horusinstall ]; then
    warn "/boot/horusinstall already exists — leftover from a previous run. Will be overwritten."
else
    ok "No leftover /boot/horusinstall directory"
fi
echo ""

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
echo -e "${BLD}${CYN}================================================================${RST}"
echo -e "${BLD}  Pre-flight Results${RST}"
echo -e "${BLD}${CYN}================================================================${RST}"

if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
    echo -e "${GRN}${BLD}  ALL CHECKS PASSED — Ready to run reinstall.sh${RST}"
elif [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${YEL}${BLD}  PASSED WITH $WARN_COUNT WARNING(S) — Review warnings before proceeding${RST}"
else
    echo -e "${RED}${BLD}  $FAIL_COUNT CRITICAL CHECK(S) FAILED — Fix issues before running reinstall.sh${RST}"
fi

echo ""
echo -e "  Failures : ${RED}${BLD}${FAIL_COUNT}${RST}"
echo -e "  Warnings : ${YEL}${BLD}${WARN_COUNT}${RST}"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
