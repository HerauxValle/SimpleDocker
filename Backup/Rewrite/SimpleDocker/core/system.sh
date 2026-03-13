#!/usr/bin/env bash
# core/system.sh — image management, LUKS, networking, namespaces,
#                  port exposure, Ubuntu bootstrap, resize

_set_img_dirs() {
    BLUEPRINTS_DIR="$MNT_DIR/Blueprints"    CONTAINERS_DIR="$MNT_DIR/Containers"
    INSTALLATIONS_DIR="$MNT_DIR/Installations" BACKUP_DIR="$MNT_DIR/Backup"
    STORAGE_DIR="$MNT_DIR/Storage"
    UBUNTU_DIR="$MNT_DIR/Ubuntu"
    GROUPS_DIR="$MNT_DIR/Groups"
    LOGS_DIR="$MNT_DIR/Logs"
    mkdir -p "$BLUEPRINTS_DIR" "$CONTAINERS_DIR" "$INSTALLATIONS_DIR" "$BACKUP_DIR" \
             "$STORAGE_DIR" "$UBUNTU_DIR" "$GROUPS_DIR" "$LOGS_DIR" 2>/dev/null
    sudo -n chown "$(id -u):$(id -g)" \
        "$BLUEPRINTS_DIR" "$CONTAINERS_DIR" "$INSTALLATIONS_DIR" "$BACKUP_DIR" \
        "$STORAGE_DIR" "$UBUNTU_DIR" "$GROUPS_DIR" "$LOGS_DIR" 2>/dev/null || true
    _sd_ub_cache_check &  # background — results written to tmp files, read on first menu open
}

# Compute Ubuntu status once per mount — results stored in _SD_UB_PKG_DRIFT / _SD_UB_HAS_UPDATES
# Runs in background after mount — writes results to tmp files under SD_MNT_BASE/.tmp/
_sd_ub_cache_check() {
    [[ ! -f "$UBUNTU_DIR/.ubuntu_ready" ]] && return
    mkdir -p "$SD_MNT_BASE/.tmp" 2>/dev/null
    local _drift_f="$SD_MNT_BASE/.tmp/.sd_ub_drift_$$"
    local _upd_f="$SD_MNT_BASE/.tmp/.sd_ub_upd_$$"
    # Drift: fast local file compare — done immediately
    local _saved_pkgs_file="$UBUNTU_DIR/.ubuntu_default_pkgs"
    if [[ -f "$_saved_pkgs_file" ]]; then
        local _cur_sorted; _cur_sorted=$(printf '%s
' $DEFAULT_UBUNTU_PKGS | sort)
        local _saved_sorted; _saved_sorted=$(sort "$_saved_pkgs_file" 2>/dev/null)
        [[ "$_cur_sorted" != "$_saved_sorted" ]] && printf 'true' > "$_drift_f" || printf 'false' > "$_drift_f"
    else
        printf 'true' > "$_drift_f"
    fi
    # Updates: apt simulate — slow, runs last
    local _sim; _sim=$(_chroot_bash "$UBUNTU_DIR" -c         "apt-get update -qq 2>/dev/null; apt-get --simulate upgrade 2>/dev/null | grep -c '^Inst '" 2>/dev/null)
    [[ "${_sim:-0}" -gt 0 ]] && printf 'true' > "$_upd_f" || printf 'false' > "$_upd_f"
}

# Called lazily on first Ubuntu menu open — reads tmp files written by background check
# Guarded by _SD_UB_CACHE_LOADED so it only ever runs once per mount session
_sd_ub_cache_read() {
    [[ "$_SD_UB_CACHE_LOADED" == true ]] && return
    _SD_UB_CACHE_LOADED=true
    local _drift_f="$SD_MNT_BASE/.tmp/.sd_ub_drift_$$"
    local _upd_f="$SD_MNT_BASE/.tmp/.sd_ub_upd_$$"
    # Wait up to 3s for the background job to finish writing (usually already done)
    local _w=0
    while [[ ! -f "$_drift_f" && $_w -lt 30 ]]; do sleep 0.1; (( _w++ )); done
    [[ -f "$_drift_f" ]] && _SD_UB_PKG_DRIFT=$(cat "$_drift_f")   || _SD_UB_PKG_DRIFT=false
    [[ -f "$_upd_f"   ]] && _SD_UB_HAS_UPDATES=$(cat "$_upd_f")   || _SD_UB_HAS_UPDATES=false
    rm -f "$_drift_f" "$_upd_f"
}


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


# ── LUKS2 helpers ─────────────────────────────────────────────────
_luks_mapper()  { printf 'sd_%s' "$(basename "${1%.img}" | tr -dc 'a-zA-Z0-9_')"; }
_luks_dev()     { printf '/dev/mapper/%s' "$(_luks_mapper "$1")"; }
_luks_is_open() { [[ -b "$(_luks_dev "$1")" ]]; }
_img_is_luks()  { sudo -n cryptsetup isLuks "$1" 2>/dev/null; }

# Slot 0 auto-unlock: try SD_VERIFICATION_CIPHER first, prompt on fail
_luks_open() {
    local img="$1" mapper pass attempts=0
    mapper=$(_luks_mapper "$img")
    _luks_is_open "$img" && return 0
    # Try each method in SD_UNLOCK_ORDER
    local _method
    for _method in $SD_UNLOCK_ORDER; do
        case "$_method" in
            verified_system)
                printf '%s' "$SD_VERIFICATION_CIPHER" | sudo -n cryptsetup open --key-file=- "$img" "$mapper" &>/dev/null \
                    && return 0 ;;
            default_keyword)
                printf '%s' "$SD_DEFAULT_KEYWORD" | sudo -n cryptsetup open --key-file=- "$img" "$mapper" &>/dev/null \
                    && return 0 ;;
            prompt)
                while [[ $attempts -lt 3 ]]; do
                    clear
                    printf '\n  \033[1m── simpleDocker ──\033[0m\n'
                    printf '  \033[2m%s is encrypted. Enter passphrase.\033[0m\n\n' "$(basename "$img")"
                    printf '  \033[1mPassphrase:\033[0m '
                    IFS= read -rs pass; printf '\n\n'
                    if printf '%s' "$pass" | sudo -n cryptsetup open --key-file=- "$img" "$mapper" &>/dev/null; then
                        clear; return 0
                    fi
                    printf '  \033[31mWrong passphrase.\033[0m\n'; (( attempts++ ))
                done
                clear; return 1 ;;
        esac
    done
    clear; return 1
}
_luks_close() { _luks_is_open "$1" && sudo -n cryptsetup close "$(_luks_mapper "$1")" &>/dev/null || true; }

# ── Encryption menu ───────────────────────────────────────────────
_enc_auto_unlock_enabled() {
    # True if this machine's verification cipher works (verified system slot active)
    printf '%s' "$SD_VERIFICATION_CIPHER" | sudo -n cryptsetup open \
        --test-passphrase --key-file=- "$IMG_PATH" &>/dev/null
}

_enc_system_agnostic_enabled() {
    # True if slot 1 (SD_DEFAULT_KEYWORD) is active
    printf '%s' "$SD_DEFAULT_KEYWORD" | sudo -n cryptsetup open \
        --test-passphrase --key-slot 1 --key-file=- "$IMG_PATH" &>/dev/null
}

# Path to the stored auth keyfile inside the mounted image
_enc_authkey_path() { printf '%s' "$MNT_DIR/.sd/auth.key"; }

# Path to file storing which LUKS slot the auth keyfile occupies
_enc_authkey_slot_file() { printf '%s' "$MNT_DIR/.sd/auth.slot"; }

# ── Verified system helpers ───────────────────────────────────
_enc_verified_dir()  { printf '%s' "$MNT_DIR/.sd/verified"; }
_enc_verified_id()   { sha256sum /etc/machine-id 2>/dev/null | cut -c1-8; }
_enc_verified_pass() { sha256sum /etc/machine-id 2>/dev/null | cut -c1-32 || printf '%s' "simpledocker_fallback"; }
_enc_verified_path() { printf '%s/%s' "$(_enc_verified_dir)" "$(_enc_verified_id)"; }
_enc_is_verified()   { [[ -f "$(_enc_verified_path)" ]]; }

# Get slot stored in cache file for a given 8-char ID (line 2)
_enc_vs_slot()    { local _f="$(_enc_verified_dir)/$1"; [[ -f "$_f" ]] && sed -n '2p' "$_f" 2>/dev/null || printf ''; }
# Get hostname stored in cache file for a given 8-char ID (line 1)
_enc_vs_hostname(){ local _f="$(_enc_verified_dir)/$1"; [[ -f "$_f" ]] && sed -n '1p' "$_f" 2>/dev/null || printf "$1"; }
# Get derived pass stored in cache file for a given 8-char ID (line 3)
_enc_vs_pass()    { local _f="$(_enc_verified_dir)/$1"; [[ -f "$_f" ]] && sed -n '3p' "$_f" 2>/dev/null || printf ''; }

# Write/update cache file: line1=hostname line2=slot line3=derived_pass
_enc_vs_write() {
    local _id="$1" _slot="$2"
    local _vdir; _vdir=$(_enc_verified_dir)
    mkdir -p "$_vdir" 2>/dev/null
    printf '%s
%s
%s
' "$(cat /etc/hostname 2>/dev/null | tr -d "[:space:]" || printf "unknown")" "$_slot" "$(_enc_verified_pass)" > "$_vdir/$_id"
}

# Returns lowest free slot in SD_LUKS_KEY_SLOT_MIN..SD_LUKS_KEY_SLOT_MAX, or empty if full
_enc_free_slot() {
    local _dump; _dump=$(sudo -n cryptsetup luksDump "$IMG_PATH" 2>/dev/null)
    local _s
    for (( _s=SD_LUKS_KEY_SLOT_MIN; _s<=SD_LUKS_KEY_SLOT_MAX; _s++ )); do
        printf '%s' "$_dump" | grep -qE "^\s+$_s: luks2" || { printf '%s' "$_s"; return 0; }
    done
    return 1
}

# Count used slots in user range (SD_LUKS_KEY_SLOT_MIN..SD_LUKS_KEY_SLOT_MAX)
_enc_slots_used() {
    sudo -n cryptsetup luksDump "$IMG_PATH" 2>/dev/null         | grep -oP '^\s+\K[0-9]+(?=: luks2)'         | awk -v mn="$SD_LUKS_KEY_SLOT_MIN" -v mx="$SD_LUKS_KEY_SLOT_MAX"               '$1+0>=mn && $1+0<=mx' | wc -l
}

# Returns the slot number the auth keyfile is in (or empty)
_enc_authkey_slot() {
    local _sf; _sf=$(_enc_authkey_slot_file)
    [[ -f "$_sf" ]] && cat "$_sf" 2>/dev/null || printf ''
}

# True if a valid auth keyfile exists and works against the image
_enc_authkey_valid() {
    local _kf; _kf=$(_enc_authkey_path)
    [[ -f "$_kf" ]] || return 1
    local _aslot; _aslot=$(_enc_authkey_slot)
    if [[ -n "$_aslot" ]]; then
        sudo -n cryptsetup open --test-passphrase --key-slot "$_aslot" --key-file "$_kf" "$IMG_PATH" &>/dev/null
    else
        sudo -n cryptsetup open --test-passphrase --key-file "$_kf" "$IMG_PATH" &>/dev/null
    fi
}

# Generate a new auth keyfile (random 64 bytes, cheapest LUKS params) and add it
# as the lowest free slot >= 1, authorizing with the provided key-file path.
# Usage: _enc_authkey_create <auth_keyfile_path>
_enc_authkey_create() {
    local _auth_kf="$1"
    local _kf; _kf=$(_enc_authkey_path)
    mkdir -p "$(dirname "$_kf")" 2>/dev/null
    # Generate random keyfile
    dd if=/dev/urandom bs=64 count=1 2>/dev/null > "$_kf"
    chmod 600 "$_kf"
    # Auth keyfile always goes in slot 0
    sudo -n cryptsetup luksAddKey \
        --batch-mode \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
        --key-slot 0 \
        --key-file "$_auth_kf" \
        "$IMG_PATH" "$_kf" &>/dev/null
    local _arc=$?
    [[ $_arc -eq 0 ]] && printf '0' > "$(_enc_authkey_slot_file)"
    return $_arc
}


_enc_menu() {
    while true; do
        local _auto _auto_label _agnostic _agnostic_label
        if _enc_auto_unlock_enabled;       then _auto=true;     _auto_label="${GRN}Enabled${NC}"
        else                                    _auto=false;    _auto_label="${RED}Disabled${NC}"
        fi
        if _enc_system_agnostic_enabled;   then _agnostic=true;  _agnostic_label="${GRN}Enabled${NC}"
        else                                    _agnostic=false; _agnostic_label="${RED}Disabled${NC}"
        fi
        local _nf="$MNT_DIR/.sd/keyslot_names.json"
        local _authslot; _authslot=$(_enc_authkey_slot)
        local _vdir; _vdir=$(_enc_verified_dir)
        local _vid;  _vid=$(_enc_verified_id)
        local _slots_used; _slots_used=$(_enc_slots_used)
        local _slots_total=$(( SD_LUKS_KEY_SLOT_MAX - SD_LUKS_KEY_SLOT_MIN + 1 ))

        # Collect verified system IDs from cache
        local _vs_ids=()
        if [[ -d "$_vdir" ]]; then
            while IFS= read -r -d '' _vf; do
                _vs_ids+=("$(basename "$_vf")")
            done < <(find "$_vdir" -maxdepth 1 -type f -print0 2>/dev/null)
        fi

        # Collect active LUKS slots in user range; split into passkeys vs verified
        local dump; dump=$(sudo -n cryptsetup luksDump "$IMG_PATH" 2>/dev/null)
        local _vs_slot_set=()
        for _vsid in "${_vs_ids[@]}"; do
            local _vslot; _vslot=$(_enc_vs_slot "$_vsid")
            [[ -n "$_vslot" && "$_vslot" != "0" ]] && _vs_slot_set+=("$_vslot")
        done
        _is_vs_slot() { local _x; for _x in "${_vs_slot_set[@]}"; do [[ "$_x" == "$1" ]] && return 0; done; return 1; }

        local _key_lines=() _key_slots=()
        local _has_passkeys=false
        while IFS= read -r _line; do
            if [[ "$_line" =~ ^[[:space:]]+([0-9]+):\ luks2 ]]; then
                local _sid="${BASH_REMATCH[1]}"
                [[ "$_sid" == "0" ]] && continue
                [[ "$_sid" == "$_authslot" ]] && continue
                [[ "$_sid" -lt "$SD_LUKS_KEY_SLOT_MIN" ]] && continue   # reserved range (incl. slot 1 default keyword)
                _is_vs_slot "$_sid" && continue
                _has_passkeys=true
                local _sname; _sname=$(jq -r --arg s "$_sid" '.[$s] // empty' "$_nf" 2>/dev/null)
                [[ -z "$_sname" ]] && _sname="Key $_sid"
                _key_lines+=("$(printf " ${DIM}◈  %s  [s:%s]${NC}" "$_sname" "$_sid")")
                _key_slots+=("$_sid")
            fi
        done <<< "$dump"

        local _SEP_G _SEP_VS _SEP_K _SEP_NAV
        _SEP_G="$(  printf "${BLD}  ── General ─────────────────────────${NC}")"
        _SEP_VS="$( printf "${BLD}  ── Verified Systems ────────────────${NC}")"
        _SEP_K="$(  printf "${BLD}  ── Passkeys ────────────────────────${NC}")"
        _SEP_NAV="$(printf "${BLD}  ── Navigation ──────────────────────${NC}")"

        local lines=(
            "$_SEP_G"
            "$(printf " ${DIM}◈  System Agnostic: %b${NC}" "$_agnostic_label")"
            "$(printf " ${DIM}◈  Auto-Unlock: %b${NC}" "$_auto_label")"
            "$(printf " ${DIM}◈  Reset Auth Token${NC}")"
            "$_SEP_VS"
        )
        for _vsid in "${_vs_ids[@]}"; do
            local _vshost; _vshost=$(_enc_vs_hostname "$_vsid")
            local _vslot2; _vslot2=$(_enc_vs_slot "$_vsid")
            lines+=("$(printf " ${DIM}◈  %s  [vs:%s]${NC}" "$_vshost" "$_vsid")")
        done
        lines+=("$(printf " ${GRN}+  Verify this system${NC}")")
        lines+=("$_SEP_K")
        if [[ "$_has_passkeys" == false ]]; then
            lines+=("$(printf "${DIM}  (no passkeys added yet)${NC}")")
        else
            lines+=("${_key_lines[@]}")
        fi
        lines+=("$(printf " ${GRN}+  Add Key${NC}")")
        lines+=("$_SEP_NAV")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out; _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}── Manage Encryption ──${NC}  ${DIM}%s/%s slots${NC}" "$_slots_used" "$_slots_total")" \
            >"$_fzf_out" 2>/dev/null &
        local _pid=$!; printf '%s' "$_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_pid" 2>/dev/null; local _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "$sel" ]] && return
        local sc; sc=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*//')
        case "$sc" in
            *"${L[back]}"*|"") return ;;

            *"System Agnostic"*)
                if [[ "$_agnostic" == true ]]; then
                    # Disable: ensure at least one other unlock method exists
                    local _sa_vs_count=0
                    for _sa_vsid in "${_vs_ids[@]}"; do
                        local _sa_slot; _sa_slot=$(_enc_vs_slot "$_sa_vsid")
                        [[ -n "$_sa_slot" && "$_sa_slot" != "0" ]] && (( _sa_vs_count++ ))
                    done
                    if [[ "$_has_passkeys" == false && "$_sa_vs_count" -eq 0 ]]; then
                        pause "$(printf 'Cannot disable — no other unlock method exists.\nAdd a passkey or verify a system first.')"
                        continue
                    fi
                    confirm "Disable System Agnostic? This image will no longer open on unknown machines." || continue
                    local _tf_sa_kill; _tf_sa_kill=$(mktemp "$TMP_DIR/.sd_sakill_XXXXXX")
                    _enc_authkey_valid && cp "$(_enc_authkey_path)" "$_tf_sa_kill" || printf '%s' "$SD_DEFAULT_KEYWORD" > "$_tf_sa_kill"
                    sudo -n cryptsetup luksKillSlot --batch-mode --key-file "$_tf_sa_kill" "$IMG_PATH" 1 &>/dev/null
                    local _sa_rc=$?; rm -f "$_tf_sa_kill"; clear
                    [[ $_sa_rc -eq 0 ]] && pause "System Agnostic disabled." || pause "Failed."
                else
                    # Enable: add SD_DEFAULT_KEYWORD back to slot 1
                    if ! _enc_authkey_valid; then
                        pause "$(printf 'Auth keyfile missing or invalid.\nUse Reset Auth Token first.')"
                        continue
                    fi
                    local _tf_sa_auth; _tf_sa_auth=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
                    local _tf_sa_key;  _tf_sa_key=$(mktemp "$TMP_DIR/.sd_new_XXXXXX")
                    cp "$(_enc_authkey_path)" "$_tf_sa_auth"
                    printf '%s' "$SD_DEFAULT_KEYWORD" > "$_tf_sa_key"
                    sudo -n cryptsetup luksAddKey --batch-mode \
                        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
                        --key-slot 1 --key-file "$_tf_sa_auth" \
                        "$IMG_PATH" "$_tf_sa_key" &>/dev/null
                    local _sa_erc=$?; rm -f "$_tf_sa_auth" "$_tf_sa_key"; clear
                    [[ $_sa_erc -eq 0 ]] && pause "System Agnostic enabled." || pause "Failed."
                fi ;;

            *"Auto-Unlock"*)
                if [[ "$_auto" == true ]]; then
                    if [[ "$_has_passkeys" == false ]]; then
                        pause "$(printf 'No passkeys exist.\nAdd a passkey first,\nthen disable Auto-Unlock.')"
                        continue
                    fi
                    confirm "Disable Auto-Unlock? All verified system slots will be removed (cache kept)." || continue
                    clear
                    printf '\n  \033[1m── Disable Auto-Unlock ──\033[0m\n'
                    printf '  \033[2mRemoving verified system slots...\033[0m\n\n'
                    local _tf_dis; _tf_dis=$(mktemp "$TMP_DIR/.sd_dis_XXXXXX")
                    _enc_authkey_valid && cp "$(_enc_authkey_path)" "$_tf_dis" || printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_dis"
                    local _dis_ok=true
                    for _vsid in "${_vs_ids[@]}"; do
                        local _dslot; _dslot=$(_enc_vs_slot "$_vsid")
                        [[ -z "$_dslot" || "$_dslot" == "0" ]] && continue
                        sudo -n cryptsetup luksKillSlot --batch-mode --key-file "$_tf_dis" "$IMG_PATH" "$_dslot" &>/dev/null || _dis_ok=false
                        local _dhost; _dhost=$(_enc_vs_hostname "$_vsid")
                        local _dpass; _dpass=$(_enc_vs_pass "$_vsid")
                        printf '%s\n%s\n%s\n' "$_dhost" "" "$_dpass" > "$_vdir/$_vsid"
                    done
                    rm -f "$_tf_dis"; clear
                    "$_dis_ok" && pause "Auto-Unlock disabled." || pause "Failed (some slots may remain)."
                else
                    if ! _enc_authkey_valid; then
                        pause "$(printf 'Auth keyfile missing or invalid.\nUse Reset Auth first.')"
                        continue
                    fi
                    clear
                    printf '\n  \033[1m── Enable Auto-Unlock ──\033[0m\n'
                    printf '  \033[2mRe-adding verified system keys...\033[0m\n\n'
                    local _tf_en_auth; _tf_en_auth=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
                    cp "$(_enc_authkey_path)" "$_tf_en_auth"
                    local _en_ok=true _en_count=0
                    for _vsid in "${_vs_ids[@]}"; do
                        local _vspass; _vspass=$(_enc_vs_pass "$_vsid")
                        [[ -z "$_vspass" ]] && continue
                        local _free_s; _free_s=$(_enc_free_slot)
                        if [[ -z "$_free_s" ]]; then
                            pause "$(printf 'No free slots (slots %s-%s full).' "$SD_LUKS_KEY_SLOT_MIN" "$SD_LUKS_KEY_SLOT_MAX")"
                            _en_ok=false; break
                        fi
                        local _tf_vsp; _tf_vsp=$(mktemp "$TMP_DIR/.sd_vsp_XXXXXX")
                        printf '%s' "$_vspass" > "$_tf_vsp"
                        sudo -n cryptsetup luksAddKey --batch-mode \
                            --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
                            --key-slot "$_free_s" --key-file "$_tf_en_auth" \
                            "$IMG_PATH" "$_tf_vsp" &>/dev/null
                        if [[ $? -eq 0 ]]; then
                            local _vshost4; _vshost4=$(_enc_vs_hostname "$_vsid")
                            printf '%s\n%s\n%s\n' "$_vshost4" "$_free_s" "$_vspass" > "$_vdir/$_vsid"
                            (( _en_count++ ))
                        else
                            _en_ok=false
                        fi
                        rm -f "$_tf_vsp"
                    done
                    rm -f "$_tf_en_auth"; clear
                    if "$_en_ok"; then
                        [[ $_en_count -eq 0 ]] \
                            && pause "No verified systems to restore. Use '+ Verify this system'." \
                            || pause "$(printf 'Auto-Unlock enabled (%s system(s) restored).' "$_en_count")"
                    else
                        pause "Partially failed — some systems may not have been restored."
                    fi
                fi ;;

            *"Reset Auth Token"*)
                clear
                printf '\n  \033[1m── Reset Auth ──\033[0m\n'
                printf '  \033[2mEnter any existing passphrase to authorize.\033[0m\n\n'
                printf '  \033[1mPassphrase:\033[0m '
                local _ra_pass; IFS= read -rs _ra_pass; printf '\n\n'; clear
                printf '\n  \033[1m── Reset Auth ──\033[0m\n'
                printf '  \033[2mGenerating auth keyfile, please wait...\033[0m\n\n'
                local _tf_ra; _tf_ra=$(mktemp "$TMP_DIR/.sd_ra_XXXXXX")
                printf '%s' "$_ra_pass" > "$_tf_ra"
                local _old_kf; _old_kf=$(_enc_authkey_path)
                if [[ -f "$_old_kf" ]] && sudo -n cryptsetup open \
                        --test-passphrase --key-file "$_old_kf" "$IMG_PATH" &>/dev/null; then
                    sudo -n cryptsetup luksKillSlot --batch-mode \
                        --key-file "$_tf_ra" "$IMG_PATH" 0 &>/dev/null || true
                fi
                rm -f "$_old_kf"
                _enc_authkey_create "$_tf_ra"
                local _rrc=$?; rm -f "$_tf_ra"; clear
                [[ $_rrc -eq 0 ]] && pause "Auth keyfile reset." || pause "Failed — wrong passphrase?" ;;

            *"Verify this system"*)
                if _enc_is_verified; then
                    local _my_slot; _my_slot=$(_enc_vs_slot "$_vid")
                    if [[ -n "$_my_slot" && "$_my_slot" != "0" ]]; then
                        pause "$(printf 'Already verified: %s (slot %s).' "$(cat /etc/hostname 2>/dev/null | tr -d "[:space:]" || printf "unknown")" "$_my_slot")"
                    else
                        pause "$(printf 'System cached but Auto-Unlock is disabled.\nEnable Auto-Unlock to activate it.')"
                    fi
                    continue
                fi
                local _free_vs; _free_vs=$(_enc_free_slot)
                if [[ "$_auto" == true && -z "$_free_vs" ]]; then
                    pause "$(printf 'No free slots (slots %s-%s full).' "$SD_LUKS_KEY_SLOT_MIN" "$SD_LUKS_KEY_SLOT_MAX")"
                    continue
                fi
                if ! _enc_authkey_valid; then
                    pause "$(printf 'Auth keyfile missing or invalid.\nUse Reset Auth first.')"
                    continue
                fi
                if [[ "$_auto" == true ]]; then
                    local _tf_vs_auth; _tf_vs_auth=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
                    local _tf_vs_new;  _tf_vs_new=$(mktemp "$TMP_DIR/.sd_new_XXXXXX")
                    cp "$(_enc_authkey_path)" "$_tf_vs_auth"
                    printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_vs_new"
                    sudo -n cryptsetup luksAddKey --batch-mode \
                        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
                        --key-slot "$_free_vs" --key-file "$_tf_vs_auth" \
                        "$IMG_PATH" "$_tf_vs_new" &>/dev/null
                    local _vsrc=$?; rm -f "$_tf_vs_auth" "$_tf_vs_new"; clear
                    if [[ $_vsrc -eq 0 ]]; then
                        _enc_vs_write "$_vid" "$_free_vs"
                        pause "$(printf 'Verified: %s (slot %s, auto-unlock active).' "$(cat /etc/hostname 2>/dev/null | tr -d "[:space:]" || printf "unknown")" "$_free_vs")"
                    else
                        pause "Failed to add key slot."
                    fi
                else
                    _enc_vs_write "$_vid" ""
                    pause "$(printf 'Cached: %s (Auto-Unlock disabled — enable to activate).' "$(cat /etc/hostname 2>/dev/null | tr -d "[:space:]" || printf "unknown")")"
                fi ;;

            *"[vs:"*)
                local _sel_vsid; _sel_vsid=$(printf '%s' "$sc" | grep -o '\[vs:[a-f0-9]*\]' | sed 's/\[vs://;s/\]//')
                [[ -z "$_sel_vsid" ]] && continue
                local _sel_vshost; _sel_vshost=$(_enc_vs_hostname "$_sel_vsid")
                local _sel_vslot; _sel_vslot=$(_enc_vs_slot "$_sel_vsid")
                local _vs_action
                _vs_action=$(printf 'Unauthorize\nCancel\n' \
                    | fzf "${FZF_BASE[@]}" \
                      --header="$(printf "${BLD}── %s (%s) ──${NC}" "$_sel_vshost" "$_sel_vsid")" \
                      2>/dev/null | _trim_s)
                case "$_vs_action" in
                    Unauthorize)
                        if [[ "$_sel_vsid" == "$_vid" && "$_auto" == true && "$_has_passkeys" == false ]]; then
                            local _remaining_vs=0
                            for _chk_id in "${_vs_ids[@]}"; do
                                [[ "$_chk_id" == "$_sel_vsid" ]] && continue
                                local _chk_slot; _chk_slot=$(_enc_vs_slot "$_chk_id")
                                [[ -n "$_chk_slot" && "$_chk_slot" != "0" ]] && (( _remaining_vs++ ))
                            done
                            if [[ $_remaining_vs -eq 0 ]]; then
                                pause "$(printf 'Cannot unauthorize — this is the only unlock method.\nAdd a passkey first.')"
                                continue
                            fi
                        fi
                        confirm "$(printf 'Unauthorize %s?' "$_sel_vshost")" || continue
                        clear
                        printf '\n  \033[1m── Unauthorize ──\033[0m\n'
                        printf '  \033[2mRemoving...\033[0m\n\n'
                        local _unauth_ok=true
                        if [[ -n "$_sel_vslot" && "$_sel_vslot" != "0" ]]; then
                            local _tf_unauth; _tf_unauth=$(mktemp "$TMP_DIR/.sd_unauth_XXXXXX")
                            _enc_authkey_valid \
                                && cp "$(_enc_authkey_path)" "$_tf_unauth" \
                                || printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_unauth"
                            sudo -n cryptsetup luksKillSlot --batch-mode \
                                --key-file "$_tf_unauth" "$IMG_PATH" "$_sel_vslot" &>/dev/null \
                                || _unauth_ok=false
                            rm -f "$_tf_unauth"
                        fi
                        rm -f "$_vdir/$_sel_vsid"; clear
                        "$_unauth_ok" && pause "Unauthorize complete." || pause "Failed to remove slot (cache removed)." ;;
                esac ;;

            *"[s:"*)
                local _sn; _sn=$(printf '%s' "$sc" | grep -o '\[s:[0-9]*\]' | sed 's/\[s://;s/\]//')
                [[ -z "$_sn" ]] && continue
                local _cur_name; _cur_name=$(jq -r --arg s "$_sn" '.[$s] // empty' "$_nf" 2>/dev/null)
                [[ -z "$_cur_name" ]] && _cur_name="Key $_sn"
                local action
                action=$(printf 'Rename\nRemove\nCancel\n' \
                    | fzf "${FZF_BASE[@]}" \
                      --header="$(printf "${BLD}── %s ──${NC}" "$_cur_name")" \
                      2>/dev/null | _trim_s)
                case "$action" in
                    Rename)
                        finput "$(printf 'New name for "%s":' "$_cur_name")" || continue
                        local _nn="${FINPUT_RESULT}"; [[ -z "$_nn" ]] && continue
                        local _cur2; _cur2=$(cat "$_nf" 2>/dev/null || printf '{}')
                        local _tmp2; _tmp2=$(mktemp "$TMP_DIR/.sd_kn_XXXXXX")
                        printf '%s' "$_cur2" | jq --arg s "$_sn" --arg n "$_nn" '.[$s] = $n' \
                            > "$_tmp2" 2>/dev/null && mv "$_tmp2" "$_nf" || rm -f "$_tmp2"
                        pause "Renamed to \"$_nn\"." ;;
                    Remove)
                        local _pk_count=${#_key_slots[@]}
                        local _vs_active_count=0
                        for _vsid2 in "${_vs_ids[@]}"; do
                            local _vs2slot; _vs2slot=$(_enc_vs_slot "$_vsid2")
                            [[ -n "$_vs2slot" && "$_vs2slot" != "0" ]] && (( _vs_active_count++ ))
                        done
                        if [[ "$_auto" == false && "$_pk_count" -le 1 ]]; then
                            pause "$(printf 'Cannot remove — Auto-Unlock is disabled.\nKeep at least one passkey\nor re-enable Auto-Unlock first.')"
                            continue
                        fi
                        if [[ "$_auto" == true && "$_pk_count" -le 1 && "$_vs_active_count" -eq 0 ]]; then
                            pause "$(printf 'Cannot remove — this is the only non-auto-unlock key.\nVerify a system or keep this key.')"
                            continue
                        fi
                        confirm "$(printf 'Remove key "%s"?' "$_cur_name")" || continue
                        clear
                        printf '\n  \033[1m── Remove Key ──\033[0m\n'
                        printf '  \033[2mRemoving key, please wait...\033[0m\n\n'
                        local _tf_rm; _tf_rm=$(mktemp "$TMP_DIR/.sd_rm_XXXXXX")
                        if _enc_authkey_valid; then
                            cp "$(_enc_authkey_path)" "$_tf_rm"
                        else
                            clear
                            printf '\n  \033[1m── Remove Key ──\033[0m\n\n'
                            printf '  \033[1mPassphrase for "%s":\033[0m ' "$_cur_name"
                            local _rp; IFS= read -rs _rp; printf '\n\n'
                            printf '%s' "$_rp" > "$_tf_rm"
                            clear; printf '\n  \033[1m── Remove Key ──\033[0m\n'
                            printf '  \033[2mRemoving key, please wait...\033[0m\n\n'
                        fi
                        sudo -n cryptsetup luksKillSlot \
                            --batch-mode --key-file "$_tf_rm" "$IMG_PATH" "$_sn" &>/dev/null
                        local _rmrc=$?; rm -f "$_tf_rm"; clear
                        if [[ $_rmrc -eq 0 ]]; then
                            local _kn_del; _kn_del=$(mktemp "$TMP_DIR/.sd_kn_del_XXXXXX")
                            jq --arg s "$_sn" 'del(.[$s])' "$_nf" > "$_kn_del" \
                                && mv "$_kn_del" "$_nf" 2>/dev/null || rm -f "$_kn_del"
                            pause "Key removed."
                        else
                            pause "Failed."
                        fi ;;
                esac ;;

            *"Add Key"*)
                local _free_k; _free_k=$(_enc_free_slot)
                if [[ -z "$_free_k" ]]; then
                    pause "$(printf 'No free slots (slots %s-%s full).' "$SD_LUKS_KEY_SLOT_MIN" "$SD_LUKS_KEY_SLOT_MAX")"
                    continue
                fi
                local _rname; _rname=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
                local _kname="$_rname"
                local _pbkdf="argon2id" _ram="262144" _threads="4" _iter="1000"
                local _cipher="aes-xts-plain64" _keybits="512" _hash="sha256" _sector="512"
                local _param_done=false
                while [[ "$_param_done" == false ]]; do
                    local _param_lines=(
                        "$(printf "${BLD}  ── Parameters ──────────────────────${NC}")"
                        "$(printf "  %-10s${CYN}%s${NC}" "name"     "$_kname")"
                        "$(printf "  %-10s${CYN}%s${NC}" "pbkdf"    "$_pbkdf")"
                        "$(printf "  %-10s${CYN}%s KiB${NC}" "ram"  "$_ram")"
                        "$(printf "  %-10s${CYN}%s${NC}" "threads"  "$_threads")"
                        "$(printf "  %-10s${CYN}%s${NC}" "iter-ms"  "$_iter")"
                        "$(printf "  %-10s${CYN}%s${NC}" "cipher"   "$_cipher")"
                        "$(printf "  %-10s${CYN}%s${NC}" "key-bits" "$_keybits")"
                        "$(printf "  %-10s${CYN}%s${NC}" "hash"     "$_hash")"
                        "$(printf "  %-10s${CYN}%s${NC}" "sector"   "$_sector")"
                        "$(printf "${BLD}  ── Navigation ──────────────────────${NC}")"
                        "$(printf "${GRN}▷  Continue${NC}")"
                        "$(printf "${RED}×  Cancel${NC}")"
                    )
                    local _po; _po=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
                    printf '%s\n' "${_param_lines[@]}" | fzf "${FZF_BASE[@]}" \
                        --header="$(printf "${BLD}── Encryption parameters ──${NC}\n${DIM}  Select a param to change it.${NC}")" \
                        >"$_po" 2>/dev/null &
                    local _ppid=$!; printf '%s' "$_ppid" > "$TMP_DIR/.sd_active_fzf_pid"
                    wait "$_ppid" 2>/dev/null; local _pfrc=$?
                    local _psel; _psel=$(cat "$_po" 2>/dev/null | _trim_s | _strip_ansi | sed 's/^[[:space:]]*//')
                    rm -f "$_po"
                    _sig_rc $_pfrc && { stty sane 2>/dev/null; continue; }
                    [[ $_pfrc -ne 0 || -z "$_psel" ]] && break
                    case "$_psel" in
                        *"Continue"*) _param_done=true ;;
                        *"Cancel"*)   break ;;
                        *"name"*)
                            finput "$(printf 'Key name (blank = %s):' "$_rname")" || continue
                            _kname="${FINPUT_RESULT:-$_rname}" ;;
                        *"pbkdf"*)
                            local _pv; _pv=$(printf 'argon2id\nargon2i\npbkdf2\n' \
                                | fzf "${FZF_BASE[@]}" --header="pbkdf" 2>/dev/null | _trim_s)
                            [[ -n "$_pv" ]] && _pbkdf="$_pv" ;;
                        *"ram"*)
                            finput "RAM in KiB (e.g. 262144 = 256MB):" || continue
                            [[ "$FINPUT_RESULT" =~ ^[0-9]+$ ]] && _ram="$FINPUT_RESULT" ;;
                        *"threads"*)
                            finput "Threads (e.g. 4):" || continue
                            [[ "$FINPUT_RESULT" =~ ^[0-9]+$ ]] && _threads="$FINPUT_RESULT" ;;
                        *"iter-ms"*)
                            finput "Iteration time in ms (e.g. 1000):" || continue
                            [[ "$FINPUT_RESULT" =~ ^[0-9]+$ ]] && _iter="$FINPUT_RESULT" ;;
                        *"cipher"*)
                            local _cv; _cv=$(printf 'aes-xts-plain64\nchacha20-poly1305\n' \
                                | fzf "${FZF_BASE[@]}" --header="cipher" 2>/dev/null | _trim_s)
                            [[ -n "$_cv" ]] && _cipher="$_cv" ;;
                        *"key-bits"*)
                            local _kv; _kv=$(printf '256\n512\n' \
                                | fzf "${FZF_BASE[@]}" --header="key-bits" 2>/dev/null | _trim_s)
                            [[ -n "$_kv" ]] && _keybits="$_kv" ;;
                        *"hash"*)
                            local _hv; _hv=$(printf 'sha256\nsha512\nsha1\n' \
                                | fzf "${FZF_BASE[@]}" --header="hash" 2>/dev/null | _trim_s)
                            [[ -n "$_hv" ]] && _hash="$_hv" ;;
                        *"sector"*)
                            local _sv2; _sv2=$(printf '512\n1024\n2048\n4096\n' \
                                | fzf "${FZF_BASE[@]}" --header="sector size" 2>/dev/null | _trim_s)
                            [[ -n "$_sv2" ]] && _sector="$_sv2" ;;
                    esac
                done
                [[ "$_param_done" == false ]] && continue
                clear
                printf '\n  \033[1m── Add Key: %s ──\033[0m\n\n' "$_kname"
                printf '  \033[1mNew passphrase:\033[0m '
                local _np1; IFS= read -rs _np1; printf '\n'
                printf '  \033[1mConfirm:\033[0m      '
                local _np2; IFS= read -rs _np2; printf '\n\n'
                [[ "$_np1" != "$_np2" || -z "$_np1" ]] && { clear; pause "Mismatch or empty."; continue; }
                local _tf_auth; _tf_auth=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
                local _tf_new;  _tf_new=$(mktemp "$TMP_DIR/.sd_new_XXXXXX")
                _enc_authkey_valid && cp "$(_enc_authkey_path)" "$_tf_auth" || printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_auth"
                printf '%s' "$_np1" > "$_tf_new"
                clear
                printf '\n  \033[1m── Add Key: %s ──\033[0m\n' "$_kname"
                printf '  \033[2mAdding key, this might take a few seconds...\033[0m\n\n'
                sudo -n cryptsetup luksAddKey \
                    --batch-mode \
                    --pbkdf "$_pbkdf" --pbkdf-memory "$_ram" --pbkdf-parallel "$_threads" --iter-time "$_iter" \
                    --key-slot "$_free_k" --key-file "$_tf_auth" \
                    "$IMG_PATH" "$_tf_new" &>/dev/null
                local _rc=$?; rm -f "$_tf_auth" "$_tf_new"; clear
                [[ $_rc -ne 0 ]] && { pause "Failed to add key."; continue; }
                local _cur; _cur=$(cat "$_nf" 2>/dev/null || printf '{}')
                local _tmp; _tmp=$(mktemp "$TMP_DIR/.sd_kn_XXXXXX")
                printf '%s' "$_cur" | jq --arg s "$_free_k" --arg n "$_kname" '.[$s] = $n' \
                    > "$_tmp" 2>/dev/null && mv "$_tmp" "$_nf" 2>/dev/null || rm -f "$_tmp"
                pause "$(printf 'Key "%s" added (slot %s).' "$_kname" "$_free_k")" ;;
        esac
    done
}

_mount_img() {
    IMG_PATH="$1"
    MNT_DIR="${SD_MNT_BASE}/mnt_$(basename "${1%.img}")"
    mkdir -p "$MNT_DIR" 2>/dev/null
    if _img_is_luks "$1"; then
        _luks_open "$1" || { rmdir "$MNT_DIR" 2>/dev/null; pause "Failed to unlock image."; return 1; }
        sudo -n mount -o compress=zstd "$(_luks_dev "$1")" "$MNT_DIR" 2>/dev/null
    else
        sudo -n mount -o loop,compress=zstd "$1" "$MNT_DIR" 2>/dev/null
    fi
    sudo -n chown "$(id -u):$(id -g)" "$MNT_DIR" 2>/dev/null || true
    rm -rf "$TMP_DIR" 2>/dev/null || true
    _set_img_dirs
    TMP_DIR="$MNT_DIR/.tmp"
    mkdir -p "$TMP_DIR" "$MNT_DIR/.sd" 2>/dev/null
    rm -rf "$TMP_DIR" 2>/dev/null || true
    mkdir -p "$TMP_DIR" 2>/dev/null
    CACHE_DIR="$MNT_DIR/.cache"
    mkdir -p "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null
    _netns_setup "$MNT_DIR"
    rm -f "$MNT_DIR/Logs/"*.log 2>/dev/null || true
    if [[ -f "$MNT_DIR/.sd/proxy.json" ]] && \
       [[ "$(jq -r '.autostart // false' "$MNT_DIR/.sd/proxy.json" 2>/dev/null)" == "true" ]]; then
        _proxy_start --background
    fi
}

_yazi_pick() {
    local filter="${1:-}"
    local tmp; tmp=$(mktemp "$TMP_DIR/.sd_tmp_XXXXXX" 2>/dev/null) || { pause "mktemp failed (TMP_DIR=$TMP_DIR)"; return 1; }
    yazi --chooser-file="$tmp" 2>/dev/null
    local chosen; chosen=$(head -1 "$tmp" 2>/dev/null | tr -d '

'); rm -f "$tmp"
    [[ -z "$chosen" ]] && return 1
    if [[ -n "$filter" && "${chosen##*.}" != "$filter" ]]; then
        pause "Please select a .$filter file."; return 1
    fi
    printf '%s' "${chosen%/}"
}
_pick_img() { _yazi_pick img; }
_pick_dir() { _yazi_pick; }

_unmount_img() {
    [[ -z "$MNT_DIR" ]] && return 0
    mountpoint -q "$MNT_DIR" 2>/dev/null || { rmdir "$MNT_DIR" 2>/dev/null; return 0; }
    _proxy_stop 2>/dev/null || true
    _netns_teardown "$MNT_DIR"
    sudo -n umount -lf "$MNT_DIR" 2>/dev/null || true
    rmdir "$MNT_DIR" 2>/dev/null || true
    [[ -n "$IMG_PATH" ]] && _luks_close "$IMG_PATH" 2>/dev/null || true
    TMP_DIR="$SD_MNT_BASE/.tmp"
    mkdir -p "$TMP_DIR" 2>/dev/null || true
}

_create_img() {
    local name size_gb dir imgfile
    finput "$(printf "Image name (e.g. simpleDocker):\n\n  %b  The name cannot be changed after creation." "${RED}⚠  WARNING:${NC}")" || return 1
    name="${FINPUT_RESULT//[^a-zA-Z0-9_\-]/}"
    [[ -z "$name" ]] && { pause "No name given."; return 1; }
    finput "Max size in GB (sparse — only uses actual disk space, leave blank for 50 GB):" || return 1
    size_gb="$FINPUT_RESULT"
    [[ -z "$size_gb" ]] && size_gb=50
    [[ ! "$size_gb" =~ ^[0-9]+$ || "$size_gb" -lt 1 ]] && { pause "Invalid size."; return 1; }
    dir=$(_pick_dir) || { pause "No directory selected."; return 1; }
    imgfile="$dir/$name.img"
    [[ -f "$imgfile" ]] && { pause "Already exists: $imgfile"; return 1; }
    truncate -s "${size_gb}G" "$imgfile" 2>/dev/null || { pause "Failed to allocate image file."; return 1; }

    # Format as LUKS2 — use slot 31 as bootstrap (slot 0 reserved for authkey)
    printf '%s' "$SD_VERIFICATION_CIPHER" | sudo -n cryptsetup luksFormat \
        --type luks2 --batch-mode \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
        --key-slot 31 --key-file=- "$imgfile" &>/dev/null \
        || { rm -f "$imgfile"; pause "luksFormat failed."; return 1; }

    local _mapper; _mapper=$(_luks_mapper "$imgfile")
    printf '%s' "$SD_VERIFICATION_CIPHER" | sudo -n cryptsetup open --key-file=- "$imgfile" "$_mapper" &>/dev/null \
        || { rm -f "$imgfile"; pause "LUKS open failed."; return 1; }

    sudo -n mkfs.btrfs -q -f "/dev/mapper/$_mapper" &>/dev/null \
        || { sudo -n cryptsetup close "$_mapper"; rm -f "$imgfile"; pause "mkfs.btrfs failed."; return 1; }

    MNT_DIR="${SD_MNT_BASE}/mnt_$(basename "${imgfile%.img}")"
    mkdir -p "$MNT_DIR" 2>/dev/null
    if ! sudo -n mount -o compress=zstd "/dev/mapper/$_mapper" "$MNT_DIR" 2>/dev/null; then
        sudo -n cryptsetup close "$_mapper"; rm -f "$imgfile"; rmdir "$MNT_DIR" 2>/dev/null
        pause "Mount failed."; return 1
    fi
    sudo -n chown "$(id -u):$(id -g)" "$MNT_DIR" 2>/dev/null || true
    IMG_PATH="$imgfile"
    TMP_DIR="$MNT_DIR/.tmp"
    mkdir -p "$TMP_DIR" "$MNT_DIR/.sd" 2>/dev/null

    # Add authkey to slot 0 (authorizing with bootstrap slot 31)
    local _tf_img_auth; _tf_img_auth=$(mktemp "$TMP_DIR/.sd_imgauth_XXXXXX")
    printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_img_auth"
    _enc_authkey_create "$_tf_img_auth" || { rm -f "$_tf_img_auth"; pause "Auth keyfile creation failed."; return 1; }

    # Kill bootstrap slot 31 — authkey (slot 0) takes over as the master key
    sudo -n cryptsetup luksKillSlot --batch-mode \
        --key-file "$(_enc_authkey_path)" "$imgfile" 31 &>/dev/null || true
    rm -f "$_tf_img_auth"

    # Add default keyword to slot 1 (system agnostic — any machine can open)
    local _tf_dk_a; _tf_dk_a=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
    local _tf_dk_p; _tf_dk_p=$(mktemp "$TMP_DIR/.sd_new_XXXXXX")
    cp "$(_enc_authkey_path)" "$_tf_dk_a"
    printf '%s' "$SD_DEFAULT_KEYWORD" > "$_tf_dk_p"
    sudo -n cryptsetup luksAddKey --batch-mode \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
        --key-slot 1 --key-file "$_tf_dk_a" \
        "$imgfile" "$_tf_dk_p" &>/dev/null || true
    rm -f "$_tf_dk_a" "$_tf_dk_p"

    # Auto-verify this system — add derived pass to lowest free slot in user range
    local _img_vs_slot; _img_vs_slot=$(_enc_free_slot)
    if [[ -n "$_img_vs_slot" ]]; then
        local _tf_vs_a; _tf_vs_a=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
        local _tf_vs_p; _tf_vs_p=$(mktemp "$TMP_DIR/.sd_new_XXXXXX")
        cp "$(_enc_authkey_path)" "$_tf_vs_a"
        printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_vs_p"
        sudo -n cryptsetup luksAddKey --batch-mode \
            --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
            --key-slot "$_img_vs_slot" --key-file "$_tf_vs_a" \
            "$imgfile" "$_tf_vs_p" &>/dev/null
        [[ $? -eq 0 ]] && _enc_vs_write "$(_enc_verified_id)" "$_img_vs_slot"
        rm -f "$_tf_vs_a" "$_tf_vs_p"
    fi
    for sv in Blueprints Containers Installations Backup Storage Ubuntu Groups; do
        sudo -n btrfs subvolume create "$MNT_DIR/$sv" &>/dev/null || true
    done
    _set_img_dirs
    _netns_setup "$MNT_DIR"
    pause "Image created: $imgfile"
    return 0
}

_setup_image() {
    # Auto-enter if already mounted (resuming session), otherwise always show selection
    if mountpoint -q "$MNT_DIR" 2>/dev/null; then _set_img_dirs; return 0; fi
    if [[ -n "$DEFAULT_IMG" && -f "$DEFAULT_IMG" ]]; then _mount_img "$DEFAULT_IMG"; return 0; fi
    while true; do
        # Detect compatible SD images in $HOME live (no cache) — BTRFS .img files
        local detected_imgs=()
        while IFS= read -r -d '' _df; do
            { file "$_df" 2>/dev/null | grep -q 'BTRFS' || _img_is_luks "$_df"; } && detected_imgs+=("$_df")
        done < <(find "$HOME" -maxdepth 4 -name '*.img' -type f -print0 2>/dev/null)

        local lines=()
        lines+=("$(printf " ${CYN}◈${NC}  ${L[img_select]}")")
        lines+=("$(printf " ${CYN}◈${NC}  ${L[img_create]}")")

        if [[ ${#detected_imgs[@]} -gt 0 ]]; then
            lines+=("$(printf "${DIM}  ── Detected images ──────────────────${NC}")")
            for _di in "${detected_imgs[@]}"; do
                lines+=("$(printf " ${CYN}◈${NC}  %s  ${DIM}(%s)${NC}" "$(basename "$_di")" "$(dirname "$_di")")")
            done
        fi

        local choice
        choice=$(printf '%s\n' "${lines[@]}" \
            | fzf --ansi --no-sort --prompt="  ❯ " --pointer="▶" \
                  --height=40% --reverse --border=rounded --margin=1,2 --no-info \
                  --header="$(printf "${BLD}── simpleDocker ──${NC}")" 2>/dev/null) || { clear; exit 0; }
        local clean; clean=$(printf '%s' "$choice" | _strip_ansi | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$clean" in
            *"${L[img_select]}"*) local picked; picked=$(_pick_img) && { _mount_img "$picked" && return 0; } ;;
            *"${L[img_create]}"*) _create_img && return 0 ;;
            *)
                for _di in "${detected_imgs[@]}"; do
                    if [[ "$clean" == *"$(basename "$_di")"* ]]; then
                        _mount_img "$_di" && return 0
                        break
                    fi
                done ;;
        esac
    done
}

# ── Ubuntu bootstrap ─────────────────────────────────────────────
# Downloads Ubuntu 24.04 LTS minirootfs into $UBUNTU_DIR — base for all containers.
# Uses glibc so PyPI wheels and system packages work correctly.
# Prompts attach/background like container installs.

_ubuntu_default_pkgs_file() { printf '%s/.ubuntu_default_pkgs' "$UBUNTU_DIR"; }

_ensure_ubuntu() {
    [[ -z "$UBUNTU_DIR" ]] && return 0
    if [[ -f "$UBUNTU_DIR/.ubuntu_ready" && ! -f "$UBUNTU_DIR/usr/bin/apt-get" ]]; then
        rm -f "$UBUNTU_DIR/.ubuntu_ready"
    fi
    [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && return 0
    [[ ! -d "$UBUNTU_DIR" ]] && mkdir -p "$UBUNTU_DIR" 2>/dev/null

    local arch; arch=$(uname -m)
    local ub_arch
    case "$arch" in
        x86_64)  ub_arch="amd64" ;;
        aarch64) ub_arch="arm64" ;;
        armv7l)  ub_arch="armhf" ;;
        *)       ub_arch="amd64" ;;
    esac

    # Ubuntu 24.04 LTS (Noble) minimal rootfs — resolve latest point release dynamically
    local base_index="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/"
    local ver_full; ver_full=$(curl -fsSL "$base_index" 2>/dev/null \
        | grep -oP "ubuntu-base-\K[0-9]+\.[0-9]+\.[0-9]+-base-${ub_arch}" | head -1)
    [[ -z "$ver_full" ]] && ver_full="24.04.3-base-${ub_arch}"
    local url="${base_index}ubuntu-base-${ver_full}.tar.gz"
    local tmp; tmp=$(mktemp "$TMP_DIR/.sd_ubuntu_XXXXXX.tar.gz")
    local ok_flag="$UBUNTU_DIR/.ubuntu_ok_flag" fail_flag="$UBUNTU_DIR/.ubuntu_fail_flag"
    rm -f "$ok_flag" "$fail_flag"
    mkdir -p "$UBUNTU_DIR" 2>/dev/null

    local ubuntu_script; ubuntu_script=$(mktemp "$TMP_DIR/.sd_ubuntu_dl_XXXXXX.sh")
    local _sd_chroot_fn='_chroot_bash() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }'
    cat > "$ubuntu_script" <<UBUNTUSCRIPT
#!/usr/bin/env bash
$_sd_chroot_fn
trap '' INT
printf '\033[1m── simpleDocker — Ubuntu base setup ──\033[0m\n\n'
printf 'Downloading Ubuntu 24.04 LTS Noble base...\n'
if curl -fsSL --progress-bar $(printf '%q' "$url") -o $(printf '%q' "$tmp"); then
    printf 'Extracting...\n'
    tar -xzf $(printf '%q' "$tmp") -C $(printf '%q' "$UBUNTU_DIR") 2>&1 || true
    rm -f $(printf '%q' "$tmp")
    # Ensure /bin -> usr/bin symlink exists (Ubuntu Noble merged-usr)
    if [[ ! -e $(printf '%q' "$UBUNTU_DIR/bin") ]]; then
        ln -sf usr/bin $(printf '%q' "$UBUNTU_DIR/bin") 2>/dev/null || true
    fi
    if [[ ! -e $(printf '%q' "$UBUNTU_DIR/lib") ]]; then
        ln -sf usr/lib $(printf '%q' "$UBUNTU_DIR/lib") 2>/dev/null || true
    fi
    if [[ ! -e $(printf '%q' "$UBUNTU_DIR/lib64") ]]; then
        ln -sf usr/lib64 $(printf '%q' "$UBUNTU_DIR/lib64") 2>/dev/null || true
    fi
    printf 'nameserver 8.8.8.8\n' > $(printf '%q' "$UBUNTU_DIR/etc/resolv.conf") 2>/dev/null || true
    # Suppress apt warnings in chroot
    printf 'APT::Sandbox::User "root";\n' > $(printf '%q' "$UBUNTU_DIR/etc/apt/apt.conf.d/99sandbox") 2>/dev/null || true
        printf 'Pre-installing common packages...\n'
    _chroot_bash "$UBUNTU_DIR" -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $DEFAULT_UBUNTU_PKGS 2>&1" || true
    touch $(printf '%q' "$UBUNTU_DIR/.ubuntu_ready")
    date '+%Y-%m-%d' > $(printf '%q' "$UBUNTU_DIR/.sd_ubuntu_stamp")
    printf '%s\n' $DEFAULT_UBUNTU_PKGS > $(printf '%q' "$UBUNTU_DIR/.ubuntu_default_pkgs") 2>/dev/null || true
    touch $(printf '%q' "$ok_flag")
    printf '\n\033[0;32m✓ Ubuntu base ready.\033[0m\n'
else
    rm -f $(printf '%q' "$tmp")
    touch $(printf '%q' "$fail_flag")
    printf '\n\033[0;31m✗ Download failed.\033[0m\n'
fi
sleep 1
tmux kill-session -t sdUbuntuSetup 2>/dev/null || true
UBUNTUSCRIPT
    chmod +x "$ubuntu_script"

    local _tl_rc
    _tmux_launch "sdUbuntuSetup" "Ubuntu base setup" "$ubuntu_script"
    _tl_rc=$?
    [[ $_tl_rc -eq 1 ]] && { rm -f "$ubuntu_script"; return 1; }
}

# Run a command inside Ubuntu chroot
# ── Chroot mount/umount helpers ──────────────────────────────────
_chroot_mount()     { local d="$1"
    sudo -n mount --bind /proc "$d/proc" 2>/dev/null || true
    sudo -n mount --bind /sys  "$d/sys"  2>/dev/null || true
    sudo -n mount --bind /dev  "$d/dev"  2>/dev/null || true; }
_chroot_umount()    { local d="$1"
    sudo -n umount -lf "$d/dev" "$d/sys" "$d/proc" 2>/dev/null || true; }
_chroot_mount_mnt() { _chroot_mount "$1"
    [[ -n "${2:-}" ]] && sudo -n mount --bind "$2" "$1/mnt" 2>/dev/null || true; }
_chroot_umount_mnt(){ sudo -n umount -lf "$1/mnt" 2>/dev/null || true; _chroot_umount "$1"; }

_guard_space() {
    [[ -z "$MNT_DIR" ]] && return 0
    mountpoint -q "$MNT_DIR" 2>/dev/null || return 0
    local avail_kb; avail_kb=$(df -k "$MNT_DIR" 2>/dev/null | awk 'NR==2{print $4}')
    [[ -z "$avail_kb" || "$avail_kb" -ge 2097152 ]] && return 0
    pause "$(printf '⚠  Less than 2 GiB free in the image.\nUse Other → Resize image to increase the size first.')"
    return 1
}

# ── fzf / UI primitives ───────────────────────────────────────────

_resize_image() {
    [[ -z "$IMG_PATH" || ! -f "$IMG_PATH" ]] && { pause "No image mounted."; return 1; }
    local cur_bytes; cur_bytes=$(stat -c%s "$IMG_PATH" 2>/dev/null)
    local cur_gib;   cur_gib=$(awk "BEGIN{printf \"%.1f\",$cur_bytes/1073741824}")
    local used_bytes=0
    if mountpoint -q "$MNT_DIR" 2>/dev/null; then
        used_bytes=$(btrfs filesystem usage -b "$MNT_DIR" 2>/dev/null \
            | grep -i 'used' | head -1 | grep -oP '[0-9]+' | tail -1 || echo 0)
        [[ -z "$used_bytes" || "$used_bytes" == "0" ]] && \
            used_bytes=$(df -k "$MNT_DIR" 2>/dev/null | awk 'NR==2{print $3*1024}')
    fi
    local used_gib; used_gib=$(awk "BEGIN{printf \"%.1f\",$used_bytes/1073741824}")
    local min_gib;  min_gib=$(awk "BEGIN{print int($used_bytes/1073741824)+1+10}")
    local new_gib_raw
    finput "$(printf 'Current: %s GB   Used: %s GB   Minimum: %s GB\n\nNew size in GB:' "$cur_gib" "$used_gib" "$min_gib")" || return 0
    new_gib_raw="${FINPUT_RESULT//[^0-9]/}"
    if [[ -z "$new_gib_raw" || "$new_gib_raw" -lt "$min_gib" ]]; then
        pause "$(printf 'Invalid size. Must be a whole number ≥ %s GB.' "$min_gib")"; return 1
    fi
    local new_gib="$new_gib_raw" new_bytes=$(( new_gib_raw * 1073741824 ))

    local running_names=()
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local _cid; _cid=$(basename "$d")
        tmux_up "$(tsess "$_cid")" && running_names+=("$(jq -r '.name // empty' "$d/state.json" 2>/dev/null)")
    done
    # per-container install sessions checked per-cid below

    local confirm_msg
    if [[ ${#running_names[@]} -gt 0 ]]; then
        local list; list=$(printf '  • %s\n' "${running_names[@]}")
        confirm_msg="$(printf 'Running services will be stopped:\n%s\n\nResize image from %s GB → %s GB?' "$list" "$cur_gib" "$new_gib")"
    else
        confirm_msg="$(printf 'Resize image from %s GB → %s GB?' "$cur_gib" "$new_gib")"
    fi
    confirm "$confirm_msg" || return 0

    if [[ ${#running_names[@]} -gt 0 ]]; then
        for d in "$CONTAINERS_DIR"/*/; do
            [[ -f "$d/state.json" ]] || continue
            local _cid; _cid=$(basename "$d"); local _sess; _sess="$(tsess "$_cid")"
            tmux_up "$_sess" && { tmux send-keys -t "$_sess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$_sess" 2>/dev/null || true; }
        done
        tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
        _tmux_set SD_INSTALLING ""
        sleep 0.5
    fi

    local img_to_resize="$IMG_PATH"
    # Sentinel files must survive image unmount — use SD_MNT_BASE/.tmp not TMP_DIR
    mkdir -p "$SD_MNT_BASE/.tmp" 2>/dev/null
    local ok_file;   ok_file=$(mktemp "$SD_MNT_BASE/.tmp/.sd_resize_ok_XXXXXX")
    local fail_file; fail_file=$(mktemp "$SD_MNT_BASE/.tmp/.sd_resize_fail_XXXXXX")
    rm -f "$ok_file" "$fail_file"
    local resize_script; resize_script=$(mktemp "$SD_MNT_BASE/.tmp/.sd_resize_XXXXXX.sh")
    # Compute the known LUKS mapper name (same logic as _luks_mapper) so we can close it directly
    local _known_mapper; _known_mapper="sd_$(basename "${img_to_resize%.img}" | tr -dc 'a-zA-Z0-9_')"
    cat > "$resize_script" <<RESIZESCRIPT
#!/usr/bin/env bash
mnt_dir=$(printf '%q' "$MNT_DIR")
img=$(printf '%q' "$img_to_resize")
ok_f=$(printf '%q' "$ok_file")
fail_f=$(printf '%q' "$fail_file")
known_mapper=$(printf '%q' "$_known_mapper")
auto_pass=$(printf '%q' "$SD_VERIFICATION_CIPHER")

_fail() {
    printf '\n\033[0;31m══ Resize failed ══\033[0m\n'
    touch "\$fail_f" 2>/dev/null
    printf 'Press Enter to return…\n'; read -r _
    tmux switch-client -t simpleDocker 2>/dev/null || true
    tmux kill-session -t sdResize 2>/dev/null || true
}
trap '' INT

# ── 1. Unmount and fully detach the image ────────────────────────
printf '\033[0;33mUnmounting image…\033[0m\n'
# Force-unmount fs first, then close LUKS mapper, then detach loop
sudo -n umount -lf "\$mnt_dir" 2>/dev/null || true
sudo -n cryptsetup close "\$known_mapper" 2>/dev/null || true
# Find and detach backing loop device via /sys
_lodev=""
for _lo in /sys/block/loop*/backing_file; do
    [[ -f "\$_lo" ]] || continue
    if [[ "\$(cat "\$_lo" 2>/dev/null)" == "\$img" ]]; then
        _lodev="/dev/\$(basename "\$(dirname "\$_lo")")"
        break
    fi
done
printf '[unmount] lodev=%s\n' "\$_lodev"
if [[ -n "\$_lodev" ]]; then
    sudo -n losetup -d "\$_lodev" 2>/dev/null || true
else
    printf '[unmount] no loop device found via /sys — will let losetup --find pick a fresh one\n'
fi

# ── 2. LUKS-aware mount helper ───────────────────────────────────
# Usage: _do_mount img mntpoint mapper_name
# Globals: lodev/mapper for current mount, saved passphrase for reuse
_mounted_lodev="" _mounted_mapper="" _saved_pp=""
_do_mount() {
    local _img="\$1" _mnt="\$2" _mname="\$3"
    mkdir -p "\$_mnt" 2>/dev/null
    _mounted_lodev=\$(sudo -n losetup --find --show "\$_img" 2>/dev/null)
    printf '[mount] lodev=%s mapper=%s\n' "\$_mounted_lodev" "\$_mname"
    if [[ -z "\$_mounted_lodev" ]]; then printf 'ERROR: losetup failed\n'; return 1; fi
    if sudo -n cryptsetup isLuks "\$_mounted_lodev" 2>/dev/null; then
        _mounted_mapper="\$_mname"
        # Close stale mapper if already open
        if [[ -b "/dev/mapper/\$_mounted_mapper" ]]; then
            printf '[mount] stale mapper found, closing\n'
            sudo -n cryptsetup close "\$_mounted_mapper" 2>/dev/null || true
            sleep 0.3
        fi
        local _luks_ok=false
        for _try_pass in "\$auto_pass" "\$_saved_pp"; do
            [[ -z "\$_try_pass" ]] && continue
            local _e; _e=\$(printf '%s' "\$_try_pass" | sudo -n cryptsetup open --key-file=- "\$_mounted_lodev" "\$_mounted_mapper" 2>&1)
            if [[ \$? -eq 0 ]]; then _luks_ok=true; printf '[mount] auto-unlock OK\n'; break; fi
        done
        if [[ "\$_luks_ok" != true ]]; then
            printf '[mount] auto-unlock disabled, using passphrase\n'
            printf '  \033[1mPassphrase:\033[0m '; IFS= read -rs _saved_pp; printf '\n'
            local _e2; _e2=\$(printf '%s' "\$_saved_pp" | sudo -n cryptsetup open --key-file=- "\$_mounted_lodev" "\$_mounted_mapper" 2>&1)
            if [[ \$? -eq 0 ]]; then _luks_ok=true; printf '[mount] passphrase open OK\n'
            else printf '[mount] passphrase open failed: %s\n' "\$_e2"; fi
        fi
        if [[ "\$_luks_ok" != true ]]; then
            sudo -n losetup -d "\$_mounted_lodev" 2>/dev/null
            printf 'ERROR: LUKS open failed\n'; return 1
        fi
        if ! sudo -n mount -o compress=zstd "/dev/mapper/\$_mounted_mapper" "\$_mnt"; then
            sudo -n cryptsetup close "\$_mounted_mapper" 2>/dev/null
            sudo -n losetup -d "\$_mounted_lodev" 2>/dev/null
            printf 'ERROR: mount failed\n'; return 1
        fi
    else
        _mounted_mapper=""
        printf '[mount] not LUKS, mounting plain\n'
        if ! sudo -n mount -o compress=zstd "\$_mounted_lodev" "\$_mnt"; then
            sudo -n losetup -d "\$_mounted_lodev" 2>/dev/null
            printf 'ERROR: mount failed\n'; return 1
        fi
    fi
    printf '[mount] done\n'
}
_do_umount() {
    local _mnt="\$1"
    printf '[umount] mnt=%s mapper=%s lodev=%s\n' "\$_mnt" "\$_mounted_mapper" "\$_mounted_lodev"
    sudo -n umount "\$_mnt" 2>/dev/null || true
    if [[ -n "\$_mounted_mapper" ]]; then
        sudo -n cryptsetup close "\$_mounted_mapper" 2>/dev/null || true
        # Wait until mapper device node is gone before detaching loop
        local _w=0
        while [[ -b "/dev/mapper/\$_mounted_mapper" && \$_w -lt 50 ]]; do
            sleep 0.1; ((_w++))
        done
        printf '[umount] waited %d ticks for mapper release\n' "\$_w"
    fi
    [[ -n "\$_mounted_lodev" ]] && sudo -n losetup -d "\$_mounted_lodev" 2>/dev/null || true
    _mounted_lodev="" _mounted_mapper=""
    printf '[umount] done\n'
}

# ── 3. Resize ────────────────────────────────────────────────────
tmp_mnt=\$(mktemp -d /tmp/.sd_mnt_XXXXXX)
cur_bytes=\$(stat -c%s "\$img")
if [[ ${new_bytes} -ge \$cur_bytes ]]; then
    printf '\033[0;33mGrowing: file ${new_gib} GB → expand fs…\033[0m\n'
    truncate -s ${new_bytes} "\$img" || { _fail; exit 1; }
    _do_mount "\$img" "\$tmp_mnt" "sd_rsz_\${\$}" || { rm -rf "\$tmp_mnt"; _fail; exit 1; }
    sudo -n btrfs filesystem resize max "\$tmp_mnt" 2>/dev/null || { printf 'ERROR: btrfs resize failed\n'; _do_umount "\$tmp_mnt"; rm -rf "\$tmp_mnt"; _fail; exit 1; }
    _do_umount "\$tmp_mnt"
else
    printf '\033[0;33mShrinking: shrink fs first, then file…\033[0m\n'
    _do_mount "\$img" "\$tmp_mnt" "sd_rsz_\${\$}" || { rm -rf "\$tmp_mnt"; _fail; exit 1; }
    sudo -n btrfs filesystem resize ${new_bytes} "\$tmp_mnt" 2>/dev/null || { printf 'ERROR: btrfs resize failed\n'; _do_umount "\$tmp_mnt"; rm -rf "\$tmp_mnt"; _fail; exit 1; }
    _do_umount "\$tmp_mnt"
    truncate -s ${new_bytes} "\$img" || { _fail; exit 1; }
fi
rm -rf "\$tmp_mnt"

# ── 4. Remount ───────────────────────────────────────────────────
printf '\033[0;33mRemounting image…\033[0m\n'
mkdir -p "\$mnt_dir" 2>/dev/null
if [[ -b "/dev/mapper/\$known_mapper" ]]; then
    printf '[remount] mapper already open, mounting directly\n'
    if ! sudo -n mount -o compress=zstd "/dev/mapper/\$known_mapper" "\$mnt_dir"; then
        printf 'ERROR: final remount failed\n'; _fail; exit 1
    fi
else
    _do_mount "\$img" "\$mnt_dir" "\$known_mapper" || { printf 'ERROR: final remount failed\n'; _fail; exit 1; }
fi
sudo -n chown "\$(id -u):\$(id -g)" "\$mnt_dir" 2>/dev/null || true
touch "\$ok_f"
printf '\n\033[0;32m══ Resized to ${new_gib} GB successfully ══\033[0m\n'
printf 'Press Enter to return…\n'; read -r _
tmux switch-client -t simpleDocker 2>/dev/null || true
tmux kill-session -t sdResize 2>/dev/null || true
RESIZESCRIPT
    chmod +x "$resize_script"
    _tmux_launch --no-prompt "sdResize" "Resize image" "$resize_script"
    sleep 0.5
    while tmux_up "sdResize"; do
        sleep 0.3
        [[ -f "$ok_file" || -f "$fail_file" ]] && break
        if ! tmux list-clients -t "sdResize" 2>/dev/null | grep -q .; then
            [[ -f "$ok_file" || -f "$fail_file" ]] && break
            printf '%s\n' "  Attach to resize log" \
                | _fzf "${FZF_BASE[@]}" \
                      --header="$(printf "${BLD}── Resize in progress ──${NC}\n${DIM}  Press Enter to reattach${NC}")" \
                      --no-multi --bind=esc:ignore 2>/dev/null || true
            [[ -f "$ok_file" || -f "$fail_file" ]] && break
            tmux_up "sdResize" && tmux switch-client -t "sdResize" 2>/dev/null || true
        fi
    done
    clear; IMG_PATH="$img_to_resize"; _set_img_dirs
    if [[ -f "$ok_file" ]]; then
        rm -f "$ok_file" "$fail_file"
        for d in "$CONTAINERS_DIR"/*/; do
            [[ -f "$d/state.json" ]] || continue
            tmux kill-session -t "sd_$(basename "$d")" 2>/dev/null || true
        done
        tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
        _unmount_img
        exec bash "$(realpath "$0" 2>/dev/null || printf '%s' "$0")"
    else
        rm -f "$ok_file" "$fail_file"
        TMP_DIR="$SD_MNT_BASE/.tmp"; mkdir -p "$TMP_DIR" 2>/dev/null
        pause "Resize failed. Check that sudo commands succeeded."
        mountpoint -q "$MNT_DIR" 2>/dev/null || _mount_img "$img_to_resize"
    fi
}

# ── Container list & validation ───────────────────────────────────
