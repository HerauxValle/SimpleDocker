#!/usr/bin/env bash

_proxy_caddyfile() { printf '%s/.sd/Caddyfile'     "$MNT_DIR"; }

_proxy_caddy_storage() { printf '%s/.sd/caddy/data'        "$MNT_DIR"; }

_proxy_dns_pidfile() { printf '%s/.sd/caddy/dnsmasq.pid'  "$MNT_DIR"; }

_proxy_dns_running() { local p; p=$(cat "$(_proxy_dns_pidfile)" 2>/dev/null); [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

_hostpkg_flagfile() { printf '%s/.sd/.sd_hostpkg_%s' "$MNT_DIR" "$1"; }

_hostpkg_installed() { [[ -f "$(_hostpkg_flagfile "$1")" ]]; }

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

_proxy_menu() {
    [[ ! -f "$(_proxy_cfg)" ]] && printf '{"autostart":false,"routes":[]}' > "$(_proxy_cfg)"
    local _SEP_INST _SEP_STARTUP _SEP_ROUTES _SEP_NAV
    _SEP_INST="$(   printf "${BLD}  ── Installation ─────────────────────${NC}")"
    _SEP_STARTUP="$(printf "${BLD}  ── Startup ──────────────────────────${NC}")"
    _SEP_ROUTES="$( printf "${BLD}  ── Rerouting ────────────────────────${NC}")"
    _SEP_NAV="$(    printf "${BLD}  ── Navigation ───────────────────────${NC}")"

    while true; do
        local autostart; autostart=$(_proxy_get autostart); autostart="${autostart:-false}"
        local at_s; [[ "$autostart" == "true" ]] && at_s="${GRN}on${NC}" || at_s="${DIM}off${NC}"
        local caddy_ok=false; [[ -x "$(_proxy_caddy_bin)" ]] && caddy_ok=true
        local inst_s; $caddy_ok && inst_s="${GRN}installed${NC}" || inst_s="${RED}not installed${NC}"
        local run_s;  _proxy_running && run_s="${GRN}running${NC}" || run_s="${RED}stopped${NC}"
        local local_count=0
        while IFS= read -r _ru; do [[ "$_ru" == *.local ]] && (( local_count++ )) || true
        done < <(jq -r '.routes[]?.url // empty' "$(_proxy_cfg)" 2>/dev/null)
        local lines=("$_SEP_INST"
            "$(printf " ${DIM}◈${NC}  Caddy + mDNS — %b" "$inst_s")"
            "$_SEP_STARTUP"
            "$(printf " ${DIM}◈${NC}  Running — %b" "$run_s")"
            "$(printf " ${DIM}◈${NC}  Autostart — %b  ${DIM}(starts with img mount)${NC}" "$at_s")"
            "$_SEP_ROUTES")

        local route_urls=(); local route_lines=()
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            local rurl rcid rhttps proto rname
            rurl=$( printf '%s' "$r" | jq -r '.url');  rcid=$(printf '%s' "$r" | jq -r '.cid')
            rhttps=$(printf '%s' "$r" | jq -r '.https // "false"')
            rname=$(_cname "$rcid" 2>/dev/null || printf '%s' "$rcid")
            [[ "$rhttps" == "true" ]] && proto="https" || proto="http"
            local rmdns; rmdns=$(_avahi_mdns_name "$rurl")
            route_lines+=("$(printf " ${CYN}◈${NC}  ${CYN}%s${NC}  →  %s  ${DIM}(%s  mDNS: %s)${NC}" "$rurl" "$rname" "$proto" "$rmdns")")
            route_urls+=("$rurl")
        done < <(jq -c '.routes[]?' "$(_proxy_cfg)" 2>/dev/null)
        for rl in "${route_lines[@]}"; do lines+=("$rl"); done
        lines+=("$(printf "${GRN} +${NC}  Add URL")")

        # ── Port exposure per container ────────────────────────────
        local _SEP_EXP; _SEP_EXP="$(printf "${BLD}  ── Port exposure ────────────────────${NC}")"
        lines+=("$_SEP_EXP")
        local exp_cids=() exp_names=()
        _load_containers false
        for i in "${!CT_IDS[@]}"; do
            local ecid="${CT_IDS[$i]}"
            [[ "$(_st "$ecid" installed)" != "true" ]] && continue
            local eport; eport=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$ecid/service.json" 2>/dev/null)
            local eep; eep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$ecid/service.json" 2>/dev/null)
            [[ -n "$eep" ]] && eport="$eep"
            [[ -z "$eport" || "$eport" == "0" ]] && continue
            local ename="${CT_NAMES[$i]}"
            local ect_ip; ect_ip=$(_netns_ct_ip "$ecid" "$MNT_DIR")
            lines+=("$(printf " %b  %s  ${DIM}%s:%s  %s.local${NC}" "$(_exposure_label "$(_exposure_get "$ecid")")" "$ename" "$ect_ip" "$eport" "$ecid")")
            exp_cids+=("$ecid"); exp_names+=("$ename")
        done
        [[ ${#exp_cids[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no installed containers with ports)${NC}")")

        lines+=("$_SEP_NAV" "$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Reverse proxy ──${NC}  ${DIM}ns: 10.88.%d.0/24${NC}" "$(_netns_idx "$MNT_DIR")")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "$sel" ]] && return
        local sc; sc=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*//')

        case "$sc" in
            *"${L[back]}"*) return ;;
            *"Caddy + mDNS"*)
                if $caddy_ok; then
                    _menu "Caddy + mDNS" "Reinstall / update" "Uninstall" "View log" "View Caddyfile" "Reset proxy config" || continue
                    case "$REPLY" in
                        "Reinstall / update")
                            _proxy_install_caddy "reinstall"
                            _hostpkg_mark "avahi-utils" ;;
                        "Uninstall")
                            _proxy_stop 2>/dev/null; _avahi_stop 2>/dev/null || true
                            rm -f "$(_proxy_caddy_bin)" "$(_proxy_caddy_runner)" 2>/dev/null
                            sudo -n rm -f "$(_proxy_sudoers_path)" 2>/dev/null || true
                            _hostpkg_ensure_apt_sudoers
                            local _sc; _sc=$(mktemp "$TMP_DIR/.sd_avahi_XXXXXX.sh")
                            printf '#!/usr/bin/env bash\nsudo -n apt-get remove -y avahi-utils 2>&1\n' > "$_sc"; chmod +x "$_sc"
                            _tmux_launch "sdAvahiUninst" "Uninstall mDNS (avahi-utils)" "$_sc"; rm -f "$_sc"
                            _hostpkg_unmark "avahi-utils" ;;
                        "View log") pause "$(cat "$(_proxy_caddy_log)" 2>/dev/null | tail -50 || echo "(no log)")" ;;
                        "View Caddyfile") pause "$(cat "$(_proxy_caddyfile)" 2>/dev/null || echo "(no Caddyfile)")" ;;
                        "Reset proxy config")
                            confirm "$(printf '⚠  This will:\n  - Remove all custom rerouting URLs\n  - Reset all containers to default exposure (localhost)\n\nThe Caddyfile will be regenerated from scratch.\nContinue?')" || continue
                            _proxy_stop 2>/dev/null || true
                            # Wipe proxy.json — removes all custom routes
                            printf '{"autostart":false,"routes":[]}' > "$(_proxy_cfg)"
                            # Reset all container exposure files to default (localhost)
                            _load_containers false 2>/dev/null || true
                            for _rcid in "${CT_IDS[@]}"; do
                                [[ -f "$(_exposure_file "$_rcid")" ]] && rm -f "$(_exposure_file "$_rcid")"
                            done
                            # Regenerate Caddyfile and restart
                            _proxy_write
                            _proxy_update_hosts add
                            _proxy_start
                            pause "Proxy config reset and restarted." ;;
                    esac
                else
                    _proxy_install_caddy
                    _hostpkg_mark "avahi-utils"
                    while tmux_up "sdCaddyMdnsInst_$$" 2>/dev/null; do sleep 0.3; done
                fi
                continue ;;
            *"Autostart"*)
                [[ "$autostart" == "true" ]] \
                    && local _ptmp; _ptmp=$(mktemp "$TMP_DIR/.sd_px_XXXXXX") && jq '.autostart=false' "$(_proxy_cfg)" > "$_ptmp" && mv "$_ptmp" "$(_proxy_cfg)" || rm -f "$_ptmp" \
                    || local _ptmp; _ptmp=$(mktemp "$TMP_DIR/.sd_px_XXXXXX") && jq '.autostart=true' "$(_proxy_cfg)" > "$_ptmp" && mv "$_ptmp" "$(_proxy_cfg)" || rm -f "$_ptmp" ;;
            *"Running"*)
                if _proxy_running; then
                    _proxy_stop; _avahi_stop 2>/dev/null || true; pause "Proxy stopped."
                else
                    if _proxy_start; then
                        _hostpkg_installed "avahi-utils" && _avahi_start
                        pause "Proxy started."
                    else
                        local _caddy_log_tail; _caddy_log_tail=$(tail -30 "$(_proxy_caddy_log)" 2>/dev/null || echo "(no log yet)")
                        local _extra=""
                        # Detect port conflict: "ambiguous site definition: http://localhost:PORT"
                        local _conflict_port; _conflict_port=$(printf '%s' "$_caddy_log_tail" \
                            | grep -oP 'ambiguous site definition: https?://[^:]+:\K[0-9]+' | head -1)
                        if [[ -n "$_conflict_port" ]]; then
                            local _conflicting=()
                            _load_containers false 2>/dev/null || true
                            for _cc in "${CT_IDS[@]}"; do
                                [[ "$(_st "$_cc" installed)" != "true" ]] && continue
                                local _cp; _cp=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$_cc/service.json" 2>/dev/null)
                                local _cep; _cep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$_cc/service.json" 2>/dev/null)
                                [[ -n "$_cep" ]] && _cp="$_cep"
                                [[ "$_cp" == "$_conflict_port" ]] && _conflicting+=("$(_cname "$_cc")")
                            done
                            if [[ ${#_conflicting[@]} -gt 1 ]]; then
                                local _clist; _clist=$(printf '  - %s\n' "${_conflicting[@]}")
                                _extra=$(printf '\n\n  Port conflict on :%s — containers sharing this port:\n%s\n  Fix: change one container port or set one to isolated.' \
                                    "$_conflict_port" "$_clist")
                            fi
                        fi
                        pause "$(printf '⚠  Caddy failed to start.%s\n\nLog:\n%s' "$_extra" "$_caddy_log_tail")"
                    fi
                fi ;;
            *"Add URL"*)
                _load_containers false
                [[ ${#CT_IDS[@]} -eq 0 ]] && { pause "No containers found."; continue; }
                local copts2=()
                for ci in "${CT_IDS[@]}"; do copts2+=("$(_cname "$ci")"); done
                local _fzf_out _fzf_pid _frc
                _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
                printf '%s\n' "${copts2[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Add route ──${NC}  ${DIM}Select container${NC}")" >"$_fzf_out" 2>/dev/null &
                _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
                wait "$_fzf_pid" 2>/dev/null; _frc=$?
                local csel; csel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
                _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
                [[ $_frc -ne 0 || -z "$csel" ]] && continue
                local ncid=""; for ci in "${CT_IDS[@]}"; do [[ "$(_cname "$ci")" == "$csel" ]] && ncid="$ci"; done
                local nport; nport=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$ncid/service.json" 2>/dev/null)
                local nep; nep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$ncid/service.json" 2>/dev/null)
                [[ -n "$nep" ]] && nport="$nep"
                [[ -z "$nport" || "$nport" == "0" ]] && { pause "$(printf "⚠  %s has no port defined.\n  Add 'port = XXXX' under [meta] in its blueprint." "$csel")"; continue; }
                finput "$(printf "Enter URL  (e.g. comfyui.local, myapp.local)\n\n  Use .local for zero-config LAN access on all devices (mDNS).\n  Other TLDs (e.g. .sd) only work on this machine unless you configure DNS.")" || continue
                local nurl="${FINPUT_RESULT}"; nurl="${nurl#http://}"; nurl="${nurl#https://}"; nurl="${nurl%%/*}"
                [[ -z "$nurl" ]] && continue
                local nhttps="false"
                _menu "Protocol for $nurl" "http  (no cert needed)" "https  (tls internal, CA trusted automatically)" || continue
                [[ "$REPLY" == "https"* ]] && nhttps="true"
                jq --arg u "$nurl" --arg c "$ncid" --argjson h "$nhttps" \
                    '.routes += [{"url":$u,"cid":$c,"https":$h}]' \
                    "$(_proxy_cfg)" > "$TMP_DIR/.sd_px_tmp.$$.tmp" && mv "$TMP_DIR/.sd_px_tmp.$$.tmp" "$(_proxy_cfg)" || rm -f "$TMP_DIR/.sd_px_tmp.$$.tmp"
                # Ensure Caddy CA is trusted when HTTPS selected
                [[ "$nhttps" == "true" && -x "$(_proxy_caddy_bin)" ]] \
                    && CADDY_STORAGE_DIR="$(_proxy_caddy_storage)" "$(_proxy_caddy_bin)" trust &>/dev/null &
                if _proxy_running; then
                    _proxy_stop; _proxy_start
                elif [[ "$(_proxy_get autostart)" == "true" ]]; then
                    _proxy_start --background
                fi
                pause "$(printf '✓ Added: %s → %s (port %s)\n\n  Visit: %s://%s' "$nurl" "$csel" "$nport" "$( [ "$nhttps" = "true" ] && echo "https" || echo "http" )" "$nurl")" ;;
            *)
                local _exp_hit=false
                for i in "${!exp_names[@]}"; do
                    [[ "$sc" != *"${exp_names[$i]}"* ]] && continue
                    local ecid2="${exp_cids[$i]}"
                    local _enew; _enew=$(_exposure_next "$ecid2")
                    _exposure_set "$ecid2" "$_enew"
                    tmux_up "$(tsess "$ecid2")" && _exposure_apply "$ecid2"
                    pause "$(printf "Port exposure set to: %b\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network" \
                        "$(_exposure_label "$_enew")")"
                    _exp_hit=true; break
                done
                [[ "$_exp_hit" == true ]] && continue
                # Otherwise it's a route URL — edit it
                local matched=""; local i
                for i in "${!route_lines[@]}"; do
                    [[ "$(printf '%s' "${route_lines[$i]}" | _strip_ansi | sed 's/^[[:space:]]*//')" == "$sc" ]] \
                        && matched="${route_urls[$i]}" && break
                done
                [[ -z "$matched" ]] && continue
                local rr; rr=$(jq -c --arg u "$matched" '.routes[] | select(.url==$u)' "$(_proxy_cfg)" 2>/dev/null)
                local rcid2; rcid2=$(printf '%s' "$rr" | jq -r '.cid')
                local rh2; rh2=$(printf '%s' "$rr" | jq -r '.https // "false"')
                _menu "$(printf 'Edit: %s' "$matched")" \
                    "Change URL" "Change container" "Toggle HTTPS (currently: $rh2)" "Remove" || continue
                case "$REPLY" in

                    "Change URL")
                        finput "New URL:" || continue
                        local nu="${FINPUT_RESULT}"; nu="${nu#http://}"; nu="${nu#https://}"; nu="${nu%%/*}"
                        [[ -z "$nu" ]] && continue
                        jq --arg o "$matched" --arg n "$nu" '(.routes[] | select(.url==$o)).url=$n' \
                            "$(_proxy_cfg)" > "$TMP_DIR/.sd_px_tmp.$$.tmp" && mv "$TMP_DIR/.sd_px_tmp.$$.tmp" "$(_proxy_cfg)" || rm -f "$TMP_DIR/.sd_px_tmp.$$.tmp"
                        _proxy_running && { _proxy_stop; _proxy_start; } ;;
                    "Change container")
                        _load_containers false
                        local copts3=(); for ci in "${CT_IDS[@]}"; do copts3+=("$(_cname "$ci")"); done
                        local _fzf_out _fzf_pid _frc
                        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
                        printf '%s\n' "${copts3[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Route: new container ──${NC}")" >"$_fzf_out" 2>/dev/null &
                        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
                        wait "$_fzf_pid" 2>/dev/null; _frc=$?
                        local cs3; cs3=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
                        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
                        [[ $_frc -ne 0 || -z "$cs3" ]] && continue
                        local nc3=""; for ci in "${CT_IDS[@]}"; do [[ "$(_cname "$ci")" == "$cs3" ]] && nc3="$ci"; done
                        jq --arg u "$matched" --arg c "$nc3" '(.routes[] | select(.url==$u)).cid=$c' \
                            "$(_proxy_cfg)" > "$TMP_DIR/.sd_px_tmp.$$.tmp" && mv "$TMP_DIR/.sd_px_tmp.$$.tmp" "$(_proxy_cfg)" || rm -f "$TMP_DIR/.sd_px_tmp.$$.tmp"
                        _proxy_running && { _proxy_stop; _proxy_start; } ;;
                    *"Toggle HTTPS"*)
                        local newh; [[ "$rh2" == "true" ]] && newh=false || newh=true
                        jq --arg u "$matched" --argjson h "$newh" '(.routes[] | select(.url==$u)).https=$h' \
                            "$(_proxy_cfg)" > "$TMP_DIR/.sd_px_tmp.$$.tmp" && mv "$TMP_DIR/.sd_px_tmp.$$.tmp" "$(_proxy_cfg)" || rm -f "$TMP_DIR/.sd_px_tmp.$$.tmp"
                        _proxy_running && { _proxy_stop; _proxy_start; } ;;
                    "Remove")
                        confirm "Remove $matched?" || continue
                        jq --arg u "$matched" '.routes=[.routes[] | select(.url!=$u)]' \
                            "$(_proxy_cfg)" > "$TMP_DIR/.sd_px_tmp.$$.tmp" && mv "$TMP_DIR/.sd_px_tmp.$$.tmp" "$(_proxy_cfg)" || rm -f "$TMP_DIR/.sd_px_tmp.$$.tmp"
                        _proxy_running && { _proxy_stop; _proxy_start; } ;;
                esac ;;
        esac
    done
}
