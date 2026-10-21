#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use sudo)"
  exit 1
fi

# ==============================================================================
# Security and Validation Filters
# ==============================================================================

# Trim leading and trailing whitespace
trim_whitespace() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf "%s" "$var"
}

# Validate basic IPv4 dotted-quad format and octet ranges (0-255)
validate_ipv4_syntax() {
    local ip="$1"
    if [ -z "$ip" ]; then
        echo "IP address cannot be empty."
        return 1
    fi
    if [[ ! "$ip" =~ ^[0-9.]+$ ]]; then
        echo "contains invalid characters (only decimal numbers and dots allowed)."
        return 1
    fi
    local IFS=.
    local -a octets=($ip)
    if [ "${#octets[@]}" -ne 4 ]; then
        echo "must contain exactly 4 octets separated by dots (found ${#octets[@]})."
        return 1
    fi
    for octet in "${octets[@]}"; do
        if [ -z "$octet" ]; then
            echo "contains an empty octet."
            return 1
        fi
        if [[ "$octet" =~ ^0[0-9]+$ ]]; then
            echo "octet \"$octet\" has invalid leading zeros."
            return 1
        fi
        if (( 10#$octet < 0 || 10#$octet > 255 )); then
            echo "octet \"$octet\" is out of range (must be between 0 and 255)."
            return 1
        fi
    done
    return 0
}

# Validate unicast host IPv4 address (disallow 0.0.0.0/8, loopback, multicast, reserved/broadcast)
validate_host_ip() {
    local ip="$1"
    local err
    if ! err=$(validate_ipv4_syntax "$ip"); then
        echo "$err"
        return 1
    fi
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    o1=$((10#$o1))
    if (( o1 == 0 )); then
        echo "0.0.0.0/8 is reserved and cannot be assigned as a host IP address."
        return 1
    fi
    if (( o1 == 127 )); then
        echo "127.0.0.0/8 is loopback and cannot be assigned to an external interface."
        return 1
    fi
    if (( o1 >= 224 && o1 <= 239 )); then
        echo "multicast addresses (224.0.0.0 - 239.255.255.255) cannot be assigned as a host IP."
        return 1
    fi
    if (( o1 >= 240 )); then
        echo "reserved/broadcast addresses (240.0.0.0 - 255.255.255.255) cannot be assigned."
        return 1
    fi
    return 0
}

# Validate subnet mask or CIDR prefix and return numeric prefix (1-32)
parse_and_validate_subnet() {
    local subnet="$1"
    if [[ "$subnet" =~ ^/?([0-9]{1,2})$ ]]; then
        local p="${BASH_REMATCH[1]}"
        if (( 10#$p >= 1 && 10#$p <= 32 )); then
            echo "$((10#$p))"
            return 0
        fi
        return 1
    fi

    case "$subnet" in
        255.255.255.255) echo 32; return 0 ;;
        255.255.255.254) echo 31; return 0 ;;
        255.255.255.252) echo 30; return 0 ;;
        255.255.255.248) echo 29; return 0 ;;
        255.255.255.240) echo 28; return 0 ;;
        255.255.255.224) echo 27; return 0 ;;
        255.255.255.192) echo 26; return 0 ;;
        255.255.255.128) echo 25; return 0 ;;
        255.255.255.0)   echo 24; return 0 ;;
        255.255.254.0)   echo 23; return 0 ;;
        255.255.252.0)   echo 22; return 0 ;;
        255.255.248.0)   echo 21; return 0 ;;
        255.255.240.0)   echo 20; return 0 ;;
        255.255.224.0)   echo 19; return 0 ;;
        255.255.192.0)   echo 18; return 0 ;;
        255.255.128.0)   echo 17; return 0 ;;
        255.255.0.0)     echo 16; return 0 ;;
        255.254.0.0)     echo 15; return 0 ;;
        255.252.0.0)     echo 14; return 0 ;;
        255.248.0.0)     echo 13; return 0 ;;
        255.240.0.0)     echo 12; return 0 ;;
        255.224.0.0)     echo 11; return 0 ;;
        255.192.0.0)     echo 10; return 0 ;;
        255.128.0.0)     echo 9; return 0 ;;
        255.0.0.0)       echo 8; return 0 ;;
        254.0.0.0)       echo 7; return 0 ;;
        252.0.0.0)       echo 6; return 0 ;;
        248.0.0.0)       echo 5; return 0 ;;
        240.0.0.0)       echo 4; return 0 ;;
        224.0.0.0)       echo 3; return 0 ;;
        192.0.0.0)       echo 2; return 0 ;;
        128.0.0.0)       echo 1; return 0 ;;
        *) return 1 ;;
    esac
}

# Convert IPv4 dotted-quad to integer
ip_to_int() {
    local ip="$1"
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    echo $(( (10#$o1 << 24) + (10#$o2 << 16) + (10#$o3 << 8) + 10#$o4 ))
}

# Convert integer to IPv4 dotted-quad
int_to_ip() {
    local int="$1"
    echo "$(( (int >> 24) & 255 )).$(( (int >> 16) & 255 )).$(( (int >> 8) & 255 )).$(( int & 255 ))"
}

# Check if IP is network or broadcast address of its subnet
validate_ip_in_subnet() {
    local ip="$1"
    local prefix="$2"
    local ip_num
    ip_num=$(ip_to_int "$ip")
    local mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    local net=$(( ip_num & mask ))
    local bcast=$(( net | ((~mask) & 0xFFFFFFFF) ))

    if (( prefix < 31 )); then
        if (( ip_num == net )); then
            echo "IP address $ip is the network address for subnet $(int_to_ip $net)/$prefix."
            return 1
        fi
        if (( ip_num == bcast )); then
            echo "IP address $ip is the broadcast address for subnet $(int_to_ip $net)/$prefix."
            return 1
        fi
    fi
    return 0
}

# Validate default gateway against host IP and subnet
validate_gateway() {
    local ip="$1"
    local prefix="$2"
    local gw="$3"

    local err
    if ! err=$(validate_host_ip "$gw"); then
        echo "$err"
        return 1
    fi

    if [ "$ip" = "$gw" ]; then
        echo "gateway address cannot be identical to host IP ($ip)."
        return 1
    fi

    local ip_num
    ip_num=$(ip_to_int "$ip")
    local gw_num
    gw_num=$(ip_to_int "$gw")
    local mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    local net=$(( ip_num & mask ))
    local bcast=$(( net | ((~mask) & 0xFFFFFFFF) ))
    local gw_net=$(( gw_num & mask ))

    if (( gw_net != net )); then
        echo "gateway ($gw) is not in the same subnet ($(int_to_ip $net)/$prefix)."
        return 1
    fi

    if (( prefix < 31 )); then
        if (( gw_num == net )); then
            echo "gateway ($gw) cannot be the network address ($(int_to_ip $net))."
            return 1
        fi
        if (( gw_num == bcast )); then
            echo "gateway ($gw) cannot be the broadcast address ($(int_to_ip $bcast))."
            return 1
        fi
    fi
    return 0
}

# ==============================================================================
# Interface Discovery & Selection
# ==============================================================================

echo "Available Ethernet Interfaces:"
# List physical ethernet interfaces
mapfile -t INTERFACES < <(ip -o link show | awk -F': ' '{print $2}' | awk -F'@' '{print $1}' | grep -E '^en|^eth' | grep -v '\.' | sort -u)

if [ ${#INTERFACES[@]} -eq 0 ]; then
    echo "No Ethernet interfaces found."
    exit 1
fi

for idx in "${!INTERFACES[@]}"; do
    echo "  $((idx + 1))) ${INTERFACES[idx]}"
done

if [ ${#INTERFACES[@]} -eq 1 ]; then
    read -p "Select interface [1]: " IFACE_CHOICE
    IFACE_CHOICE=${IFACE_CHOICE:-1}
else
    read -p "Select interface [1-${#INTERFACES[@]}]: " IFACE_CHOICE
fi
IFACE_CHOICE="$(trim_whitespace "$IFACE_CHOICE")"

# Support selecting by index number or interface name safely
IFACE=""
if [[ "$IFACE_CHOICE" =~ ^[0-9]+$ ]] && [ "$IFACE_CHOICE" -ge 1 ] && [ "$IFACE_CHOICE" -le "${#INTERFACES[@]}" ]; then
    IFACE="${INTERFACES[$((IFACE_CHOICE - 1))]}"
else
    for candidate in "${INTERFACES[@]}"; do
        if [ "$IFACE_CHOICE" = "$candidate" ]; then
            IFACE="$candidate"
            break
        fi
    done
fi

if [ -z "$IFACE" ]; then
    echo "Error: Invalid interface selected: '$IFACE_CHOICE'."
    exit 1
fi

if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
    echo "Error: Network interface '$IFACE' does not exist."
    exit 1
fi

echo "Selected interface: $IFACE"

# ==============================================================================
# VLAN Configuration
# ==============================================================================

read -p "Enter the VLAN ID you want to access (enter 0 to remove VLAN and use untagged): " VLAN_ID
VLAN_ID="$(trim_whitespace "$VLAN_ID")"

if [ -z "$VLAN_ID" ] || [[ ! "$VLAN_ID" =~ ^[0-9]+$ ]] || (( 10#$VLAN_ID < 0 || 10#$VLAN_ID > 4094 )); then
    echo "Error: Invalid VLAN ID '$VLAN_ID'. Must be an integer between 0 and 4094."
    exit 1
fi
VLAN_ID=$((10#$VLAN_ID))

# ==============================================================================
# IP Address / DHCP Configuration
# ==============================================================================

# Prompt for IP address or DHCP
read -p "Enter the IP address you want to assign (or type 'dhcp') [192.168.0.10]: " IP_INPUT
IP_INPUT="$(trim_whitespace "$IP_INPUT")"

if [[ "${IP_INPUT,,}" =~ ^(dhcp|auto)$ ]]; then
    USE_DHCP=true
    echo "DHCP selected. Skipping subnet and gateway configuration."
else
    USE_DHCP=false

    # Support optional CIDR notation in IP prompt (e.g. 192.168.0.10/24)
    SUBNET_DEFAULT="/24"
    if [[ "$IP_INPUT" == */* ]]; then
        IP="${IP_INPUT%/*}"
        SUBNET_DEFAULT="/${IP_INPUT#*/}"
    else
        IP="${IP_INPUT:-192.168.0.10}"
    fi
    IP="$(trim_whitespace "$IP")"

    # Validate IP address format and host range (strictly filters out e.g. 192.168.0.500)
    val_err=""
    if ! val_err=$(validate_host_ip "$IP"); then
        echo "Error: Invalid IP address '$IP' - $val_err"
        exit 1
    fi

    read -p "Enter the subnet mask/prefix [$SUBNET_DEFAULT]: " SUBNET
    SUBNET="${SUBNET:-$SUBNET_DEFAULT}"
    SUBNET="$(trim_whitespace "$SUBNET")"

    # Validate and normalize subnet prefix (supports /24, 24, or dotted decimal like 255.255.255.0)
    if ! PREFIX=$(parse_and_validate_subnet "$SUBNET"); then
        echo "Error: Invalid subnet mask or prefix '$SUBNET'. Must be CIDR prefix (1-32) or a valid contiguous dotted-decimal mask (e.g., 255.255.255.0)."
        exit 1
    fi

    # Ensure IP is neither the network nor broadcast address
    if ! val_err=$(validate_ip_in_subnet "$IP" "$PREFIX"); then
        echo "Error: $val_err"
        exit 1
    fi

    # Suggest smart default gateway if possible: first usable IP in subnet (net + 1)
    DEFAULT_GW=""
    if (( PREFIX < 31 )); then
        net_int=$(( $(ip_to_int "$IP") & ((0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF) ))
        first_usable=$(int_to_ip $(( net_int + 1 )))
        if [ "$IP" = "$first_usable" ]; then
            bcast_int=$(( net_int | ((~( (0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF )) & 0xFFFFFFFF) ))
            if (( bcast_int - 1 > net_int + 1 )); then
                DEFAULT_GW=$(int_to_ip $(( bcast_int - 1 )))
            else
                DEFAULT_GW="none"
            fi
        else
            DEFAULT_GW="$first_usable"
        fi
    else
        DEFAULT_GW="none"
    fi

    read -p "Enter the default gateway (or 'none') [${DEFAULT_GW:-none}]: " GATEWAY
    GATEWAY="${GATEWAY:-$DEFAULT_GW}"
    GATEWAY="$(trim_whitespace "$GATEWAY")"

    if [ -n "$GATEWAY" ] && [ "$GATEWAY" != "none" ]; then
        if ! val_err=$(validate_gateway "$IP" "$PREFIX" "$GATEWAY"); then
            echo "Error: Invalid gateway address '$GATEWAY' - $val_err"
            exit 1
        fi
    fi
fi

# ==============================================================================
# Network Configuration Execution
# ==============================================================================

# Detect whether NetworkManager (nmcli) is available and running
USE_NMCLI=false
if command -v nmcli >/dev/null 2>&1 && nmcli general status >/dev/null 2>&1; then
    USE_NMCLI=true
fi

# Stop any standalone DHCP client processes bound to a specific interface
release_dhcp_on_dev() {
    local dev="$1"
    [ -z "$dev" ] && return 0
    if command -v dhclient >/dev/null 2>&1; then
        dhclient -r -pf "/run/dhclient.${dev}.pid" "$dev" >/dev/null 2>&1 || true
        dhclient -r "$dev" >/dev/null 2>&1 || true
        pkill -f "dhclient.*(^|[[:space:]])${dev}([[:space:]]|$)" >/dev/null 2>&1 || true
    fi
    if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -k "$dev" >/dev/null 2>&1 || true
    fi
    if command -v udhcpc >/dev/null 2>&1; then
        pkill -f "udhcpc.*-i[[:space:]]*${dev}([[:space:]]|$)" >/dev/null 2>&1 || true
    fi
}

# Request a DHCP lease on a specific interface using available system tools
request_dhcp_on_dev() {
    local dev="$1"
    [ -z "$dev" ] && return 1
    if command -v dhclient >/dev/null 2>&1; then
        release_dhcp_on_dev "$dev"
        if command -v timeout >/dev/null 2>&1; then
            timeout 8 dhclient -pf "/run/dhclient.${dev}.pid" "$dev" >/dev/null 2>&1 || \
                dhclient -nw -pf "/run/dhclient.${dev}.pid" "$dev" >/dev/null 2>&1 || true
        else
            dhclient -nw -pf "/run/dhclient.${dev}.pid" "$dev" >/dev/null 2>&1 || \
                dhclient "$dev" >/dev/null 2>&1 || true
        fi
        return 0
    elif command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -b "$dev" >/dev/null 2>&1 || true
        return 0
    elif command -v udhcpc >/dev/null 2>&1; then
        udhcpc -i "$dev" -b -q >/dev/null 2>&1 || true
        return 0
    elif command -v networkctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        networkctl reconfigure "$dev" >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

# Wait up to 10 seconds for an IPv4 address on an interface
wait_for_dhcp_ip() {
    local dev="$1"
    local ip=""
    for _ in {1..10}; do
        ip=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet / {print $2}' | head -n1)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
        sleep 1
    done
    return 1
}

# Bring down any active NetworkManager connection attached to the selected base interface ($IFACE)
bring_down_base_connection() {
    if [ "$USE_NMCLI" = true ]; then
        nmcli -t -f DEVICE,UUID,NAME con show --active 2>/dev/null | while IFS=: read -r dev uuid name; do
            if [ "$dev" = "$IFACE" ] && [ -n "$uuid" ]; then
                echo "Bringing down active connection '$name' on $IFACE..."
                nmcli connection down uuid "$uuid" >/dev/null 2>&1 || true
            fi
        done
    fi
    release_dhcp_on_dev "$IFACE"
}

# Clean up previous VLAN connections and VLAN sub-interfaces on $IFACE
echo "Cleaning up previous VLAN connections..."
if [ "$USE_NMCLI" = true ]; then
    nmcli -t -f NAME con show 2>/dev/null | grep "^vlan-" | while read -r con; do
        nmcli con delete "$con" >/dev/null 2>&1 || true
    done
fi

# Clean up any kernel VLAN sub-interfaces attached to $IFACE (e.g. eth0.10)
ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk -v iface="$IFACE" -F'@' '$2 == iface {print $1}' | while read -r vdev; do
    if [ -n "$vdev" ]; then
        release_dhcp_on_dev "$vdev"
        ip addr flush dev "$vdev" 2>/dev/null || true
        ip link set "$vdev" down 2>/dev/null || true
        ip link delete "$vdev" 2>/dev/null || true
    fi
done

if [ "$VLAN_ID" -eq 0 ]; then
    if [ "$USE_DHCP" = true ]; then
        echo "Reverting to untagged network on $IFACE using DHCP..."
        release_dhcp_on_dev "$IFACE"
        ip link set "$IFACE" up
        ip addr flush dev "$IFACE" 2>/dev/null || true

        if [ "$USE_NMCLI" = true ]; then
            nmcli dev set "$IFACE" managed yes >/dev/null 2>&1 || true
            if ! nmcli dev connect "$IFACE" >/dev/null 2>&1; then
                request_dhcp_on_dev "$IFACE" || true
            fi
        else
            request_dhcp_on_dev "$IFACE" || true
        fi

        echo "Retrieving IP configuration via DHCP..."
        ASSIGNED_IP=$(wait_for_dhcp_ip "$IFACE")
        ASSIGNED_GW=$(ip route show dev "$IFACE" 2>/dev/null | awk '/default/ {print $3}' | head -n1)

        if [ -n "$ASSIGNED_IP" ]; then
            echo "Done! Your adapter ($IFACE) is now connected to the untagged network via DHCP."
            echo "  - IP / Subnet: $ASSIGNED_IP"
            echo "  - Gateway:     ${ASSIGNED_GW:-None}"
        else
            echo "Done! Adapter ($IFACE) configured for DHCP (waiting for DHCP lease from server)."
        fi
    else
        echo "Reverting to untagged network on $IFACE..."
        bring_down_base_connection
        ip link set "$IFACE" up
        ip addr flush dev "$IFACE" 2>/dev/null || true
        if ! ip addr add "${IP}/${PREFIX}" dev "$IFACE"; then
            echo "Error: Failed to assign IP ${IP}/${PREFIX} to $IFACE."
            exit 1
        fi
        if [ -n "$GATEWAY" ] && [ "$GATEWAY" != "none" ]; then
            if ! ip route replace default via "$GATEWAY" dev "$IFACE" 2>/dev/null; then
                echo "Warning: Failed to set default gateway $GATEWAY on $IFACE."
            fi
        fi
        echo "Done! Your adapter ($IFACE) is now connected to the untagged network with IP ${IP}/${PREFIX}."
    fi
else
    bring_down_base_connection
    ip addr flush dev "$IFACE" 2>/dev/null || true

    CON_NAME="vlan-${VLAN_ID}"
    VLAN_DEV="${IFACE}.${VLAN_ID}"
    NM_VLAN_SUCCESS=false

    if [ "$USE_NMCLI" = true ]; then
        if [ "$USE_DHCP" = true ]; then
            echo "Configuring VLAN $VLAN_ID on $IFACE using DHCP..."
            nmcli con add type vlan con-name "$CON_NAME" dev "$IFACE" id "$VLAN_ID" ipv4.method auto ipv6.method auto autoconnect yes
        else
            echo "Configuring VLAN $VLAN_ID on $IFACE with IP ${IP}/${PREFIX}..."
            NM_ARGS=()
            if [ -n "$GATEWAY" ] && [ "$GATEWAY" != "none" ]; then
                NM_ARGS+=(gw4 "$GATEWAY")
            fi
            nmcli con add type vlan con-name "$CON_NAME" dev "$IFACE" id "$VLAN_ID" ip4 "${IP}/${PREFIX}" "${NM_ARGS[@]}" ipv6.method auto autoconnect yes
        fi

        if [ $? -eq 0 ]; then
            ip link set "$IFACE" up 2>/dev/null || true
            echo "Bringing up VLAN connection $CON_NAME..."
            if nmcli con up "$CON_NAME"; then
                NM_VLAN_SUCCESS=true
                # Ensure original connection stays down after parent link comes up
                bring_down_base_connection
                ip link set "$IFACE" up 2>/dev/null || true
                NM_DETECTED_DEV=$(nmcli -t -f DEVICE con show id "$CON_NAME" 2>/dev/null | head -n1)
                VLAN_DEV=${NM_DETECTED_DEV:-"$VLAN_DEV"}
            else
                echo "Warning: nmcli could not activate $CON_NAME, falling back to iproute2..."
                nmcli con delete "$CON_NAME" >/dev/null 2>&1 || true
            fi
        fi
    fi

    # Headless / iproute2 fallback when NetworkManager is unavailable or interface is unmanaged
    if [ "$NM_VLAN_SUCCESS" = false ]; then
        echo "Configuring VLAN $VLAN_ID on $IFACE ($VLAN_DEV) using iproute2..."
        modprobe 8021q >/dev/null 2>&1 || true
        ip link set "$IFACE" up
        ip link delete "$VLAN_DEV" >/dev/null 2>&1 || true
        if ! ip link add link "$IFACE" name "$VLAN_DEV" type vlan id "$VLAN_ID"; then
            echo "Error: Failed to create VLAN interface $VLAN_DEV."
            exit 1
        fi
        if ! ip link set "$VLAN_DEV" up; then
            echo "Error: Failed to bring up VLAN interface $VLAN_DEV."
            exit 1
        fi

        if [ "$USE_DHCP" = true ]; then
            request_dhcp_on_dev "$VLAN_DEV" || true
        else
            ip addr flush dev "$VLAN_DEV" 2>/dev/null || true
            if ! ip addr add "${IP}/${PREFIX}" dev "$VLAN_DEV"; then
                echo "Error: Failed to assign IP ${IP}/${PREFIX} to $VLAN_DEV."
                exit 1
            fi
            if [ -n "$GATEWAY" ] && [ "$GATEWAY" != "none" ]; then
                if ! ip route replace default via "$GATEWAY" dev "$VLAN_DEV" 2>/dev/null; then
                    echo "Warning: Failed to set default gateway $GATEWAY on $VLAN_DEV."
                fi
            fi
        fi
    fi

    if [ "$USE_DHCP" = true ]; then
        echo "Retrieving IP configuration via DHCP..."
        ASSIGNED_IP=$(wait_for_dhcp_ip "$VLAN_DEV")
        ASSIGNED_GW=$(ip route show dev "$VLAN_DEV" 2>/dev/null | awk '/default/ {print $3}' | head -n1)

        if [ -n "$ASSIGNED_IP" ]; then
            echo "Done! Your adapter is now connected to VLAN $VLAN_ID via DHCP."
            echo "  - IP / Subnet: $ASSIGNED_IP"
            echo "  - Gateway:     ${ASSIGNED_GW:-None}"
        else
            echo "Done! Your adapter is now connected to VLAN $VLAN_ID via DHCP (waiting for DHCP lease from server)."
        fi
    else
        echo "Done! Your adapter is now connected to VLAN $VLAN_ID with IP ${IP}/${PREFIX}."
    fi
fi
