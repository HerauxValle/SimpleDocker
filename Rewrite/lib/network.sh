# lib/network.sh — Network namespace per mounted image, port exposure (isolated/localhost/public)
# Sourced by main.sh — do NOT run directly

#  NETWORK NAMESPACE — one per mounted img
#  10.88.<idx>.0/24 inside ns;  host veth gets 10.88.<idx>.254
#  containers: 10.88.<idx>.2+;  /etc/hosts inside ns for name→IP
_netns_name()  { printf 'sd_%s' "$(printf '%s' "${1:-$MNT_DIR}" | md5sum | cut -c1-8)"; }
_netns_idx()   { printf '%d' $(( 0x$(printf '%s' "${1:-$MNT_DIR}" | md5sum | cut -c1-2) % 254 )); }
_netns_hosts() { printf '%s/.sd/.netns_hosts' "${1:-$MNT_DIR}"; }

_netns_setup() {
    local mnt="${1:-$MNT_DIR}" ns idx subnet br veth_h veth_ns ip_ns ip_h
    ns=$(_netns_name "$mnt"); idx=$(_netns_idx "$mnt")
    subnet="10.88.${idx}"; br="sd-br${idx}"; veth_h="sd-h${idx}"; veth_ns="sd-ns${idx}"
    ip_ns="${subnet}.1"; ip_h="${subnet}.254"
    sudo -n ip netns list 2>/dev/null | grep -q "^${ns}" && return 0
    # Pre-cleanup: remove any stale host-side interfaces from a previous session that
    # wasn't cleanly torn down (prevents cascading "Cannot find device" errors).
    sudo -n ip link del "$veth_h" 2>/dev/null || true
    sudo -n ip netns del "$ns"    2>/dev/null || true
    sudo -n ip netns add "$ns"                                                         2>/dev/null || true
    sudo -n ip link add "$veth_h" type veth peer name "$veth_ns"                       2>/dev/null || true
    sudo -n ip link set "$veth_ns" netns "$ns"                                         2>/dev/null || true
    sudo -n ip netns exec "$ns" ip link add "$br" type bridge                          2>/dev/null || true
    sudo -n ip netns exec "$ns" ip link set "$veth_ns" master "$br"                    2>/dev/null || true
    sudo -n ip netns exec "$ns" ip addr add "${ip_ns}/24" dev "$br"                    2>/dev/null || true
    sudo -n ip netns exec "$ns" ip link set "$br"      up                              2>/dev/null || true
    sudo -n ip netns exec "$ns" ip link set "$veth_ns" up                              2>/dev/null || true
    sudo -n ip netns exec "$ns" ip link set lo         up                              2>/dev/null || true
    sudo -n ip addr add "${ip_h}/24" dev "$veth_h"                                     2>/dev/null || true
    sudo -n ip link set "$veth_h" up                                                   2>/dev/null || true
    sudo -n ip netns exec "$ns" sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
    printf '%s\n' "$ns"  > "${mnt}/.sd/.netns_name" 2>/dev/null || true
    printf '%s\n' "$idx" > "${mnt}/.sd/.netns_idx"  2>/dev/null || true
}

_netns_teardown() {
    local mnt="${1:-$MNT_DIR}" ns idx
    ns=$(_netns_name "$mnt"); idx=$(_netns_idx "$mnt")
    sudo -n ip netns del "$ns"      2>/dev/null || true
    sudo -n ip link del "sd-h${idx}" 2>/dev/null || true
    rm -f "${mnt}/.sd/.netns_name" "${mnt}/.sd/.netns_idx" "${mnt}/.sd/.netns_hosts" 2>/dev/null || true
}

_netns_ct_ip() {
    local cid="$1" mnt="${2:-$MNT_DIR}" idx last
    idx=$(_netns_idx "$mnt")
    last=$(( ( 0x$(printf '%s' "$cid" | md5sum | cut -c1-2) % 252 ) + 2 ))
    printf '10.88.%d.%d' "$idx" "$last"
}

_netns_ct_add() {
    local cid="$1" name="$2" mnt="${3:-$MNT_DIR}" ns idx ip br veth_h veth_ns port
    ns=$(_netns_name "$mnt"); idx=$(_netns_idx "$mnt")
    ip=$(_netns_ct_ip "$cid" "$mnt")
    br="sd-br${idx}"; veth_h="sd-c${idx}-${cid:0:6}"; veth_ns="sd-i${idx}-${cid:0:6}"
    sudo -n ip link add "$veth_h" type veth peer name "$veth_ns" 2>/dev/null || true
    sudo -n ip link set "$veth_ns" netns "$ns"                   2>/dev/null || true
    sudo -n ip netns exec "$ns" ip link set "$veth_ns" master "$br" 2>/dev/null || true
    sudo -n ip netns exec "$ns" ip addr add "${ip}/24" dev "$veth_ns" 2>/dev/null || true
    sudo -n ip netns exec "$ns" ip link set "$veth_ns" up        2>/dev/null || true
    sudo -n ip link set "$veth_h" up                             2>/dev/null || true
    # Port exposure managed by _exposure_apply (called separately on start)
    local hf; hf=$(_netns_hosts "$mnt")
    { grep -v " ${name}$" "$hf" 2>/dev/null; printf '%s %s\n' "$ip" "$name"; } > "${hf}.tmp" && mv "${hf}.tmp" "$hf" 2>/dev/null || true
}

_netns_ct_del() {
    local cid="$1" name="$2" mnt="${3:-$MNT_DIR}" idx ip port
    idx=$(_netns_idx "$mnt"); ip=$(_netns_ct_ip "$cid" "$mnt")
    local port2; port2=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
    sudo -n ip link del "sd-c${idx}-${cid:0:6}" 2>/dev/null || true
    _exposure_flush "$cid" "$port2" "$ip"
    local hf; hf=$(_netns_hosts "$mnt")
    { grep -v " ${name}$" "$hf" 2>/dev/null; } > "${hf}.tmp" && mv "${hf}.tmp" "$hf" 2>/dev/null || true
}

# ── Port exposure: isolated / localhost / public ──────────────────
# Stored in containers/<cid>/exposure  (values: isolated|localhost|public)
# Default: localhost (DNAT to host loopback only, same as before)
_exposure_file() { printf '%s/exposure' "$CONTAINERS_DIR/$1"; }
_exposure_get()  { local _v; _v=$(cat "$(_exposure_file "$1")" 2>/dev/null); case "$_v" in isolated|localhost|public) printf "%s" "$_v";; *) printf "localhost";; esac; }
_exposure_set()  { printf '%s' "$2" > "$(_exposure_file "$1")"; }
_exposure_next() {
    case "$(_exposure_get "$1")" in
        isolated)  printf 'localhost' ;;
        localhost) printf 'public'    ;;
        public)    printf 'isolated'  ;;
        *)         printf 'localhost' ;;
    esac
}
_exposure_label() {
    case "$1" in
        isolated) printf "${DIM}⬤  isolated${NC}" ;;
        localhost) printf "${YLW}⬤  localhost${NC}" ;;
        public)    printf "${GRN}⬤  public${NC}" ;;
        *)         printf "${YLW}⬤  localhost${NC}" ;;
    esac
}

_exposure_apply() {
    # Apply iptables rules for a container based on its exposure mode.
    # Called on start and on toggle. Safe to call multiple times (idempotent via -C check).
    local cid="$1" mode; mode=$(_exposure_get "$1")
    local port; port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
    local ep; ep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
    [[ -n "$ep" ]] && port="$ep"
    [[ -z "$port" || "$port" == "0" ]] && return 0
    local ct_ip; ct_ip=$(_netns_ct_ip "$cid" "$MNT_DIR")

    # Always flush old rules for this container first
    _exposure_flush "$cid" "$port" "$ct_ip"

    case "$mode" in
        isolated)
            # Block inbound from outside AND from host processes (including Caddy)
            sudo -n iptables -I INPUT   -p tcp --dport "$port" -j DROP 2>/dev/null || true
            sudo -n iptables -I OUTPUT  -p tcp -d "${ct_ip}/32" --dport "$port" -j DROP 2>/dev/null || true
            sudo -n iptables -I FORWARD -d "${ct_ip}/32" -p tcp --dport "$port" -j DROP 2>/dev/null || true
            ;;
        localhost)
            # localhost:port access is handled by Caddy (127.0.0.1:port stanza → ct_ip).
            # ip_forward needed so the host kernel routes packets to 10.88.x.y via veth.
            sudo -n sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
            sudo -n iptables -I FORWARD -d "${ct_ip}/32" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            sudo -n iptables -I FORWARD -s "${ct_ip}/32" -p tcp --sport "$port" -j ACCEPT 2>/dev/null || true
            ;;
        public)
            sudo -n sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
            # PREROUTING DNAT: LAN devices hitting host:port get forwarded to ct_ip:port
            sudo -n iptables -t nat -A PREROUTING -p tcp --dport "$port" -j DNAT --to-destination "${ct_ip}:${port}" 2>/dev/null || true
            sudo -n iptables -t nat -A POSTROUTING -d "${ct_ip}/32" -p tcp --dport "$port" -j MASQUERADE 2>/dev/null || true
            sudo -n iptables -I FORWARD -d "${ct_ip}/32" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            sudo -n iptables -I FORWARD -s "${ct_ip}/32" -p tcp --sport "$port" -j ACCEPT 2>/dev/null || true
            ;;
    esac
}

_exposure_flush() {
    local cid="$1" port="$2" ct_ip="$3"
    [[ -z "$port" || "$port" == "0" ]] && return 0
    [[ -z "$ct_ip" ]] && ct_ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
    # Remove DROP rules (isolated mode)
    sudo -n iptables -D INPUT   -p tcp --dport "$port" -j DROP 2>/dev/null || true
    sudo -n iptables -D OUTPUT  -p tcp -d "${ct_ip}/32" --dport "$port" -j DROP 2>/dev/null || true
    sudo -n iptables -D FORWARD -d "${ct_ip}/32" -p tcp --dport "$port" -j DROP 2>/dev/null || true
    # Remove all nat rules
    sudo -n iptables -t nat -D PREROUTING  -p tcp --dport "$port" -j DNAT --to-destination "${ct_ip}:${port}" 2>/dev/null || true
    sudo -n iptables -t nat -D POSTROUTING -d "${ct_ip}/32" -p tcp --dport "$port" -j MASQUERADE 2>/dev/null || true
    # Remove FORWARD rules
    sudo -n iptables -D FORWARD -d "${ct_ip}/32" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    sudo -n iptables -D FORWARD -s "${ct_ip}/32" -p tcp --sport "$port" -j ACCEPT 2>/dev/null || true
}


