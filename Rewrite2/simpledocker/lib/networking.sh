#!/usr/bin/env bash

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

_proxy_cfg()       { printf '%s/.sd/proxy.json'    "$MNT_DIR"; }

_proxy_caddyfile() { printf '%s/.sd/Caddyfile'     "$MNT_DIR"; }

_proxy_pidfile()   { printf '%s/.sd/.caddy.pid'    "$MNT_DIR"; }

_proxy_caddy_bin()     { printf '%s/.sd/caddy/caddy'       "$MNT_DIR"; }

_proxy_caddy_storage() { printf '%s/.sd/caddy/data'        "$MNT_DIR"; }

_proxy_caddy_runner()  { printf '%s/.sd/caddy/run.sh'      "$MNT_DIR"; }

_proxy_caddy_log()     { printf '%s/.sd/caddy/caddy.log'   "$MNT_DIR"; }

_proxy_get()       { jq -r ".$1 // empty" "$(_proxy_cfg)" 2>/dev/null; }

_proxy_running()   { local p; p=$(cat "$(_proxy_pidfile)" 2>/dev/null); [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

_proxy_dns_pidfile() { printf '%s/.sd/caddy/dnsmasq.pid'  "$MNT_DIR"; }

_proxy_dns_conf()    { printf '%s/.sd/caddy/dnsmasq.conf' "$MNT_DIR"; }

_proxy_dns_log()     { printf '%s/.sd/caddy/dnsmasq.log'  "$MNT_DIR"; }

_proxy_dns_running() { local p; p=$(cat "$(_proxy_dns_pidfile)" 2>/dev/null); [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

_hostpkg_flagfile() { printf '%s/.sd/.sd_hostpkg_%s' "$MNT_DIR" "$1"; }

_hostpkg_installed() { [[ -f "$(_hostpkg_flagfile "$1")" ]]; }

_hostpkg_mark()      { touch "$(_hostpkg_flagfile "$1")" 2>/dev/null; }

_hostpkg_unmark()    { rm -f "$(_hostpkg_flagfile "$1")" 2>/dev/null; }

_hostpkg_apt_sudoers_path() { printf '/etc/sudoers.d/simpledocker_apt_%s' "$(id -un)"; }

_hostpkg_ensure_apt_sudoers() { return 0;  # covered by main sudoers written at startup
    _hostpkg_ensure_apt_sudoers_unused() {
    local sudoers_path; sudoers_path="$(_hostpkg_apt_sudoers_path)"
    # Already written — nothing to do
    [[ -f "$sudoers_path" ]] && return 0
    local apt_bin; apt_bin=$(command -v apt-get 2>/dev/null || printf '/usr/bin/apt-get')
    local me; me=$(id -un)
    local sudoers_line; sudoers_line="${me} ALL=(ALL) NOPASSWD: ${apt_bin}"
    # Try passwordless first (e.g. already have broad NOPASSWD)
    if printf '%s\n' "$sudoers_line" | sudo -n tee "$sudoers_path" >/dev/null 2>&1; then
        chmod 0440 "$sudoers_path" 2>/dev/null || sudo -n chmod 0440 "$sudoers_path" 2>/dev/null || true
        return 0
    fi
    # Need password — ask once in the terminal, then write sudoers
    printf '\n\033[1m[simpleDocker] One-time sudo setup for plugin installs.\033[0m\n'
    printf '  This grants passwordless apt-get for your user.\n'
    printf '  You will not be asked again.\n\n'
    if printf '%s\n' "$sudoers_line" | sudo tee "$sudoers_path" >/dev/null 2>&1; then
        sudo chmod 0440 "$sudoers_path" 2>/dev/null || true
        printf '\033[0;32m✓ Done — plugins will now install silently in background.\033[0m\n\n'
        return 0
    fi
    printf '\033[0;33m⚠  Could not write sudoers — plugin installs will prompt for password.\033[0m\n\n'
    return 1   # non-fatal: scripts fall back to plain sudo (works when attached)
    }  # end _hostpkg_ensure_apt_sudoers_unused
}

_avahi_piddir()  { printf '%s/.sd/caddy/avahi' "$MNT_DIR"; }

_avahi_pidfile() { printf '%s/%s.pid' "$(_avahi_piddir)" "$(printf '%s' "$1" | tr './' '__')"; }

_avahi_mdns_name() {
    # Append .local to any URL: comfyui.com → comfyui.com.local, comfyui.sd → comfyui.sd.local
    # Already ends in .local? return as-is
    local url="$1"
    [[ "$url" == *.local ]] && printf '%s' "$url" || printf '%s.local' "$url"
}

_avahi_start() {
    command -v avahi-publish >/dev/null 2>&1 || return 0
    _avahi_stop
    mkdir -p "$(_avahi_piddir)" 2>/dev/null
    local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$lan_ip" ]] && return 0
    local _seen="|"
    # Publish cid.local for every installed container — always, regardless of exposure mode.
    # mDNS is just name resolution; port access is controlled by iptables separately.
    _load_containers false 2>/dev/null || true
    for _acid in "${CT_IDS[@]}"; do
        [[ "$(_st "$_acid" installed)" != "true" ]] && continue
        local _aport; _aport=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$_acid/service.json" 2>/dev/null)
        local _aep; _aep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$_acid/service.json" 2>/dev/null)
        [[ -n "$_aep" ]] && _aport="$_aep"
        [[ -z "$_aport" || "$_aport" == "0" ]] && continue
        local _cid_mdns="${_acid}.local"
        [[ "$_seen" == *"|${_cid_mdns}|"* ]] && continue
        _seen+="|${_cid_mdns}|"
        setsid avahi-publish --address -R "$_cid_mdns" "$lan_ip"             </dev/null >>"$(_proxy_dns_log)" 2>&1 &
        printf '%d' "$!" > "$(_avahi_pidfile "$_cid_mdns")"
    done
    # Also publish route .local aliases for public-exposure routes
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        local url cid
        url=$(printf '%s' "$r" | jq -r '.url')
        cid=$(printf '%s' "$r" | jq -r '.cid')
        [[ "$(_exposure_get "$cid")" != "public" ]] && continue
        local mdns; mdns=$(_avahi_mdns_name "$url")
        [[ "$_seen" == *"|${mdns}|"* ]] && continue
        _seen+="|${mdns}|"
        setsid avahi-publish --address -R "$mdns" "$lan_ip"             </dev/null >>"$(_proxy_dns_log)" 2>&1 &
        printf '%d' "$!" > "$(_avahi_pidfile "$mdns")"
    done < <(jq -c '.routes[]?' "$(_proxy_cfg)" 2>/dev/null)
}

_avahi_stop() {
    local piddir; piddir=$(_avahi_piddir)
    [[ ! -d "$piddir" ]] && return 0
    for pf in "$piddir"/*.pid; do
        [[ -f "$pf" ]] || continue
        local pid; pid=$(cat "$pf" 2>/dev/null)
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        rm -f "$pf"
    done
    pkill -f "avahi-publish.*--address" 2>/dev/null || true
}

_avahi_running() {
    # Consider avahi "running" if avahi-daemon is active (it handles mDNS resolution)
    # The avahi-publish processes only appear for public routes
    command -v avahi-publish >/dev/null 2>&1 || return 1
    systemctl is-active --quiet avahi-daemon 2>/dev/null && return 0
    # Fallback: check for live publish processes
    local piddir; piddir=$(_avahi_piddir)
    [[ ! -d "$piddir" ]] && return 1
    for pf in "$piddir"/*.pid; do
        [[ -f "$pf" ]] || continue
        local pid; pid=$(cat "$pf" 2>/dev/null)
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

_proxy_dns_write() {
    # Build a dnsmasq config that resolves all proxy hostnames to the LAN IP.
    # Other devices use this host as DNS (set in router DHCP or per-device settings).
    local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$lan_ip" ]] && return 1
    local conf; conf=$(_proxy_dns_conf)
    mkdir -p "$(dirname "$conf")" 2>/dev/null
    # Forward unknown queries upstream; bind only on LAN IP to avoid conflict with systemd-resolved
    local upstream; upstream=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
    [[ -z "$upstream" || "$upstream" == "$lan_ip" || "$upstream" == "127.0.0.53" ]] && upstream="1.1.1.1"
    {
        printf 'listen-address=%s
' "$lan_ip"
        printf 'bind-interfaces
'
        printf 'port=53
'
        printf 'log-facility=%s
' "$(_proxy_dns_log)"
        printf 'server=%s
' "$upstream"
        # One address record per proxy route pointing to this host's LAN IP
        jq -r '.routes[]?.url // empty' "$(_proxy_cfg)" 2>/dev/null | while read -r url; do
            [[ -z "$url" ]] && continue
            printf 'address=/%s/%s
' "$url" "$lan_ip"
        done
    } > "$conf"
}

_proxy_dns_start() {
    command -v dnsmasq >/dev/null 2>&1 || return 0   # dnsmasq not installed — skip silently
    _proxy_dns_write || return 0
    local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$lan_ip" ]] && return 0
    # Stop any old instance
    _proxy_dns_stop
    # dnsmasq needs root to bind port 53; sudoers written by _proxy_ensure_sudoers before this
    setsid sudo -n dnsmasq --conf-file="$(_proxy_dns_conf)" \
        --pid-file="$(_proxy_dns_pidfile)" </dev/null >>"$(_proxy_dns_log)" 2>&1 &
}

_proxy_dns_stop() {
    local pid; pid=$(cat "$(_proxy_dns_pidfile)" 2>/dev/null)
    if [[ -n "$pid" ]]; then
        sudo -n kill "$pid" 2>/dev/null || true
    else
        # Kill any dnsmasq listening on our LAN IP
        local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
        [[ -n "$lan_ip" ]] && sudo -n pkill -f "dnsmasq.*${lan_ip}" 2>/dev/null || true
    fi
    rm -f "$(_proxy_dns_pidfile)" 2>/dev/null || true
}

_proxy_write() {
    # Generate Caddyfile respecting exposure modes:
    #   isolated  — no Caddy stanza (completely blocked)
    #   localhost — stanza bound to 127.0.0.1 only (host browser only)
    #   public    — stanza on all interfaces + LAN_IP:port direct access
    local cf; cf=$(_proxy_caddyfile)
    printf '{\n  admin off\n  local_certs\n}\n\n' > "$cf"
    local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    # Write one Caddy stanza, binding based on exposure mode
    _pw_stanza() {
        local _exp="$1" _scheme="$2" _host="$3" _ct="$4" _p="$5"
        case "$_exp" in
            isolated) return ;;
            localhost|public)
                [[ "$_scheme" == "https" ]]                     && printf 'https://%s {
  tls internal
  reverse_proxy %s:%s
}

' "$_host" "$_ct" "$_p"                     || printf 'http://%s {
  reverse_proxy %s:%s
}

' "$_host" "$_ct" "$_p" ;;
        esac
    }

    local _seen_lan_ports="|"
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        local url cid https port
        url=$(printf '%s' "$r" | jq -r '.url')
        cid=$(printf '%s' "$r" | jq -r '.cid')
        https=$(printf '%s' "$r" | jq -r '.https // "false"')
        port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local ep; ep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        [[ -n "$ep" ]] && port="$ep"
        [[ -z "$port" || "$port" == "0" ]] && continue
        local ct_ip; ct_ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
        local exp_mode; exp_mode=$(_exposure_get "$cid")
        local scheme; [[ "$https" == "true" ]] && scheme="https" || scheme="http"
        # Named-URL stanza + its .local alias
        _pw_stanza "$exp_mode" "$scheme" "$url" "$ct_ip" "$port" >> "$cf"
        local mdns_url; mdns_url=$(_avahi_mdns_name "$url")
        [[ "$mdns_url" != "$url" ]] && _pw_stanza "$exp_mode" "$scheme" "$mdns_url" "$ct_ip" "$port" >> "$cf"

    done < <(jq -c '.routes[]?' "$(_proxy_cfg)" 2>/dev/null)

    # Per-container stanzas: cid.local (exposure-aware) + 127.0.0.1:port (localhost browser access)
    local _seen_cid="|"
    _load_containers false 2>/dev/null || true
    for _wcid in "${CT_IDS[@]}"; do
        [[ "$(_st "$_wcid" installed)" != "true" ]] && continue
        local _wport; _wport=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$_wcid/service.json" 2>/dev/null)
        local _wep; _wep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$_wcid/service.json" 2>/dev/null)
        [[ -n "$_wep" ]] && _wport="$_wep"
        [[ -z "$_wport" || "$_wport" == "0" ]] && continue
        [[ "$_seen_cid" == *"|${_wcid}|"* ]] && continue
        _seen_cid+="|${_wcid}|"
        local _wct_ip; _wct_ip=$(_netns_ct_ip "$_wcid" "$MNT_DIR")
        local _wexp; _wexp=$(_exposure_get "$_wcid")
        # cid.local — mDNS hostname routing (exposure-aware)
        _pw_stanza "$_wexp" "http" "${_wcid}.local" "$_wct_ip" "$_wport" >> "$cf"
    done
}

_proxy_update_hosts() {
    # Rewrite /etc/hosts: strip our old entries, re-add current routes if action=add
    local action="${1:-add}"
    local tmp; tmp=$(mktemp)
    grep -v '# simpleDocker' /etc/hosts > "$tmp" 2>/dev/null || cp /etc/hosts "$tmp"
    if [[ "$action" == "add" ]]; then
        # Get LAN IP once for public-exposure routes
        local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
        [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        jq -c '.routes[]?' "$(_proxy_cfg)" 2>/dev/null \
            | while IFS= read -r r; do
                [[ -z "$r" ]] && continue
                local url; url=$(printf '%s' "$r" | jq -r '.url')
                local cid; cid=$(printf '%s' "$r" | jq -r '.cid')
                [[ -z "$url" ]] && continue
                local exp_mode; exp_mode=$(_exposure_get "$cid")
                # Use LAN IP for public routes so other devices can reach the URL too
                local host_ip="127.0.0.1"
                [[ "$exp_mode" == "public" && -n "$lan_ip" ]] && host_ip="$lan_ip"
                printf '%s %s  # simpleDocker\n' "$host_ip" "$url"
                # Also add .local alias so the local machine can resolve comfyui.com.local
                local _mdns; _mdns=$(_avahi_mdns_name "$url")
                [[ "$_mdns" != "$url" ]] && printf '%s %s  # simpleDocker\n' "$host_ip" "$_mdns"
                # Also add cid.local so the local machine resolves it (Caddy stanza handles routing)
                printf '127.0.0.1 %s.local  # simpleDocker\n' "$cid"
              done >> "$tmp"
        # Also add hostnames for port-exposure containers (not in routes, but have a .local in Caddyfile)
        _load_containers false 2>/dev/null || true
        for _hcid in "${CT_IDS[@]}"; do
            [[ "$(_st "$_hcid" installed)" != "true" ]] && continue
            local _hport; _hport=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$_hcid/service.json" 2>/dev/null)
            [[ -z "$_hport" || "$_hport" == "0" ]] && continue
            local _hexp; _hexp=$(_exposure_get "$_hcid")
            [[ "$_hexp" == "isolated" ]] && continue
            local _hurl; _hurl="${_hcid}.local"
            local _hip="127.0.0.1"
            [[ "$_hexp" == "public" && -n "$lan_ip" ]] && _hip="$lan_ip"
            printf '%s %s  # simpleDocker\n' "$_hip" "$_hurl"
        done >> "$tmp"
    fi
    sudo -n tee /etc/hosts < "$tmp" >/dev/null 2>/dev/null || true
    rm -f "$tmp"
}

_proxy_sudoers_path() { printf '/etc/sudoers.d/simpledocker_caddy_%s' "$(id -un)"; }

_proxy_ensure_sudoers() {
    # Write a tiny wrapper script that sets CADDY_STORAGE_DIR and execs caddy.
    # We grant sudo to the wrapper — avoids "sudo -n env ..." which sudo rejects
    # because it sees "env" as the target command, not "caddy".
    local bin; bin="$(_proxy_caddy_bin)"
    local dnsmasq_bin; dnsmasq_bin=$(command -v dnsmasq 2>/dev/null || true)
    # Need at least one of caddy or dnsmasq to write sudoers
    [[ ! -x "$bin" && -z "$dnsmasq_bin" ]] && return 1
    local nopasswd_line=""
    if [[ -x "$bin" ]]; then
        local runner; runner="$(_proxy_caddy_runner)"
        local storage; storage="$(_proxy_caddy_storage)"
        printf '#!/bin/bash\nexport CADDY_STORAGE_DIR=%q\nexec %q "$@"\n' "$storage" "$bin" > "$runner"
        chmod +x "$runner"
        nopasswd_line="${runner}, /usr/sbin/update-ca-certificates, /usr/bin/update-ca-certificates"
    fi
    if [[ -n "$dnsmasq_bin" ]]; then
        local pkill_bin; pkill_bin=$(command -v pkill 2>/dev/null || printf '/usr/bin/pkill')
        [[ -n "$nopasswd_line" ]] && nopasswd_line+=", "
        nopasswd_line+="${dnsmasq_bin}, ${pkill_bin}"
    fi
    # Allow starting avahi-daemon without password
    local systemctl_bin; systemctl_bin=$(command -v systemctl 2>/dev/null || true)
    if [[ -n "$systemctl_bin" ]]; then
        [[ -n "$nopasswd_line" ]] && nopasswd_line+=", "
        nopasswd_line+="${systemctl_bin} start avahi-daemon, ${systemctl_bin} enable avahi-daemon"
    fi
    printf '%s ALL=(ALL) NOPASSWD: %s\n' "$(id -un)" "$nopasswd_line" \
        | sudo -n tee "$(_proxy_sudoers_path)" >/dev/null 2>/dev/null || true
}

_proxy_start() {
    # Optional flag: --background = fire and forget (no wait, no trust step blocking caller)
    local _bg=false; [[ "${1:-}" == "--background" ]] && _bg=true

    [[ ! -x "$(_proxy_caddy_bin)" ]] && { printf '[sd] caddy not installed\n' >>"$(_proxy_caddy_log)"; return 1; }
    [[ ! -f "$(_proxy_cfg)" ]] && return 0
    _proxy_write
    _proxy_update_hosts add
    _proxy_ensure_sudoers
    _proxy_dns_start
    # Ensure avahi-daemon is running (needed for mDNS resolution on LAN devices)
    systemctl is-active --quiet avahi-daemon 2>/dev/null \
        || sudo -n systemctl start avahi-daemon 2>/dev/null || true
    _avahi_start
    setsid sudo -n "$(_proxy_caddy_runner)" run --config "$(_proxy_caddyfile)" </dev/null >>"$(_proxy_caddy_log)" 2>&1 &
    printf '%d' "$!" > "$(_proxy_pidfile)"

    if [[ "$_bg" == "true" ]]; then
        # Non-blocking: do trust step async so menu appears instantly
        {
            local _w=0
            while ! _proxy_running && [[ $_w -lt 20 ]]; do sleep 0.3; (( _w++ )); done
            _proxy_trust_ca
        } &>/dev/null &
        return 0
    fi

    sleep 1.2
    if ! _proxy_running; then
        printf '[sd] Caddy failed to start — check "$(_proxy_caddy_log)"\n' >>"$(_proxy_caddy_log)"
        return 1
    fi
    _proxy_trust_ca
}

_proxy_trust_ca() {
    sudo -n chown -R "$(id -u):$(id -g)" "$(_proxy_caddy_storage)" 2>/dev/null || true
    local ca_crt; ca_crt="$(_proxy_caddy_storage)/pki/authorities/local/root.crt"
    local _waited=0
    while [[ ! -f "$ca_crt" && $_waited -lt 10 ]]; do sleep 0.5; (( _waited++ )); done
    sudo -n chown -R "$(id -u):$(id -g)" "$(_proxy_caddy_storage)" 2>/dev/null || true
    [[ ! -f "$ca_crt" ]] && { printf '[sd] Caddy CA cert never appeared\n' >>"$(_proxy_caddy_log)"; return 0; }

    # Install into system CA store — browser-agnostic, works for all browsers
    sudo -n cp "$ca_crt" /usr/local/share/ca-certificates/simpleDocker-caddy.crt 2>/dev/null \
        && sudo -n update-ca-certificates 2>/dev/null \
        && printf '[sd] CA trusted via system store\n' >>"$(_proxy_caddy_log)" \
        || printf '[sd] system CA trust failed (update-ca-certificates not available?)\n' >>"$(_proxy_caddy_log)"

    # Copy CA cert inside the img for reference/portability
    cp "$ca_crt" "$MNT_DIR/.sd/caddy/ca.crt" 2>/dev/null || true
}

_proxy_stop() {
    local pid; pid=$(cat "$(_proxy_pidfile)" 2>/dev/null)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$(_proxy_pidfile)" 2>/dev/null
    _proxy_dns_stop
    _avahi_stop
    [[ -f "$(_proxy_cfg)" ]] && _proxy_update_hosts remove || true
}

_proxy_install_caddy() {
    # $1 = "reinstall" for reinstall/update mode, default = fresh install
    local _mode="${1:-install}"
    mkdir -p "$MNT_DIR/.sd/caddy" 2>/dev/null
    local caddy_dest; caddy_dest="$(_proxy_caddy_bin)"

    local log_file="$TMP_DIR/.sd_caddy_log_$$"

    # Ensure passwordless apt-get before launching (asks password once if needed)
    _hostpkg_ensure_apt_sudoers

    local script; script=$(mktemp "$TMP_DIR/.sd_caddy_inst_XXXXXX.sh")
    {
        printf '#!/usr/bin/env bash\n'
        printf 'exec > >(tee -a %q) 2>&1\n' "$log_file"
        printf 'set -uo pipefail\n'
        printf 'die() { printf "\\033[0;31mFAIL: %%s\\033[0m\\n" "$*"; exit 1; }\n'

        # ── Part 1: Caddy binary from GitHub ──────────────────────────
        printf 'printf "\\033[1m── Installing Caddy ──────────────────────────\\033[0m\\n"\n'
        printf 'mkdir -p %q\n' "$MNT_DIR/.sd/caddy"
        printf 'case "$(uname -m)" in\n'
        printf '    x86_64)        ARCH=amd64 ;;\n'
        printf '    aarch64|arm64) ARCH=arm64 ;;\n'
        printf '    armv7l)        ARCH=armv7 ;;\n'
        printf '    *)             ARCH=amd64 ;;\n'
        printf 'esac\n'
        printf 'VER=""\n'
        printf 'printf "Fetching latest Caddy version...\\n"\n'
        printf 'API_RESP=$(curl -fsSL --max-time 15 "https://api.github.com/repos/caddyserver/caddy/releases/latest" 2>&1) && {\n'
        printf '    VER=$(printf "%%s" "$API_RESP" | tr -d "\\n" | grep -o '"'"'"tag_name":"[^"]*"'"'"' | cut -d: -f2 | tr -d '"'"'"v '"'"')\n'
        printf '} || printf "GitHub API unreachable: %%s\\n" "$API_RESP"\n'
        printf '[[ -z "$VER" ]] && {\n'
        printf '    VER=$(curl -fsSL --max-time 15 -o /dev/null -w "%%{url_effective}" \\\n'
        printf '         "https://github.com/caddyserver/caddy/releases/latest" 2>&1 | grep -o "[0-9]*\\.[0-9]*\\.[0-9]*" | head -1)\n'
        printf '}\n'
        printf '[[ -z "$VER" ]] && { printf "Using fallback version 2.9.1\\n"; VER="2.9.1"; }\n'
        printf 'printf "Version: %%s\\n" "$VER"\n'
        printf 'TMPD=$(mktemp -d)\n'
        printf 'URL="https://github.com/caddyserver/caddy/releases/download/v${VER}/caddy_${VER}_linux_${ARCH}.tar.gz"\n'
        printf 'printf "Downloading: %%s\\n" "$URL"\n'
        printf 'curl -fsSL --max-time 120 "$URL" -o "$TMPD/caddy.tar.gz" || die "Download failed"\n'
        printf 'tar -xzf "$TMPD/caddy.tar.gz" -C "$TMPD" caddy   || die "Extraction failed"\n'
        printf '[[ -f "$TMPD/caddy" ]] || die "caddy binary not found after extraction"\n'
        printf 'mv "$TMPD/caddy" %q\n' "$caddy_dest"
        printf 'chmod +x %q\n' "$caddy_dest"
        printf 'rm -rf "$TMPD"\n'
        printf 'printf "\\033[0;32m✓ Caddy binary ready\\033[0m\\n"\n'

        # ── Part 2: Write caddy sudoers (can use sudo -n now that apt sudoers is set) ──
        printf 'printf "%%s ALL=(ALL) NOPASSWD: %%s\\n" "$(id -un)" %q \\\n' "$caddy_dest"
        printf '    | sudo -n tee %q >/dev/null 2>/dev/null || true\n' "$(_proxy_sudoers_path)"

        # ── Part 3: avahi-utils via apt ────────────────────────────────
        printf 'printf "\\033[1m── Installing mDNS (avahi-utils) ─────────────\\033[0m\\n"\n'
        if [[ "$_mode" == "reinstall" ]]; then
            printf 'sudo -n apt-get install --reinstall -y avahi-utils 2>&1\n'
        else
            printf 'sudo -n apt-get install -y avahi-utils 2>&1\n'
        fi
        printf 'printf "\\033[0;32m✓ mDNS ready\\033[0m\\n"\n'

        printf 'printf "\\033[1;32m✓ Caddy + mDNS installed.\\033[0m\\n"\n'
    } > "$script"
    chmod +x "$script"

    local sess="sdCaddyMdnsInst_$$"
    local _tl_rc
    _tmux_launch "$sess" "Install Caddy + mDNS" "$script"
    _tl_rc=$?
    [[ $_tl_rc -eq 1 ]] && { rm -f "$script"; return 1; }
    return 0
}
