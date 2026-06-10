#!/bin/bash
# =============================================================================
# initrd-network.sh
# HorusInstall - Linux to Windows reinstall tool
# Based on: github.com/bin456789/reinstall (GPL-3.0)
# Modified by: HorusHDx
#
# Purpose: Configure networking inside the transitional Alpine Linux initrd
#          environment, before the Windows installer takes over.
#
# Supports:
#   - DHCP (IPv4 and IPv6)
#   - Static IPv4 (including /32 masks and out-of-subnet gateways)
#   - Static IPv6 (including /128)
#   - Pure IPv6 setups
#   - Multi-NIC environments (IPv4 and IPv6 on different interfaces)
#   - Automatic detection of network parameters from the current Linux system
# =============================================================================

set -eE

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
info()  { echo -e "\e[32m***** $(echo "$*" | tr '[:lower:]' '[:upper:]') *****\e[0m" >&2; }
warn()  { echo -e "\e[33mWarning: $*\e[0m" >&2; }
error() { echo -e "\e[31m***** ERROR *****\e[0m" >&2; echo -e "\e[31m$*\e[0m" >&2; }

error_and_exit() { error "$@"; exit 1; }

# -----------------------------------------------------------------------------
# Detect all active network interfaces (excluding loopback)
# -----------------------------------------------------------------------------
get_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | grep -v '@'
}

# -----------------------------------------------------------------------------
# Check if an interface has a DHCP lease (looks for dhclient/udhcpc PID files)
# -----------------------------------------------------------------------------
is_dhcp_interface() {
    local iface="$1"
    [ -f "/run/udhcpc.${iface}.pid" ] ||
    [ -f "/run/dhclient.${iface}.pid" ] ||
    [ -f "/var/run/udhcpc.${iface}.pid" ]
}

# -----------------------------------------------------------------------------
# Get IPv4 address and prefix for an interface
# Returns: "ADDRESS PREFIX" or empty
# -----------------------------------------------------------------------------
get_ipv4_info() {
    local iface="$1"
    ip -4 addr show dev "$iface" 2>/dev/null \
        | awk '/inet / {print $2}' \
        | head -1
}

# -----------------------------------------------------------------------------
# Get IPv6 address and prefix for an interface (non-link-local)
# Returns: "ADDRESS/PREFIX" or empty
# -----------------------------------------------------------------------------
get_ipv6_info() {
    local iface="$1"
    ip -6 addr show dev "$iface" 2>/dev/null \
        | awk '/inet6/ && !/fe80/ {print $2}' \
        | head -1
}

# -----------------------------------------------------------------------------
# Get default IPv4 gateway
# -----------------------------------------------------------------------------
get_ipv4_gateway() {
    ip -4 route show default 2>/dev/null \
        | awk '{print $3}' \
        | head -1
}

# -----------------------------------------------------------------------------
# Get default IPv6 gateway
# -----------------------------------------------------------------------------
get_ipv6_gateway() {
    ip -6 route show default 2>/dev/null \
        | awk '{print $3}' \
        | head -1
}

# -----------------------------------------------------------------------------
# Get DNS servers from resolv.conf
# -----------------------------------------------------------------------------
get_dns_servers() {
    grep '^nameserver' /etc/resolv.conf 2>/dev/null \
        | awk '{print $2}' \
        | head -2 \
        | tr '\n' ' ' \
        | sed 's/ $//'
}

# -----------------------------------------------------------------------------
# Convert CIDR prefix to netmask
# e.g. 24 -> 255.255.255.0
# -----------------------------------------------------------------------------
cidr_to_mask() {
    local prefix="$1"
    local mask=""
    local full_octets=$(( prefix / 8 ))
    local partial=$(( prefix % 8 ))

    for i in 1 2 3 4; do
        if [ "$i" -le "$full_octets" ]; then
            mask="${mask}255"
        elif [ "$i" -eq $(( full_octets + 1 )) ] && [ "$partial" -gt 0 ]; then
            mask="${mask}$(( 256 - ( 1 << ( 8 - partial ) ) ))"
        else
            mask="${mask}0"
        fi
        [ "$i" -lt 4 ] && mask="${mask}."
    done
    echo "$mask"
}

# -----------------------------------------------------------------------------
# Detect if the gateway is outside the subnet (/32 or out-of-subnet gateway)
# This is common in some cloud providers (Hetzner, some OVH configs, etc.)
# -----------------------------------------------------------------------------
is_gateway_out_of_subnet() {
    local ip="$1"
    local prefix="$2"
    local gw="$3"

    # /32 means single-host — gateway is always out of subnet
    [ "$prefix" -eq 32 ] && return 0

    # Check if gateway is in the same subnet
    local network
    network=$(ip route show dev "$(ip route get "$gw" 2>/dev/null | awk '{print $5; exit}')" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' | head -1)

    # If we can't determine, assume it's in subnet
    [ -z "$network" ] && return 1

    # Use ipcalc if available
    if command -v ipcalc &>/dev/null; then
        local net_addr
        net_addr=$(ipcalc -n "$ip/$prefix" 2>/dev/null | grep Network | awk '{print $2}')
        local gw_net
        gw_net=$(ipcalc -n "$gw/$prefix" 2>/dev/null | grep Network | awk '{print $2}')
        [ "$net_addr" != "$gw_net" ] && return 0
    fi

    return 1
}

# -----------------------------------------------------------------------------
# Generate Alpine /etc/network/interfaces content for static IPv4
# Handles out-of-subnet gateways with an explicit host route
# -----------------------------------------------------------------------------
gen_static_ipv4_config() {
    local iface="$1"
    local addr="$2"      # e.g. 1.2.3.4
    local prefix="$3"    # e.g. 24
    local gw="$4"        # e.g. 1.2.3.1
    local dns="$5"       # e.g. "8.8.8.8 8.8.4.4"

    local mask
    mask=$(cidr_to_mask "$prefix")

    cat <<EOF
auto $iface
iface $iface inet static
    address $addr
    netmask $mask
EOF

    # For /32 or out-of-subnet gateways, add a host route first
    if [ "$prefix" -eq 32 ]; then
        cat <<EOF
    pointopoint $gw
    gateway $gw
EOF
    else
        echo "    gateway $gw"
    fi

    if [ -n "$dns" ]; then
        echo "    dns-nameservers $dns"
    fi
}

# -----------------------------------------------------------------------------
# Generate Alpine /etc/network/interfaces content for static IPv6
# -----------------------------------------------------------------------------
gen_static_ipv6_config() {
    local iface="$1"
    local addr6="$2"    # e.g. 2001:db8::1
    local prefix6="$3"  # e.g. 64
    local gw6="$4"      # e.g. 2001:db8::ff

    cat <<EOF

auto $iface
iface $iface inet6 static
    address $addr6
    netmask $prefix6
    gateway $gw6
    pre-up echo 0 > /proc/sys/net/ipv6/conf/$iface/accept_ra
EOF

    # For /128 (single-host), add host route for the gateway
    if [ "$prefix6" -eq 128 ] && [ -n "$gw6" ]; then
        cat <<EOF
    up ip -6 route add $gw6 dev $iface
    up ip -6 route add default via $gw6 dev $iface
EOF
    fi
}

# -----------------------------------------------------------------------------
# collect_network_info
# Reads current network configuration from the running Linux system
# and exports it as variables for later use in the initrd.
# -----------------------------------------------------------------------------
collect_network_info() {
    info "Collecting network configuration"

    local ifaces
    ifaces=$(get_interfaces)

    if [ -z "$ifaces" ]; then
        error_and_exit "No active network interfaces found."
    fi

    # Walk interfaces, pick the first one with an IP
    for iface in $ifaces; do
        local ipv4_cidr ipv4_addr ipv4_prefix
        local ipv6_cidr ipv6_addr ipv6_prefix

        ipv4_cidr=$(get_ipv4_info "$iface")
        ipv6_cidr=$(get_ipv6_info "$iface")

        if [ -n "$ipv4_cidr" ]; then
            ipv4_addr="${ipv4_cidr%/*}"
            ipv4_prefix="${ipv4_cidr#*/}"
            export NET_IPV4_IFACE="$iface"
            export NET_IPV4_ADDR="$ipv4_addr"
            export NET_IPV4_PREFIX="$ipv4_prefix"
            export NET_IPV4_MASK=$(cidr_to_mask "$ipv4_prefix")
            export NET_IPV4_GW=$(get_ipv4_gateway)
        fi

        if [ -n "$ipv6_cidr" ]; then
            ipv6_addr="${ipv6_cidr%/*}"
            ipv6_prefix="${ipv6_cidr#*/}"
            export NET_IPV6_IFACE="$iface"
            export NET_IPV6_ADDR="$ipv6_addr"
            export NET_IPV6_PREFIX="$ipv6_prefix"
            export NET_IPV6_GW=$(get_ipv6_gateway)
        fi
    done

    export NET_DNS=$(get_dns_servers)

    # Use defaults if DNS is empty
    if [ -z "$NET_DNS" ]; then
        export NET_DNS="8.8.8.8 8.8.4.4"
        warn "No DNS found in resolv.conf, using defaults: $NET_DNS"
    fi

    echo "  IPv4 interface : ${NET_IPV4_IFACE:-none}"
    echo "  IPv4 address   : ${NET_IPV4_ADDR:-none}/${NET_IPV4_PREFIX:-}"
    echo "  IPv4 gateway   : ${NET_IPV4_GW:-none}"
    echo "  IPv6 interface : ${NET_IPV6_IFACE:-none}"
    echo "  IPv6 address   : ${NET_IPV6_ADDR:-none}/${NET_IPV6_PREFIX:-}"
    echo "  IPv6 gateway   : ${NET_IPV6_GW:-none}"
    echo "  DNS servers    : ${NET_DNS}"
}

# -----------------------------------------------------------------------------
# write_initrd_network_config
# Writes the /etc/network/interfaces file that will be embedded
# into the Alpine initrd so the transitional environment has connectivity.
#
# Output file path is passed as argument (default: /etc/network/interfaces)
# -----------------------------------------------------------------------------
write_initrd_network_config() {
    local out="${1:-/etc/network/interfaces}"

    info "Writing initrd network config to $out"

    # Always add loopback
    cat > "$out" <<EOF
auto lo
iface lo inet loopback

EOF

    # --- IPv4 ---
    if [ -n "$NET_IPV4_ADDR" ] && [ -n "$NET_IPV4_GW" ]; then
        local iface="${NET_IPV4_IFACE:-eth0}"

        if is_dhcp_interface "$iface"; then
            cat >> "$out" <<EOF
auto $iface
iface $iface inet dhcp

EOF
        else
            gen_static_ipv4_config \
                "$iface" \
                "$NET_IPV4_ADDR" \
                "$NET_IPV4_PREFIX" \
                "$NET_IPV4_GW" \
                "$NET_DNS" >> "$out"
            echo "" >> "$out"
        fi
    else
        # Fallback: try DHCP on all interfaces
        warn "No IPv4 config detected, falling back to DHCP on all interfaces."
        for iface in $(get_interfaces); do
            cat >> "$out" <<EOF
auto $iface
iface $iface inet dhcp

EOF
        done
    fi

    # --- IPv6 ---
    if [ -n "$NET_IPV6_ADDR" ] && [ -n "$NET_IPV6_GW" ]; then
        local iface6="${NET_IPV6_IFACE:-eth0}"

        # If IPv6 is on a different interface than IPv4, define it separately
        gen_static_ipv6_config \
            "$iface6" \
            "$NET_IPV6_ADDR" \
            "$NET_IPV6_PREFIX" \
            "$NET_IPV6_GW" >> "$out"
        echo "" >> "$out"
    elif [ -n "$NET_IPV6_ADDR" ]; then
        # IPv6 address but no gateway — try SLAAC
        local iface6="${NET_IPV6_IFACE:-eth0}"
        cat >> "$out" <<EOF

auto $iface6
iface $iface6 inet6 auto

EOF
    fi

    echo "Network config written to: $out"
    echo "--- Contents ---"
    cat "$out"
    echo "----------------"
}

# -----------------------------------------------------------------------------
# write_dns_config
# Writes /etc/resolv.conf for the initrd environment
# -----------------------------------------------------------------------------
write_dns_config() {
    local out="${1:-/etc/resolv.conf}"

    info "Writing DNS config to $out"

    # Clear and rewrite
    : > "$out"

    for ns in $NET_DNS; do
        echo "nameserver $ns" >> "$out"
    done

    # Always add a fallback
    if ! grep -q "8.8.8.8" "$out" 2>/dev/null; then
        echo "nameserver 8.8.8.8" >> "$out"
    fi
}

# -----------------------------------------------------------------------------
# Main — run when executed directly (not sourced)
# -----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    collect_network_info
    write_initrd_network_config
    write_dns_config
fi
