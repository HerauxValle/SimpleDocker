#!/usr/bin/env bash


DEFAULT_IMG=""                # path to .img file to auto-mount on launch (leave empty to prompt)
DEFAULT_UBUNTU_PKGS="curl git wget ca-certificates zstd tar xz-utils python3 python3-venv python3-pip build-essential"
ROOT_DIR="$HOME/.config/simpleDocker"  # where image list and config are stored

declare -A KB=(
    [detach]="ctrl-d"         # detach from tmux session
    [quit]="ctrl-q"           # quit simpleDocker
    [tmux_detach]="ctrl-\\"   # detach inside tmux
)

GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[0;33m'; BLU='\033[0;34m'
CYN='\033[0;36m'; BLD='\033[1m';    DIM='\033[2m';     NC='\033[0m'

SD_VERIFICATION_CIPHER=$(sha256sum /etc/machine-id 2>/dev/null | cut -c1-32 || printf '%s' "simpledocker_fallback")
SD_DEFAULT_KEYWORD="1991316125415311518"
SD_LUKS_KEY_SLOT_MIN=7
SD_LUKS_KEY_SLOT_MAX=31

SD_UNLOCK_ORDER="verified_system default_keyword prompt"

SD_MNT_BASE="${XDG_RUNTIME_DIR:-$HOME/.local/share}/simpleDocker"  # host mount points only
TMP_DIR="$SD_MNT_BASE/.tmp"  # pre-mount bootstrap; reset to inside img after mount
CACHE_DIR=""                  # set after mount to $MNT_DIR/.cache
SD_SHELL_PID=$$               # main shell pid — watcher sends SIGUSR1 here to force fzf refresh
SD_ACTIVE_FZF_PID=""          # pid of currently blocking fzf, updated by _fzf()
trap '_sd_usr1_handler() { _SD_USR1_FIRED=1; kill "$(cat "$TMP_DIR/.sd_active_fzf_pid" 2>/dev/null)" 2>/dev/null || true; sleep 0.2; stty sane 2>/dev/null; while IFS= read -r -t 0.15 -n 256 _ 2>/dev/null; do :; done; }; _sd_usr1_handler' USR1
_SD_USR1_FIRED=0
_SD_UB_PKG_DRIFT=false    # true if DEFAULT_UBUNTU_PKGS differ from .ubuntu_default_pkgs
_SD_UB_HAS_UPDATES=false  # true if apt-get --simulate upgrade has pending upgrades
_SD_UB_CACHE_LOADED=false # guard — cache_read runs exactly once per mount

: << 'SD_PERSISTENT_END'

# [Counter]
[container]
[meta]
name         = counter-test
version      = 2.0.0
port         = 8833
dialogue     = Feature test
storage_type = counter-test
health       = true
log          = logs/counter.log

[dirs]
logs

[install]
for i in $(seq 1 10); do
    printf '%d\n' "$i"
    sleep 0.2
done
printf 'Install done.\n'

[start]
mkdir -p "$CONTAINER_ROOT/logs"
n=1
while true; do
    printf '[%s] tick %d\n' "$(date '+%H:%M:%S')" "$n" | tee -a "$CONTAINER_ROOT/logs/counter.log"
    (( n++ ))
    sleep 1
done

[actions]
Reset log      | printf '' > "$CONTAINER_ROOT/logs/counter.log" && printf 'Log cleared.\n'
Show log tail  | tail -20 "$CONTAINER_ROOT/logs/counter.log"

[cron]
10s [ping]     | printf '[cron] ping at %s\n' "$(date '+%H:%M:%S')" >> logs/counter.log
1m [minutely]  | printf '[cron] 1min heartbeat\n' >> logs/counter.log

[/container]

SD_PERSISTENT_END


read -r -d '' SD_BLUEPRINT_PRESET <<'SD_PRESET_END' || true
[container]

[meta]
name         = my-service
version      = 1.0.0
dialogue     = Short label shown in the container list
description  = Longer notes about this service.
port         = 8080
storage_type = my-service
entrypoint   = bin/my-service --port 8080
# log        = logs/service.log        # log file shown in View log (default: start.log)
# health     = [true | false]          # enable health check ping on port
# gpu        = [nvidia | amd]          # pass GPU into container
# cap_drop   = [true | false]          # drop Linux capabilities (default: true)
# seccomp    = [true | false]          # apply seccomp profile (default: true)

[env]
PORT     = 8080
HOST     = 127.0.0.1
DATA_DIR = data
# API_KEY = secret

[storage]
# Paths inside CONTAINER_ROOT that persist across reinstalls
data, logs

[deps]
# apt packages installed into the container chroot
curl, tar

[dirs]
# Directories created automatically inside CONTAINER_ROOT
# Supports nested:  lib(subdir1, subdir2)
bin, data, logs

[pip]
# Python packages installed into CONTAINER_ROOT/venv
# Supports version pins: requests==2.31.0  or bare: requests

[npm]
# Node packages installed into CONTAINER_ROOT/node_modules
# e.g. express, lodash

[git]
# org/repo                              → auto-detect archive/binary, extract to CONTAINER_ROOT
# org/repo [asset-name.tar.zst]         → match exact release asset filename, then extract
# org/repo [asset-name][TYPE]           → match asset and filter by type before selecting
# org/repo → subdir/                    → extract to subdir
# org/repo source                       → git clone to src/
# TYPE tokens: [BIN] raw binary  [ZIP] .zip  [TAR] .tar.gz/.tar.zst/etc  (default: auto/ZIP)

[build]
# Compile steps — run once during install, after git source clone
# cd src && make

[install]
# Extra setup steps run once after deps/dirs/git

[update]
# Steps run when manually triggering Update from the container menu

[start]
# Script run to start the container (runs inside namespace+chroot)
# $CONTAINER_ROOT is always available and points to the install path

[cron]
# interval [name] [--sudo] [--unjailed] | command
# interval: [N][s|m|h]  e.g. 30s, 5m, 1h
# --unjailed: run on host instead of inside container
# --sudo:     wrap command with sudo
# 5m [heartbeat] | printf '[cron] ping\n' >> logs/cron.log

[actions]
# One action per line:  Label | [prompt: "text" |] [select: cmd [--skip-header] [--col N] |] cmd [{input}|{selection}]
# ⊙ auto-prepended if label starts with a plain letter
Show logs | tail -f logs/service.log

[/container]
SD_PRESET_END

declare -A L=(
    [title]="simpleDocker"
    [detach]="⊙  Detach"
    [quit]="Quit"
    [quit_stop_all]="■  Stop all & quit"
    [new_container]="New container"
    [help]="Other"
    [help_resize]="Resize image"
    [help_storage]="Persistent storage"
    [ct_start]="▶  Start"
    [ct_stop]="■  Stop"
    [ct_restart]="↺  Restart"
    [ct_attach]="→  Attach"
    [ct_install]="↓  Install"
    [ct_edit]="◦  Edit toml"
    [ct_terminal]="◉  Terminal"
    [ct_update]="↑  Update"
    [ct_uninstall]="○  Uninstall"
    [ct_remove]="×  Remove"
    [ct_rename]="✎  Rename"
    [ct_backups]="◈  Backups"
    [ct_profiles]="◧  Profiles"
    [ct_open_in]="⊕  Open in"
    [ct_exposure]="⬤  Port exposure"
    [ct_attach_inst]="→  Attach to installation"
    [ct_kill_inst]="×  Kill installation"
    [ct_finish_inst]="✓  Finish installation"
    [ct_log]="≡  View log"
    [bp_new]="New blueprint"
    [bp_edit]="◦  Edit"
    [bp_delete]="×  Delete"
    [bp_rename]="✎  Rename"
    [grp_new]="New group"
    [stor_rename]="✎  Rename"
    [stor_delete]="×  Delete"
    [back]="← Back"
    [yes]="Yes, confirm"
    [no]="No"
    [ok_press]="Press Enter or ESC to continue"
    [type_enter]="Type and press Enter  (ESC to cancel)"
    [msg_install_running]="An installation is already running"
    [msg_install_ok]="installed successfully."
    [msg_install_fail]="Installation failed — attach to check output."
    [img_select]="Select existing image"
    [img_create]="Create new image"
)

mkdir -p "$SD_MNT_BASE" "$TMP_DIR" 2>/dev/null

MNT_DIR=""
IMG_PATH=""
BLUEPRINTS_DIR=""
CONTAINERS_DIR=""
INSTALLATIONS_DIR=""
BACKUP_DIR=""
STORAGE_DIR=""
UBUNTU_DIR=""
GROUPS_DIR=""
LOGS_DIR=""

_stor_ctx_cid=""  # set before calling _persistent_storage_menu from container context

_chroot_bash() {
    local root="$1"; shift
    local bash_bin
    if [[ -f "$root/bin/bash" || -L "$root/bin/bash" ]]; then
        bash_bin=/bin/bash
    elif [[ -f "$root/usr/bin/bash" ]]; then
        bash_bin=/usr/bin/bash
    else
        bash_bin=/bin/bash  # fallback, let chroot report the error
    fi
    sudo -n chroot "$root" "$bash_bin" "$@"
}

_check_deps() {
    local missing=()
    for t in jq tmux yazi fzf btrfs sudo curl ip; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    [[ ${#missing[@]} -eq 0 ]] && return
    clear
    local ans
    ans=$(printf '%s\n' "Yes, install them" "No, exit" \
        | fzf --ansi --no-sort --prompt="  ❯ " --pointer="▶" \
              --height=40% --reverse --border=rounded --margin=1,2 --no-info \
              --header="$(printf "  Required: jq tmux yazi fzf btrfs-progs sudo curl iproute2\n  Missing:  %s\n\n  Install missing tools?" "${missing[*]}")" \
              2>/dev/null)
    [[ "$ans" != "Yes, install them" ]] && clear && exit 1
    local pm_cmd=""
    if   command -v pacman  &>/dev/null; then pm_cmd="sudo pacman -S --noconfirm"
    elif command -v apt-get &>/dev/null; then pm_cmd="sudo apt-get install -y"
    elif command -v dnf     &>/dev/null; then pm_cmd="sudo dnf install -y"
    elif command -v zypper  &>/dev/null; then pm_cmd="sudo zypper install -y"
    else echo "No known package manager found"; exit 1; fi
    for t in "${missing[@]}"; do
        [[ "$t" == "btrfs" ]] && t="btrfs-progs"
        [[ "$t" == "ip"    ]] && t="iproute2"
        $pm_cmd "$t" &>/dev/null
    done
}
_check_deps

SD_USERNS_OK=false   # kept for compatibility; never set to true

grep -qw btrfs /proc/filesystems 2>/dev/null || {
    clear
    printf '\n  \033[0;31m✗  BTRFS is not available in your kernel.\033[0m\n'
    printf '  \033[2m  Enable CONFIG_BTRFS_FS or install the btrfs kernel module.\033[0m\n\n'
    exit 1
}

tmux bind-key -n 'C-\\' detach-client 2>/dev/null || true

_sudo_keepalive() {
    ( while true; do sudo -n true 2>/dev/null; sleep 55; done ) &
    disown "$!" 2>/dev/null || true
}

_require_sudo() {
    _sudo_keepalive
}

if [[ -z "$TMUX" ]]; then
    _self="$(realpath "$0" 2>/dev/null || printf '%s' "$0")"
    _sd_outer_sudo() {
        local _me; _me=$(id -un)
        local _sudoers="/etc/sudoers.d/simpledocker_${_me}"
        local _rule
        _rule=$(printf '%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/mount, /usr/bin/umount, /usr/bin/btrfs, /usr/sbin/btrfs, /bin/btrfs, /sbin/btrfs, /usr/bin/mkfs.btrfs, /sbin/mkfs.btrfs, /usr/bin/chown, /bin/chown, /bin/mkdir, /usr/bin/mkdir, /usr/bin/rm, /bin/rm, /usr/bin/chmod, /bin/chmod, /usr/bin/tee /etc/hosts, /usr/bin/nsenter, /usr/sbin/nsenter, /usr/bin/unshare, /usr/bin/chroot, /usr/sbin/chroot, /bin/bash, /usr/bin/bash, /usr/bin/ip, /bin/ip, /sbin/ip, /usr/sbin/ip, /usr/sbin/iptables, /usr/bin/iptables, /sbin/iptables, /usr/sbin/sysctl, /usr/bin/sysctl, /bin/cp, /usr/bin/cp, /usr/bin/apt-get, /usr/bin/apt, /usr/sbin/cryptsetup, /usr/bin/cryptsetup, /sbin/cryptsetup, /sbin/losetup, /usr/sbin/losetup, /bin/losetup, /sbin/blockdev, /usr/sbin/blockdev\n' "$_me")
        printf '\n  \033[1m── simpleDocker ──\033[0m\n'
        printf '  \033[2msimpleDocker requires sudo access.\033[0m\n\n'
        sudo -k 2>/dev/null
        while ! sudo -v 2>/dev/null; do
            printf '  \033[0;31mIncorrect password.\033[0m  Try again.\n\n'
        done
        sudo mkdir -p /etc/sudoers.d
        printf '%s' "$_rule" | sudo tee "$_sudoers" >/dev/null
    }
    _sd_outer_sudo
    if tmux has-session -t "simpleDocker" 2>/dev/null; then
        if [[ "$(tmux show-environment -t "simpleDocker" SD_READY 2>/dev/null)" != "SD_READY=1" ]]; then
            tmux kill-session -t "simpleDocker" 2>/dev/null || true
        fi
    fi
    if ! tmux has-session -t "simpleDocker" 2>/dev/null; then
        tmux new-session -d -s "simpleDocker" "bash $(printf '%q' "$_self")" 2>/dev/null
        tmux set-option -t "simpleDocker" status off 2>/dev/null
    fi
    while tmux has-session -t "simpleDocker" 2>/dev/null; do
        tmux attach-session -t "simpleDocker" >/dev/null 2>&1
        stty sane 2>/dev/null
        while IFS= read -r -t 0.1 -n 256 _ 2>/dev/null; do :; done
        clear
        [[ "$(tmux show-environment -g SD_DETACH 2>/dev/null)" == "SD_DETACH=1" ]] \
            && { tmux set-environment -g SD_DETACH 0 2>/dev/null; clear; break; }
    done
    clear; exit 0
fi

_force_quit() {
    if [[ -n "$CONTAINERS_DIR" ]]; then
        for d in "$CONTAINERS_DIR"/*/; do
            [[ -f "$d/state.json" ]] || continue
            local _cid; _cid=$(basename "$d"); local _s; _s="$(tsess "$_cid")"
            tmux_up "$_s" && { tmux send-keys -t "$_s" C-c "" 2>/dev/null; sleep 0.2; tmux kill-session -t "$_s" 2>/dev/null || true; }
            if _is_installing "$_cid" && [[ ! -f "$d.install_ok" && ! -f "$d.install_fail" ]]; then
                touch "$d.install_fail" 2>/dev/null || true
            fi
        done
    fi
    tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
    _unmount_img
    rm -rf "$SD_MNT_BASE" 2>/dev/null || true
    tmux kill-session -t "simpleDocker" 2>/dev/null || true
    exit 0
}
trap '_force_quit' INT TERM HUP
stty -ixon 2>/dev/null || true

_tmux_get()   { tmux show-environment -g "$1" 2>/dev/null | cut -d= -f2-; }
_tmux_set()   { tmux set-environment -g "$1" "$2" 2>/dev/null; }
_st()         { jq -r ".$2 // empty" "$CONTAINERS_DIR/$1/state.json" 2>/dev/null; }
_set_st()     { local f="$CONTAINERS_DIR/$1/state.json"
                jq ".$2 = $3" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null; }
_state_get()  { _st "$1" "$2"; }
_cname()      { _st "$1" name; }
_cpath()      { local r; r=$(_st "$1" install_path); [[ -n "$r" ]] && printf '%s/%s' "$INSTALLATIONS_DIR" "$r"; }
tsess()       { printf 'sd_%s' "$1"; }
tmux_up()     { tmux has-session -t "$1" 2>/dev/null; }
_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
_trim_s()    { _strip_ansi | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
_sig_rc()    { [[ ${1:-0} -eq 143 || ${1:-0} -eq 138 || ${1:-0} -eq 137 ]]; }
_log_write() {
    local f="$1"; shift
    local max=10485760  # 10 MB
    printf '%s\n' "$@" >> "$f" 2>/dev/null || true
    local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [[ "$sz" -gt "$max" ]]; then
        local keep=$(( max * 8 / 10 ))
        local tmp; tmp=$(mktemp "$TMP_DIR/.sd_log_tmp_XXXXXX" 2>/dev/null) || return
        tail -c "$keep" "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    fi
}
_log_path() {
    local cname; cname=$(_cname "$1" 2>/dev/null || printf '%s' "$1")
    printf '%s/%s-%s-%s.log' "$LOGS_DIR" "$cname" "$1" "$2"
}

_health_check() {
    local cid="$1"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local health; health=$(jq -r '.meta.health // empty' "$sj" 2>/dev/null)
    [[ "$health" != "true" ]] && return 1
    local port; port=$(jq -r '.meta.port // empty' "$sj" 2>/dev/null)
    [[ -z "$port" || "$port" == "0" ]] && return 1
    nc -z -w1 127.0.0.1 "$port" 2>/dev/null
}
_log_rotate() {
    local f="$1"
    [[ ! -f "$f" ]] && return
    local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [[ "$sz" -gt 10485760 ]] && tail -c 8388608 "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || true
}
_rand_id()    { local id
                while true; do id=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
                    [[ ! -d "$CONTAINERS_DIR/$id" ]] && printf '%s' "$id" && return; done; }

_sd_open_url() {
    local url="$1"
    local browser; browser=$(xdg-settings get default-web-browser 2>/dev/null)
    browser="${browser%.desktop}"
    case "${browser,,}" in
        firefox*|librewolf*|waterfox*|floorp*)
            { firefox --new-tab "$url" 2>/dev/null || \
              librewolf --new-tab "$url" 2>/dev/null || \
              floorp --new-tab "$url" 2>/dev/null; } & disown ;;
        vivaldi*)
            { vivaldi-stable --new-tab "$url" 2>/dev/null || \
              vivaldi --new-tab "$url" 2>/dev/null; } & disown ;;
        google-chrome*|chrome*)
            { google-chrome-stable --new-tab "$url" 2>/dev/null || \
              google-chrome --new-tab "$url" 2>/dev/null; } & disown ;;
        chromium*|chromium-browser*)
            chromium --new-tab "$url" 2>/dev/null & disown ;;
        brave*|brave-browser*)
            { brave-browser --new-tab "$url" 2>/dev/null || \
              brave --new-tab "$url" 2>/dev/null; } & disown ;;
        microsoft-edge*|msedge*)
            microsoft-edge --new-tab "$url" 2>/dev/null & disown ;;
        *)
            { [[ -n "$browser" ]] && gtk-launch "$browser" "$url" 2>/dev/null; } & disown \
            || xdg-open "$url" 2>/dev/null & disown ;;
    esac
}

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

_sd_ub_cache_check() {
    [[ ! -f "$UBUNTU_DIR/.ubuntu_ready" ]] && return
    mkdir -p "$SD_MNT_BASE/.tmp" 2>/dev/null
    local _drift_f="$SD_MNT_BASE/.tmp/.sd_ub_drift_$$"
    local _upd_f="$SD_MNT_BASE/.tmp/.sd_ub_upd_$$"
    local _saved_pkgs_file="$UBUNTU_DIR/.ubuntu_default_pkgs"
    if [[ -f "$_saved_pkgs_file" ]]; then
        local _cur_sorted; _cur_sorted=$(printf '%s
' $DEFAULT_UBUNTU_PKGS | sort)
        local _saved_sorted; _saved_sorted=$(sort "$_saved_pkgs_file" 2>/dev/null)
        [[ "$_cur_sorted" != "$_saved_sorted" ]] && printf 'true' > "$_drift_f" || printf 'false' > "$_drift_f"
    else
        printf 'true' > "$_drift_f"
    fi
    local _sim; _sim=$(_chroot_bash "$UBUNTU_DIR" -c         "apt-get update -qq 2>/dev/null; apt-get --simulate upgrade 2>/dev/null | grep -c '^Inst '" 2>/dev/null)
    [[ "${_sim:-0}" -gt 0 ]] && printf 'true' > "$_upd_f" || printf 'false' > "$_upd_f"
}

_sd_ub_cache_read() {
    [[ "$_SD_UB_CACHE_LOADED" == true ]] && return
    _SD_UB_CACHE_LOADED=true
    local _drift_f="$SD_MNT_BASE/.tmp/.sd_ub_drift_$$"
    local _upd_f="$SD_MNT_BASE/.tmp/.sd_ub_upd_$$"
    local _w=0
    while [[ ! -f "$_drift_f" && $_w -lt 30 ]]; do sleep 0.1; (( _w++ )); done
    [[ -f "$_drift_f" ]] && _SD_UB_PKG_DRIFT=$(cat "$_drift_f")   || _SD_UB_PKG_DRIFT=false
    [[ -f "$_upd_f"   ]] && _SD_UB_HAS_UPDATES=$(cat "$_upd_f")   || _SD_UB_HAS_UPDATES=false
    rm -f "$_drift_f" "$_upd_f"
}

_netns_name()  { printf 'sd_%s' "$(printf '%s' "${1:-$MNT_DIR}" | md5sum | cut -c1-8)"; }
_netns_idx()   { printf '%d' $(( 0x$(printf '%s' "${1:-$MNT_DIR}" | md5sum | cut -c1-2) % 254 )); }
_netns_hosts() { printf '%s/.sd/.netns_hosts' "${1:-$MNT_DIR}"; }

_netns_setup() {
    local mnt="${1:-$MNT_DIR}" ns idx subnet br veth_h veth_ns ip_ns ip_h
    ns=$(_netns_name "$mnt"); idx=$(_netns_idx "$mnt")
    subnet="10.88.${idx}"; br="sd-br${idx}"; veth_h="sd-h${idx}"; veth_ns="sd-ns${idx}"
    ip_ns="${subnet}.1"; ip_h="${subnet}.254"
    sudo -n ip netns list 2>/dev/null | grep -q "^${ns}" && return 0
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
    local cid="$1" mode; mode=$(_exposure_get "$1")
    local port; port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
    local ep; ep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
    [[ -n "$ep" ]] && port="$ep"
    [[ -z "$port" || "$port" == "0" ]] && return 0
    local ct_ip; ct_ip=$(_netns_ct_ip "$cid" "$MNT_DIR")

    _exposure_flush "$cid" "$port" "$ct_ip"

    case "$mode" in
        isolated)
            sudo -n iptables -I INPUT   -p tcp --dport "$port" -j DROP 2>/dev/null || true
            sudo -n iptables -I OUTPUT  -p tcp -d "${ct_ip}/32" --dport "$port" -j DROP 2>/dev/null || true
            sudo -n iptables -I FORWARD -d "${ct_ip}/32" -p tcp --dport "$port" -j DROP 2>/dev/null || true
            ;;
        localhost)
            sudo -n sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
            sudo -n iptables -I FORWARD -d "${ct_ip}/32" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            sudo -n iptables -I FORWARD -s "${ct_ip}/32" -p tcp --sport "$port" -j ACCEPT 2>/dev/null || true
            ;;
        public)
            sudo -n sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
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
    sudo -n iptables -D INPUT   -p tcp --dport "$port" -j DROP 2>/dev/null || true
    sudo -n iptables -D OUTPUT  -p tcp -d "${ct_ip}/32" --dport "$port" -j DROP 2>/dev/null || true
    sudo -n iptables -D FORWARD -d "${ct_ip}/32" -p tcp --dport "$port" -j DROP 2>/dev/null || true
    sudo -n iptables -t nat -D PREROUTING  -p tcp --dport "$port" -j DNAT --to-destination "${ct_ip}:${port}" 2>/dev/null || true
    sudo -n iptables -t nat -D POSTROUTING -d "${ct_ip}/32" -p tcp --dport "$port" -j MASQUERADE 2>/dev/null || true
    sudo -n iptables -D FORWARD -d "${ct_ip}/32" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    sudo -n iptables -D FORWARD -s "${ct_ip}/32" -p tcp --sport "$port" -j ACCEPT 2>/dev/null || true
}

_luks_mapper()  { printf 'sd_%s' "$(basename "${1%.img}" | tr -dc 'a-zA-Z0-9_')"; }
_luks_dev()     { printf '/dev/mapper/%s' "$(_luks_mapper "$1")"; }
_luks_is_open() { [[ -b "$(_luks_dev "$1")" ]]; }
_img_is_luks()  { sudo -n cryptsetup isLuks "$1" 2>/dev/null; }

_luks_open() {
    local img="$1" mapper pass attempts=0
    mapper=$(_luks_mapper "$img")
    _luks_is_open "$img" && return 0
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

_enc_auto_unlock_enabled() {
    printf '%s' "$SD_VERIFICATION_CIPHER" | sudo -n cryptsetup open \
        --test-passphrase --key-file=- "$IMG_PATH" &>/dev/null
}

_enc_system_agnostic_enabled() {
    printf '%s' "$SD_DEFAULT_KEYWORD" | sudo -n cryptsetup open \
        --test-passphrase --key-slot 1 --key-file=- "$IMG_PATH" &>/dev/null
}

_enc_authkey_path() { printf '%s' "$MNT_DIR/.sd/auth.key"; }

_enc_authkey_slot_file() { printf '%s' "$MNT_DIR/.sd/auth.slot"; }

_enc_verified_dir()  { printf '%s' "$MNT_DIR/.sd/verified"; }
_enc_verified_id()   { sha256sum /etc/machine-id 2>/dev/null | cut -c1-8; }
_enc_verified_pass() { sha256sum /etc/machine-id 2>/dev/null | cut -c1-32 || printf '%s' "simpledocker_fallback"; }
_enc_verified_path() { printf '%s/%s' "$(_enc_verified_dir)" "$(_enc_verified_id)"; }
_enc_is_verified()   { [[ -f "$(_enc_verified_path)" ]]; }

_enc_vs_slot()    { local _f="$(_enc_verified_dir)/$1"; [[ -f "$_f" ]] && sed -n '2p' "$_f" 2>/dev/null || printf ''; }
_enc_vs_hostname(){ local _f="$(_enc_verified_dir)/$1"; [[ -f "$_f" ]] && sed -n '1p' "$_f" 2>/dev/null || printf "$1"; }
_enc_vs_pass()    { local _f="$(_enc_verified_dir)/$1"; [[ -f "$_f" ]] && sed -n '3p' "$_f" 2>/dev/null || printf ''; }

_enc_vs_write() {
    local _id="$1" _slot="$2"
    local _vdir; _vdir=$(_enc_verified_dir)
    mkdir -p "$_vdir" 2>/dev/null
    printf '%s
%s
%s
' "$(cat /etc/hostname 2>/dev/null | tr -d "[:space:]" || printf "unknown")" "$_slot" "$(_enc_verified_pass)" > "$_vdir/$_id"
}

_enc_free_slot() {
    local _dump; _dump=$(sudo -n cryptsetup luksDump "$IMG_PATH" 2>/dev/null)
    local _s
    for (( _s=SD_LUKS_KEY_SLOT_MIN; _s<=SD_LUKS_KEY_SLOT_MAX; _s++ )); do
        printf '%s' "$_dump" | grep -qE "^\s+$_s: luks2" || { printf '%s' "$_s"; return 0; }
    done
    return 1
}

_enc_slots_used() {
    sudo -n cryptsetup luksDump "$IMG_PATH" 2>/dev/null         | grep -oP '^\s+\K[0-9]+(?=: luks2)'         | awk -v mn="$SD_LUKS_KEY_SLOT_MIN" -v mx="$SD_LUKS_KEY_SLOT_MAX"               '$1+0>=mn && $1+0<=mx' | wc -l
}

_enc_authkey_slot() {
    local _sf; _sf=$(_enc_authkey_slot_file)
    [[ -f "$_sf" ]] && cat "$_sf" 2>/dev/null || printf ''
}

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

_enc_authkey_create() {
    local _auth_kf="$1"
    local _kf; _kf=$(_enc_authkey_path)
    mkdir -p "$(dirname "$_kf")" 2>/dev/null
    dd if=/dev/urandom bs=64 count=1 2>/dev/null > "$_kf"
    chmod 600 "$_kf"
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

        local _vs_ids=()
        if [[ -d "$_vdir" ]]; then
            while IFS= read -r -d '' _vf; do
                _vs_ids+=("$(basename "$_vf")")
            done < <(find "$_vdir" -maxdepth 1 -type f -print0 2>/dev/null)
        fi

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

    local _tf_img_auth; _tf_img_auth=$(mktemp "$TMP_DIR/.sd_imgauth_XXXXXX")
    printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_img_auth"
    _enc_authkey_create "$_tf_img_auth" || { rm -f "$_tf_img_auth"; pause "Auth keyfile creation failed."; return 1; }

    sudo -n cryptsetup luksKillSlot --batch-mode \
        --key-file "$(_enc_authkey_path)" "$imgfile" 31 &>/dev/null || true
    rm -f "$_tf_img_auth"

    local _tf_dk_a; _tf_dk_a=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
    local _tf_dk_p; _tf_dk_p=$(mktemp "$TMP_DIR/.sd_new_XXXXXX")
    cp "$(_enc_authkey_path)" "$_tf_dk_a"
    printf '%s' "$SD_DEFAULT_KEYWORD" > "$_tf_dk_p"
    sudo -n cryptsetup luksAddKey --batch-mode \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
        --key-slot 1 --key-file "$_tf_dk_a" \
        "$imgfile" "$_tf_dk_p" &>/dev/null || true
    rm -f "$_tf_dk_a" "$_tf_dk_p"

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
    if mountpoint -q "$MNT_DIR" 2>/dev/null; then _set_img_dirs; return 0; fi
    if [[ -n "$DEFAULT_IMG" && -f "$DEFAULT_IMG" ]]; then _mount_img "$DEFAULT_IMG"; return 0; fi
    while true; do
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
$_sd_chroot_fn
trap '' INT
printf '\033[1m── simpleDocker — Ubuntu base setup ──\033[0m\n\n'
printf 'Downloading Ubuntu 24.04 LTS Noble base...\n'
if curl -fsSL --progress-bar $(printf '%q' "$url") -o $(printf '%q' "$tmp"); then
    printf 'Extracting...\n'
    tar -xzf $(printf '%q' "$tmp") -C $(printf '%q' "$UBUNTU_DIR") 2>&1 || true
    rm -f $(printf '%q' "$tmp")
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

FZF_BASE=(
    --ansi --no-sort --header-first
    --prompt="  ❯ " --pointer="▶"
    --height=80% --min-height=18
    --reverse --border=rounded --margin=1,2
    --no-info --bind=esc:abort
    "--bind=${KB[detach]}:execute-silent(tmux set-environment -g SD_DETACH 1 && tmux detach-client >/dev/null 2>&1)+abort"
)

_fzf() {
    local _out; _out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    fzf "$@" >"$_out" 2>/dev/null &
    local _pid=$!
    printf '%s' "$_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_pid" 2>/dev/null
    local _rc=$?
    if [[ $_rc -eq 143 || $_rc -eq 137 ]]; then rm -f "$_out"; return 2; fi
    cat "$_out" 2>/dev/null; rm -f "$_out"
    return $_rc
}

confirm() {
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "$(printf "${GRN}%s${NC}" "${L[yes]}")" "$(printf "${RED}%s${NC}" "${L[no]}")" \
        | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}%s${NC}" "$1")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local ans; ans=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; return 1; }
    [[ $_frc -ne 0 ]] && return 1
    printf '%s' "$ans" | grep -qi "${L[yes]}"
}

pause() {
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "$(printf "${GRN}[ OK ]${NC}  ${DIM}%s${NC}" "${1:-Done.}")" \
        | fzf "${FZF_BASE[@]}" --header="$(printf "${DIM}%s${NC}" "${L[ok_press]}")" --no-multi >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; return 0; }
    return 0
}

FINPUT_RESULT=""
finput() {
    FINPUT_RESULT=""
    local _tmp; _tmp=$(mktemp "$TMP_DIR/.sd_finput_XXXXXX")
    : | fzf "${FZF_BASE[@]}" --print-query \
        --header="$(printf "${BLD}%s${NC}\n${DIM}  %s${NC}" "$1" "${L[type_enter]}")" \
        2>/dev/null > "$_tmp"
    local _rc=$?
    if [[ $_rc -eq 0 || $_rc -eq 1 ]]; then
        FINPUT_RESULT=$(head -1 "$_tmp" 2>/dev/null || true)
        rm -f "$_tmp"; return 0
    else
        rm -f "$_tmp"; return 1
    fi
}

_menu() {
    local header="$1"; shift
    local lines=()
    for x in "$@"; do
        if printf '%s' "$x" | grep -q $'\033'; then
            lines+=("$x")
        else
            lines+=("$(printf "${DIM} %s${NC}" "$x")")
        fi
    done
    local _SEP_NAV; _SEP_NAV="$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"
    lines+=("$_SEP_NAV" "$(printf "${DIM} %s${NC}" "${L[back]}")")
    local _out _pid _rc
    while true; do
        while IFS= read -r -t 0 -n 1 _ 2>/dev/null; do :; done
        _out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── %s ──${NC}" "$header")" >"$_out" 2>/dev/null &
        _pid=$!; printf '%s' "$_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_pid" 2>/dev/null; _rc=$?
        REPLY=$(cat "$_out" 2>/dev/null | _trim_s); rm -f "$_out"
        _sig_rc $_rc && { stty sane 2>/dev/null; if [[ "$_SD_USR1_FIRED" == "1" ]]; then _SD_USR1_FIRED=0; return 2; fi; continue; }
        [[ $_rc -ne 0 || -z "$REPLY" || "$REPLY" == "${L[back]}" ]] && return 1
        return 0
    done
}

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
    mkdir -p "$SD_MNT_BASE/.tmp" 2>/dev/null
    local ok_file;   ok_file=$(mktemp "$SD_MNT_BASE/.tmp/.sd_resize_ok_XXXXXX")
    local fail_file; fail_file=$(mktemp "$SD_MNT_BASE/.tmp/.sd_resize_fail_XXXXXX")
    rm -f "$ok_file" "$fail_file"
    local resize_script; resize_script=$(mktemp "$SD_MNT_BASE/.tmp/.sd_resize_XXXXXX.sh")
    local _known_mapper; _known_mapper="sd_$(basename "${img_to_resize%.img}" | tr -dc 'a-zA-Z0-9_')"
    cat > "$resize_script" <<RESIZESCRIPT
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

printf '\033[0;33mUnmounting image…\033[0m\n'
sudo -n umount -lf "\$mnt_dir" 2>/dev/null || true
sudo -n cryptsetup close "\$known_mapper" 2>/dev/null || true
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

_mounted_lodev="" _mounted_mapper="" _saved_pp=""
_do_mount() {
    local _img="\$1" _mnt="\$2" _mname="\$3"
    mkdir -p "\$_mnt" 2>/dev/null
    _mounted_lodev=\$(sudo -n losetup --find --show "\$_img" 2>/dev/null)
    printf '[mount] lodev=%s mapper=%s\n' "\$_mounted_lodev" "\$_mname"
    if [[ -z "\$_mounted_lodev" ]]; then printf 'ERROR: losetup failed\n'; return 1; fi
    if sudo -n cryptsetup isLuks "\$_mounted_lodev" 2>/dev/null; then
        _mounted_mapper="\$_mname"
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

CT_IDS=(); CT_NAMES=()
_load_containers() {
    CT_IDS=(); CT_NAMES=()
    local show_hidden="${1:-false}"
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        local hidden n
        { read -r hidden; IFS= read -r n; } < <(jq -r '.hidden // false, .name // empty' "$d/state.json" 2>/dev/null)
        [[ "$show_hidden" == "false" && "$hidden" == "true" ]] && continue
        [[ -z "$n" ]] && n="(unnamed-$cid)"
        CT_IDS+=("$cid"); CT_NAMES+=("$n")
    done
}

_validate_containers() {
    [[ -z "$CONTAINERS_DIR" ]] && return
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        [[ "$(_st "$cid" installed)" != "true" ]] && continue
        local ip; ip=$(_cpath "$cid")
        [[ -n "$ip" && -d "$ip" ]] || _set_st "$cid" installed false
    done
}

_installing_id()      { _tmux_get SD_INSTALLING; }
_inst_sess()          { printf 'sdInst_%s' "$1"; }
_is_installing()      { local cid="$1"; tmux_up "$(_inst_sess "$cid")"; }
_cleanup_stale_lock() {
    local cur; cur=$(_installing_id)
    [[ -z "$cur" ]] && return 0
    tmux_up "$(_inst_sess "$cur")" && return 0
    _tmux_set SD_INSTALLING ""
}



declare -A BP_META=()
declare -A BP_ENV=()

_bp_parse() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1
    BP_META=() BP_ENV=() BP_STORAGE="" BP_DEPS="" BP_DIRS="" BP_PIP=""
    BP_GITHUB="" BP_NPM="" BP_BUILD="" BP_INSTALL="" BP_UPDATE="" BP_START=""
    BP_ACTIONS_NAMES=() BP_ACTIONS_SCRIPTS=() BP_ACTIONS=() BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=() BP_CRON_FLAGS=()
    BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()

    local cur_section="" cur_content="" in_container=0 action_name=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        local stripped; stripped=$(printf '%s' "$line" | sed 's/#.*//' | sed 's/[[:space:]]*$//')

        if [[ "$stripped" =~ ^\[([^/][^]]*)\]$ ]]; then
            local new_sec="${BASH_REMATCH[1]}"
            _bp_flush_section "$cur_section" "$cur_content"
            cur_section="$new_sec"
            cur_content=""

            if [[ "$new_sec" == "container" || "$new_sec" == "blueprint" ]]; then
                in_container=1; cur_section=""; continue
            fi
            continue
        fi

        if [[ "$stripped" =~ ^\[/(container|blueprint|end)\]$ ]]; then
            _bp_flush_section "$cur_section" "$cur_content"
            cur_section=""; cur_content=""; in_container=0
            continue
        fi

        [[ -n "$cur_section" ]] && cur_content+="$line"$'\n'
    done < "$file"

    _bp_flush_section "$cur_section" "$cur_content"
}

_bp_flush_section() {
    local sec="$1" content="$2"
    [[ -z "$sec" ]] && return
    content=$(printf '%s' "$content" | sed 's/[[:space:]]*$//')

    case "${sec,,}" in
        meta)
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" ]] && continue
                local k="${l%%=*}" v="${l#*=}"
                k=$(printf '%s' "$k" | sed 's/[[:space:]]*$//')
                v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//')
                BP_META["$k"]="$v"
            done <<< "$content" ;;
        env)
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" ]] && continue
                local k="${l%%=*}" v="${l#*=}"
                k=$(printf '%s' "$k" | sed 's/[[:space:]]*$//')
                v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//')
                BP_ENV["$k"]="$v"
            done <<< "$content" ;;
        storage)     BP_STORAGE="$content" ;;
        dependencies|deps) BP_DEPS="$content" ;;
        dirs)        BP_DIRS="$content" ;;
        pip|pypi)    BP_PIP="$content" ;;
        git)          BP_GITHUB="$content" ;;
        npm)         BP_NPM="$content" ;;
        build)       BP_BUILD="$content" ;;
        install)     BP_INSTALL="$content" ;;
        update)      BP_UPDATE="$content" ;;
        start)       BP_START="$content" ;;
        actions)
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" || "$l" == \#* ]] && continue
                local albl="${l%%|*}"; albl=$(printf '%s' "$albl" | sed 's/[[:space:]]*$//')
                local arest="${l#*|}"; arest=$(printf '%s' "$arest" | sed 's/^[[:space:]]*//')
                [[ -z "$albl" ]] && continue
                BP_ACTIONS_NAMES+=("$albl")
                BP_ACTIONS_SCRIPTS+=("$arest")
            done <<< "$content" ;;
        cron)
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" || "$l" == \#* ]] && continue
                local cinterval_name="${l%%|*}"; cinterval_name=$(printf '%s' "$cinterval_name" | sed 's/[[:space:]]*$//')
                local ccmd="${l#*|}"; ccmd=$(printf '%s' "$ccmd" | sed 's/^[[:space:]]*//')
                [[ -z "$ccmd" ]] && continue
                local cflags=""
                printf '%s' "$cinterval_name" | grep -q -- '--sudo'    && cflags="$cflags --sudo"
                printf '%s' "$cinterval_name" | grep -q -- '--unjailed' && cflags="$cflags --unjailed"
                cflags=$(printf '%s' "$cflags" | sed 's/^[[:space:]]*//')
                cinterval_name=$(printf '%s' "$cinterval_name" | sed 's/--sudo//g;s/--unjailed//g' | sed 's/[[:space:]]*$//')
                local cinterval cname
                cinterval=$(printf '%s' "$cinterval_name" | awk '{print $1}')
                cname=$(printf '%s' "$cinterval_name" | sed 's/^[^[:space:]]*//' | sed 's/^[[:space:]]*//' | sed 's/^\[//;s/\]$//')
                [[ -z "$cname" ]] && cname="$cinterval job"
                BP_CRON_NAMES+=("$cname")
                BP_CRON_INTERVALS+=("$cinterval")
                local ccmd_prefixed; ccmd_prefixed=$(printf '%s' "$ccmd" | \
                    sed 's#>>[[:space:]]*\([[:alpha:]_][^[:space:]]*\)#>> $CONTAINER_ROOT/\1#g')
                BP_CRON_CMDS+=("$ccmd_prefixed")
                BP_CRON_FLAGS+=("$cflags")
            done <<< "$content" ;;
        *)
            BP_ACTIONS_NAMES+=("$sec")
            BP_ACTIONS_SCRIPTS+=("$content") ;;
    esac
}

BP_ERRORS=()
_bp_validate() {
    BP_ERRORS=()

    [[ -z "${BP_META[name]:-}" ]] && BP_ERRORS+=("  [meta]  'name' is required")

    local has_entry=0
    [[ -n "${BP_META[entrypoint]:-}" ]] && has_entry=1
    [[ -n "$BP_START" ]] && has_entry=1
    [[ $has_entry -eq 0 ]] && BP_ERRORS+=("  [meta]  'entrypoint' or a [start] block is required")

    local port; port=$(printf '%s' "${BP_META[port]:-}" | sed 's/[[:space:]]//g')
    [[ -n "$port" && ! "$port" =~ ^[0-9]+$ ]] && BP_ERRORS+=("  [meta]  'port' must be a number, got: $port")

    if [[ -n "$BP_STORAGE" ]]; then
        local st; st=$(printf '%s' "$BP_STORAGE" | tr ',' '\n' | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | head -1)
        [[ -n "$st" && -z "${BP_META[storage_type]:-}" ]] && \
            BP_ERRORS+=("  [storage]  'storage_type' in [meta] is required when [storage] paths are declared")
    fi

    if [[ -n "$BP_GITHUB" ]]; then
        local gln=0
        while IFS= read -r gl; do
            (( gln++ )) || true
            gl=$(printf '%s' "$gl" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$gl" ]] && continue
            [[ "$gl" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*=[[:space:]]*(.*) ]] && gl="${BASH_REMATCH[1]}"
            local repo; repo=$(printf '%s' "$gl" | awk '{print $1}')
            [[ ! "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] && \
                BP_ERRORS+=("  [git]  line $gln: invalid repo format '$repo' (expected org/repo)")
        done <<< "$BP_GITHUB"
    fi

    if [[ -n "$BP_DIRS" ]]; then
        local open=0 close=0 ch di=0 dlen=${#BP_DIRS}
        while [[ $di -lt $dlen ]]; do
            ch="${BP_DIRS:$di:1}"
            [[ "$ch" == '(' ]] && (( open++ ))  || true
            [[ "$ch" == ')' ]] && (( close++ )) || true
            (( di++ )) || true
        done
        [[ $open -ne $close ]] && \
            BP_ERRORS+=("  [dirs]  unbalanced parentheses (${open} open, ${close} close)")
    fi

    local ai=0
    for i in "${!BP_ACTIONS_NAMES[@]}"; do
        (( ai++ )) || true
        local lbl="${BP_ACTIONS_NAMES[$i]}" dsl="${BP_ACTIONS_SCRIPTS[$i]}"
        printf '%s' "$dsl" | grep -q '|' || continue
        local has_prompt=0 has_select=0
        local seg
        while IFS= read -r seg; do
            seg=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ "$seg" == prompt:* ]] && has_prompt=1
            [[ "$seg" == select:* ]] && has_select=1
        done <<< "$(printf '%s' "$dsl" | tr '|' '\n')"
        printf '%s' "$dsl" | grep -q '{input}' && [[ $has_prompt -eq 0 ]] && \
            BP_ERRORS+=("  [actions]  '$lbl': uses {input} but no 'prompt:' segment")
        printf '%s' "$dsl" | grep -q '{selection}' && [[ $has_select -eq 0 ]] && \
            BP_ERRORS+=("  [actions]  '$lbl': uses {selection} but no 'select:' segment")
        [[ -z "$lbl" ]] && BP_ERRORS+=("  [actions]  action $ai has an empty label")
    done

    if [[ -n "$BP_PIP" ]]; then
        local has_py=0
        if [[ -n "$BP_DEPS" ]]; then
            printf '%s' "$BP_DEPS" | tr ',' ' ' | grep -qE 'python3' && has_py=1
        fi
        [[ $has_py -eq 0 ]] && \
            BP_ERRORS+=("  [pip]  requires 'python3' in [deps]")
    fi


    [[ ${#BP_ERRORS[@]} -eq 0 ]] && return 0 || return 1
}

_bp_compile_to_json() {
    local file="$1" cid="$2"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    declare -A BP_META; declare -A BP_ENV
    BP_META=() BP_ENV=() BP_STORAGE="" BP_DEPS="" BP_DIRS="" BP_PIP=""
    BP_GITHUB="" BP_NPM="" BP_BUILD="" BP_INSTALL="" BP_UPDATE="" BP_START=""
    BP_ACTIONS_NAMES=() BP_ACTIONS_SCRIPTS=() BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()
    BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()
    _bp_parse "$file" || return 1

    local ct_name; ct_name=$(_cname "$cid")
    [[ -n "$ct_name" ]] && BP_META["name"]="$ct_name"

    if ! _bp_validate; then
        local errmsg; errmsg=$(printf '%s\n' "${BP_ERRORS[@]}")
        pause "$(printf '⚠  Blueprint validation failed:\n\n%s\n\n  Fix the blueprint and try again.' "$errmsg")"
        return 1
    fi

    local meta_json="{}"
    for k in "${!BP_META[@]}"; do
        meta_json=$(printf '%s' "$meta_json" | jq --arg k "$k" --arg v "${BP_META[$k]}" '.[$k]=$v')
    done

    local env_json="{}"
    for k in "${!BP_ENV[@]}"; do
        env_json=$(printf '%s' "$env_json" | jq --arg k "$k" --arg v "${BP_ENV[$k]}" '.[$k]=$v')
    done

    local storage_json="[]"
    if [[ -n "$BP_STORAGE" ]]; then
        local sp; sp=$(printf '%s' "$BP_STORAGE" | tr ',' '\n' | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
        storage_json=$(printf '%s\n' $sp | jq -R -s 'split("\n") | map(select(length>0))')
    fi

    local acts_json="[]"
    for i in "${!BP_ACTIONS_NAMES[@]}"; do
        local lbl="${BP_ACTIONS_NAMES[$i]}" dsl="${BP_ACTIONS_SCRIPTS[$i]}"
        acts_json=$(printf '%s' "$acts_json" | jq \
            --arg l "$lbl" --arg d "$dsl" '. + [{"label":$l,"dsl":$d}]')
    done

    local crons_json="[]"
    for i in "${!BP_CRON_NAMES[@]}"; do
        local cn="${BP_CRON_NAMES[$i]}" ci="${BP_CRON_INTERVALS[$i]}" cc="${BP_CRON_CMDS[$i]}" cf="${BP_CRON_FLAGS[$i]:-}"
        crons_json=$(printf '%s' "$crons_json" | jq \
            --arg n "$cn" --arg iv "$ci" --arg c "$cc" --arg f "$cf" '. + [{"name":$n,"interval":$iv,"cmd":$c,"flags":$f}]')
    done

    jq -n \
        --argjson meta "$meta_json" \
        --argjson env "$env_json" \
        --argjson storage "$storage_json" \
        --arg deps "$BP_DEPS" \
        --arg dirs "$BP_DIRS" \
        --arg pip "$BP_PIP" \
        --arg npm "$BP_NPM" \
        --arg git "$BP_GITHUB" \
        --arg build "$BP_BUILD" \
        --arg install "$BP_INSTALL" \
        --arg update "$BP_UPDATE" \
        --arg start "$BP_START" \
        --argjson actions "$acts_json" \
        --argjson crons "$crons_json" \
        '{meta:$meta, environment:$env, storage:$storage,
          deps:$deps, dirs:$dirs, pip:$pip, npm:$npm, git:$git, build:$build,
          install:$install, update:$update, start:$start,
          actions:$actions, crons:$crons}' > "$sj" 2>/dev/null || return 1
}

_bp_is_json() {
    jq '.' "$1" >/dev/null 2>&1
}


_cr_prefix() {
    local v="$1"
    if [[ "$v" == /* || "$v" == ~* || "$v" == *'$'* || "$v" == *'://'* ]]; then
        printf '%s' "$v"; return
    fi
    [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return; }
    [[ "$v" == *':'* ]] && { printf '%s' "$v"; return; }
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$v"; return; }
    printf '$CONTAINER_ROOT/%s' "$v"
}


_SELF_PATH="$(realpath "$0" 2>/dev/null || printf '%s' "$0")"

_bp_cfg()           { printf '%s/.sd/bp_settings.json' "$MNT_DIR"; }
_bp_cfg_get()       { jq -r ".$1 // empty" "$(_bp_cfg)" 2>/dev/null; }
_bp_cfg_set() {
    local key="$1" val="$2" tmp
    mkdir -p "$(dirname "$(_bp_cfg)")" 2>/dev/null
    [[ ! -f "$(_bp_cfg)" ]] && printf '{}' > "$(_bp_cfg)"
    tmp=$(mktemp "$TMP_DIR/.sd_bpcfg_XXXXXX")
    jq --arg k "$key" --arg v "$val" '.[$k]=$v' "$(_bp_cfg)" > "$tmp" && mv "$tmp" "$(_bp_cfg)" || rm -f "$tmp"
}
_bp_persistent_enabled() { [[ "$(_bp_cfg_get persistent_blueprints)" != "false" ]]; }
_bp_autodetect_mode()    { local m; m=$(_bp_cfg_get autodetect_blueprints); printf '%s' "${m:-Home}"; }

_bp_custom_paths_get() {
    jq -r '.custom_paths[]? // empty' "$(_bp_cfg)" 2>/dev/null
}
_bp_custom_paths_add() {
    local p="$1"
    mkdir -p "$(dirname "$(_bp_cfg)")" 2>/dev/null
    [[ ! -f "$(_bp_cfg)" ]] && printf '{}' > "$(_bp_cfg)"
    local tmp; tmp=$(mktemp "$TMP_DIR/.sd_bpcfg_XXXXXX")
    jq --arg p "$p" '.custom_paths = ((.custom_paths // []) + [$p] | unique)' "$(_bp_cfg)" > "$tmp" \
        && mv "$tmp" "$(_bp_cfg)" || rm -f "$tmp"
}
_bp_custom_paths_remove() {
    local p="$1"
    local tmp; tmp=$(mktemp "$TMP_DIR/.sd_bpcfg_XXXXXX")
    jq --arg p "$p" '.custom_paths = [.custom_paths[]? | select(. != $p)]' "$(_bp_cfg)" > "$tmp" \
        && mv "$tmp" "$(_bp_cfg)" || rm -f "$tmp"
}

_bp_autodetect_dirs() {
    local mode; mode=$(_bp_autodetect_mode)
    case "$mode" in
        Home)
            find "$HOME" -maxdepth 6 \
                \( -path "$HOME/.*" -o -path '*/node_modules' -o -path '*/__pycache__' -o -path '*/.git' -o -path '*/vendor' \) \
                -prune -o -name '*.container' -type f -print 2>/dev/null \
                | grep -E '/[^./]+\.container$' ;;
        Root)
            find / -maxdepth 8 \
                \( -path '*/node_modules' -o -path '*/__pycache__' -o -path '*/.git' -o -path '*/vendor' \) \
                -prune -o -name '*.container' -type f -print 2>/dev/null \
                | grep -E '/[^./]+\.container$' ;;
        Everywhere)
            find / -maxdepth 12 \
                \( -path '*/node_modules' -o -path '*/__pycache__' -o -path '*/.git' -o -path '*/vendor' \) \
                -prune -o -name '*.container' -type f -print 2>/dev/null \
                | grep -E '/[^./]+\.container$' ;;
        Custom)
            while IFS= read -r _cpath; do
                [[ -d "$_cpath" ]] || continue
                find "$_cpath" \
                    \( -path '*/node_modules' -o -path '*/__pycache__' -o -path '*/.git' -o -path '*/vendor' \) \
                    -prune -o -name '*.container' -type f -print 2>/dev/null \
                    | grep -E '/[^./]+\.container$'
            done < <(_bp_custom_paths_get) ;;
        Disabled|*) return ;;
    esac
}

_list_imported_names() {
    [[ "$(_bp_autodetect_mode)" == "Disabled" ]] && return
    while IFS= read -r f; do
        [[ -f "$f" ]] && basename "${f%.container}"
    done < <(_bp_autodetect_dirs) | sort -u
}

_get_imported_bp_path() {
    local name="$1"
    [[ "$(_bp_autodetect_mode)" == "Disabled" ]] && return
    while IFS= read -r f; do
        [[ "$(basename "${f%.container}")" == "$name" ]] && printf '%s' "$f" && return
    done < <(_bp_autodetect_dirs)
}

_list_persistent_names() {
    _bp_persistent_enabled || return 0
    awk '
        /SD_PERSISTENT_END/ && !opened  { in_block=1; opened=1; next }
        /^SD_PERSISTENT_END$/ && opened { in_block=0; exit }
        in_block && /^# \[/ { s=$0; sub(/^# \[/,"",s); sub(/\].*/,"",s); print s }
    ' "$_SELF_PATH" 2>/dev/null
}

_get_persistent_bp() {
    awk -v name="$1" '
        /SD_PERSISTENT_END/ && !opened  { in_block=1; opened=1; next }
        /^SD_PERSISTENT_END$/ && opened { exit }
        !in_block { next }
        !found && $0 == "# [" name "]" { found=1; next }
        found && /^# \[/ { exit }
        found { sub(/^# /, ""); print }
    ' "$_SELF_PATH" 2>/dev/null
}

_view_persistent_bp() {
    local content; content=$(_get_persistent_bp "$1")
    [[ -z "$content" ]] && { pause "Could not read blueprint '$1'."; return; }
    printf '%s\n' "$content" \
        | _fzf "${FZF_BASE[@]}" \
              --header="$(printf "${BLD}── [Persistent] %s  ${DIM}(read only)${NC} ──${NC}" "$1")" \
              --no-multi --disabled 2>/dev/null || true
}

_bp_path() {
    local name="$1"
    [[ -f "$BLUEPRINTS_DIR/$name.toml" ]] && printf '%s/%s.toml' "$BLUEPRINTS_DIR" "$name" && return
    [[ -f "$BLUEPRINTS_DIR/$name.json" ]] && printf '%s/%s.json' "$BLUEPRINTS_DIR" "$name" && return
    printf '%s/%s.toml' "$BLUEPRINTS_DIR" "$name"  # default for new
}

_list_blueprint_names() {
    for f in "$BLUEPRINTS_DIR"/*.toml "$BLUEPRINTS_DIR"/*.json; do
        [[ -f "$f" ]] && basename "${f%.*}"
    done | sort -u
}

_emit_runner_steps() {
    local mode="$1" cid="$2" install_path="$3"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local script; script=$(jq -r ".$mode // empty" "$sj" 2>/dev/null)
    local label; [[ "$mode" == "install" ]] && label="Installation" || label="Update"
    local github_block; github_block=$(jq -r '.git // empty' "$sj" 2>/dev/null)
    local build_block;  build_block=$(jq -r '.build // empty' "$sj" 2>/dev/null)
    local _me; _me=$(id -un)

    if [[ -n "$github_block" && "$mode" == "install" ]]; then
        local go_arch; [[ "$(uname -m)" == "aarch64" ]] && go_arch="arm64" || go_arch="amd64"
        local gpu_flag; gpu_flag=$(jq -r '.meta.gpu // empty' "$sj" 2>/dev/null)
        printf '# ── GitHub downloads ──\n'
        printf '_SD_ARCH=%q\n_SD_INSTALL=%q\n\n' "$go_arch" "$install_path"
        if [[ "$gpu_flag" == "cuda_auto" || "$gpu_flag" == "auto" ]]; then
            cat <<'GPUDETECT'
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    _SD_GPU=cuda
else
    _SD_GPU=cpu
fi
GPUDETECT
        fi
        cat <<'SDHELPER'
_sd_extract_auto() {
    local url="$1" dest="$2"; mkdir -p "$dest"
    local _tmp; _tmp=$(mktemp "$dest/.sd_dl_XXXXXX")
    curl -fL --progress-bar --retry 5 --retry-delay 3 --retry-all-errors -C - "$url" -o "$_tmp" || { rm -f "$_tmp"; printf "[!] Download failed: %s\n" "$url"; return 1; }
    local strip=1
    if [[ "$url" =~ \.tar\.zst$ ]]; then
        local _tops; _tops=$(tar --use-compress-program=unzstd -t -f "$_tmp" 2>/dev/null | sed 's|/.*||' | sort -u | grep -v '^\.$' | wc -l) || true
        [[ "${_tops:-1}" -gt 1 ]] && strip=0
        tar --use-compress-program=unzstd -x -C "$dest" --strip-components="$strip" -f "$_tmp"
    elif [[ "$url" =~ \.tar\.(gz|bz2|xz)$|\.tgz$ ]]; then
        local _tops; _tops=$(tar -ta -f "$_tmp" 2>/dev/null | sed 's|/.*||' | sort -u | grep -v '^\.$' | wc -l) || true
        [[ "${_tops:-1}" -gt 1 ]] && strip=0
        tar -xa -C "$dest" --strip-components="$strip" -f "$_tmp"
    elif [[ "$url" =~ \.zip$ ]]; then unzip -o -d "$dest" "$_tmp" 2>/dev/null
    else
        local _bn; _bn=$(basename "$url" | sed 's/[?#].*//' | sed 's/[-_]linux[-_][^.]*$//' | sed 's/[-_]\(amd64\|arm64\|x86_64\|aarch64\)$//')
        [[ -z "$_bn" ]] && _bn=$(basename "$url" | sed 's/[?#].*//')
        mkdir -p "$dest/bin"
        mv "$_tmp" "$dest/bin/$_bn"; chmod +x "$dest/bin/$_bn"; return; fi
    rm -f "$_tmp"
}
_sd_latest_tag() {
    local repo="$1"
    local tag
    tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"') || true
    printf '%s' "$tag"
}
_sd_best_url() {
    local repo="$1" arch="$2" hint="${3:-}" atype="${4:-}"
    local rel; rel=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) || true
    local urls; urls=$(printf '%s' "$rel" | grep -o '"browser_download_url": *"[^"]*"' \
        | grep -ivE 'sha256|\.sig|\.txt|\.json|rocm|jetpack' | grep -o 'https://[^"]*') || true
    local _arc_pat='\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$'
    local _zip_pat='\.zip$'
    local _tar_pat='\.(tar\.(gz|zst|xz|bz2)|tgz)$'
    local _bin_pat  # matches URLs that are NOT archives
    local type_urls="$urls"
    case "${atype^^}" in
        BIN)  type_urls=$(printf '%s' "$urls" | grep -ivE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$') ;;
        ZIP)  type_urls=$(printf '%s' "$urls" | grep -iE "$_zip_pat") ;;
        TAR)  type_urls=$(printf '%s' "$urls" | grep -iE "$_tar_pat") ;;
    esac
    local url=""
    if [[ -n "$hint" ]]; then
        url=$(printf '%s' "$type_urls" | grep -iF "$hint" | head -1) || true
        [[ -z "$url" ]] && url=$(printf '%s' "$urls" | grep -iF "$hint" | head -1) || true
    fi
    if [[ -z "$url" && "${_SD_GPU:-cpu}" == "cuda" ]]; then
        url=$(printf '%s' "$type_urls" | grep -iE "cuda" | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true
        [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE "cuda" | grep -iE "$arch" | head -1) || true
    fi
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$' | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$' | grep -iE "$arch" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE "$arch" | head -1) || true
    [[ -z "$url" && -n "$hint" ]] && url=$(printf '%s' "$urls" | grep -i "$hint" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$' | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$rel" | grep -o '"tarball_url": *"[^"]*"' | grep -o 'https://[^"]*' | head -1) || true
    printf '%s' "$url"
}
SDHELPER

        while IFS= read -r ghline; do
            ghline=$(printf '%s' "$ghline" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$ghline" ]] && continue
            [[ "$ghline" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*=[[:space:]]*(.*) ]] && ghline="${BASH_REMATCH[1]}"
            local repo; repo=$(printf '%s' "$ghline" | awk '{print $1}')
            local rest;  rest=$(printf '%s' "$ghline" | cut -d' ' -f2-)
            local asset_hint="" asset_type=""
            local _rest_scan="$rest"
            while [[ "$_rest_scan" =~ \[([^]]+)\] ]]; do
                local _bval="${BASH_REMATCH[1]}"
                _rest_scan="${_rest_scan#*\[${_bval}\]}"
                if [[ "${_bval^^}" =~ ^(BIN|ZIP|TAR)$ ]]; then
                    asset_type="${_bval^^}"
                elif [[ -z "$asset_hint" ]]; then
                    asset_hint="$_bval"
                fi
            done
            rest=$(printf '%s' "$rest" | sed 's/\[[^]]*\]//g')
            local dest_sub=""; [[ "$rest" =~ →[[:space:]]*([^[:space:]]+) ]] && dest_sub="${BASH_REMATCH[1]%/}"
            local dest_expr; [[ -n "$dest_sub" && "$dest_sub" != "." ]] && dest_expr="\$_SD_INSTALL/${dest_sub}" || dest_expr="\$_SD_INSTALL"
            local hint="$asset_hint"; [[ -z "$hint" && "$rest" =~ (binary|tarball):([^[:space:]→]+) ]] && hint="${BASH_REMATCH[2]}"
            if [[ "$rest" =~ ^source ]]; then
                cat <<GHBLOCK
printf 'Cloning ${repo}...\\n'
_sd_tag=\$(_sd_latest_tag "${repo}")
_sd_cdest="${dest_expr}"
_sd_ctmp=""
if [[ -d "\$_sd_cdest" && -n "\$(ls -A "\$_sd_cdest" 2>/dev/null)" ]]; then
    _sd_ctmp=\$(mktemp -d "\$_SD_INSTALL/.sd_clone_XXXXXX")
    _sd_cdest="\$_sd_ctmp"
fi
if [[ -n "\$_sd_tag" ]]; then
    git clone --depth=1 --branch "\$_sd_tag" "https://github.com/${repo}.git" "\$_sd_cdest" 2>&1
else
    git clone --depth=1 "https://github.com/${repo}.git" "\$_sd_cdest" 2>&1
fi
if [[ -n "\$_sd_ctmp" ]]; then
    mkdir -p "${dest_expr}"
    cp -rn "\$_sd_ctmp/." "${dest_expr}/" 2>/dev/null || true
    rm -rf "\$_sd_ctmp"
fi

GHBLOCK
            else
                cat <<GHBLOCK
printf 'Fetching ${repo} (%s)...\\n' "\$_SD_ARCH"
_sd_url=\$(_sd_best_url "${repo}" "\$_SD_ARCH" "${hint}" "${asset_type}")
[[ -z "\$_sd_url" ]] && { printf '[!] No asset found for ${repo}\\n'; exit 1; }
_sd_extract_auto "\$_sd_url" "${dest_expr}"
printf '✓ ${repo} → ${dest_expr}\\n'

GHBLOCK
            fi
        done <<< "$github_block"
    fi
    [[ -n "$build_block" && "$mode" == "install" ]] && printf '# ── Build ──\n%s\n\n' "$build_block"
    if [[ -n "$script" ]]; then
        local _base; _base=$(jq -r '.meta.base // "ubuntu"' "$sj" 2>/dev/null)
        printf '# ── %s script ──\n' "$label"
        local _ub_q3; _ub_q3=$(printf '%q' "$UBUNTU_DIR")
        local _ip_q3; _ip_q3=$(printf '%q' "$install_path")
        local _sudoers_q; _sudoers_q=$(printf '%q' "/etc/sudoers.d/simpledocker_script_$$")
        printf 'printf '\''%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/bash, /usr/bin/chroot, /usr/sbin/chroot, /usr/bin/unshare\\n'\'' | sudo -n tee %q >/dev/null 2>&1 || true\n' "$_me" "$_sudoers_q"
        printf 'mkdir -p %s/tmp %s/mnt %s/proc %s/sys %s/dev 2>/dev/null || true\n' "$_ub_q3" "$_ub_q3" "$_ub_q3" "$_ub_q3" "$_ub_q3"
        printf 'sudo -n mount --bind /proc %s/proc 2>/dev/null || true\n' "$_ub_q3"
        printf 'sudo -n mount --bind /sys  %s/sys  2>/dev/null || true\n' "$_ub_q3"
        printf 'sudo -n mount --bind /dev  %s/dev  2>/dev/null || true\n' "$_ub_q3"
        printf 'sudo -n mount --bind %s %s/mnt 2>/dev/null || true\n' "$_ip_q3" "$_ub_q3"
        printf '_sd_run_cmd=$(mktemp %s/../.sd_run_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_run_%s.sh)\n' "$_ub_q3" "$$"
        printf 'cat > "$_sd_run_cmd" << '"'"'_SD_RUN_EOF'"'"'\n'
        printf '#!/bin/bash\nset -e\ncd /mnt\n'
        printf '%s\n' "$script"
        printf '_SD_RUN_EOF\n'
        printf 'chmod +x "$_sd_run_cmd"\n'
        printf 'sudo -n mount --bind "$_sd_run_cmd" %s/tmp/.sd_run.sh 2>/dev/null || cp "$_sd_run_cmd" %s/tmp/.sd_run.sh 2>/dev/null || true\n' "$_ub_q3" "$_ub_q3"
        printf '_chroot_bash %s /tmp/.sd_run.sh\n' "$_ub_q3"
        printf '_sd_run_rc=$?\n'
        printf 'sudo -n umount -lf %s/tmp/.sd_run.sh 2>/dev/null || true\n' "$_ub_q3"
        printf 'sudo -n umount -lf %s/mnt %s/dev %s/sys %s/proc 2>/dev/null || true\n' "$_ub_q3" "$_ub_q3" "$_ub_q3" "$_ub_q3"
        printf 'rm -f "$_sd_run_cmd" %s/tmp/.sd_run.sh 2>/dev/null || true\n' "$_ub_q3"
        printf 'sudo -n rm -f %q 2>/dev/null || true\n' "$_sudoers_q"
        printf 'if [[ $_sd_run_rc -ne 0 ]]; then exit "$_sd_run_rc"; fi\n'
    fi
}

_compile_service() {
    local cid="$1"
    local src="$CONTAINERS_DIR/$cid/service.src"
    [[ ! -f "$src" ]] && return 1

    if _bp_is_json "$src"; then
        local sj="$CONTAINERS_DIR/$cid/service.json"
        cp "$src" "$sj"
        sha256sum "$src" 2>/dev/null | cut -d" " -f1 > "$src.hash"
        return 0
    fi

    _bp_compile_to_json "$src" "$cid" || return 1
    sha256sum "$src" 2>/dev/null | cut -d" " -f1 > "$CONTAINERS_DIR/$cid/service.src.hash"
}

_bootstrap_src() {
    local cid="$1"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local src="$CONTAINERS_DIR/$cid/service.src"
    [[ ! -f "$sj" ]] && return 1
    cp "$sj" "$src"
    sha256sum "$src" 2>/dev/null | cut -d" " -f1 > "$src.hash"
}

_ensure_src() {
    local cid="$1"
    local src="$CONTAINERS_DIR/$cid/service.src"
    [[ -f "$src" ]] && return 0
    _bootstrap_src "$cid"
}

_env_exports() {
    local cid="$1" install_path="$2"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    printf 'export CONTAINER_ROOT=%q\n' "$install_path"
    cat <<'ENVBLOCK'
export HOME="$CONTAINER_ROOT"
export XDG_CACHE_HOME="$CONTAINER_ROOT/.cache"
export XDG_CONFIG_HOME="$CONTAINER_ROOT/.config"
export XDG_DATA_HOME="$CONTAINER_ROOT/.local/share"
export XDG_STATE_HOME="$CONTAINER_ROOT/.local/state"
export PATH="$CONTAINER_ROOT/venv/bin:$CONTAINER_ROOT/python/bin:$CONTAINER_ROOT/.local/bin:$CONTAINER_ROOT/bin:$PATH"
export PYTHONNOUSERSITE=1 PIP_USER=false VIRTUAL_ENV="$CONTAINER_ROOT/venv"
_sd_sp=$(python3 -c "import sys; print(next((p for p in sys.path if 'site-packages' in p and '/usr' not in p), ''))" 2>/dev/null)
_sd_vsp=$(compgen -G "$CONTAINER_ROOT/venv/lib/python*/site-packages" 2>/dev/null | head -1) || true
[[ -n "$_sd_vsp" ]] && export PYTHONPATH="$_sd_vsp${PYTHONPATH:+:$PYTHONPATH}"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
         "$CONTAINER_ROOT/bin" "$CONTAINER_ROOT/.local/bin" 2>/dev/null
ENVBLOCK

    local gpu_flag; gpu_flag=$(jq -r '.meta.gpu // empty' "$sj" 2>/dev/null)
    if [[ "$gpu_flag" == "cuda_auto" || "$gpu_flag" == "auto" ]]; then
        cat <<'GPUBLOCK'
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    export NVIDIA_GPU=1 CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
    printf '[gpu] CUDA mode\n'
else
    printf '[gpu] CPU mode\n'
fi
GPUBLOCK
    fi

    local keys; mapfile -t keys < <(jq -r '.environment // {} | keys[]' "$sj" 2>/dev/null)
    for k in "${keys[@]}"; do
        local v; v=$(jq -r --arg k "$k" '.environment[$k] | tostring' "$sj" 2>/dev/null)
        local pv; pv=$(_cr_prefix "$v")
        if [[ "$v" == "generate:hex32" ]]; then
            pv='$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d - || echo "changeme_set_secret")'
        fi
        if [[ "$k" == "LD_LIBRARY_PATH" || "$k" == "LIBRARY_PATH" || "$k" == "PKG_CONFIG_PATH" ]]; then
            printf 'export %s="%s:${%s:-}"\n' "$k" "$pv" "$k"
        else
            printf 'export %s="%s"\n' "$k" "$pv"
        fi
    done
}


_emit_ubuntu_bootstrap_inline() {
    local ub_q;      ub_q=$(printf '%q'      "$UBUNTU_DIR")
    local pkgs_q;    pkgs_q=$(printf '%q'    "$DEFAULT_UBUNTU_PKGS")
    local me_q;      me_q=$(printf '%q'      "$(id -un)")
    local sudoers_q; sudoers_q=$(printf '%q' "/etc/sudoers.d/simpledocker_ubsetup_$$")
    printf '# ── Ubuntu base (auto-install if missing) ──\n'
    printf 'if [[ ! -f %q/.ubuntu_ready ]]; then\n' "$UBUNTU_DIR"
    printf '    printf '"'"'\033[1m[ubuntu] Base not found — installing (this takes a few minutes)...\033[0m\n'"'"'\n'
    printf '    _sd_ub_arch=$(uname -m)\n'
    printf '    case "$_sd_ub_arch" in\n'
    printf '        x86_64)  _sd_ub_arch=amd64 ;;\n'
    printf '        aarch64) _sd_ub_arch=arm64  ;;\n'
    printf '        armv7l)  _sd_ub_arch=armhf  ;;\n'
    printf '        *)       _sd_ub_arch=amd64  ;;\n'
    printf '    esac\n'
    printf '    _sd_ub_index="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/"\n'
    printf '    _sd_ub_ver=$(curl -fsSL "$_sd_ub_index" 2>/dev/null | grep -oP "ubuntu-base-\\K[0-9]+\\.[0-9]+\\.[0-9]+-base-${_sd_ub_arch}" | head -1)\n'
    printf '    [[ -z "$_sd_ub_ver" ]] && _sd_ub_ver="24.04.3-base-${_sd_ub_arch}"\n'
    printf '    _sd_ub_url="${_sd_ub_index}ubuntu-base-${_sd_ub_ver}.tar.gz"\n'
    printf '    _sd_ub_tmp=$(mktemp %q/../.sd_ubuntu_dl_XXXXXX.tar.gz 2>/dev/null || mktemp /tmp/.sd_ubuntu_dl_XXXXXX.tar.gz)\n' "$UBUNTU_DIR"
    printf '    mkdir -p %q\n' "$UBUNTU_DIR"
    printf '    printf '"'"'[ubuntu] Downloading Ubuntu 24.04 LTS Noble (%%s)...\\n'"'"' "$_sd_ub_arch"\n'
    printf '    if curl -fsSL --progress-bar "$_sd_ub_url" -o "$_sd_ub_tmp"; then\n'
    printf '        printf '"'"'[ubuntu] Extracting...\\n'"'"'\n'
    printf '        tar -xzf "$_sd_ub_tmp" -C %q 2>&1 || true\n' "$UBUNTU_DIR"
    printf '        rm -f "$_sd_ub_tmp"\n'
    printf '        [[ ! -e %q/bin   ]] && ln -sf usr/bin   %q/bin   2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        [[ ! -e %q/lib   ]] && ln -sf usr/lib   %q/lib   2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        [[ ! -e %q/lib64 ]] && ln -sf usr/lib64 %q/lib64 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        printf '"'"'nameserver 8.8.8.8\\n'"'"' > %q/etc/resolv.conf 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        mkdir -p %q/etc/apt/apt.conf.d 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        printf '"'"'APT::Sandbox::User "root";\\n'"'"' > %q/etc/apt/apt.conf.d/99sandbox 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        printf '"'"'[ubuntu] Installing base packages...\\n'"'"'\n'
    printf '        printf '"'"'%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/chroot, /usr/sbin/chroot\\n'"'"' | sudo -n tee %q >/dev/null 2>&1 || true\n' "$me_q" "$sudoers_q"
    printf '        mkdir -p %q/tmp %q/proc %q/sys %q/dev 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR" "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        sudo -n mount --bind /proc %q/proc 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        sudo -n mount --bind /sys  %q/sys  2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        sudo -n mount --bind /dev  %q/dev  2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        _sd_ub_apt=$(mktemp %q/../.sd_ubinit_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_ubinit_%s.sh)\n' "$UBUNTU_DIR" "$$"
    printf '        printf '"'"'#!/bin/sh\nset -e\napt-get update -qq\nDEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s 2>&1\n'"'"' > "$_sd_ub_apt"\n' "$DEFAULT_UBUNTU_PKGS"
    printf '        chmod +x "$_sd_ub_apt"\n'
    printf '        sudo -n mount --bind "$_sd_ub_apt" %q/tmp/.sd_ubinit.sh 2>/dev/null || cp "$_sd_ub_apt" %q/tmp/.sd_ubinit.sh 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        _chroot_bash %q /tmp/.sd_ubinit.sh || true\n' "$UBUNTU_DIR"
    printf '        sudo -n umount -lf %q/tmp/.sd_ubinit.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        sudo -n umount -lf %q/dev %q/sys %q/proc 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        rm -f "$_sd_ub_apt" %q/tmp/.sd_ubinit.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        sudo -n rm -f %q 2>/dev/null || true\n' "$sudoers_q"
    printf '        touch %q/.ubuntu_ready\n' "$UBUNTU_DIR"
    printf '        date '"'"'+%%Y-%%m-%%d'"'"' > %q/.sd_ubuntu_stamp\n' "$UBUNTU_DIR"
    printf '        printf '"'"'\033[0;32m[ubuntu] Ubuntu base ready.\033[0m\\n\\n'"'"'\n'
    printf '    else\n'
    printf '        rm -f "$_sd_ub_tmp"\n'
    printf '        printf '"'"'\033[0;31m[ubuntu] ERROR: Download failed — cannot proceed.\033[0m\\n'"'"'\n'
    printf '        exit 1\n'
    printf '    fi\n'
    printf 'fi\n\n'
}

SD_APK_PKGS=""
_deps_pkg_apt_token() {
    local block="$1" name="$2"
    local tok _pkg _ver
    while IFS= read -r l; do
        l=$(printf '%s' "$l" | tr -d '\r' | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        while IFS=',' read -r tok; do
            tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            tok="${tok//$'\r'/}"
            [[ "$tok" == @* ]] && tok="${tok#@}"
            _pkg="${tok%%:*}"
            [[ "$_pkg" != "$name" ]] && continue
            if [[ "$tok" == *:* ]]; then
                _ver="${tok#*:}"
                [[ "$_ver" == "latest" ]] && { printf '%s' "$name"; return; }
                _ver="${_ver//.x/.*}"
                printf '%s=%s' "$name" "$_ver"; return
            else
                printf '%s' "$name"; return
            fi
        done <<< "$l"
    done <<< "$block"
    printf '%s' "$name"
}

_deps_parse_split() {
    local block="$1"
    SD_APK_PKGS=""
    while IFS= read -r l; do
        l=$(printf '%s' "$l" | tr -d '\r' | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$l" ]] && continue
        while IFS=',' read -r tok; do
            tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            tok="${tok//$'\r'/}"
            [[ -z "$tok" ]] && continue
            [[ "$tok" == @* ]] && tok="${tok#@}"
            if [[ "$tok" == *:* ]]; then
                local _pkg="${tok%%:*}" _ver="${tok#*:}"
                if [[ "$_ver" == "latest" ]]; then
                    tok="$_pkg"
                else
                    _ver="${_ver//.x/.*}"
                    tok="${_pkg}=${_ver}"
                fi
            fi
            [[ -n "$tok" ]] && SD_APK_PKGS+=" $tok"
        done
    done <<< "$block"
    SD_APK_PKGS="${SD_APK_PKGS# }"
}

_run_job() {
    local mode="$1" cid="$2"
    local install_path; install_path=$(_cpath "$cid")
    local ok_file="$CONTAINERS_DIR/$cid/.install_ok"
    local fail_file="$CONTAINERS_DIR/$cid/.install_fail"

    if [[ "$mode" == "install" ]] && _is_installing "$cid"; then
        confirm "$(printf '⚠  %s is already installing.\n\n  Running it again will restart from scratch.\n  Continue?' "$(_cname "$cid")")" || return 1
        tmux kill-session -t "$(_inst_sess "$cid")" 2>/dev/null || true
    fi

    _compile_service "$cid" 2>/dev/null || true

    if [[ "$mode" == "install" ]]; then
        [[ -z "$install_path" ]] && { pause "No install path set."; return 1; }
        local _check; _check=$(jq -r '.install // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local _ghck;  _ghck=$(jq -r '.git // empty'  "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local _dirck; _dirck=$(jq -r '.dirs // empty'   "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local _pipck; _pipck=$(jq -r '.pip // empty'    "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local _npmck; _npmck=$(jq -r '.npm // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        [[ -z "$_check" && -z "$_ghck" && -z "$_dirck" && -z "$_pipck" && -z "$_npmck" ]] && \
            { pause "⚠  No install, git, dirs, pip, or npm block in service.json."; return 1; }
        [[ -d "$install_path" ]] && { sudo -n btrfs subvolume delete "$install_path" &>/dev/null || btrfs subvolume delete "$install_path" &>/dev/null || sudo -n rm -rf "$install_path" 2>/dev/null || rm -rf "$install_path" 2>/dev/null || true; }
        local _base_src=""
        [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && _base_src="$UBUNTU_DIR"
        if [[ -n "$_base_src" ]]; then
            btrfs subvolume snapshot "$_base_src" "$install_path" &>/dev/null \
                || { btrfs subvolume create "$install_path" &>/dev/null || mkdir -p "$install_path" 2>/dev/null; }
            sudo -n chown "$(id -u):$(id -g)" "$install_path" 2>/dev/null || true
            [[ -f "$_base_src/.sd_ubuntu_stamp" ]] && cp "$_base_src/.sd_ubuntu_stamp" "$install_path/.sd_ubuntu_stamp" 2>/dev/null || true
        else
            btrfs subvolume create "$install_path" &>/dev/null || mkdir -p "$install_path" 2>/dev/null
        fi
        rm -f "$ok_file" "$fail_file" 2>/dev/null
    else
        [[ -z "$install_path" || ! -d "$install_path" ]] && { pause "Not installed."; return 1; }
    fi
    _guard_space || return 1

    local _logfile; _logfile=$(_log_path "$cid" "$mode")
    mkdir -p "$LOGS_DIR" 2>/dev/null

    local full_script; full_script=$(mktemp "$TMP_DIR/.sd_install_XXXXXX.sh")
    local ok_q;   ok_q=$(printf '%q' "$ok_file")
    local fail_q; fail_q=$(printf '%q' "$fail_file")
    local log_q;  log_q=$(printf '%q' "$_logfile")
    local env_block; env_block=$(_env_exports "$cid" "$install_path")

    {
        printf '#!/usr/bin/env bash\n'
        printf 'mkdir -p %q 2>/dev/null || true\n' "$_logdir"
        printf 'exec > >(tee -a %q) 2>&1\n' "$_logfile"
        printf '_sd_icap() { local _z; _z=$(stat -c%%s %q 2>/dev/null||echo 0); [[ $_z -gt 10485760 ]] && { tail -c 8388608 %q > %q.t 2>/dev/null && mv %q.t %q 2>/dev/null||true; }; }\ntrap _sd_icap EXIT\n' "$_logfile" "$_logfile" "$_logfile" "$_logfile" "$_logfile"
        printf '_finish() {\n'
        printf '    local code=$?\n'
        printf '    if [[ $code -eq 0 ]]; then\n'
        printf '        touch %s; printf '"'"'\n\033[0;32m══ %s complete ══\033[0m\n'"'"'\n' \
            "$ok_q" "${mode^}"
        printf '    else\n'
        printf '        touch %s; printf '"'"'\n\033[0;31m══ %s failed (exit %%d) ══\033[0m\n'"'"' "$code"\n' \
            "$fail_q" "${mode^}"
        printf '    fi\n'
        printf '}\n'
        printf 'trap _finish EXIT\n'
        printf 'trap '"'"'touch %s; exit 130'"'"' INT TERM\n\n' "$fail_q"

        printf '%s\n' "$env_block"
        printf 'cd "$CONTAINER_ROOT"\n\n'
        printf '_chroot_bash() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }\n'

        _emit_ubuntu_bootstrap_inline

        if [[ "$mode" == "install" ]]; then
            local _deps_raw; _deps_raw=$(jq -r '.deps // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local _pip;      _pip=$(jq -r '.pip // empty'    "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local _npm_raw;  _npm_raw=$(jq -r '.npm // empty'  "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local _dirs;     _dirs=$(jq -r '.dirs // empty'   "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)

            if [[ -n "$_deps_raw" ]]; then
                _deps_parse_split "$_deps_raw"
                if [[ -n "$SD_APK_PKGS" ]]; then
                    printf '# ── System deps (apt) ──\n'
                    printf 'printf '\''\033[1m[deps] Installing: %s\033[0m\n'\'' %q\n' "$SD_APK_PKGS"
                    local _me; _me=$(id -un)
                    local _sudoers_q; _sudoers_q=$(printf '%q' "/etc/sudoers.d/simpledocker_deps_$$")
                    local _ub_q2; _ub_q2=$(printf '%q' "$UBUNTU_DIR")
                    printf 'printf '\''%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/chroot, /usr/sbin/chroot, /usr/bin/unshare\n'\'' | sudo -n tee %q >/dev/null 2>&1 || true\n' "$_me" "$_sudoers_q"
                    printf 'mkdir -p %s/tmp %s/proc %s/sys %s/dev 2>/dev/null || true\n' "$_ub_q2" "$_ub_q2" "$_ub_q2" "$_ub_q2"
                    printf 'sudo -n mount --bind /proc %s/proc 2>/dev/null || true\n' "$_ub_q2"
                    printf 'sudo -n mount --bind /sys  %s/sys  2>/dev/null || true\n' "$_ub_q2"
                    printf 'sudo -n mount --bind /dev  %s/dev  2>/dev/null || true\n' "$_ub_q2"
                    printf '_sd_deps_cmd=$(mktemp %s/../.sd_deps_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_deps_%s.sh)\n' "$_ub_q2" "$$"
                    printf 'printf '"'"'#!/bin/sh\nset -e\nDEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s 2>&1 || { apt-get update -qq 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s 2>&1; }\n'"'"' > "$_sd_deps_cmd"\n' "$SD_APK_PKGS" "$SD_APK_PKGS"
                    printf 'chmod +x "$_sd_deps_cmd"\n'
                    printf 'sudo -n mount --bind "$_sd_deps_cmd" %s/tmp/.sd_deps_run.sh 2>/dev/null || cp "$_sd_deps_cmd" %s/tmp/.sd_deps_run.sh 2>/dev/null || true\n' "$_ub_q2" "$_ub_q2"
                    printf '_chroot_bash %s /tmp/.sd_deps_run.sh\n' "$_ub_q2"
                    printf 'sudo -n umount -lf %s/tmp/.sd_deps_run.sh 2>/dev/null || true\n' "$_ub_q2"
                    printf 'sudo -n umount -lf %s/dev %s/sys %s/proc 2>/dev/null || true\n' "$_ub_q2" "$_ub_q2" "$_ub_q2"
                    printf 'rm -f "$_sd_deps_cmd" %s/tmp/.sd_deps_run.sh 2>/dev/null || true\n' "$_ub_q2"
                    printf 'sudo -n rm -f %q 2>/dev/null || true\n\n' "$_sudoers_q"
                fi
            fi

            if [[ -n "$_dirs" ]]; then
                printf '# ── Create dirs ──\n'
                printf 'printf '"'"'\033[1m[dirs] Creating directory structure\033[0m\n'"'"'\n'
                local flat_dirs; flat_dirs=$(printf '%s' "$_dirs" | tr ',' '\n' | sed 's/([^)]*)//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
                while IFS= read -r d; do
                    printf 'mkdir -p %q 2>/dev/null || true\n' "$install_path/$d"
                done <<< "$flat_dirs"
                printf '\n'
            fi


            if [[ -n "$_pip" ]]; then
                local _pip_pkgs; _pip_pkgs=$(printf '%s' "$_pip" | tr ',' ' ' | sed 's/#.*//' | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                printf '# ── pip install ──\n'
                printf 'printf '"'"'\033[1m[pip] Installing: %s\033[0m\n'"'"' %q\n' "$_pip_pkgs"
                local _me2; _me2=$(id -un)
                local _sudoers2_q; _sudoers2_q=$(printf '%q' "/etc/sudoers.d/simpledocker_pip_$$")
                local _ub_q; _ub_q=$(printf '%q' "$UBUNTU_DIR")
                local _ip_q; _ip_q=$(printf '%q' "$install_path")
                local _venv_q; _venv_q=$(printf '%q' "$install_path/venv")
                printf 'printf '"'"'\033[2m[pip] Using Ubuntu base (glibc)\033[0m\n'"'"'\n'
                printf 'printf '"'"'%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/bash, /usr/bin/chroot, /usr/sbin/chroot, /usr/bin/unshare\n'"'"' | sudo -n tee %q >/dev/null 2>&1 || true\n' "$_me2" "$_sudoers2_q"
                printf 'mkdir -p %s/tmp %s/mnt %s/proc %s/sys %s/dev 2>/dev/null || true\n' "$_ub_q" "$_ub_q" "$_ub_q" "$_ub_q" "$_ub_q"
                printf 'sudo -n mount --bind /proc %s/proc 2>/dev/null || true\n' "$_ub_q"
                printf 'sudo -n mount --bind /sys  %s/sys  2>/dev/null || true\n' "$_ub_q"
                printf 'sudo -n mount --bind /dev  %s/dev  2>/dev/null || true\n' "$_ub_q"
                printf 'sudo -n mount --bind %s %s/mnt 2>/dev/null || true\n' "$_ip_q" "$_ub_q"
                printf '_sd_pip_cmd=%s\n' "$(printf '%q' "$(mktemp "$TMP_DIR/.sd_pip_XXXXXX.sh" 2>/dev/null || echo "/tmp/.sd_pip_$$.sh")")"
                printf 'cat > "$_sd_pip_cmd" << '"'"'_SD_PIP_EOF'"'"'\n'
                printf '#!/bin/sh\n'
                printf 'set -e\n'
                local _py_tok; _py_tok=$(_deps_pkg_apt_token "$_deps_raw" "python3")
                printf 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s python3-full python3-pip 2>&1 || {\n' "$_py_tok"
                printf '    apt-get update -qq 2>&1\n'
                printf '    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s python3-full python3-pip 2>&1\n' "$_py_tok"
                printf '}\n'
                printf 'python3 -m venv --clear /mnt/venv\n'
                printf '/mnt/venv/bin/pip install --upgrade pip\n'
                printf '/mnt/venv/bin/pip install --upgrade %s\n' "$_pip_pkgs"
                printf '_SD_PIP_EOF\n'
                printf 'chmod +x "$_sd_pip_cmd"\n'
                printf 'sudo -n mount --bind "$_sd_pip_cmd" %s/tmp/.sd_pip_run.sh 2>/dev/null || cp "$_sd_pip_cmd" %s/tmp/.sd_pip_run.sh 2>/dev/null || true\n' "$_ub_q" "$_ub_q"
                printf '_chroot_bash %s /tmp/.sd_pip_run.sh\n' "$_ub_q"
                printf '_sd_pip_rc=$?\n'
                printf 'sudo -n umount -lf %s/tmp/.sd_pip_run.sh 2>/dev/null || true\n' "$_ub_q"
                printf 'sudo -n umount -lf %s/mnt %s/dev %s/sys %s/proc 2>/dev/null || true\n' "$_ub_q" "$_ub_q" "$_ub_q" "$_ub_q"
                printf 'rm -f "$_sd_pip_cmd" %s/tmp/.sd_pip_run.sh 2>/dev/null || true\n' "$_ub_q"
                printf 'sudo -n rm -f %q 2>/dev/null || true\n' "$_sudoers2_q"
                printf 'sudo -n chown -R %q %s 2>/dev/null || true\n' "${_me2}:" "$_venv_q"
                printf 'if [[ $_sd_pip_rc -ne 0 ]]; then exit "$_sd_pip_rc"; fi\n\n'
            fi

            if [[ -n "$_npm_raw" ]]; then
                local _npm_pkgs; _npm_pkgs=$(printf '%s' "$_npm_raw" | tr ',' ' ' | sed 's/#.*//' | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                printf '# ── npm install ──\n'
                printf 'printf '"'"'\033[1m[npm] Installing: %s\033[0m\n'"'"' %q\n' "$_npm_pkgs"
                local _me3; _me3=$(id -un)
                local _sudoers3_q; _sudoers3_q=$(printf '%q' "/etc/sudoers.d/simpledocker_npm_$$")
                local _ub_qn; _ub_qn=$(printf '%q' "$UBUNTU_DIR")
                local _ip_qn; _ip_qn=$(printf '%q' "$install_path")
                printf 'printf '"'"'%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/bash, /usr/bin/chroot, /usr/sbin/chroot, /usr/bin/unshare\n'"'"' | sudo -n tee %q >/dev/null 2>&1 || true\n' "$_me3" "$_sudoers3_q"
                printf 'mkdir -p %s/tmp %s/mnt %s/proc %s/sys %s/dev 2>/dev/null || true\n' "$_ub_qn" "$_ub_qn" "$_ub_qn" "$_ub_qn" "$_ub_qn"
                printf 'sudo -n mount --bind /proc %s/proc 2>/dev/null || true\n' "$_ub_qn"
                printf 'sudo -n mount --bind /sys  %s/sys  2>/dev/null || true\n' "$_ub_qn"
                printf 'sudo -n mount --bind /dev  %s/dev  2>/dev/null || true\n' "$_ub_qn"
                printf 'sudo -n mount --bind %s %s/mnt 2>/dev/null || true\n' "$_ip_qn" "$_ub_qn"
                printf '_sd_npm_cmd=%s\n' "$(printf '%q' "$(mktemp "$TMP_DIR/.sd_npm_XXXXXX.sh" 2>/dev/null || echo "/tmp/.sd_npm_$$.sh")")"
                printf 'cat > "$_sd_npm_cmd" << '"'"'_SD_NPM_EOF'"'"'\n'
                printf '#!/bin/sh\n'
                printf 'set -e\n'
                printf '# ── Install Node.js >=22 via NodeSource if needed ──\n'
                printf 'node_ok=0\n'
                printf 'if command -v node >/dev/null 2>&1; then\n'
                printf '    _nv=$(node -e "process.exit(parseInt(process.version.slice(1)) >= 22 ? 0 : 1)" 2>/dev/null && echo 1 || echo 0)\n'
                printf '    [ "$_nv" = "1" ] && node_ok=1\n'
                printf 'fi\n'
                printf 'if [ "$node_ok" = "0" ]; then\n'
                printf '    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates 2>&1 || { apt-get update -qq 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates 2>&1; }\n'
                printf '    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1\n'
                printf '    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs 2>&1\n'
                printf 'fi\n'
                printf 'cd /mnt && npm install %s 2>&1\n' "$_npm_pkgs"
                printf '_SD_NPM_EOF\n'
                printf 'chmod +x "$_sd_npm_cmd"\n'
                printf 'sudo -n mount --bind "$_sd_npm_cmd" %s/tmp/.sd_npm_run.sh 2>/dev/null || cp "$_sd_npm_cmd" %s/tmp/.sd_npm_run.sh 2>/dev/null || true\n' "$_ub_qn" "$_ub_qn"
                printf '_chroot_bash %s /tmp/.sd_npm_run.sh\n' "$_ub_qn"
                printf '_sd_npm_rc=$?\n'
                printf 'sudo -n umount -lf %s/tmp/.sd_npm_run.sh 2>/dev/null || true\n' "$_ub_qn"
                printf 'sudo -n umount -lf %s/mnt %s/dev %s/sys %s/proc 2>/dev/null || true\n' "$_ub_qn" "$_ub_qn" "$_ub_qn" "$_ub_qn"
                printf 'rm -f "$_sd_npm_cmd" %s/tmp/.sd_npm_run.sh 2>/dev/null || true\n' "$_ub_qn"
                printf 'sudo -n rm -f %q 2>/dev/null || true\n' "$_sudoers3_q"
                printf 'sudo -n chown -R %q %s/node_modules 2>/dev/null || true\n' "${_me3}:" "$_ip_qn"
                printf 'if [[ $_sd_npm_rc -ne 0 ]]; then exit "$_sd_npm_rc"; fi\n\n'
            fi
        fi # end install mode

        _emit_runner_steps "$mode" "$cid" "$install_path"

    } > "$full_script"
    chmod +x "$full_script"

    _tmux_set SD_INSTALLING "$cid"
    local _inst_s; _inst_s=$(_inst_sess "$cid")
    tmux kill-session -t "$_inst_s" 2>/dev/null || true

    local _tl_rc
    _tmux_launch "$_inst_s" "$(printf "%s: %s" "${mode^}" "$(_cname "$cid")")" "$full_script"
    _tl_rc=$?
    if [[ $_tl_rc -eq 1 ]]; then rm -f "$full_script"; _tmux_set SD_INSTALLING ""; return 1; fi
    local _ok_f="$CONTAINERS_DIR/$cid/.install_ok"
    local _fail_f="$CONTAINERS_DIR/$cid/.install_fail"
    local _hook_script; _hook_script=$(mktemp "$TMP_DIR/.sd_inst_hook_XXXXXX.sh")
    printf '#!/usr/bin/env bash\n[[ -f %q || -f %q ]] || touch %q\n' \
        "$_ok_f" "$_fail_f" "$_fail_f" > "$_hook_script"
    chmod +x "$_hook_script"
    tmux set-hook -t "$_inst_s" pane-exited "run-shell $(printf '%q' "$_hook_script")" 2>/dev/null || true
}

_guard_install() {
    local _running=()
    for _d in "$CONTAINERS_DIR"/*/; do
        local _c; _c=$(basename "$_d")
        _is_installing "$_c" && _running+=("$(_cname "$_c")")
    done
    [[ ${#_running[@]} -eq 0 ]] && return 0
    confirm "$(printf "${BLD}⚠  Installation already running: %s${NC}\n\n  Running another simultaneously may slow both down.\n  Continue anyway?" "${_running[*]}")" || return 1
    return 0
}

_build_start_script() {
    local cid="$1" install_path; install_path=$(_cpath "$cid")
    [[ -d "$install_path" ]] && sudo -n chown "$(id -u):$(id -g)" "$install_path" 2>/dev/null || true
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local start_cmd; start_cmd=$(jq -r '.start // empty' "$sj" 2>/dev/null)
    [[ -z "$start_cmd" ]] && start_cmd=$(jq -r '.start.cmd // empty' "$sj" 2>/dev/null)
    if [[ -z "$start_cmd" ]]; then
        local ep; ep=$(jq -r '.meta.entrypoint // empty' "$sj" 2>/dev/null)
        if [[ -n "$ep" ]]; then
            local ep_bin="${ep%% *}" ep_args="${ep#* }"
            [[ "$ep_args" == "$ep_bin" ]] && ep_args=""
            local ep_bin_prefixed; ep_bin_prefixed=$(_cr_prefix "$ep_bin")
            start_cmd="exec ${ep_bin_prefixed}${ep_args:+ $ep_args}"
        fi
    fi
    local _base; _base=$(jq -r '.meta.base // "ubuntu"' "$sj" 2>/dev/null)
    local env_block; env_block=$(_env_exports "$cid" "$install_path")
    {
        printf '#!/usr/bin/env bash\n# Auto-generated by simpleDocker\n\n'
        local _slog; _slog=$(_log_path "$cid" "start")
        printf 'mkdir -p %q 2>/dev/null || true\n' "$LOGS_DIR"
        printf 'exec > >(tee -a %q) 2>&1\n' "$_slog"
        printf '_sd_scap() { local _z; _z=$(stat -c%%s %q 2>/dev/null||echo 0); [[ $_z -gt 10485760 ]] && { tail -c 8388608 %q > %q.t 2>/dev/null && mv %q.t %q 2>/dev/null||true; }; }\ntrap _sd_scap EXIT\n\n' "$_slog" "$_slog" "$_slog" "$_slog" "$_slog"
            local env_str="export CONTAINER_ROOT=/mnt HOME=/mnt"
            local keys; mapfile -t keys < <(jq -r '.environment // {} | keys[]' "$sj" 2>/dev/null)
            for k in "${keys[@]}"; do
                local v; v=$(jq -r --arg k "$k" '.environment[$k] | tostring' "$sj" 2>/dev/null)
                if [[ "$v" == "generate:hex32" ]]; then
                    local _scid; _scid=$(_state_get "$cid" storage_id)
                    local _secret_file=""
                    if [[ -n "$_scid" ]]; then
                        _secret_file="$(_stor_path "$_scid")/.sd_secret_${k}"
                    else
                        _secret_file="$CONTAINERS_DIR/$cid/.sd_secret_${k}"
                    fi
                    if [[ -f "$_secret_file" ]]; then
                        v=$(cat "$_secret_file" 2>/dev/null)
                    else
                        v=$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d - || echo "changeme")
                        printf '%s' "$v" > "$_secret_file" 2>/dev/null || true
                    fi
                fi
                if [[ "$v" != /* && "$v" != '$'* && "$v" != *'://'* && -n "$v" && "$v" =~ / ]]; then v="/mnt/$v"; fi
                env_str+=" $k=\"$v\""
            done
            local chroot_cmd; chroot_cmd=$(printf '%s' "${start_cmd:-printf 'No start defined\\nsleep 10'}" | sed 's|\$CONTAINER_ROOT|/mnt|g')
            local _gpu_mode; _gpu_mode=$(jq -r '.meta.gpu // empty' "$sj" 2>/dev/null)

            if [[ "$_gpu_mode" == "cuda_auto" ]]; then
                local _nv_chroot_lib; _nv_chroot_lib="$UBUNTU_DIR/usr/local/lib/sd_nvidia"
                printf '# NVIDIA: copy host driver .so files into chroot (exact version match)\n'
                printf '_SD_NV_MAJ=""\n'
                printf 'if [[ -f /sys/module/nvidia/version ]]; then\n'
                printf '  _SD_NV_MAJ=$(cut -d. -f1 /sys/module/nvidia/version 2>/dev/null)\n'
                printf 'fi\n'
                printf 'if [[ -z "$_SD_NV_MAJ" ]] && [[ -f /proc/driver/nvidia/version ]]; then\n'
                printf '  _SD_NV_MAJ=$(grep -oP '"'"'Kernel Module[[:space:]]+\K[0-9]+'"'"' /proc/driver/nvidia/version 2>/dev/null | head -1)\n'
                printf 'fi\n'
                printf '_SD_EXTRA=""\n'
                printf 'if [[ -z "$_SD_NV_MAJ" ]]; then\n'
                printf '  printf "[sd] No NVIDIA kernel module -- CPU mode\n"\n'
                printf '  _SD_EXTRA="--cpu"\n'
                printf 'else\n'
                printf '  printf "[sd] NVIDIA driver major version: %%s\n" "$_SD_NV_MAJ"\n'
                printf '  # ── Version mismatch check: clear stale libs if driver changed ──\n'
                printf '  _SD_NV_CACHED_VER=""\n'
                printf '  [[ -f %q/.sd_nv_ver ]] && _SD_NV_CACHED_VER=$(cat %q/.sd_nv_ver 2>/dev/null)\n' "$_nv_chroot_lib" "$_nv_chroot_lib"
                printf '  if [[ -n "$_SD_NV_CACHED_VER" && "$_SD_NV_CACHED_VER" != "$_SD_NV_MAJ" ]]; then\n'
                printf '    printf "[sd] WARNING: NVIDIA driver changed (%%s → %%s) -- clearing cached libs\n" "$_SD_NV_CACHED_VER" "$_SD_NV_MAJ"\n'
                printf '    rm -rf %q 2>/dev/null || true\n' "$_nv_chroot_lib"
                printf '  fi\n'
                printf '  _SD_NV_DIR=%q\n' "$_nv_chroot_lib"
                printf '  mkdir -p "$_SD_NV_DIR"\n'
                printf '  _SD_NV_COUNT=0\n'
                printf '  for _sd_f in /usr/lib/libcuda.so* /usr/lib/libnvidia*.so* /usr/lib64/libcuda.so* /usr/lib64/libnvidia*.so* /usr/lib/x86_64-linux-gnu/libcuda.so* /usr/lib/x86_64-linux-gnu/libnvidia*.so* /usr/lib/aarch64-linux-gnu/libcuda.so* /usr/lib/aarch64-linux-gnu/libnvidia*.so*; do\n'
                printf '    [[ -e "$_sd_f" ]] && cp -Pf "$_sd_f" "$_SD_NV_DIR/" 2>/dev/null && (( _SD_NV_COUNT++ )) || true\n'
                printf '  done\n'
                printf '  if [[ "$_SD_NV_COUNT" -eq 0 ]]; then\n'
                printf '    printf "[sd] WARNING: no NVIDIA .so files found on host -- CPU mode\n"\n'
                printf '    _SD_EXTRA="--cpu"\n'
                printf '  else\n'
                printf '    printf "%s" "$_SD_NV_MAJ" > %q/.sd_nv_ver\n' ''"'"''"'"'' "$_nv_chroot_lib"
                printf '    printf "[sd] Copied %%d NVIDIA lib files into chroot (driver %%s) -- GPU enabled\n" "$_SD_NV_COUNT" "$_SD_NV_MAJ"\n'
                printf '  fi\n'
                printf 'fi\n'
            fi

            local _nv_ld=""
            [[ "$_gpu_mode" == "cuda_auto" ]] && _nv_ld=" LD_LIBRARY_PATH=\"/usr/local/lib/sd_nvidia:\${LD_LIBRARY_PATH:-}\""
            local _chroot_inner_cmd
            _chroot_inner_cmd=$(printf '%q' "cd /mnt && $env_str$_nv_ld && $chroot_cmd")
            local _ct_hostname; _ct_hostname=$(printf '%s' "$(_cname "$cid")" \
                | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | cut -c1-63)

            local _nswrap_body=""
            _nswrap_body+='_chroot_bash() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }'$'\n'
            _nswrap_body+="# Runs inside: sudo nsenter -- unshare --mount --pid --uts --ipc [--user] --fork"$'\n'
            _nswrap_body+="_NS_EXTRA=\"\${1:-}\""$'\n\n'
            _nswrap_body+="# UTS: set container hostname"$'\n'
            _nswrap_body+="$(printf 'printf "%%s" %q > /proc/sys/kernel/hostname 2>/dev/null || true' "$_ct_hostname")"$'\n\n'
            _nswrap_body+="# Mount: proc must be fresh mount -t proc (not bind) when inside PID namespace"$'\n'
            _nswrap_body+="$(printf 'mount -t proc proc %q' "$UBUNTU_DIR/proc")"$'\n'
            _nswrap_body+="$(printf 'mount --bind /sys  %q' "$UBUNTU_DIR/sys")"$'\n'
            _nswrap_body+="$(printf 'mount --bind /dev  %q' "$UBUNTU_DIR/dev")"$'\n'
            _nswrap_body+="$(printf 'mount --bind %q %q' "$install_path" "$UBUNTU_DIR/mnt")"$'\n'
            if [[ -n "$MNT_DIR" ]]; then
                _nswrap_body+="$(printf 'mkdir -p %q 2>/dev/null || true' "$UBUNTU_DIR$MNT_DIR")"$'\n'
                _nswrap_body+="$(printf 'mount --bind %q %q' "$MNT_DIR" "$UBUNTU_DIR$MNT_DIR") \\"$'\n'
                _nswrap_body+='  || printf "[sd] WARNING: MNT_DIR bind mount failed -- storage symlinks may not resolve\n"'$'\n'
            fi
            local _nhf; _nhf=$(_netns_hosts "$MNT_DIR")
            _nswrap_body+="$(printf 'if [[ -f %q ]]; then mount --bind %q %q 2>/dev/null || true; fi' "$_nhf" "$_nhf" "$UBUNTU_DIR/etc/hosts")"$'\n\n'
            local _exec_inner; _exec_inner=$(printf '_chroot_bash %q -c %s' "$UBUNTU_DIR" "$_chroot_inner_cmd")
            _nswrap_body+="${_exec_inner}"$'\n'

            local _unshare_flags="--mount --pid --uts --ipc"

            local _nsname; _nsname=$(_netns_name "$MNT_DIR")
            if [[ "$_gpu_mode" == "cuda_auto" ]]; then
                printf '  sudo -n nsenter --net=/run/netns/%q -- unshare %s --fork bash -s "$_SD_EXTRA" << '"'"'_SDNS_WRAP'"'"'\n%s\n_SDNS_WRAP\n' \
                    "$_nsname" "$_unshare_flags" "$_nswrap_body"
            else
                printf '  sudo -n nsenter --net=/run/netns/%q -- unshare %s --fork bash -s << '"'"'_SDNS_WRAP'"'"'\n%s\n_SDNS_WRAP\n' \
                    "$_nsname" "$_unshare_flags" "$_nswrap_body"
            fi
    } > "$install_path/start.sh"
    chmod +x "$install_path/start.sh"
}

_cron_sess()     { printf 'sdCron_%s_%s' "$1" "$2"; }
_cron_next_file(){ printf '%s/cron_%s_next' "$CONTAINERS_DIR/$1" "$2"; }

_cron_interval_secs() {
    local iv="$1"
    local num unit
    num=$(printf '%s' "$iv" | grep -oE '^[0-9]+')
    unit=$(printf '%s' "$iv" | grep -oE '[a-z]+$')
    [[ -z "$num" ]] && { printf '3600'; return; }
    case "$unit" in
        s)  printf '%d' "$num" ;;
        m)  printf '%d' $(( num * 60 )) ;;
        h)  printf '%d' $(( num * 3600 )) ;;
        d)  printf '%d' $(( num * 86400 )) ;;
        w)  printf '%d' $(( num * 604800 )) ;;
        mo) printf '%d' $(( num * 2592000 )) ;;
        *)  printf '%d' $(( num * 3600 )) ;;
    esac
}

_cron_countdown() {
    local secs="$1"
    (( secs < 0 )) && secs=0
    local d=$(( secs / 86400 ))
    local h=$(( (secs % 86400) / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    local s=$(( secs % 60 ))
    if   (( d > 0 )); then printf '%dd %02dh %02dm %02ds' "$d" "$h" "$m" "$s"
    elif (( h > 0 )); then printf '%dh %02dm %02ds' "$h" "$m" "$s"
    elif (( m > 0 )); then printf '%dm %02ds' "$m" "$s"
    else printf '%ds' "$s"
    fi
}

_cron_start_one() {
    local cid="$1" idx="$2" name="$3" interval="$4" cmd="$5" cflags="${6:-}"
    local sname; sname=$(_cron_sess "$cid" "$idx")
    local ip; ip=$(_cpath "$cid")
    local secs; secs=$(_cron_interval_secs "$interval")
    local next_file; next_file=$(_cron_next_file "$cid" "$idx")
    local runner; runner=$(mktemp "$TMP_DIR/.sd_cron_XXXXXX.sh")

    local _use_sudo=false _unjailed=false
    printf '%s' "$cflags" | grep -q -- '--sudo'    && _use_sudo=true
    printf '%s' "$cflags" | grep -q -- '--unjailed' && _unjailed=true
    if [[ "$_use_sudo" == "true" ]]; then
        local _cmd_trimmed; _cmd_trimmed=$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//')
        if [[ "$_cmd_trimmed" != sudo* ]]; then
            local _cmd_resolved; _cmd_resolved="${cmd//\$CONTAINER_ROOT/$ip}"
            cmd="sudo -n bash -c $(printf '%q' "$_cmd_resolved")"
        fi
    fi

    {
        printf '#!/usr/bin/env bash\n'
        printf '_cron_secs=%d\n' "$secs"
        printf '_cron_next_file=%q\n' "$next_file"
        printf '_cron_cmd=%q\n' "$cmd"
        printf 'while true; do\n'
        printf '    _next=$(( $(date +%%s) + _cron_secs ))\n'
        printf '    printf "%%d" "$_next" > "$_cron_next_file"\n'
        printf '    sleep "$_cron_secs" &\n'
        printf '    wait $!\n'
        printf '    [[ -f "$_cron_next_file" ]] || exit 0\n'
        printf '    printf "\\n\\033[1m── Cron: %s ──\\033[0m\\n" %q\n' "$name" "$name"
        if [[ "$_unjailed" == "false" ]]; then
            local _nsname; _nsname=$(_netns_name "$MNT_DIR")
            local _ub; _ub="$UBUNTU_DIR"
            local _cmd_inner; _cmd_inner=$(printf '%s' "$cmd" | sed 's|\$CONTAINER_ROOT|/mnt|g' | sed 's#>>[[:space:]]*\([^[:space:]]*\)#| tee -a \1#g')
            printf '    sudo -n nsenter --net=/run/netns/%q -- unshare --mount --pid --uts --ipc --fork bash -s << '"'"'_SDCRON_NS'"'"'\n' "$_nsname"
            printf '_cb() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }\n'
            printf 'mount -t proc proc %q 2>/dev/null || true\n' "$_ub/proc"
            printf 'mount --bind /sys %q 2>/dev/null || true\n' "$_ub/sys"
            printf 'mount --bind /dev %q 2>/dev/null || true\n' "$_ub/dev"
            printf 'mount --bind %q %q 2>/dev/null || true\n' "$ip" "$_ub/mnt"
            printf '_cb %q -c %q\n' "$_ub" "cd /mnt && $_cmd_inner"
            printf '_SDCRON_NS\n'
        else
            local _cmd_unjailed; _cmd_unjailed=$(printf '%s' "$cmd" | sed 's#>>[[:space:]]*\([^[:space:]]*\)#| tee -a \1#g')
            printf '    export CONTAINER_ROOT=%q\n' "$ip"
            printf '    (eval %q)\n' "$_cmd_unjailed"
        fi
        printf '    _cron_next_ts=$(( $(date +%%s) + _cron_secs ))\n'
        printf '    _cron_next_time=$(date -d "@$_cron_next_ts" +%%H:%%M:%%S 2>/dev/null || date -v+"${_cron_secs}S" +%%H:%%M:%%S 2>/dev/null)\n'
        printf '    _cron_next_date=$(date -d "@$_cron_next_ts" +%%Y-%%m-%%d 2>/dev/null || date -v+"${_cron_secs}S" +%%Y-%%m-%%d 2>/dev/null)\n'
        printf '    printf "\\n\\033[2mDone. Next execution: %%s [%%s]\\033[0m\\n" "$_cron_next_time" "$_cron_next_date"\n'
        printf 'done\n'
    } > "$runner"; chmod +x "$runner"
    tmux new-session -d -s "$sname" "bash $(printf '%q' "$runner"); rm -f $(printf '%q' "$runner")" 2>/dev/null
    tmux set-option -t "$sname" detach-on-destroy off 2>/dev/null || true
}

_cron_start_all() {
    local cid="$1"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local count; count=$(jq -r '.crons | length' "$sj" 2>/dev/null)
    [[ -z "$count" || "$count" -eq 0 ]] && return
    for (( i=0; i<count; i++ )); do
        local name iv cmd cflags
        name=$(jq -r --argjson i "$i" '.crons[$i].name' "$sj" 2>/dev/null)
        iv=$(jq -r --argjson i "$i" '.crons[$i].interval' "$sj" 2>/dev/null)
        cmd=$(jq -r --argjson i "$i" '.crons[$i].cmd' "$sj" 2>/dev/null)
        cflags=$(jq -r --argjson i "$i" '.crons[$i].flags // ""' "$sj" 2>/dev/null)
        [[ -z "$cmd" ]] && continue
        _cron_start_one "$cid" "$i" "$name" "$iv" "$cmd" "$cflags"
    done
}

_cron_stop_all() {
    local cid="$1"
    rm -f "$CONTAINERS_DIR/$cid"/cron_*_next 2>/dev/null
    while IFS= read -r sess; do
        tmux kill-session -t "$sess" 2>/dev/null || true
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdCron_${cid}_")
}

_update_size_cache() {
    local cid="$1"
    local _ipath; _ipath=$(_cpath "$cid")
    [[ -d "$_ipath" ]] || return
    local _sz; _sz=$(du -sb "$_ipath" 2>/dev/null | awk '{printf "%.2f",$1/1073741824}')
    [[ -n "$_sz" ]] && printf '%s' "$_sz" > "$CACHE_DIR/sd_size/$cid"
}

_start_container() {
    local cid="$1" _auto=false
    [[ "${2:-}" == "--auto" ]] && _auto=true
    local install_path; install_path=$(_cpath "$cid")
    local sess; sess="$(tsess "$cid")"
    _guard_space || return 1
    _compile_service "$cid" 2>/dev/null || true

    if [[ "$(_stor_count "$cid")" -gt 0 ]]; then
        local prev_scid; prev_scid=$(_state_get "$cid" storage_id)
        if [[ -n "$prev_scid" && "$(_stor_read_active "$prev_scid")" == "$cid" ]]; then
            _stor_clear_active "$prev_scid"
        fi
        _stor_unlink "$cid" "$install_path"
        local scid
        if [[ "$_auto" == "true" ]]; then
            scid=$(_auto_pick_storage_profile "$cid")
        else
            scid=$(_pick_storage_profile "$cid")
        fi
        [[ -z "$scid" ]] && return 1
        _stor_link "$cid" "$install_path" "$scid"
    fi

    _rotate_and_snapshot "$cid"
    _build_start_script "$cid"
    _netns_ct_add "$cid" "$(_cname "$cid")" "$MNT_DIR"
    if [[ ! -f "$(_exposure_file "$cid")" ]]; then
        local _host_env; _host_env=$(jq -r '.environment.HOST // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        if [[ "$_host_env" == "0.0.0.0" ]]; then
            _exposure_set "$cid" "public"
        elif [[ "$_host_env" == "127.0.0.1" || "$_host_env" == "localhost" ]]; then
            _exposure_set "$cid" "localhost"
        fi
    fi
    _exposure_apply "$cid"
    local _sd_me; _sd_me=$(id -un)
    local _sd_sudoers="/etc/sudoers.d/simpledocker_${_sd_me}"
    : # sudoers written at startup by _sd_outer_sudo

    local _sd_base_cmd; _sd_base_cmd="cd $(printf '%q' "$install_path") && bash $(printf '%q' "$install_path/start.sh")"
    local _sd_run_prefix=""
    local _res_cfg; _res_cfg="$CONTAINERS_DIR/$cid/resources.json"
    if [[ -f "$_res_cfg" ]] && [[ "$(jq -r '.enabled // false' "$_res_cfg" 2>/dev/null)" == "true" ]]; then
        _sd_run_prefix="systemd-run --user --scope --unit=sd-$cid"
        local _rq; _rq=$(jq -r '.cpu_quota  // empty' "$_res_cfg" 2>/dev/null); [[ -n "$_rq" ]] && _sd_run_prefix+=" -p CPUQuota=$_rq"
        local _rm; _rm=$(jq -r '.mem_max    // empty' "$_res_cfg" 2>/dev/null); [[ -n "$_rm" ]] && _sd_run_prefix+=" -p MemoryMax=$_rm"
        local _rs; _rs=$(jq -r '.mem_swap   // empty' "$_res_cfg" 2>/dev/null); [[ -n "$_rs" ]] && _sd_run_prefix+=" -p MemorySwapMax=$_rs"
        local _rw; _rw=$(jq -r '.cpu_weight // empty' "$_res_cfg" 2>/dev/null); [[ -n "$_rw" ]] && _sd_run_prefix+=" -p CPUWeight=$_rw"
        _sd_run_prefix+=" -- bash -c"
        tmux new-session -d -s "$sess" "$_sd_run_prefix $(printf '%q' "$_sd_base_cmd")" 2>/dev/null
    else
        tmux new-session -d -s "$sess" "$_sd_base_cmd" 2>/dev/null
    fi
    tmux set-option -t "$sess" detach-on-destroy off 2>/dev/null || true
    tmux set-hook -t "$sess" pane-exited "kill-session -t $sess" 2>/dev/null || true
    { while tmux_up "$sess" 2>/dev/null; do sleep 0.5; done
      kill -USR1 "$SD_SHELL_PID" 2>/dev/null || true
    } &
    disown $! 2>/dev/null || true
    _cron_start_all "$cid"
    { sleep 2; _cap_drop_apply "$cid"; _seccomp_apply "$cid"; } &>/dev/null &
    disown $! 2>/dev/null || true
    if [[ "$_auto" == "true" ]]; then
        sleep 0.5
        return 0
    fi
    sleep 0.5
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n%s\n' "$(printf "${GRN}▶  Start and show live output${NC}")" "$(printf "${DIM}   Start in the background${NC}")" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Start ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local _start_choice; _start_choice=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 ]] && return
    if printf '%s' "$_start_choice" | _strip_ansi | grep -q "show live output"; then
        tmux switch-client -t "$sess" 2>/dev/null || true
        sleep 0.1; stty sane 2>/dev/null
        while IFS= read -r -t 0 -n 256 _ 2>/dev/null; do :; done
    fi
}

_SD_CAP_DROP_DEFAULT="cap_sys_ptrace,cap_sys_rawio,cap_sys_boot,cap_sys_module,cap_mknod,cap_audit_write,cap_audit_control,cap_syslog"

_cap_drop_enabled() {
    local v; v=$(jq -r '.meta.cap_drop // "true"' "$CONTAINERS_DIR/$1/service.json" 2>/dev/null)
    [[ "$v" != "false" ]]
}

_cap_drop_apply() {
    local cid="$1"
    _cap_drop_enabled "$cid" || return 0
    command -v capsh &>/dev/null || return 0
    local sess; sess="$(tsess "$cid")"
    local pane_pid; pane_pid=$(tmux list-panes -t "$sess" -F "#{pane_pid}" 2>/dev/null | head -1)
    [[ -z "$pane_pid" ]] && return 0
    pgrep -P "$pane_pid" 2>/dev/null | while IFS= read -r cpid; do
        sudo -n capsh --drop="$_SD_CAP_DROP_DEFAULT" --pid="$cpid" 2>/dev/null || true
    done
}

_SD_SECCOMP_BLOCKLIST=(
    kexec_load kexec_file_load reboot init_module finit_module delete_module
    ioperm iopl
    mount umount2 pivot_root
    unshare setns clone
    perf_event_open ptrace process_vm_readv process_vm_writev
    add_key request_key keyctl
    acct swapon swapoff syslog quotactl nfsservctl
)

_seccomp_enabled() {
    local v; v=$(jq -r '.meta.seccomp // "true"' "$CONTAINERS_DIR/$1/service.json" 2>/dev/null)
    [[ "$v" != "false" ]]
}

_seccomp_apply() {
    local cid="$1"
    _seccomp_enabled "$cid" || return 0

    if [[ -f "$CONTAINERS_DIR/$cid/resources.json" ]] && \
       [[ "$(jq -r '.enabled // false' "$CONTAINERS_DIR/$cid/resources.json" 2>/dev/null)" == "true" ]]; then
        local unit="sd-${cid}.scope"
        if systemctl --user is-active "$unit" &>/dev/null; then
            local block_str; block_str=$(printf '~%s ' "${_SD_SECCOMP_BLOCKLIST[@]}")
            systemctl --user set-property "$unit" "SystemCallFilter=${block_str}" 2>/dev/null || true
            return 0
        fi
    fi

    local profile_file="$CONTAINERS_DIR/$cid/.seccomp_profile.json"
    if [[ ! -f "$profile_file" ]]; then
        local syscall_list; syscall_list=$(printf '{"names":[%s],"action":"SCMP_ACT_ERRNO"}' \
            "$(printf '"%s",' "${_SD_SECCOMP_BLOCKLIST[@]}" | sed 's/,$//')")
        printf '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[%s]}\n' "$syscall_list" \
            > "$profile_file" 2>/dev/null || true
    fi
}

_stop_container() {
    local cid="$1"
    local sess; sess="$(tsess "$cid")"
    local install_path; install_path=$(_cpath "$cid")
    tmux send-keys -t "$sess" C-c "" 2>/dev/null || true
    local _w=0
    while tmux_up "$sess" 2>/dev/null && [[ $_w -lt 40 ]]; do
        sleep 0.2; (( _w++ )) || true
    done
    tmux kill-session -t "$sess" 2>/dev/null || true
    tmux kill-session -t "sdTerm_${cid}" 2>/dev/null || true
    _netns_ct_del "$cid" "$(_cname "$cid")" "$MNT_DIR"
    while IFS= read -r _as; do
        tmux kill-session -t "$_as" 2>/dev/null || true
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdAction_${cid}_")
    _cron_stop_all "$cid"
    sleep 0.2
    if [[ "$(_stor_count "$cid")" -gt 0 ]]; then
        _stor_unlink "$cid" "$install_path"
        local scid; scid=$(_state_get "$cid" storage_id)
        [[ -n "$scid" ]] && _stor_clear_active "$scid"
    fi
    clear; pause "'$(_cname "$cid")' stopped."
    _update_size_cache "$cid"
}


_ct_main_pid() {
    local sess; sess="$(tsess "$1")"
    tmux list-panes -t "$sess" -F "#{pane_pid}" 2>/dev/null | head -1
}


_grp_path()        { printf '%s/%s.toml' "$GROUPS_DIR" "$1"; }
_grp_read_field()  { grep -m1 "^$2[[:space:]]*=" "$(_grp_path "$1")" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//' ; }
_list_groups()     { for f in "$GROUPS_DIR"/*.toml; do [[ -f "$f" ]] && basename "${f%.toml}"; done; }

_grp_containers() {
    local gid="$1"
    local raw; raw=$(grep -m1 '^start[[:space:]]*=' "$(_grp_path "$gid")" 2>/dev/null \
        | sed 's/^start[[:space:]]*=[[:space:]]*//' | tr -d '{}')
    printf '%s' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' \
        | grep -iv '^wait' | sort -u
}

_grp_seq_steps() {
    local gid="$1"
    local raw; raw=$(grep -m1 '^start[[:space:]]*=' "$(_grp_path "$gid")" 2>/dev/null \
        | sed 's/^start[[:space:]]*=[[:space:]]*//' | tr -d '{}')
    printf '%s' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
}

_grp_seq_save() {
    local gid="$1"; shift
    local steps=("$@")
    local joined; joined=$(printf '%s, ' "${steps[@]}")
    joined="${joined%, }"
    local toml; toml="$(_grp_path "$gid")"
    if grep -q '^start[[:space:]]*=' "$toml" 2>/dev/null; then
        sed -i "s|^start[[:space:]]*=.*|start = { ${joined} }|" "$toml"
    else
        printf 'start = { %s }\n' "$joined" >> "$toml"
    fi
    local cts; cts=$(printf '%s\n' "${steps[@]}" | grep -iv '^wait' | sort -u | tr '\n' ', ' | sed 's/, $//')
    if grep -q '^containers[[:space:]]*=' "$toml" 2>/dev/null; then
        sed -i "s|^containers[[:space:]]*=.*|containers = ${cts}|" "$toml"
    else
        printf 'containers = %s\n' "$cts" >> "$toml"
    fi
}

_ct_id_by_name() {
    local cname="$1"
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        [[ "$(_cname "$cid")" == "$cname" ]] && printf '%s' "$cid" && return
    done
}

_start_group() {
    local gid="$1"
    local gname; gname=$(_grp_read_field "$gid" name)
    local batch=()
    _flush_batch() {
        [[ ${#batch[@]} -eq 0 ]] && return
        for bname in "${batch[@]}"; do
            local bcid; bcid=$(_ct_id_by_name "$bname")
            if [[ -n "$bcid" ]]; then
                tmux_up "$(tsess "$bcid")" \
                    && printf '[%s] already running\n' "$bname" \
                    || { _start_container "$bcid" --auto || true; }
            else
                printf '[!] Container not found: %s\n' "$bname" >&2
            fi
        done
        batch=()
    }
    while IFS= read -r step; do
        step=$(printf '%s' "$step" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$step" ]] && continue
        if [[ "${step,,}" =~ ^wait[[:space:]]+([0-9]+)$ ]]; then
            _flush_batch
            sleep "${BASH_REMATCH[1]}"
        elif [[ "${step,,}" =~ ^wait[[:space:]]+for[[:space:]]+(.+)$ ]]; then
            _flush_batch
            local wait_name="${BASH_REMATCH[1]}"
            local wait_cid; wait_cid=$(_ct_id_by_name "$wait_name")
            if [[ -n "$wait_cid" ]]; then
                local waited=0
                while ! tmux_up "$(tsess "$wait_cid")" && [[ $waited -lt 60 ]]; do
                    sleep 1; (( waited++ )) || true
                done
                sleep 2
            fi
        else
            batch+=("$step")
        fi
    done < <(_grp_seq_steps "$gid")
    _flush_batch
}

_stop_group() {
    local gid="$1"
    local steps=(); mapfile -t steps < <(_grp_seq_steps "$gid")
    local i
    for (( i=${#steps[@]}-1; i>=0; i-- )); do
        local step="${steps[$i]}"
        [[ "${step,,}" =~ ^wait ]] && continue
        local cid; cid=$(_ct_id_by_name "$step")
        [[ -z "$cid" ]] && continue
        tmux_up "$(tsess "$cid")" || continue
        local in_other=false
        for gf in "$GROUPS_DIR"/*.toml; do
            [[ -f "$gf" ]] || continue
            local ogid; ogid=$(basename "${gf%.toml}")
            [[ "$ogid" == "$gid" ]] && continue
            _grp_containers "$ogid" | grep -q "^${step}$" || continue
            while IFS= read -r oc; do
                [[ "$oc" == "$step" ]] && continue
                local ocid; ocid=$(_ct_id_by_name "$oc")
                [[ -n "$ocid" ]] && tmux_up "$(tsess "$ocid")" && in_other=true && break
            done < <(_grp_containers "$ogid")
            [[ "$in_other" == true ]] && break
        done
        if [[ "$in_other" == false ]]; then
            _stop_container "$cid" || true
        else
            printf '[%s] shared with active group — leaving running\n' "$step"
        fi
    done
}


_grp_pick_container() {
    local names=()
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        local cn; cn=$(_cname "$cid")
        [[ -n "$cn" ]] && names+=("$cn")
    done
    [[ ${#names[@]} -eq 0 ]] && { pause "No containers found."; return 1; }
    local sel
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${names[@]}" | fzf "${FZF_BASE[@]}" --header="Select container" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 || -z "$sel" ]] && return
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s' "$sel" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Select container ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local FINPUT_RESULT; FINPUT_RESULT=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 || -z "${FINPUT_RESULT}" ]] && return
    sel=$(printf '%s' "$sel" | _trim_s)
    if [[ "$sel" == "Wait seconds" ]]; then
        finput "Seconds to wait:" || return 1
        local n="${FINPUT_RESULT//[^0-9]/}"
        [[ -z "$n" ]] && { pause "Invalid number."; return 1; }
        FINPUT_RESULT="Wait $n"
    else
        _grp_pick_container || return 1
        FINPUT_RESULT="Wait for ${FINPUT_RESULT}"
    fi
}

_grp_pick_step() {
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "Container" "Wait" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Add step ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 || -z "${sel}" ]] && return
    sel=$(printf '%s' "$sel" | _trim_s)
    if [[ "$sel" == "Container" ]]; then
        _grp_pick_container || return 1
    else
        _grp_pick_wait || return 1
    fi
}

_grp_edit_step() {
    local step="$1"
    if [[ "${step,,}" =~ ^wait ]]; then
        _grp_pick_wait || return 1
    else
        _grp_pick_container || return 1
    fi
}


_group_submenu() {
    local gid="$1"
    local D_START; D_START="$(printf " ${GRN}▶  Start group${NC}")"
    local D_STOP;  D_STOP="$(printf " ${RED}■  Stop group${NC}")"
    local D_EDIT;  D_EDIT="$(printf " ${BLU}≡  Edit name/desc${NC}")"
    local D_DEL;   D_DEL="$(printf " ${RED}×  Delete group${NC}")"
    local D_ADD;   D_ADD="$(printf " ${GRN}+  Add step${NC}")"
    local M_START="▶  Start group"
    local M_STOP="■  Stop group"
    local M_EDIT="≡  Edit name/desc"
    local M_DEL="×  Delete group"
    local M_ADD="+  Add step"

    while true; do
        clear
        local gname; gname=$(_grp_read_field "$gid" name)
        local gdesc;  gdesc=$(_grp_read_field "$gid" desc)

        local n_running=0
        while IFS= read -r cname; do
            [[ -z "$cname" ]] && continue
            local cid; cid=$(_ct_id_by_name "$cname")
            [[ -n "$cid" ]] && tmux_up "$(tsess "$cid")" && (( n_running++ )) || true
        done < <(_grp_containers "$gid")
        local is_running=false
        [[ $n_running -gt 0 ]] && is_running=true

        local steps=(); mapfile -t steps < <(_grp_seq_steps "$gid")

        local SEP_GEN SEP_SEQ
        SEP_GEN="$(printf "${BLD}  ── General ──────────────────────────${NC}")"
        SEP_SEQ="$(printf "${BLD}  ── Sequence ─────────────────────────${NC}")"

        local items=("$SEP_GEN")
        if [[ "$is_running" == "true" ]]; then
            items+=("$D_STOP")
        else
            items+=("$D_START" "$D_EDIT" "$D_DEL")
        fi

        items+=("$SEP_SEQ")

        local i
        for (( i=0; i<${#steps[@]}; i++ )); do
            local s="${steps[$i]}"
            if [[ "${s,,}" =~ ^wait ]]; then
                items+=("$(printf " ${YLW}⏱${NC}  ${DIM}%s${NC}" "$s")")
            else
                local cid; cid=$(_ct_id_by_name "$s")
                local dot status_str
                if [[ -z "$cid" ]]; then
                    dot="${RED}◈${NC}"; status_str="$(printf "${DIM} — not found${NC}")"
                elif tmux_up "$(tsess "$cid")"; then
                    dot="${GRN}◈${NC}"; status_str="$(printf "  ${GRN}running${NC}")"
                else
                    dot="${RED}◈${NC}"; status_str="$(printf "  ${DIM}stopped${NC}")"
                fi
                items+=("$(printf " ${dot}  %s%b" "$s" "$status_str")")
            fi
        done

        [[ ${#steps[@]} -eq 0 ]] && items+=("$(printf " ${DIM}(empty — add a step below)${NC}")")
        items+=("$D_ADD")

        local hdr_dot
        [[ "$is_running" == "true" ]] && hdr_dot="${GRN}▶${NC}" || hdr_dot="${DIM}▶${NC}"
        local hdr; hdr="$(printf "%b  ${BLD}%s${NC}" "$hdr_dot" "${gname:-$gid}")"
        [[ -n "$gdesc" ]] && hdr+="$(printf "  ${DIM}— %s${NC}" "$gdesc")"

        _menu "$hdr" "${items[@]}"
        case $? in 2) continue ;; 0) ;; *) return ;; esac

        case "$REPLY" in
            "$M_START") _start_group "$gid" ;;
            "$M_STOP")  _stop_group  "$gid" ;;
            "$M_EDIT")
                finput "Group name (${gname}):" && {
                    local nn="${FINPUT_RESULT:-$gname}"
                    sed -i "s|^name[[:space:]]*=.*|name = $nn|" "$(_grp_path "$gid")"
                }
                finput "Description (${gdesc}):" && {
                    sed -i "s|^desc[[:space:]]*=.*|desc = ${FINPUT_RESULT}|" "$(_grp_path "$gid")"
                }
                ;;
            "$M_DEL")
                confirm "Delete group '${gname:-$gid}'?" || continue
                rm -f "$(_grp_path "$gid")" 2>/dev/null
                pause "Group deleted."; return ;;
            "$M_ADD"|"(empty — add a step below)")
                _grp_pick_step || continue
                steps+=("$FINPUT_RESULT")
                _grp_seq_save "$gid" "${steps[@]}"
                ;;
            *)
                local matched_idx=-1
                for (( i=0; i<${#steps[@]}; i++ )); do
                    [[ "$REPLY" == *"${steps[$i]}"* ]] && { matched_idx=$i; break; }
                done
                [[ $matched_idx -lt 0 ]] && continue

                local _fzf_out _fzf_pid _frc
                _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
                printf '%s\n' "Add before" "Edit" "Add after" "Remove" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Edit step ──${NC}")" >"$_fzf_out" 2>/dev/null &
                _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
                wait "$_fzf_pid" 2>/dev/null; _frc=$?
                local action; action=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
                _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
                [[ $_frc -ne 0 || -z "${action}" ]] && continue
                action=$(printf '%s' "$action" | _trim_s)

                case "$action" in
                    "Add before")
                        _grp_pick_step || continue
                        steps=("${steps[@]:0:$matched_idx}" "$FINPUT_RESULT" "${steps[@]:$matched_idx}")
                        _grp_seq_save "$gid" "${steps[@]}"
                        ;;
                    "Add after")
                        _grp_pick_step || continue
                        local ins=$(( matched_idx + 1 ))
                        steps=("${steps[@]:0:$ins}" "$FINPUT_RESULT" "${steps[@]:$ins}")
                        _grp_seq_save "$gid" "${steps[@]}"
                        ;;
                    "Edit")
                        _grp_edit_step "${steps[$matched_idx]}" || continue
                        steps[$matched_idx]="$FINPUT_RESULT"
                        _grp_seq_save "$gid" "${steps[@]}"
                        ;;
                    "Remove")
                        steps=("${steps[@]:0:$matched_idx}" "${steps[@]:$(( matched_idx + 1 ))}")
                        _grp_seq_save "$gid" "${steps[@]}"
                        ;;
                esac
                ;;
        esac
    done
}

_groups_menu() {
    while true; do
        clear
        while IFS= read -r -t 0 -n 1 _ 2>/dev/null; do :; done
        local groups=(); mapfile -t groups < <(_list_groups)
        local SEP_GRP
        SEP_GRP="$(printf "${BLD}  ── Groups ───────────────────────────${NC}")"

        local lines=("$SEP_GRP")
        for gid in "${groups[@]}"; do
            local gname; gname=$(_grp_read_field "$gid" name)
            local n_running=0
            while IFS= read -r cname; do
                [[ -z "$cname" ]] && continue
                local cid; cid=$(_ct_id_by_name "$cname")
                [[ -n "$cid" ]] && tmux_up "$(tsess "$cid")" && (( n_running++ )) || true
            done < <(_grp_containers "$gid")
            local n_total; n_total=$(_grp_containers "$gid" | wc -l)
            local dot
            [[ $n_running -gt 0 ]] && dot="$(printf "${GRN}▶${NC}")" || dot="$(printf "${DIM}▶${NC}")"
            lines+=("$(printf " %b  %-24s ${DIM}%d/%d running${NC}" "$dot" "${gname:-$gid}" "$n_running" "$n_total")")
        done

        [[ ${#groups[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no groups yet)${NC}")")
        lines+=("$(printf "${GRN} +  ${L[grp_new]}${NC}")")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        local _n_grp_active=0
        for gid in "${groups[@]}"; do
            while IFS= read -r cname; do
                [[ -z "$cname" ]] && continue
                local _gcc; _gcc=$(_ct_id_by_name "$cname")
                [[ -n "$_gcc" ]] && tmux_up "$(tsess "$_gcc")" && { (( _n_grp_active++ )); break; } || true
            done < <(_grp_containers "$gid")
        done
        local _grp_hdr_extra
        _grp_hdr_extra=$(printf "  \033[2m[%d · \033[0;32m%d active\033[0m\033[2m]\033[0m" "${#groups[@]}" "$_n_grp_active")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Groups ──${NC}%s" "$_grp_hdr_extra")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel}" ]] && return
        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" ]] && return
        [[ "$clean" == *"${L[grp_new]}"* ]] && { _create_group; continue; }

        for gid in "${groups[@]}"; do
            local gname; gname=$(_grp_read_field "$gid" name)
            if [[ "$clean" == *"${gname:-$gid}"* ]]; then
                _group_submenu "$gid"; break
            fi
        done
    done
}

_create_group() {
    finput "Group name:" || return 1
    local gname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"
    [[ -z "$gname" ]] && { pause "Name cannot be empty."; return 1; }
    local gid; gid=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
    printf 'name = %s\ndesc =\ncontainers =\nstart = {  }\n' "$gname" > "$(_grp_path "$gid")"
    pause "Group '$gname' created."
}

_snap_dir()     { printf '%s/%s' "$BACKUP_DIR" "$(_cname "$1")"; }
_rand_snap_id() {
    local sdir="$1" id
    while true; do
        id=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
        [[ ! -d "$sdir/$id" ]] && printf '%s' "$id" && return
    done
}
_snap_meta_get() { local f="$1/$2.meta"; [[ -f "$f" ]] && grep -m1 "^$3=" "$f" 2>/dev/null | cut -d= -f2- || printf ''; }
_snap_meta_set() {
    local sdir="$1" snap_id="$2"; shift 2
    local f="$sdir/$snap_id.meta"; local tmp; tmp=$(mktemp)
    [[ -f "$f" ]] && cp "$f" "$tmp" || true
    for pair in "$@"; do
        local k="${pair%%=*}" v="${pair#*=}"
        sed -i "/^${k}=/d" "$tmp" 2>/dev/null || true
        printf '%s=%s\n' "$k" "$v" >> "$tmp"
    done
    mv "$tmp" "$f" 2>/dev/null || true
}
_delete_snap() {
    local path="$1"; [[ -z "$path" || ! -d "$path" ]] && return 0
    btrfs property set "$path" ro false &>/dev/null || true
    btrfs subvolume delete "$path" &>/dev/null || rm -rf "$path" 2>/dev/null || true
}
_delete_backup() { local sdir="$1" snap_id="$2"; _delete_snap "$sdir/$snap_id"; rm -f "$sdir/$snap_id.meta" 2>/dev/null || true; }

_rotate_and_snapshot() {
    local cid="$1" install_path; install_path=$(_cpath "$cid")
    [[ -z "$install_path" || ! -d "$install_path" ]] && return 1
    local sdir; sdir=$(_snap_dir "$cid"); mkdir -p "$sdir" 2>/dev/null
    local auto_ids=()
    for f in "$sdir"/*.meta; do
        [[ -f "$f" ]] || continue
        local fid; fid=$(basename "$f" .meta)
        [[ "$(_snap_meta_get "$sdir" "$fid" type)" == "auto" ]] && auto_ids+=("$fid")
    done
    while [[ ${#auto_ids[@]} -ge 2 ]]; do
        _delete_backup "$sdir" "${auto_ids[0]}"; auto_ids=("${auto_ids[@]:1}")
    done
    local new_id; new_id=$(_rand_snap_id "$sdir")
    local ts; ts=$(date '+%Y-%m-%d %H:%M')
    btrfs subvolume snapshot -r "$install_path" "$sdir/$new_id" &>/dev/null || return 1
    _snap_meta_set "$sdir" "$new_id" "type=auto" "ts=$ts"
}

_do_restore_snap() {
    local cid="$1" snap_path="$2" snap_label="$3"
    local name; name=$(_cname "$cid"); local install_path; install_path=$(_cpath "$cid")
    confirm "$(printf "Restore '%s' from '%s'?\n\n  Current installation will be overwritten.\n  Persistent storage profiles are untouched." "$name" "$snap_label")" || return 0
    btrfs property set "$snap_path" ro false &>/dev/null || true
    btrfs subvolume delete "$install_path" &>/dev/null || rm -rf "$install_path" 2>/dev/null
    if ! btrfs subvolume snapshot "$snap_path" "$install_path" &>/dev/null; then
        cp -a "$snap_path/." "$install_path/" 2>/dev/null
    fi
    btrfs property set "$snap_path" ro true &>/dev/null || true
    pause "$(printf "Restored '%s' from '%s'." "$name" "$snap_label")"
}

_prompt_backup_name() {
    local sdir="$1"; local default_id; default_id=$(_rand_snap_id "$sdir")
    while true; do
        local input
        if ! finput "$(printf 'Backup name:\n  (leave blank for random: %s)' "$default_id")"; then
            input="$default_id"
        else
            input="${FINPUT_RESULT//[^a-zA-Z0-9_\-]/}"
            [[ -z "$input" ]] && input="$default_id"
        fi
        [[ -d "$sdir/$input" ]] && { pause "A backup named '$input' already exists."; continue; }
        printf '%s' "$input"; return 0
    done
}

_create_manual_backup() {
    local cid="$1" name; name=$(_cname "$cid")
    local install_path; install_path=$(_cpath "$cid")
    [[ -z "$install_path" || ! -d "$install_path" ]] && { pause "No installation found for '$name'."; return 1; }
    local sdir; sdir=$(_snap_dir "$cid"); mkdir -p "$sdir" 2>/dev/null
    local snap_id; snap_id=$(_prompt_backup_name "$sdir"); [[ -z "$snap_id" ]] && return 1
    local ts; ts=$(date '+%Y-%m-%d %H:%M')
    if ! btrfs subvolume snapshot -r "$install_path" "$sdir/$snap_id" &>/dev/null; then
        cp -a "$install_path" "$sdir/$snap_id" 2>/dev/null || { pause "Snapshot failed."; return 1; }
    fi
    _snap_meta_set "$sdir" "$snap_id" "type=manual" "ts=$ts"
    pause "$(printf "Backup '%s' created." "$snap_id")"
}

_clone_from_snap() {
    local src_cid="$1" snap_path="$2" snap_label="$3"
    local src_name; src_name=$(_cname "$src_cid")
    [[ ! -d "$snap_path" ]] && { pause "Snapshot not found."; return 1; }
    finput "Name for the clone:" || return 1
    local clone_name="$FINPUT_RESULT"
    [[ -z "$clone_name" ]] && { pause "No name given."; return 1; }
    local clone_cid; clone_cid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -dc 'a-z0-9' | head -c 8 || tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
    local clone_dir="$CONTAINERS_DIR/$clone_cid"
    local clone_path="$INSTALLATIONS_DIR/$clone_cid"
    mkdir -p "$clone_dir" 2>/dev/null
    cp "$CONTAINERS_DIR/$src_cid/service.json" "$clone_dir/service.json" 2>/dev/null || true
    cp "$CONTAINERS_DIR/$src_cid/state.json"   "$clone_dir/state.json"   2>/dev/null || true
    [[ -f "$CONTAINERS_DIR/$src_cid/resources.json" ]] && cp "$CONTAINERS_DIR/$src_cid/resources.json" "$clone_dir/resources.json" 2>/dev/null || true
    jq --arg n "$clone_name" --arg p "$(basename "$clone_path")" '.name=$n | .install_path=$p' \
        "$clone_dir/state.json" > "$clone_dir/state.json.tmp" 2>/dev/null \
        && mv "$clone_dir/state.json.tmp" "$clone_dir/state.json"
    if btrfs subvolume snapshot "$snap_path" "$clone_path" &>/dev/null; then
        btrfs property set "$clone_path" ro false &>/dev/null || true
        pause "$(printf "Cloned '%s' (%s) → '%s'" "$src_name" "$snap_label" "$clone_name")"
    else
        cp -a "$snap_path/." "$clone_path/" 2>/dev/null \
            || { rm -rf "$clone_dir" "$clone_path" 2>/dev/null; pause "Clone failed."; return 1; }
        pause "$(printf "Cloned '%s' (%s) → '%s' (plain copy)" "$src_name" "$snap_label" "$clone_name")"
    fi
}

_clone_source_submenu() {
    local src_cid="$1"
    local src_name; src_name=$(_cname "$src_cid")
    local src_path; src_path=$(_cpath "$src_cid")
    local sdir; sdir=$(_snap_dir "$src_cid")
    tmux_up "$(tsess "$src_cid")" && { pause "Stop '$src_name' before cloning."; return; }
    [[ ! -d "$src_path" ]] && { pause "Container not installed."; return; }

    local lines=()
    lines+=("$(printf "${BLD}  ── Main ─────────────────────────────${NC}\t__sep__")")
    lines+=("$(printf "   ${DIM}◈${NC}  Current state\tcurrent")")
    local pi_path="$sdir/Post-Installation"
    [[ -d "$pi_path" ]] && {
        local pi_ts; pi_ts=$(_snap_meta_get "$sdir" "Post-Installation" ts)
        lines+=("$(printf "   ${DIM}◈${NC}  Post-Installation${DIM}  (%s)${NC}\tpost" "${pi_ts:-?}")")
    }

    local other_ids=() other_ts=()
    for f in "$sdir"/*.meta; do
        [[ -f "$f" ]] || continue
        local fid; fid=$(basename "$f" .meta)
        [[ "$fid" == "Post-Installation" || ! -d "$sdir/$fid" ]] && continue
        other_ids+=("$fid"); other_ts+=("$(_snap_meta_get "$sdir" "$fid" ts)")
    done
    lines+=("$(printf "${BLD}  ── Other ────────────────────────────${NC}\t__sep__")")
    if [[ ${#other_ids[@]} -gt 0 ]]; then
        for i in "${!other_ids[@]}"; do
            local oid="${other_ids[$i]}" ots="${other_ts[$i]}"
            local de="$(printf "   ${DIM}◈${NC}  %s" "$oid")"
            [[ -n "$ots" ]] && de+="$(printf "${DIM}  (%s)${NC}" "$ots")"
            lines+=("$de\t$oid")
        done
    else
        lines+=("$(printf "${DIM}  No other backups found${NC}\t__sep__")")
    fi
    lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}\t__sep__")")
    lines+=("$(printf "${DIM} %s${NC}\t__back__" "${L[back]}")")

    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --with-nth=1 --delimiter=$'\t' \
        --header="$(printf "${BLD}── Clone '%s' from ──${NC}" "$src_name")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local sel; sel=$(cat "$_fzf_out" 2>/dev/null); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; return; }
    [[ $_frc -ne 0 || -z "$sel" ]] && return
    local tag; tag=$(printf '%s' "$sel" | awk -F'\t' '{print $2}' | tr -d '[:space:]')
    [[ "$tag" == "__back__" || "$tag" == "__sep__" || -z "$tag" ]] && return
    case "$tag" in
        current) _clone_container "$src_cid" ;;
        post)    _clone_from_snap "$src_cid" "$pi_path" "Post-Installation" ;;
        *)       _clone_from_snap "$src_cid" "$sdir/$tag" "$tag" ;;
    esac
}

_install_method_menu() {
    local bps=(); mapfile -t bps < <(_list_blueprint_names)
    local pbps=(); mapfile -t pbps < <(_list_persistent_names)
    local ibps=(); mapfile -t ibps < <(_list_imported_names)
    local lines=()
    lines+=("$(printf "${BLD}  ── Install from blueprint ───────────${NC}\t__sep__")")
    if [[ ${#bps[@]} -gt 0 || ${#pbps[@]} -gt 0 || ${#ibps[@]} -gt 0 ]]; then
        for n in "${bps[@]}";  do lines+=("$(printf "   ${DIM}◈${NC}  %s\tbp:%s" "$n" "$n")"); done
        for n in "${pbps[@]}"; do lines+=("$(printf "   ${BLU}◈${NC}  %s  ${DIM}[Persistent]${NC}\tpbp:%s" "$n" "$n")"); done
        for n in "${ibps[@]}"; do lines+=("$(printf "   ${CYN}◈${NC}  %s  ${DIM}[Imported]${NC}\tibp:%s" "$n" "$n")"); done
    else
        lines+=("$(printf "${DIM}  No blueprints found${NC}\t__sep__")")
    fi

    lines+=("$(printf "${BLD}  ── Clone existing container ─────────${NC}\t__sep__")")
    _load_containers false
    local has_inst=false
    for i in "${!CT_IDS[@]}"; do
        [[ "$(_st "${CT_IDS[$i]}" installed)" != "true" ]] && continue
        has_inst=true
        lines+=("$(printf "   ${DIM}◈${NC}  %s\tclone:%s" "${CT_NAMES[$i]}" "${CT_IDS[$i]}")")
    done
    [[ "$has_inst" == "false" ]] && lines+=("$(printf "${DIM}  No installed containers found${NC}\t__sep__")")

    lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}\t__sep__")")
    lines+=("$(printf "${DIM} %s${NC}\t__back__" "${L[back]}")")

    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --with-nth=1 --delimiter=$'\t' \
        --header="$(printf "${BLD}── Select installation method ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local sel; sel=$(cat "$_fzf_out" 2>/dev/null); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; return 2; }
    [[ $_frc -ne 0 || -z "$sel" ]] && return 1
    local tag; tag=$(printf '%s' "$sel" | awk -F'\t' '{print $2}' | tr -d '[:space:]')
    [[ "$tag" == "__back__" || "$tag" == "__sep__" || -z "$tag" ]] && return 1
    case "$tag" in
        bp:*)    _create_container "${tag#bp:}" ;;
        pbp:*)   _create_container "${tag#pbp:}" "" ;;
        ibp:*)
            local _iname="${tag#ibp:}"
            local _ipath; _ipath=$(_get_imported_bp_path "$_iname")
            [[ -z "$_ipath" ]] && { pause "Could not locate imported blueprint '$_iname'."; return 1; }
            _create_container "$_iname" "$_ipath" ;;
        clone:*) _clone_source_submenu "${tag#clone:}" ;;
    esac
}

_clone_container() {
    local src_cid="$1"
    local src_name; src_name=$(_cname "$src_cid")
    local src_path; src_path=$(_cpath "$src_cid")

    [[ -z "$src_path" || ! -d "$src_path" ]] && { pause "Container not installed — nothing to clone."; return 1; }
    tmux_up "$(tsess "$src_cid")" && { pause "Stop '$src_name' before cloning."; return 1; }

    finput "Name for the clone:" || return 1
    local clone_name="$FINPUT_RESULT"
    [[ -z "$clone_name" ]] && { pause "No name given."; return 1; }

    local clone_cid; clone_cid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
        | tr -dc 'a-z0-9' | head -c 8 || tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
    local clone_dir="$CONTAINERS_DIR/$clone_cid"
    local clone_path="$INSTALLATIONS_DIR/$clone_cid"

    mkdir -p "$clone_dir" 2>/dev/null

    cp "$CONTAINERS_DIR/$src_cid/service.json"  "$clone_dir/service.json" 2>/dev/null || true
    cp "$CONTAINERS_DIR/$src_cid/state.json"    "$clone_dir/state.json" 2>/dev/null || true
    [[ -f "$CONTAINERS_DIR/$src_cid/resources.json" ]] && \
        cp "$CONTAINERS_DIR/$src_cid/resources.json" "$clone_dir/resources.json" 2>/dev/null || true

    local rel_path; rel_path=$(basename "$clone_path")
    jq --arg n "$clone_name" --arg p "$rel_path" \
        '.name = $n | .install_path = $p' \
        "$clone_dir/state.json" > "$clone_dir/state.json.tmp" 2>/dev/null \
        && mv "$clone_dir/state.json.tmp" "$clone_dir/state.json"

    if btrfs subvolume snapshot "$src_path" "$clone_path" &>/dev/null; then
        pause "$(printf "Cloned '%s' → '%s'\n\nThe clone is independent — changes won't affect the original.\nShared blocks are copy-on-write so initial disk usage is near zero." \
            "$src_name" "$clone_name")"
    else
        cp -a "$src_path" "$clone_path" 2>/dev/null \
            || { rm -rf "$clone_dir" "$clone_path" 2>/dev/null; pause "Clone failed."; return 1; }
        pause "$(printf "Cloned '%s' → '%s' (plain copy — btrfs snapshot unavailable)" \
            "$src_name" "$clone_name")"
    fi
}

_container_backups_menu() {
    local cid="$1" name; name=$(_cname "$cid")
    local sdir; sdir=$(_snap_dir "$cid")
    local SEP_AUTO SEP_MAN
    SEP_AUTO="$(printf "${BLD}  ── Automatic backups ────────────────${NC}")"
    SEP_MAN="$(printf  "${BLD}  ── Manual backups ───────────────────${NC}")"

    while true; do
        mkdir -p "$sdir" 2>/dev/null
        local auto_ids=() auto_ts=() man_ids=() man_ts=()
        for f in "$sdir"/*.meta; do
            [[ -f "$f" ]] || continue
            local fid; fid=$(basename "$f" .meta); [[ ! -d "$sdir/$fid" ]] && continue
            local ftype fts
            ftype=$(_snap_meta_get "$sdir" "$fid" type); fts=$(_snap_meta_get "$sdir" "$fid" ts)
            if [[ "$ftype" == "auto" ]]; then auto_ids+=("$fid"); auto_ts+=("$fts")
            else man_ids+=("$fid"); man_ts+=("$fts"); fi
        done

        local lines=() line_ids=()
        lines+=("$SEP_AUTO"); line_ids+=("")
        if [[ ${#auto_ids[@]} -gt 0 ]]; then
            for i in "${!auto_ids[@]}"; do
                local aid="${auto_ids[$i]}" ats="${auto_ts[$i]}"
                local disp; disp="$(printf "${DIM} ◈  %s${NC}" "$aid")"
                [[ -n "$ats" ]] && disp+="$(printf "${DIM}  (%s)${NC}" "$ats")"
                lines+=("$disp"); line_ids+=("$aid")
            done
        else lines+=("$(printf "${DIM}  (none yet)${NC}")"); line_ids+=(""); fi

        lines+=("$SEP_MAN"); line_ids+=("")
        if [[ ${#man_ids[@]} -gt 0 ]]; then
            for i in "${!man_ids[@]}"; do
                local mid="${man_ids[$i]}" mts="${man_ts[$i]}"
                local disp; disp="$(printf "${DIM} ◈  %s${NC}" "$mid")"
                [[ -n "$mts" ]] && disp+="$(printf "${DIM}  (%s)${NC}" "$mts")"
                lines+=("$disp"); line_ids+=("$mid")
            done
        else lines+=("$(printf "${DIM}  (none yet)${NC}")"); line_ids+=(""); fi

        lines+=("$(printf "${BLD}  ── Actions ──────────────────────────${NC}")"); line_ids+=("")
        lines+=("$(printf "${GRN}+${NC}${DIM}  Create manual backup${NC}")"); line_ids+=("__create__")
        lines+=("$(printf "${RED}×${NC}${DIM}  Remove all backups${NC}")");     line_ids+=("__remove_all__")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"); line_ids+=("")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")"); line_ids+=("__back__")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Backups: %s ──${NC}" "$name")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel_line; sel_line=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel_line}" ]] && return

        local sel_clean; sel_clean=$(printf '%s' "$sel_line" | _trim_s)
        local sel_id=""
        for i in "${!lines[@]}"; do
            local lc; lc=$(printf '%s' "${lines[$i]}" | _trim_s)
            if [[ "$lc" == "$sel_clean" ]]; then sel_id="${line_ids[$i]}"; break; fi
        done
        [[ -z "$sel_id" || "$sel_id" == "__back__" ]] && return

        if [[ "$sel_id" == "__create__" ]]; then
            tmux_up "$(tsess "$cid")" && { pause "Stop the container before creating a backup."; continue; }
            confirm "$(printf "Create manual backup of '%s'?" "$name")" && _create_manual_backup "$cid"
            continue
        fi

        if [[ "$sel_id" == "__remove_all__" ]]; then
            tmux_up "$(tsess "$cid")" && { pause "Stop the container before removing backups."; continue; }
            _menu "Remove backups: $name" "All automatic" "All manual" "All (automatic + manual)" || continue
            local rm_choice="$REPLY"
            local rm_auto=false rm_man=false
            case "$rm_choice" in
                "All automatic")           rm_auto=true ;;
                "All manual")              rm_man=true ;;
                "All (automatic + manual)") rm_auto=true; rm_man=true ;;
            esac
            local rm_count=0
            [[ "$rm_auto" == "true" ]] && for id in "${auto_ids[@]}"; do _delete_backup "$sdir" "$id"; (( rm_count++ )) || true; done
            [[ "$rm_man"  == "true" ]] && for id in "${man_ids[@]}";  do _delete_backup "$sdir" "$id"; (( rm_count++ )) || true; done
            pause "$(printf "%d backup(s) removed." "$rm_count")"
            continue
        fi

        [[ ! -d "$sdir/$sel_id" ]] && { pause "Backup not found."; continue; }
        local bts; bts=$(_snap_meta_get "$sdir" "$sel_id" ts)
        _menu "$(printf "Backup: %s  (%s)" "$sel_id" "${bts:-?}")" "Restore" "Create clone" "Delete" || continue
        case "$REPLY" in
            "Restore")      tmux_up "$(tsess "$cid")" && { pause "Stop the container before restoring."; continue; }
                            _do_restore_snap "$cid" "$sdir/$sel_id" "$sel_id" ;;
            "Create clone") tmux_up "$(tsess "$cid")" && { pause "Stop the container before cloning."; continue; }
                            _clone_from_snap "$cid" "$sdir/$sel_id" "$sel_id" ;;
            "Delete")       confirm "Delete backup '$sel_id'?" || continue
                            _delete_backup "$sdir" "$sel_id"
                            pause "Backup '$sel_id' deleted." ;;
        esac
    done
}

_manage_backups_menu() {
    _load_containers false
    [[ ${#CT_IDS[@]} -eq 0 ]] && { pause "No containers found."; return; }
    local lines=()
    for i in "${!CT_IDS[@]}"; do
        lines+=("$(printf "${DIM} ◈${NC}  %s" "${CT_NAMES[$i]}")")
    done
    _menu "Manage backups" "${lines[@]}" || return
    for i in "${!CT_IDS[@]}"; do
        [[ "$REPLY" == *"${CT_NAMES[$i]}"* ]] && { _container_backups_menu "${CT_IDS[$i]}"; return; }
    done
}

_stor_path()          { printf '%s/%s' "$STORAGE_DIR" "$1"; }
_stor_meta_path()     { printf '%s/.sd_meta.json' "$(_stor_path "$1")"; }
_stor_meta_set() {
    local scid="$1"; shift
    local mp; mp=$(_stor_meta_path "$scid"); local tmp; tmp=$(mktemp)
    [[ -f "$mp" ]] && cp "$mp" "$tmp" || printf '{}' > "$tmp"
    local key val
    while [[ $# -ge 2 ]]; do
        key="$1" val="$2"; shift 2
        jq --arg k "$key" --arg v "$val" '.[$k]=$v' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
    done
    mv "$tmp" "$mp"
}
_stor_read_field()     { jq -r ".$2 // empty" "$(_stor_meta_path "$1")" 2>/dev/null; }
_stor_read_name()      { _stor_read_field "$1" name; }
_stor_read_type()      { _stor_read_field "$1" storage_type; }
_stor_read_active()    { _stor_read_field "$1" active_container; }
_stor_set_active()     { _stor_meta_set "$1" active_container "$2"; }
_stor_clear_active()   { _stor_meta_set "$1" active_container ""; }

_stor_type_from_sj() {
    local cid="$1"
    jq -r '.meta.storage_type // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null
}

_stor_count() {
    local cid="$1"
    local st; st=$(_stor_type_from_sj "$cid")
    [[ -z "$st" ]] && printf '0' && return
    local sj; sj="$CONTAINERS_DIR/$cid/service.json"
    local n; n=$(jq -r '.storage | length' "$sj" 2>/dev/null)
    printf '%s' "${n:-0}"
}

_stor_paths() {
    local cid="$1"
    jq -r '.storage[]? // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null
}

_stor_unlink() {
    local cid="$1" install_path="$2"
    local rel
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        local link_path="$install_path/$rel"
        if [[ -L "$link_path" ]]; then rm -f "$link_path" 2>/dev/null; mkdir -p "$link_path" 2>/dev/null; fi
    done < <(_stor_paths "$cid")
}

_stor_link() {
    local cid="$1" install_path="$2" scid="$3"
    local sdir; sdir=$(_stor_path "$scid"); mkdir -p "$sdir" 2>/dev/null
    local -A active=()
    local rel
    while IFS= read -r rel; do [[ -z "$rel" ]] && continue; active["$rel"]=1; done < <(_stor_paths "$cid")

    local prev_paths=()
    mapfile -t prev_paths < <(jq -r '.storage_paths[]? // empty' "$CONTAINERS_DIR/$cid/state.json" 2>/dev/null)
    for prev in "${prev_paths[@]}"; do
        [[ -z "$prev" || -n "${active[$prev]:-}" ]] && continue
        local real_path="$sdir/$prev" link_path="$install_path/$prev"
        [[ ! -d "$real_path" ]] && continue
        [[ -L "$link_path" ]] && rm -f "$link_path" 2>/dev/null
        mkdir -p "$link_path" 2>/dev/null
        [[ -n "$(ls -A "$real_path" 2>/dev/null)" ]] && cp -a "$real_path/." "$link_path/" 2>/dev/null || true
        rm -rf "$real_path" 2>/dev/null
    done

    for rel in "${!active[@]}"; do
        local real_path="$sdir/$rel" link_path="$install_path/$rel"
        mkdir -p "$real_path" "$(dirname "$link_path")" 2>/dev/null
        [[ -L "$link_path" ]] && rm -f "$link_path" 2>/dev/null
        if [[ -d "$link_path" ]]; then
            [[ -n "$(ls -A "$link_path" 2>/dev/null)" ]] && cp -a "$link_path/." "$real_path/" 2>/dev/null || true
            rm -rf "$link_path" 2>/dev/null
        fi
        ln -sfn "$real_path" "$link_path" 2>/dev/null
    done

    local paths_json; paths_json=$(printf '%s\n' "${!active[@]}" | jq -R -s 'split("\n") | map(select(length>0))')
    jq --argjson p "$paths_json" --arg s "$scid" '.storage_paths=$p | .storage_id=$s' \
        "$CONTAINERS_DIR/$cid/state.json" > "$CONTAINERS_DIR/$cid/state.json.tmp" 2>/dev/null \
        && mv "$CONTAINERS_DIR/$cid/state.json.tmp" "$CONTAINERS_DIR/$cid/state.json" 2>/dev/null || true
    _stor_set_active "$scid" "$cid"
}

_auto_pick_storage_profile() {
    local cid="$1"
    local stype; stype=$(_stor_type_from_sj "$cid")
    [[ "$(_stor_count "$cid")" -eq 0 ]] && return 0
    [[ -z "$STORAGE_DIR" || ! -d "$STORAGE_DIR" ]] && { _stor_create_profile_silent "$cid" "$stype"; return; }

    local def_scid; def_scid=$(_state_get "$cid" default_storage_id)
    if [[ -n "$def_scid" && -d "$(_stor_path "$def_scid")" ]]; then
        local ac; ac=$(_stor_read_active "$def_scid")
        if [[ -z "$ac" || "$ac" == "$cid" ]] || ! tmux_up "$(tsess "$ac")"; then
            [[ -n "$ac" && "$ac" != "$cid" ]] && _stor_clear_active "$def_scid"
            printf '%s' "$def_scid"; return
        fi
    fi

    local last_scid; last_scid=$(_state_get "$cid" storage_id)
    if [[ -n "$last_scid" && -d "$(_stor_path "$last_scid")" ]]; then
        local ac; ac=$(_stor_read_active "$last_scid")
        if [[ -z "$ac" || "$ac" == "$cid" ]] || ! tmux_up "$(tsess "$ac")"; then
            [[ -n "$ac" && "$ac" != "$cid" ]] && _stor_clear_active "$last_scid"
            printf '%s' "$last_scid"; return
        fi
    fi

    for sdir in "$STORAGE_DIR"/*/; do
        [[ -d "$sdir" ]] || continue
        local scid; scid=$(basename "$sdir")
        [[ "$(_stor_read_type "$scid")" != "$stype" ]] && continue
        local ac; ac=$(_stor_read_active "$scid")
        if [[ -z "$ac" || "$ac" == "$cid" ]] || ! tmux_up "$(tsess "$ac")"; then
            [[ -n "$ac" && "$ac" != "$cid" ]] && _stor_clear_active "$scid"
            printf '%s' "$scid"; return
        fi
    done

    _stor_create_profile_silent "$cid" "$stype"
}

_stor_create_profile_silent() {
    local cid="$1" stype="$2"
    local new_scid
    while true; do
        new_scid=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
        [[ ! -d "$(_stor_path "$new_scid")" ]] && break
    done
    mkdir -p "$(_stor_path "$new_scid")" 2>/dev/null
    _stor_meta_set "$new_scid" storage_type "$stype" name "Default" created "$(date +%Y-%m-%d)" active_container ""
    _set_st "$cid" default_storage_id "\"$new_scid\""
    printf '%s' "$new_scid"
}

_pick_storage_profile() {
    local cid="$1"
    local stype; stype=$(_stor_type_from_sj "$cid")
    [[ "$(_stor_count "$cid")" -eq 0 ]] && return 0
    [[ -z "$STORAGE_DIR" || ! -d "$STORAGE_DIR" ]] && { _stor_create_profile "$cid" "$stype"; return; }

    local options=() scid_map=()
    local new_label; new_label="$(printf "${GRN}+  New profile…${NC}")"
    for sdir in "$STORAGE_DIR"/*/; do
        [[ -d "$sdir" ]] || continue
        local scid; scid=$(basename "$sdir")
        [[ "$(_stor_read_type "$scid")" != "$stype" ]] && continue
        local pname; pname=$(_stor_read_name "$scid"); [[ -z "$pname" ]] && pname="(unnamed)"
        local ssize; ssize=$(du -sh "$sdir" 2>/dev/null | cut -f1)
        local active_cid; active_cid=$(_stor_read_active "$scid")
        if [[ -n "$active_cid" && "$active_cid" != "$cid" ]]; then
            if tmux_up "$(tsess "$active_cid")"; then
                options+=("$(printf "${DIM}○  %s  [%s]  %s  — in use by %s${NC}" "$pname" "$scid" "$ssize" "$(_cname "$active_cid")")")
                scid_map+=("__inuse__"); continue
            else
                _stor_clear_active "$scid"
            fi
        fi
        options+=("$(printf "●  %s  [%s]  %s" "$pname" "$scid" "$ssize")"); scid_map+=("$scid")
    done
    options+=("$new_label"); scid_map+=("__new__")

    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${options[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Storage profile ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local chosen; chosen=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 || -z "${chosen}" ]] && return
    local chosen_clean; chosen_clean=$(printf '%s' "$chosen" | _trim_s)
    local i
    for i in "${!options[@]}"; do
        [[ "$(printf '%s' "${options[$i]}" | _trim_s)" == "$chosen_clean" ]] && break
    done
    local mapped="${scid_map[$i]:-}"
    [[ "$mapped" == "__inuse__" ]] && { pause "That profile is in use by another running container."; return 1; }
    [[ "$mapped" == "__new__"   ]] && { _stor_create_profile "$cid" "$stype"; return; }
    [[ -n "$mapped" ]] && printf '%s' "$mapped"
}

_stor_create_profile() {
    local cid="$1" stype="$2"
    local existing_names=()
    for sdir in "$STORAGE_DIR"/*/; do
        [[ -d "$sdir" ]] || continue
        local sn; sn=$(_stor_read_name "$(basename "$sdir")")
        [[ "$(_stor_read_type "$(basename "$sdir")")" == "$stype" && -n "$sn" ]] && existing_names+=("$sn")
    done
    local pname=""
    while true; do
        if ! finput "$(printf 'New storage profile name:\n  (leave blank for Default)')"; then
            printf ''; return 1
        fi
        pname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"; [[ -z "$pname" ]] && pname="Default"
        local dup=false
        for en in "${existing_names[@]}"; do [[ "$en" == "$pname" ]] && dup=true && break; done
        [[ "$dup" == "true" ]] && { pause "A profile named '$pname' already exists for this type."; continue; }
        break
    done
    local new_scid
    while true; do
        new_scid=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
        [[ ! -d "$(_stor_path "$new_scid")" ]] && break
    done
    mkdir -p "$(_stor_path "$new_scid")" 2>/dev/null
    _stor_meta_set "$new_scid" storage_type "$stype" name "$pname" created "$(date +%Y-%m-%d)" active_container ""
    printf '%s' "$new_scid"
}

_persistent_storage_menu() {
    local _ctx="${1:-}"
    while true; do
        [[ -z "$STORAGE_DIR" || ! -d "$STORAGE_DIR" ]] && { pause "No storage directory found."; return; }

        local _all_cids=()
        for _cd in "$CONTAINERS_DIR"/*/; do
            [[ -f "$_cd/state.json" ]] && _all_cids+=("$(basename "$_cd")")
        done

        local entries=() scids=()
        for sdir in "$STORAGE_DIR"/*/; do
            [[ -d "$sdir" ]] || continue
            local scid; scid=$(basename "$sdir")
            local ssize; ssize=$(du -sh "$sdir" 2>/dev/null | cut -f1)
            local pname; pname=$(_stor_read_name "$scid"); [[ -z "$pname" ]] && pname="(unnamed)"
            local stype; stype=$(_stor_read_type "$scid")
            local active_cid; active_cid=$(_stor_read_active "$scid")

            local def_for=""
            for _cid2 in "${_all_cids[@]}"; do
                local _d; _d=$(_state_get "$_cid2" default_storage_id)
                [[ "$_d" == "$scid" ]] && { def_for="$(_cname "$_cid2")"; break; }
            done

            local base_info; base_info="$(printf "${BLD}%s${NC}  ${DIM}[%s]${NC}" "$pname" "$scid")"
            [[ -n "$stype" ]] && base_info+="$(printf "  ${DIM}(%s)${NC}" "$stype")"

            local dot label
            if [[ -n "$active_cid" ]] && tmux_up "$(tsess "$active_cid")"; then
                [[ -n "$def_for" ]] && dot="${GRN}★${NC}" || dot="${GRN}●${NC}"
                label="$(printf "${dot}  %-40b  ${DIM}%s  — running in %s${NC}" "$base_info" "$ssize" "$(_cname "$active_cid")")"
            elif [[ -n "$active_cid" ]]; then
                _stor_clear_active "$scid"
                [[ -n "$def_for" ]] && dot="${YLW}★${NC}" || dot="${YLW}○${NC}"
                label="$(printf "${dot}  %-40b  ${DIM}%s  [stale]${NC}" "$base_info" "$ssize")"
            else
                [[ -n "$def_for" ]] && dot="${DIM}★${NC}" || dot="${DIM}○${NC}"
                label="$(printf "${dot}  %-40b  ${DIM}%s${NC}" "$base_info" "$ssize")"
            fi
            entries+=("$label"); scids+=("$scid")
        done

        local SEP_BACKUP
        SEP_BACKUP="$(printf "${BLD}  ── Backup data ──────────────────────${NC}")"
        entries+=("$SEP_BACKUP"); scids+=("")

        local export_running=false import_running=false
        tmux has-session -t "sdStorExport" 2>/dev/null && export_running=true
        tmux has-session -t "sdStorImport" 2>/dev/null && import_running=true

        if [[ "$export_running" == "true" ]]; then
            entries+=("$(printf "${YLW}↑${NC}${DIM}  Export running — click to manage${NC}")"); scids+=("__export_running__")
        else entries+=("$(printf "${DIM}↑  Export${NC}")"); scids+=("__export__"); fi
        if [[ "$import_running" == "true" ]]; then
            entries+=("$(printf "${YLW}↓${NC}${DIM}  Import running — click to manage${NC}")"); scids+=("__import_running__")
        else entries+=("$(printf "${DIM}↓  Import${NC}")"); scids+=("__import__"); fi

        local hdr
        if [[ -n "$_ctx" ]]; then
            hdr="$(printf "${BLD}── Profiles: %s ──${NC}\n${DIM}  ${GRN}●${NC}${DIM} running  ${YLW}○${NC}${DIM} stale  ○ free  ${YLW}★${NC}${DIM} default${NC}" "$(_cname "$_ctx")")"
        else
            hdr="$(printf "${BLD}── Persistent storage ──${NC}\n${DIM}  ${GRN}●${NC}${DIM} running  ${YLW}○${NC}${DIM} stale  ○ free  ${YLW}★${NC}${DIM} default${NC}")"
        fi

        local numbered=()
        local idx
        for (( idx=0; idx<${#entries[@]}; idx++ )); do
            numbered+=("$(printf '%04d\t%s' "$idx" "${entries[$idx]}")")
        done

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${numbered[@]}" | fzf "${FZF_BASE[@]}" --delimiter=$'\t' --with-nth=2.. --header="$hdr" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel_line; sel_line=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel_line}" ]] && return

        local sel_idx; sel_idx=$(printf '%s' "$sel_line" | _strip_ansi | cut -d$'\t' -f1 | tr -dc '0-9')
        [[ -z "$sel_idx" ]] && continue
        local sel_scid="${scids[$sel_idx]:-}"
        [[ -z "$sel_scid" ]] && continue

        case "$sel_scid" in
            "__export__")   _stor_export_menu ;;
            "__export_running__")
                _menu "Export running" "Attach to export" "Kill export" || continue
                case "$REPLY" in
                    "Attach to export") _tmux_attach_hint "export" "sdStorExport" ;;
                    "Kill export") confirm "Kill the running export?" || continue
                        tmux kill-session -t "sdStorExport" 2>/dev/null || true; pause "Export killed." ;;
                esac ;;
            "__import__")   _stor_import_menu ;;
            "__import_running__")
                _menu "Import running" "Attach to import" "Kill import" || continue
                case "$REPLY" in
                    "Attach to import") _tmux_attach_hint "import" "sdStorImport" ;;
                    "Kill import") confirm "Kill the running import?" || continue
                        tmux kill-session -t "sdStorImport" 2>/dev/null || true; pause "Import killed." ;;
                esac ;;
            *)
                local active_cid2; active_cid2=$(_stor_read_active "$sel_scid")
                if [[ -n "$active_cid2" ]] && tmux_up "$(tsess "$active_cid2")"; then
                    pause "$(printf "Storage is currently running in '%s'.\nStop the container first." "$(_cname "$active_cid2")")"; continue
                fi
                local pname2; pname2=$(_stor_read_name "$sel_scid"); [[ -z "$pname2" ]] && pname2="(unnamed)"
                local stype2; stype2=$(_stor_read_type "$sel_scid")

                local cur_def_cid=""
                for _cid2b in "${_all_cids[@]}"; do
                    local _db; _db=$(_state_get "$_cid2b" default_storage_id)
                    [[ "$_db" == "$sel_scid" ]] && { cur_def_cid="$_cid2b"; break; }
                done

                local _action_ctx="$_ctx"
                if [[ -z "$_action_ctx" && -n "$stype2" ]]; then
                    local _mc=0 _last_cid=""
                    for _cid3 in "${_all_cids[@]}"; do
                        [[ "$(_stor_type_from_sj "$_cid3")" == "$stype2" ]] && { _last_cid="$_cid3"; ((_mc++)) || true; }
                    done
                    [[ $_mc -eq 1 ]] && _action_ctx="$_last_cid"
                fi

                local act_items=()
                if [[ -n "$cur_def_cid" ]]; then
                    act_items+=("☆  Unset default")
                else
                    act_items+=("★  Set as default")
                fi
                act_items+=("${L[stor_rename]}" "${L[stor_delete]}")

                _menu "$(printf "Storage: %s" "$pname2")" "${act_items[@]}" || continue

                case "$REPLY" in
                    "☆  Unset default")
                        _set_st "$cur_def_cid" default_storage_id '""'
                        pause "$(printf "'%s' is no longer the default for %s." "$pname2" "$(_cname "$cur_def_cid")")" ;;
                    "★  Set as default")
                        if [[ -z "$_action_ctx" ]]; then
                            local _ct_names=() _ct_ids=()
                            for _cid4 in "${_all_cids[@]}"; do
                                _ct_names+=("$(_cname "$_cid4")"); _ct_ids+=("$_cid4")
                            done
                            local _fzf_out _fzf_pid _frc
                            _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
                            printf '%s\n' "${_ct_names[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Assign container ──${NC}")" >"$_fzf_out" 2>/dev/null &
                            _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
                            wait "$_fzf_pid" 2>/dev/null; _frc=$?
                            local _chosen_ct; _chosen_ct=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
                            _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
                            [[ $_frc -ne 0 || -z "${_chosen_ct}" ]] && continue
                            _chosen_ct=$(printf '%s' "$_chosen_ct" | _trim_s)
                            for i in "${!_ct_names[@]}"; do
                                [[ "${_ct_names[$i]}" == "$_chosen_ct" ]] && { _action_ctx="${_ct_ids[$i]}"; break; }
                            done
                        fi
                        [[ -z "$_action_ctx" ]] && continue
                        local old_def; old_def=$(_state_get "$_action_ctx" default_storage_id)
                        if [[ -n "$old_def" && "$old_def" != "$sel_scid" ]]; then
                            local old_type; old_type=$(_stor_read_type "$old_def")
                            [[ "$old_type" == "$stype2" ]] && _set_st "$_action_ctx" default_storage_id '""'
                        fi
                        _set_st "$_action_ctx" default_storage_id "\"$sel_scid\""
                        pause "$(printf "'%s' set as default for %s." "$pname2" "$(_cname "$_action_ctx")")" ;;
                    "${L[stor_rename]}")
                        while true; do
                            finput "New name for '$pname2':" || break
                            local new_sname; new_sname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"
                            [[ -z "$new_sname" ]] && { pause "Name cannot be empty."; continue; }
                            local dup_s=false
                            for sd2 in "$STORAGE_DIR"/*/; do
                                [[ -d "$sd2" ]] || continue
                                local scid2; scid2=$(basename "$sd2"); [[ "$scid2" == "$sel_scid" ]] && continue
                                [[ "$(_stor_read_name "$scid2")" == "$new_sname" && "$(_stor_read_type "$scid2")" == "$stype2" ]] && dup_s=true && break
                            done
                            [[ "$dup_s" == "true" ]] && { pause "A profile named '$new_sname' already exists for this type."; continue; }
                            _stor_meta_set "$sel_scid" name "$new_sname"
                            pause "Storage renamed to '$new_sname'."; break
                        done ;;
                    "${L[stor_delete]}")
                        confirm "$(printf "Permanently delete storage profile?\n\n  Name: %s\n  ID:   %s\n  Size: %s\n\n  This cannot be undone." \
                            "$pname2" "$sel_scid" "$(du -sh "$STORAGE_DIR/$sel_scid" 2>/dev/null | cut -f1)")" || continue
                        for _cid5 in "${_all_cids[@]}"; do
                            local _d5; _d5=$(_state_get "$_cid5" default_storage_id)
                            [[ "$_d5" == "$sel_scid" ]] && _set_st "$_cid5" default_storage_id '""'
                        done
                        btrfs subvolume delete "$STORAGE_DIR/$sel_scid" &>/dev/null \
                            || sudo -n btrfs subvolume delete "$STORAGE_DIR/$sel_scid" &>/dev/null \
                            || sudo -n rm -rf "$STORAGE_DIR/$sel_scid" 2>/dev/null \
                            || rm -rf "$STORAGE_DIR/$sel_scid" 2>/dev/null
                        [[ -d "$STORAGE_DIR/$sel_scid" ]] \
                            && pause "Could not delete '$pname2' — try stopping all containers first." \
                            || pause "Storage '$pname2' deleted." ;;
                esac ;;
        esac
    done
}
_stor_export_menu() {
    [[ -z "$STORAGE_DIR" || ! -d "$STORAGE_DIR" ]] && { pause "No storage directory found."; return; }
    local sel_entries=() sel_scids=()
    for sdir in "$STORAGE_DIR"/*/; do
        [[ -d "$sdir" ]] || continue
        local scid; scid=$(basename "$sdir")
        local pname; pname=$(_stor_read_name "$scid"); [[ -z "$pname" ]] && pname="(unnamed)"
        local stype; stype=$(_stor_read_type "$scid")
        local ssize; ssize=$(du -sh "$sdir" 2>/dev/null | cut -f1)
        sel_entries+=("$(printf "${DIM} ◈${NC}  %s  ${DIM}(%s)  %s${NC}" "$pname" "${stype:-no type}" "$ssize")")
        sel_scids+=("$scid")
    done
    [[ "${#sel_entries[@]}" -eq 0 ]] && { pause "No storage profiles to export."; return; }

    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${sel_entries[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Export storage ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local chosen_lines; chosen_lines=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 || -z "${chosen_lines}" ]] && return

    local selected_scids=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local lc; lc=$(printf '%s' "$line" | _trim_s)
        for ii in "${!sel_entries[@]}"; do
            local ec; ec=$(printf '%s' "${sel_entries[$ii]}" | _trim_s)
            [[ "$ec" == "$lc" ]] && { selected_scids+=("${sel_scids[$ii]}"); break; }
        done
    done <<< "$chosen_lines"
    [[ "${#selected_scids[@]}" -eq 0 ]] && { pause "No profiles selected."; return; }

    local _confirm_names=""
    for scid in "${selected_scids[@]}"; do
        local _n; _n=$(_stor_read_name "$scid"); [[ -z "$_n" ]] && _n="$scid"
        _confirm_names+="$(printf "\n    ◈  %s" "$_n")"
    done
    confirm "$(printf "Export %d profile(s)?%s" "${#selected_scids[@]}" "$_confirm_names")" || return

    pause "$(printf "Select destination folder.\n\n  Press Enter to open file manager.")"
    local dest_dir; dest_dir=$(_pick_dir) || { pause "No destination selected."; return; }
    [[ ! -d "$dest_dir" ]] && { pause "Selected path is not a directory."; return; }

    local default_fname; default_fname="Data backup $(date '+%Y-%m-%d | %H-%M-%S')"
    local fname dest_path
    while true; do
        finput "$(printf 'Archive filename (without extension):\n  Default: %s' "$default_fname")" || return
        fname="${FINPUT_RESULT}"; [[ -z "$fname" ]] && fname="$default_fname"
        dest_path="$dest_dir/${fname}.tar.zst"
        [[ ! -f "$dest_path" ]] && break
        pause "$(printf "File already exists:\n  %s\n\nPlease choose a different name." "$dest_path")"
    done

    local stor_dirs=()
    for scid in "${selected_scids[@]}"; do stor_dirs+=("$STORAGE_DIR/$scid"); done

    local export_script; export_script=$(mktemp "$TMP_DIR/.sd_export_XXXXXX.sh")
    local ok_flag; ok_flag=$(mktemp -u "$TMP_DIR/.sd_export_ok_XXXXXX")
    {
        printf '#!/usr/bin/env bash\n'
        printf 'OK_FLAG=%q\n' "$ok_flag"
        printf '_finish() {\n  local c=$?\n'
        printf '  [[ $c -eq 0 ]] && touch "$OK_FLAG" && printf "\\n\\033[0;32m══ Export complete ══\\033[0m\\n"\n'
        printf '              || printf "\\n\\033[0;31m══ Export failed ══\\033[0m\\n"\n'
        printf '  tmux list-clients -t sdStorExport 2>/dev/null | grep -q . && { printf "Press Enter to return...\\n"; read -r _; tmux switch-client -t simpleDocker 2>/dev/null || true; }\n'
        printf '  tmux kill-session -t sdStorExport 2>/dev/null || true\n}\n'
        printf 'trap _finish EXIT\n\n'
        printf 'cd %q\n' "$STORAGE_DIR"
        local base_dirs=()
        for d in "${stor_dirs[@]}"; do base_dirs+=("$(basename "$d")"); done
        printf 'printf "Compressing %d profile(s) → %s\\n" %d %q\n' "${#stor_dirs[@]}" "$dest_path" "${#stor_dirs[@]}" "$dest_path"
        printf 'tar --zstd -cf %q' "$dest_path"
        for d in "${base_dirs[@]}"; do printf ' %q' "$d"; done
        printf ' 2>&1\n'
    } > "$export_script"
    chmod +x "$export_script"
    _tmux_launch --post-launch "$ok_flag" "" "sdStorExport" "Exporting storage" "$export_script"
    if [[ -f "$ok_flag" ]]; then rm -f "$ok_flag"; pause "✓ Exported successfully."; fi
}

_stor_import_menu() {
    [[ -z "$STORAGE_DIR" || ! -d "$STORAGE_DIR" ]] && { pause "No storage directory found."; return; }
    pause "$(printf "Select a storage archive (.tar.zst) to import.\n\n  Press Enter to open file manager.")"
    local archive; archive=$(_yazi_pick) || { pause "No file selected."; return; }
    [[ ! -f "$archive" ]] && { pause "File not found: $archive"; return; }

    confirm "$(printf "Import storage from:\n  %s\n\nThis will add new profiles to your storage." "$archive")" || return

    local import_script; import_script=$(mktemp "$TMP_DIR/.sd_import_XXXXXX.sh")
    local ok_flag; ok_flag=$(mktemp -u "$TMP_DIR/.sd_import_ok_XXXXXX")
    {
        printf '#!/usr/bin/env bash\n'
        printf 'STORAGE_DIR=%q\nARCHIVE=%q\nOK_FLAG=%q\n' "$STORAGE_DIR" "$archive" "$ok_flag"
        cat <<'IMPORT_BODY'
_finish() {
  local c=$?
  [[ $c -eq 0 ]] && touch "$OK_FLAG" && printf "\n\033[0;32m══ Import complete ══\033[0m\n" \
                 || printf "\n\033[0;31m══ Import failed ══\033[0m\n"
  tmux list-clients -t sdStorImport 2>/dev/null | grep -q . && { printf "Press Enter to return...\n"; read -r _; tmux switch-client -t simpleDocker 2>/dev/null || true; }
  tmux kill-session -t sdStorImport 2>/dev/null || true
}
trap _finish EXIT
TMPEXTRACT=$(mktemp -d "$STORAGE_DIR/.sd_import_XXXXXX")
printf "Extracting archive...\n"
tar --zstd -xf "$ARCHIVE" -C "$TMPEXTRACT" 2>&1 || exit 1
imported=0
for sdir in "$TMPEXTRACT"/*/; do
    [[ -d "$sdir" ]] || continue
    meta="$sdir/.sd_meta.json"
    orig_name=$(jq -r '.name // empty' "$meta" 2>/dev/null); [[ -z "$orig_name" ]] && orig_name="$(basename "$sdir")"
    stype=$(jq -r '.storage_type // empty' "$meta" 2>/dev/null)
    candidate="$orig_name"; counter=2
    while true; do
        found=false
        for existing in "$STORAGE_DIR"/*/; do
            [[ -f "$existing/.sd_meta.json" ]] || continue
            en=$(jq -r '.name // empty' "$existing/.sd_meta.json" 2>/dev/null)
            et=$(jq -r '.storage_type // empty' "$existing/.sd_meta.json" 2>/dev/null)
            [[ "$en" == "$candidate" && "$et" == "$stype" ]] && { found=true; break; }
        done
        [[ "$found" == "false" ]] && break
        candidate="${orig_name} ${counter}"; counter=$(( counter + 1 ))
    done
    while true; do
        new_scid=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
        [[ ! -d "$STORAGE_DIR/$new_scid" ]] && break
    done
    dest="$STORAGE_DIR/$new_scid"
    if cp -a "$sdir" "$dest"; then
        jq --arg n "$candidate" '.name=$n | .active_container=""' "$dest/.sd_meta.json" > "$dest/.sd_meta.json.tmp" \
            && mv "$dest/.sd_meta.json.tmp" "$dest/.sd_meta.json" || true
        echo "[+] Imported: ${orig_name} -> ${candidate} [${new_scid}]"
        imported=$(( imported + 1 ))
    else
        echo "[!] Failed to copy: $sdir"
    fi
done
rm -rf "$TMPEXTRACT"
echo "[+] Imported ${imported} profile(s)."
IMPORT_BODY
    } > "$import_script"
    chmod +x "$import_script"
    _tmux_launch --post-launch "$ok_flag" "" "sdStorImport" "Importing storage" "$import_script"
    if [[ -f "$ok_flag" ]]; then rm -f "$ok_flag"; pause "✓ Imported successfully."; fi
}


_blueprint_template() {
    printf '%s\n' "$SD_BLUEPRINT_PRESET"
}

_list_blueprint_names() {
    for f in "$BLUEPRINTS_DIR"/*.toml "$BLUEPRINTS_DIR"/*.json; do
        [[ -f "$f" ]] && basename "${f%.*}"
    done | sort -u
}

_blueprint_submenu() {
    local bname="$1" bfile; bfile=$(_bp_path "$bname")
    while true; do
        _menu "Blueprint: $bname" "${L[bp_edit]}" "${L[bp_rename]}" "${L[bp_delete]}"
        case $? in 2) continue ;; 0) ;; *) return ;; esac
        case "$REPLY" in
            "${L[bp_edit]}")
                _guard_space || continue
                ${EDITOR:-vi} "$bfile" ;;
            "${L[bp_rename]}")
                while true; do
                    finput "New name for blueprint '$bname':" || break
                    local new_bname; new_bname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"
                    [[ -z "$new_bname" ]] && { pause "Name cannot be empty."; continue; }
                    local ext="${bfile##*.}"
                    local new_bfile="$BLUEPRINTS_DIR/$new_bname.$ext"
                    [[ -f "$new_bfile" ]] && { pause "Blueprint '$new_bname' already exists."; continue; }
                    mv "$bfile" "$new_bfile" 2>/dev/null || { pause "Could not rename."; break; }
                    pause "Blueprint renamed to '$new_bname'."; return
                done ;;
            "${L[bp_delete]}")
                confirm "$(printf "Delete blueprint '%s'?\nThis cannot be undone." "$bname")" || continue
                rm -f "$bfile" 2>/dev/null || { pause "Could not delete."; continue; }
                pause "Blueprint '$bname' deleted."; return ;;
        esac
    done
}

_UPD_FILES=(); _UPD_NAMES=(); _UPD_VERS=(); _UPD_SRCS=(); _UPD_ISTMP=()
_UPD_ITEMS=(); _UPD_IDX=()

_get_bp_storage_type() {
    local file="$1"
    if _bp_is_json "$file"; then
        jq -r '.meta.storage_type // empty' "$file" 2>/dev/null
    else
        grep -m1 '^storage_type[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//'
    fi
}
_get_bp_version() {
    local file="$1"
    if _bp_is_json "$file"; then
        jq -r '.meta.version // empty' "$file" 2>/dev/null
    else
        grep -m1 '^version[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//'
    fi
}

_collect_bps_by_type() {
    local stype="$1"
    _UPD_FILES=(); _UPD_NAMES=(); _UPD_VERS=(); _UPD_SRCS=(); _UPD_ISTMP=()
    for f in "$BLUEPRINTS_DIR"/*.toml "$BLUEPRINTS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        local t; t=$(_get_bp_storage_type "$f"); [[ "$t" != "$stype" ]] && continue
        local v; v=$(_get_bp_version "$f")
        _UPD_FILES+=("$f"); _UPD_NAMES+=("$(basename "${f%.*}")"); _UPD_VERS+=("$v"); _UPD_SRCS+=("Blueprint"); _UPD_ISTMP+=(false)
    done
    local pname
    while IFS= read -r pname; do
        local raw; raw=$(_get_persistent_bp "$pname"); [[ -z "$raw" ]] && continue
        local tmp; tmp=$(mktemp "$TMP_DIR/.sd_upd_XXXXXX.toml")
        printf '%s\n' "$raw" > "$tmp"
        local t; t=$(_get_bp_storage_type "$tmp")
        if [[ "$t" != "$stype" ]]; then rm -f "$tmp"; continue; fi
        local v; v=$(_get_bp_version "$tmp")
        _UPD_FILES+=("$tmp"); _UPD_NAMES+=("$pname"); _UPD_VERS+=("$v"); _UPD_SRCS+=("Persistent"); _UPD_ISTMP+=(true)
    done < <(_list_persistent_names)
}

_cleanup_upd_tmps() {
    for i in "${!_UPD_ISTMP[@]}"; do
        [[ "${_UPD_ISTMP[$i]}" == true && -f "${_UPD_FILES[$i]}" ]] && rm -f "${_UPD_FILES[$i]}"
    done
    _UPD_FILES=(); _UPD_NAMES=(); _UPD_VERS=(); _UPD_SRCS=(); _UPD_ISTMP=()
}

_write_pkg_manifest() {
    local cid="$1" sj="$CONTAINERS_DIR/$cid/service.json" mf="$CONTAINERS_DIR/$cid/pkg_manifest.json"
    local deps pip gh dep_arr="[]" pip_arr="[]" gh_arr="[]"
    deps=$(jq -r '.deps // empty' "$sj" 2>/dev/null)
    pip=$(jq -r '.pip // empty' "$sj" 2>/dev/null)
    gh=$(jq -r '.git // empty' "$sj" 2>/dev/null)
    if [[ -n "$deps" ]]; then
        _deps_parse_split "$deps"
        dep_arr=$(printf '%s\n' $SD_APK_PKGS | jq -R . | jq -s . 2>/dev/null || echo "[]")
    fi
    [[ -n "$pip" ]] && pip_arr=$(printf '%s' "$pip" | tr ',' '\n' | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo "[]")
    if [[ -n "$gh" ]]; then
        gh_arr=$(while IFS= read -r l; do
            l=$(printf '%s' "$l" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$l" ]] && continue
            [[ "$l" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*=[[:space:]]*(.*) ]] && l="${BASH_REMATCH[1]}"
            printf '%s\n' "$(printf '%s' "$l" | awk '{print $1}')"
        done <<< "$gh" | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo "[]")
    fi
    local npm npm_arr="[]"
    npm=$(jq -r '.npm // empty' "$sj" 2>/dev/null)
    [[ -n "$npm" ]] && npm_arr=$(printf '%s' "$npm" | tr ',' '
' | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo "[]")
    jq -n --argjson d "$dep_arr" --argjson p "$pip_arr" --argjson n "$npm_arr" --argjson g "$gh_arr" \
        --arg ts "$(date '+%Y-%m-%d %H:%M')" '{deps:$d,pip:$p,npm:$n,git:$g,updated:$ts}' > "$mf" 2>/dev/null || true
}

_build_pkg_update_item() {
    local cid="$1" mf="$CONTAINERS_DIR/$cid/pkg_manifest.json"
    [[ ! -f "$mf" ]] && return
    local n; n=$(jq -r '(.deps|length)+(.pip|length)+(.npm|length)+(.git|length)' "$mf" 2>/dev/null)
    [[ "${n:-0}" -eq 0 ]] && return
    local ts; ts=$(jq -r '.updated // empty' "$mf" 2>/dev/null)
    local has_upd=0
    local cache="$CACHE_DIR/gh_tag/$cid" inst="$CACHE_DIR/gh_tag/$cid.inst"
    local age=9999
    [[ -f "$cache" ]] && age=$(( $(date +%s) - $(date -r "$cache" +%s 2>/dev/null || echo 0) ))
    if [[ $age -gt 3600 ]]; then
        local _gh_out; _gh_out=$(jq -r '.git[]' "$mf" 2>/dev/null | while IFS= read -r repo; do
            curl -fsSL --max-time 6 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
                | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4
        done)
        [[ -n "$_gh_out" ]] && printf '%s\n' "$_gh_out" > "$cache"
    fi
    if [[ -f "$cache" && -f "$inst" ]]; then
        [[ "$(cat "$cache")" != "$(cat "$inst")" ]] && has_upd=1
    elif [[ -f "$cache" && -s "$cache" ]]; then
        has_upd=1
    fi
    local entry
    if [[ $has_upd -eq 1 ]]; then
        entry="$(printf "${DIM}[P]${NC} Packages ${DIM}— %s${NC} — ${YLW}Update available${NC}" "${ts:-never}")"
    else
        entry="$(printf "${DIM}[P]${NC} Packages ${DIM}— ✓ %s${NC}" "${ts:-never}")"
    fi
    _UPD_ITEMS=("$entry" "${_UPD_ITEMS[@]}")
    _UPD_IDX=("__pkgs__" "${_UPD_IDX[@]}")
}

_do_pkg_update() {
    local cid="$1" mf="$CONTAINERS_DIR/$cid/pkg_manifest.json"
    local install_path; install_path=$(_cpath "$cid")
    [[ ! -f "$mf" ]] && { pause "No manifest. Reinstall first."; return; }
    local dep_pkgs pip_pkgs npm_pkgs gh_repos
    dep_pkgs=$(jq -r '.deps|join(" ")' "$mf" 2>/dev/null)
    pip_pkgs=$(jq -r '.pip|join(" ")' "$mf" 2>/dev/null)
    npm_pkgs=$(jq -r '.npm|join(" ")' "$mf" 2>/dev/null)
    gh_repos=$(jq -r '.git[]' "$mf" 2>/dev/null)
    [[ -z "$dep_pkgs" && -z "$pip_pkgs" && -z "$npm_pkgs" && -z "$gh_repos" ]] && { pause "Nothing to update."; return; }
    local _um=""; [[ -n "$dep_pkgs" ]] && _um+="$(printf "  apt: %s\n" "$dep_pkgs")"
    [[ -n "$pip_pkgs" ]] && _um+="$(printf "  pip: %s\n" "$pip_pkgs")"
    [[ -n "$npm_pkgs" ]] && _um+="$(printf "  npm: %s\n" "$npm_pkgs")"
    [[ -n "$gh_repos" ]] && _um+="  git: $(printf '%s' "$gh_repos" | tr '\n' ' ')"
    confirm "$(printf "Update packages for '%s'?\n\n%s" "$(_cname "$cid")" "$_um")" || return
    local ok="$CONTAINERS_DIR/$cid/.install_ok" fail="$CONTAINERS_DIR/$cid/.install_fail"
    rm -f "$ok" "$fail"
    local scr; scr=$(mktemp "$TMP_DIR/.sd_pkgupd_XXXXXX.sh")
    local arch; [[ "$(uname -m)" == "aarch64" ]] && arch=arm64 || arch=amd64
    local _sd_cfn='_chroot_bash() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }'
    local ok_q fail_q; ok_q=$(printf '%q' "$ok"); fail_q=$(printf '%q' "$fail")
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$_sd_cfn"
        printf '_finish() { local c=$?; [[ $c -eq 0 ]] && touch %s || touch %s; }\n' "$ok_q" "$fail_q"
        printf 'trap _finish EXIT\n'
        printf 'trap '"'"'touch %s; exit 130'"'"' INT TERM\n\n' "$fail_q"
        printf '_mnt_ubuntu() { sudo -n mount --bind /proc %q/proc; sudo -n mount --bind /sys %q/sys; sudo -n mount --bind /dev %q/dev; }\n' \
            "$UBUNTU_DIR" "$UBUNTU_DIR" "$UBUNTU_DIR"
        printf '_umnt_ubuntu() { sudo -n umount -lf %q/dev %q/sys %q/proc 2>/dev/null||true; }\n' \
            "$UBUNTU_DIR" "$UBUNTU_DIR" "$UBUNTU_DIR"


        if [[ -n "$dep_pkgs" && -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
            printf 'printf "\033[1m[apt] Upgrading: %s\033[0m\n"\n' "$dep_pkgs"
            printf '_mnt_ubuntu\n'
            printf '_sd_apt_upd=$(mktemp %q/../.sd_aptupd_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_aptupd_%s.sh)\n' "$UBUNTU_DIR" "$$"
            printf 'printf '"'"'#!/bin/sh\nset -e\napt-get update -qq\nDEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade %s 2>&1\n'"'"' > "$_sd_apt_upd"\n' "$dep_pkgs"
            printf 'chmod +x "$_sd_apt_upd"\n'
            printf 'sudo -n mount --bind "$_sd_apt_upd" %q/tmp/.sd_aptupd_run.sh 2>/dev/null || cp "$_sd_apt_upd" %q/tmp/.sd_aptupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
            printf '_chroot_bash %q /tmp/.sd_aptupd_run.sh\n' "$UBUNTU_DIR"
            printf 'sudo -n umount -lf %q/tmp/.sd_aptupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf 'rm -f "$_sd_apt_upd" %q/tmp/.sd_aptupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf '_umnt_ubuntu\n\n'
        fi

        if [[ -n "$pip_pkgs" && -f "$install_path/venv/bin/pip" ]]; then
            printf 'printf "\033[1m[pip] Upgrading: %s\033[0m\n"\n' "$pip_pkgs"
            printf '_mnt_ubuntu\n'
            printf 'sudo -n mount --bind %q %q/mnt\n' "$install_path" "$UBUNTU_DIR"
            printf '_sd_pip_upd=$(mktemp %q/../.sd_pipupd_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_pipupd_%s.sh)\n' "$UBUNTU_DIR" "$$"
            printf 'printf '"'"'#!/bin/sh\nset -e\n/mnt/venv/bin/pip install --upgrade %s 2>&1\n'"'"' > "$_sd_pip_upd"\n' "$pip_pkgs"
            printf 'chmod +x "$_sd_pip_upd"\n'
            printf 'sudo -n mount --bind "$_sd_pip_upd" %q/tmp/.sd_pipupd_run.sh 2>/dev/null || cp "$_sd_pip_upd" %q/tmp/.sd_pipupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
            printf '_chroot_bash %q /tmp/.sd_pipupd_run.sh\n' "$UBUNTU_DIR"
            printf 'sudo -n umount -lf %q/tmp/.sd_pipupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf 'sudo -n umount -lf %q/mnt 2>/dev/null||true\n' "$UBUNTU_DIR"
            printf 'rm -f "$_sd_pip_upd" %q/tmp/.sd_pipupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf '_umnt_ubuntu\n\n'
        fi

        if [[ -n "$npm_pkgs" && -d "$install_path/node_modules" ]]; then
            printf 'printf "\033[1m[npm] Upgrading: %s\033[0m\n"\n' "$npm_pkgs"
            printf '_mnt_ubuntu\n'
            printf 'sudo -n mount --bind %q %q/mnt\n' "$install_path" "$UBUNTU_DIR"
            printf '_sd_npm_upd=$(mktemp %q/../.sd_npmupd_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_npmupd_%s.sh)\n' "$UBUNTU_DIR" "$$"
            printf 'printf '"'"'#!/bin/sh\nset -e\ncd /mnt && npm update %s 2>&1\n'"'"' > "$_sd_npm_upd"\n' "$npm_pkgs"
            printf 'chmod +x "$_sd_npm_upd"\n'
            printf 'sudo -n mount --bind "$_sd_npm_upd" %q/tmp/.sd_npmupd_run.sh 2>/dev/null || cp "$_sd_npm_upd" %q/tmp/.sd_npmupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
            printf '_chroot_bash %q /tmp/.sd_npmupd_run.sh\n' "$UBUNTU_DIR"
            printf 'sudo -n umount -lf %q/tmp/.sd_npmupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf 'sudo -n umount -lf %q/mnt 2>/dev/null||true\n' "$UBUNTU_DIR"
            printf 'rm -f "$_sd_npm_upd" %q/tmp/.sd_npmupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf 'sudo -n chown -R %q %q/node_modules 2>/dev/null || true\n' "${_me2}:" "$install_path"
            printf '_umnt_ubuntu\n\n'
        fi

        if [[ -n "$gh_repos" ]]; then
            printf 'printf "\033[1m[git] Checking releases\xe2\x80\xa6\033[0m\n"\n'
            printf '_SD_ARCH=%q\n_SD_INSTALL=%q\n' "$arch" "$install_path"
            local inst_f; inst_f=$(printf '%q' "$CACHE_DIR/gh_tag/$cid.inst")
            printf '_new_tags=""\n'
            cat <<'HELPERS'
_sd_ltag(){ curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4; }
_sd_burl(){ local r=$1 a=$2 rel urls u
    rel=$(curl -fsSL "https://api.github.com/repos/$r/releases/latest" 2>/dev/null)
    urls=$(printf '%s' "$rel" | grep -o '"browser_download_url":"[^"]*"' \
        | grep -ivE 'sha256|\.sig|\.txt|\.json|rocm' | grep -o 'https://[^"]*')
    u=$(printf '%s\n' "$urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$' \
        | grep -iE "linux.*$a|$a.*linux" | head -1)
    [[ -z "$u" ]] && u=$(printf '%s\n' "$urls" | grep -iE "$a" | head -1)
    printf '%s' "$u"; }
_sd_xauto(){ local u=$1 d=$2; mkdir -p "$d"
    local t; t=$(mktemp "$d/.dl_X")
    curl -fL --progress-bar --retry 3 -C - "$u" -o "$t" || { rm -f "$t"; return 1; }
    if   [[ "$u" =~ \.(tar\.(gz|bz2|xz|zst)|tgz)$ ]]; then
        tar -xa -C "$d" --strip-components=1 -f "$t" 2>/dev/null \
            || tar -xa -C "$d" -f "$t" 2>/dev/null
    elif [[ "$u" =~ \.zip$ ]]; then unzip -o -d "$d" "$t" 2>/dev/null
    else mkdir -p "$d/bin"
        mv "$t" "$d/bin/$(basename "$u" | sed 's/[?#].*//')"; chmod +x "$d/bin/"*; return
    fi; rm -f "$t"; }
HELPERS
            while IFS= read -r repo; do
                [[ -z "$repo" ]] && continue
                local _inst_tag_q; _inst_tag_q=$(printf '%q' "$CACHE_DIR/gh_tag/$cid.inst")
                printf 'printf "  checking %s\\n" %q\n' "$repo" "$repo"
                printf '_latest=$(_sd_ltag %q)\n' "$repo"
                printf '_inst=$(grep -x %q %s 2>/dev/null | head -1 || true)\n' "$repo" "$_inst_tag_q"
                printf 'if [[ -z "$_latest" ]]; then printf "  [!] could not fetch tag for %s, skipping\n"; \n' "$repo"
                printf 'elif [[ "$_latest" == "$_inst" ]]; then\n'
                printf '    printf "  \033[2m✓ %s already at %%s\033[0m\n" "$_latest"\n' "$repo"
                printf 'else\n'
                printf '    printf "  \033[1m%s: %%s → %%s\033[0m\n" "${_inst:-(unknown)}" "$_latest"\n' "$repo"
                printf '    _url=$(_sd_burl %q "$_SD_ARCH")\n' "$repo"
                printf '    if [[ -n "$_url" ]]; then\n'
                printf '        _sd_xauto "$_url" "$_SD_INSTALL" && printf "  \033[0;32m✓ updated %%s\033[0m\n" "$_latest"\n'
                printf '    else printf "  [!] no release asset found for %s\n"; fi\n' "$repo"
                printf 'fi\n'
                printf '_new_tags="${_new_tags}${_latest}\n"\n'
            done <<< "$gh_repos"
            printf 'printf "%%s" "$_new_tags" > %s\n' "$inst_f"
        fi

        printf 'jq --arg t "$(date '"'"'+%%Y-%%m-%%d %%H:%%M'"'"')" '"'"'.updated=$t'"'"' %q > %q.tmp && mv %q.tmp %q\n' \
            "$mf" "$mf" "$mf" "$mf"
        printf 'printf "\n\033[0;32m══ Package update complete ══\033[0m\n"\n'
    } > "$scr"
    chmod +x "$scr"
    _tmux_set SD_INSTALLING "$cid"
    local _pu_sess; _pu_sess=$(_inst_sess "$cid")
    tmux kill-session -t "$_pu_sess" 2>/dev/null || true
    _tmux_launch "$_pu_sess" "Pkg update: $(_cname "$cid")" "$scr"
    [[ $? -eq 1 ]] && { rm -f "$scr"; _tmux_set SD_INSTALLING ""; return; }
    rm -f "$CACHE_DIR/gh_tag/$cid"
}

_ct_ubuntu_stamp() { cat "${1}/.sd_ubuntu_stamp" 2>/dev/null; }

_ct_ubuntu_ver() {
    local p="$1"
    grep -m1 '^VERSION_ID=' "${p}/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"'
}

_build_ubuntu_update_item() {
    local cid="$1"
    local install_path; install_path=$(_cpath "$cid")
    [[ -z "$install_path" || ! -d "$install_path" ]] && return

    local entry
    if [[ ! -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
        entry="$(printf "${DIM}[U]${NC} Ubuntu base ${DIM}—${NC} ${YLW}Not installed${NC}")"
    else
        local ct_stamp;   ct_stamp=$(_ct_ubuntu_stamp "$install_path")
        local base_stamp; base_stamp=$(_ct_ubuntu_stamp "$UBUNTU_DIR")
        local ct_ver;     ct_ver=$(_ct_ubuntu_ver "$UBUNTU_DIR")
        [[ -z "$ct_ver" ]] && ct_ver="unknown"
        if [[ -z "$base_stamp" || ( -n "$ct_stamp" && "$ct_stamp" == "$base_stamp" ) ]]; then
            entry="$(printf "${DIM}[U]${NC} Ubuntu base ${DIM}— ✓ %s${NC}" "$ct_ver")"
        else
            entry="$(printf "${DIM}[U]${NC} Ubuntu base — ${YLW}%s — Update available${NC}" "$ct_ver")"
        fi
    fi
    _UPD_ITEMS+=("$entry")
    _UPD_IDX+=("__ubuntu__")
}

_do_ubuntu_update() {
    local cid="$1" name; name=$(_cname "$cid")
    local base_ver; base_ver=$(_ct_ubuntu_ver "$UBUNTU_DIR")

    confirm "$(printf "Update Ubuntu base for '%s'?\n\n  Base : %s" "$name" "$base_ver")" || return

    local snap_label="Update-${base_ver//[ .]/-}"
    if confirm "$(printf "Create a backup first?\n\n  Will appear in Backups as '%s'." "$snap_label")"; then
        local sdir; sdir=$(_snap_dir "$cid")
        local install_path; install_path=$(_cpath "$cid")
        mkdir -p "$sdir" 2>/dev/null
        local snap_id="$snap_label" n=1
        while [[ -d "$sdir/$snap_id" ]]; do snap_id="${snap_label}-$n"; (( n++ )); done
        if btrfs subvolume snapshot -r "$install_path" "$sdir/$snap_id" &>/dev/null \
            || cp -a "$install_path" "$sdir/$snap_id" 2>/dev/null; then
            _snap_meta_set "$sdir" "$snap_id" "type=manual" "ts=$(date '+%Y-%m-%d %H:%M')"
            pause "$(printf "✓ Backup '%s' created." "$snap_id")"
        else
            confirm "⚠  Backup failed. Continue anyway?" || return
        fi
    fi

    local apt_cmd="apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y 2>&1"
    _ubuntu_pkg_tmux "sdUbuntuCtUpd" "Ubuntu update — $name" "$apt_cmd"
    date '+%Y-%m-%d' > "$UBUNTU_DIR/.sd_ubuntu_stamp" 2>/dev/null || true
    local _up; _up=$(_cpath "$cid")
    [[ -n "$_up" ]] && cp "$UBUNTU_DIR/.sd_ubuntu_stamp" "$_up/.sd_ubuntu_stamp" 2>/dev/null || true
}

_build_update_items() {
    local cid="$1"; _UPD_ITEMS=(); _UPD_IDX=()
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local stype; stype=$(jq -r '.meta.storage_type // empty' "$sj" 2>/dev/null)
    local cur_ver; cur_ver=$(jq -r '.meta.version // empty' "$sj" 2>/dev/null)
    local cur_src="$CONTAINERS_DIR/$cid/service.src"
    [[ -z "$stype" ]] && return
    _collect_bps_by_type "$stype"; [[ ${#_UPD_FILES[@]} -eq 0 ]] && return
    for i in "${!_UPD_FILES[@]}"; do
        local nv="${_UPD_VERS[$i]}" src="${_UPD_SRCS[$i]}" bn="${_UPD_NAMES[$i]}"
        local stag; [[ "$src" == Persistent ]] && stag="${BLU}[P]${NC}" || stag="${DIM}[B]${NC}"
        local entry
        if [[ "$cur_ver" == "$nv" ]]; then
            local has_diff=0
            [[ -f "$cur_src" && -f "${_UPD_FILES[$i]}" ]] &&                 diff -q "$cur_src" "${_UPD_FILES[$i]}" >/dev/null 2>&1 || has_diff=1
            if [[ $has_diff -eq 1 && -f "$cur_src" && -f "${_UPD_FILES[$i]}" ]]; then
                local _vs=""; [[ -n "$cur_ver" ]] && _vs="  ${DIM}v${cur_ver}${NC}"
                entry="$(printf "%b %s ${DIM}%s${NC} — ${YLW}Changes detected${NC}%b" "$stag" "$bn" "$src" "$_vs")"
            else
                local _vs2=""; [[ -n "$cur_ver" ]] && _vs2=" ${cur_ver}"
                entry="$(printf "%b %s ${DIM}%s — ✓%s${NC}" "$stag" "$bn" "$src" "$_vs2")"
            fi
        else
            local _cv=""; [[ -n "$cur_ver" ]] && _cv="$cur_ver" || _cv="?"
            entry="$(printf "%b %s ${DIM}%s${NC} — ${YLW}%s${NC} → ${GRN}%s${NC}" "$stag" "$bn" "$src" "$_cv" "${nv:-?}")"
        fi
        _UPD_ITEMS+=("$entry"); _UPD_IDX+=("$i")
    done
}

_do_blueprint_update() {
    local cid="$1" idx="$2"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local cur_ver; cur_ver=$(jq -r '.meta.version // empty' "$sj" 2>/dev/null)
    local bp_file="${_UPD_FILES[$idx]}" new_ver="${_UPD_VERS[$idx]}" bname="${_UPD_NAMES[$idx]}" src="${_UPD_SRCS[$idx]}"
    local cur_src="$CONTAINERS_DIR/$cid/service.src"
    if [[ "$cur_ver" == "$new_ver" ]]; then
        local has_diff=0
        if [[ -f "$cur_src" && -f "$bp_file" ]]; then
            diff -q "$cur_src" "$bp_file" >/dev/null 2>&1 || has_diff=1
        fi
        if [[ $has_diff -eq 0 ]]; then
            pause "$(printf "Nothing to do — '%s' is already up to date\n  (version %s, configuration unchanged)." "$bname" "${cur_ver:-?}")"
            return
        fi
        confirm "$(printf "Changes detected in '%s' (version %s unchanged).\n\n  Blueprint : %s\n  Apply configuration changes?"             "$(_cname "$cid")" "${cur_ver:-?}" "$bname")" || return
        cp "$bp_file" "$cur_src"
        if _compile_service "$cid"; then
            [[ "$(jq -r '.meta.installed // false' "$sj" 2>/dev/null)" == "true" ]] && _build_start_script "$cid" 2>/dev/null || true
            pause "$(printf "Configuration updated for '%s' (version %s)." "$(_cname "$cid")" "${cur_ver:-?}")"
        else
            pause "⚠  Update applied but compile had errors. Check Edit configuration."
        fi
        return
    fi
    confirm "$(printf "Update '%s' from %s?\n\n  Blueprint : %s\n  Version   : %s → %s" \
        "$(_cname "$cid")" "$src" "$bname" "${cur_ver:-?}" "${new_ver:-?}")" || return
    cp "$bp_file" "$CONTAINERS_DIR/$cid/service.src"
    if _compile_service "$cid"; then
        [[ "$(jq -r '.meta.installed // false' "$sj" 2>/dev/null)" == "true" ]] && _build_start_script "$cid" 2>/dev/null || true
        pause "$(printf "'%s' updated to %s." "$(_cname "$cid")" "${new_ver:-?}")"
    else
        pause "⚠  Update applied but compile had errors. Check Edit configuration."
    fi
}

_installing_menu() {
    local cid="$1" header="$2"; shift 2
    local ok_file="$CONTAINERS_DIR/$cid/.install_ok"
    local fail_file="$CONTAINERS_DIR/$cid/.install_fail"
    local lines=()
    for x in "$@"; do
        printf '%s' "$x" | grep -q $'\033' && lines+=("$x") || lines+=("$(printf "${DIM} %s${NC}" "$x")")
    done
    local _nav; _nav="$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"
    lines+=("$_nav" "$(printf "${DIM} %s${NC}" "${L[back]}")")
    local _fzf_out; _fzf_out=$(mktemp "$TMP_DIR/.sd_fzfout_XXXXXX")
    local _wflag;   _wflag=$(mktemp -u "$TMP_DIR/.sd_wflag_XXXXXX")
    local _wpid=""
    printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$header" >"$_fzf_out" 2>/dev/null &
    local _fzf_pid=$!
    if [[ ! -f "$ok_file" && ! -f "$fail_file" ]]; then
        { while [[ ! -f "$ok_file" && ! -f "$fail_file" ]]; do sleep 0.3; done
          touch "$_wflag"; kill "$_fzf_pid" 2>/dev/null
        } &
        _wpid=$!
    fi
    wait "$_fzf_pid" 2>/dev/null
    [[ -n "$_wpid" ]] && { kill "$_wpid" 2>/dev/null; wait "$_wpid" 2>/dev/null; }
    if [[ -f "$_wflag" ]]; then
        rm -f "$_wflag" "$_fzf_out"
        stty sane 2>/dev/null
        return 2
    fi
    REPLY=$(cat "$_fzf_out" 2>/dev/null | _trim_s)
    rm -f "$_fzf_out"
    [[ -z "$REPLY" || "$REPLY" == "${L[back]}" ]] && return 1
    return 0
}

_process_install_finish() {
    local cid="$1" name; name=$(_cname "$cid")
    local ok_file="$CONTAINERS_DIR/$cid/.install_ok"
    local fail_file="$CONTAINERS_DIR/$cid/.install_fail"
    tmux kill-session -t "$(_inst_sess "$cid")" 2>/dev/null || true; _tmux_set SD_INSTALLING ""
    if [[ -f "$ok_file" ]]; then
        local _ok_age; _ok_age=$(( $(date +%s) - $(date -r "$ok_file" +%s 2>/dev/null || echo 0) ))
        if [[ "$_ok_age" -gt 600 ]] && ! tmux_up "$(_inst_sess "$cid")"; then
            rm -f "$ok_file"; pause "⚠  Installation result is stale. Please reinstall."; return
        fi
        rm -f "$ok_file"
        if [[ "$(_st "$cid" installed)" == "true" ]]; then
            _write_pkg_manifest "$cid"
            pause "$(printf "'%s' packages updated." "$name")"
            return
        fi
        _set_st "$cid" installed true
        _write_pkg_manifest "$cid"
        local _ipath; _ipath=$(_cpath "$cid")
        [[ -n "$_ipath" && -f "$UBUNTU_DIR/.sd_ubuntu_stamp" ]] && cp "$UBUNTU_DIR/.sd_ubuntu_stamp" "$_ipath/.sd_ubuntu_stamp" 2>/dev/null || true
        if confirm "$(printf "'%s' ${L[msg_install_ok]}\n\nCreate a Post-Install backup?\n  (Instant revert to clean install)" "$name")"; then
            local _pi_sdir; _pi_sdir=$(_snap_dir "$cid"); mkdir -p "$_pi_sdir" 2>/dev/null
            local _pi_id="Post-Installation" _pi_path; _pi_path=$(_cpath "$cid")
            local _pi_ts; _pi_ts=$(date '+%Y-%m-%d %H:%M')
            [[ -d "$_pi_sdir/$_pi_id" ]] && _delete_backup "$_pi_sdir" "$_pi_id"
            if btrfs subvolume snapshot -r "$_pi_path" "$_pi_sdir/$_pi_id" &>/dev/null; then
                _snap_meta_set "$_pi_sdir" "$_pi_id" "type=manual" "ts=$_pi_ts"
                pause "$(printf "Backup 'Post-Installation' created for '%s'." "$name")"
            else
                cp -a "$_pi_path" "$_pi_sdir/$_pi_id" 2>/dev/null \
                    && _snap_meta_set "$_pi_sdir" "$_pi_id" "type=manual" "ts=$_pi_ts" \
                    && pause "$(printf "Backup 'Post-Installation' created for '%s'." "$name")" \
                    || pause "$(printf "Backup failed for '%s' — disk full?" "$name")"
            fi
        else
            pause "'$name' ${L[msg_install_ok]}"
        fi
    elif [[ -f "$fail_file" ]]; then
        rm -f "$fail_file"; pause "${L[msg_install_fail]}"
    fi
    _update_size_cache "$cid"
}

_tmux_launch() {
    local _no_prompt=false _post_ok="" _post_fail=""
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --no-prompt)   _no_prompt=true; shift ;;
            --post-launch) _post_ok="$2" _post_fail="$3"; shift 3 ;;
            *) shift ;;
        esac
    done
    local sess="$1" title="$2" script="$3"
    local _logfile="" _logcmd=""
    if [[ -n "$LOGS_DIR" ]]; then
        _logfile="$LOGS_DIR/${sess}-$(date '+%Y%m%d_%H%M%S').log"
        mkdir -p "$LOGS_DIR" 2>/dev/null || true
        _logcmd=" 2>&1 | tee $(printf '%q' "$_logfile")"
    fi

    if [[ "$_no_prompt" == "true" ]]; then
        tmux kill-session -t "$sess" 2>/dev/null || true
        tmux new-session -d -s "$sess" "bash $(printf '%q' "$script")${_logcmd}; rm -f $(printf '%q' "$script")" 2>/dev/null
        tmux switch-client -t "$sess" 2>/dev/null || true
        sleep 0.1; stty sane 2>/dev/null
        while IFS= read -r -t 0 -n 256 _ 2>/dev/null; do :; done
        return 0
    fi

    local _fzf_out; _fzf_out=$(mktemp "$TMP_DIR/.sd_launch_fzf_XXXXXX")
    printf '%s\n%s\n' \
        "$(printf "${GRN}▶  Attach — follow live output${NC}")" \
        "$(printf "${DIM}   Background — run silently${NC}")" \
        | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}── %s ──${NC}\n${DIM}  Press %s to detach at any time without stopping.${NC}" \
                "$title" "${KB[tmux_detach]}")" \
            >"$_fzf_out" 2>/dev/null
    local _rc=$?
    local choice; choice=$(cat "$_fzf_out" 2>/dev/null | _trim_s)
    rm -f "$_fzf_out"
    [[ $_rc -ne 0 || -z "$choice" ]] && return 1

    tmux kill-session -t "$sess" 2>/dev/null || true
    tmux new-session -d -s "$sess" "bash $(printf '%q' "$script")${_logcmd}; rm -f $(printf '%q' "$script")" 2>/dev/null
    tmux set-option -t "$sess" detach-on-destroy off 2>/dev/null || true

    if printf '%s' "$choice" | grep -qi "attach"; then
        tmux switch-client -t "$sess" 2>/dev/null || true
        sleep 0.2; stty sane 2>/dev/null
        while IFS= read -r -t 0.2 -n 256 _ 2>/dev/null; do :; done
        tput reset 2>/dev/null || clear
    else
        sleep 0.1; stty sane 2>/dev/null
        while IFS= read -r -t 0.15 -n 256 _ 2>/dev/null; do :; done
        { while tmux_up "$sess" 2>/dev/null; do sleep 0.3; done
          kill -USR1 "$SD_SHELL_PID" 2>/dev/null || true
        } &
        disown
    fi
    return 0
}

_tmux_attach_hint() {
    local label="$1" sess="$2"
    confirm "$(printf "Attach to '%s'\n\n  Press %s to detach without stopping." "$label" "${KB[tmux_detach]}")" || return 0
    tmux switch-client -t "$sess" 2>/dev/null || true
    sleep 0.1; stty sane 2>/dev/null
    while IFS= read -r -t 0 -n 256 _ 2>/dev/null; do :; done
}

_open_in_submenu() {
    local cid="$1"; local name; name=$(_cname "$cid")
    local is_running=false; tmux_up "$(tsess "$cid")" && is_running=true
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local svc_port; svc_port=$(jq -r '.meta.port // 0' "$sj" 2>/dev/null); svc_port="${svc_port:-0}"
    local env_port; env_port=$(jq -r '.environment.PORT // empty' "$sj" 2>/dev/null)
    [[ -n "$env_port" ]] && svc_port="$env_port"
    local install_path; install_path=$(_cpath "$cid")

    _open_in_best_url() {
        local _cid="$1" _port="$2"
        local _route_url _https
        _route_url=$(jq -r --arg c "$_cid" '.routes[] | select(.cid==$c) | .url' "$(_proxy_cfg)" 2>/dev/null | head -1)
        if [[ -n "$_route_url" ]]; then
            _https=$(jq -r --arg c "$_cid" '.routes[] | select(.cid==$c) | (.https // "false")' "$(_proxy_cfg)" 2>/dev/null | head -1)
            [[ "$_https" == "true" ]] && printf 'https://%s' "$_route_url" || printf 'http://%s' "$_route_url"
        else
            printf 'http://localhost:%s' "$_port"
        fi
    }

    while true; do
        local opts=()
        [[ "$svc_port" != "0" && -n "$svc_port" ]] && opts+=("⊕  Browser")
        [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && _chroot_bash "$UBUNTU_DIR" -c 'command -v qrencode' >/dev/null 2>&1 \
            && [[ "$svc_port" != "0" && -n "$svc_port" ]] && opts+=("⊞  Show QR code")
        opts+=("◧  File manager" "◉  Terminal")
        _menu "$(printf "Open in — %s" "$name")" "${opts[@]}"
        case $? in 2) continue ;; 0) ;; *) return ;; esac
        case "$REPLY" in
            *"Browser"*)
                [[ "$is_running" == "false" ]] && { pause "Please start the container first."; continue; }
                _sd_open_url "$(_open_in_best_url "$cid" "$svc_port")" >/dev/null 2>&1
                return ;;
            *"QR code"*)
                [[ "$is_running" == "false" ]] && { pause "Please start the container first."; continue; }
                local _qr_exp; _qr_exp=$(_exposure_get "$cid")
                if [[ "$_qr_exp" != "public" ]]; then
                    pause "$(printf "Exposure is %b — QR code requires public.\n\n  Set this container to public in Reverse Proxy → Port exposure." "$(_exposure_label "$_qr_exp")")"
                    continue
                fi
                local _qr_url="http://${cid}.local"
                local _qr_render; _qr_render=$(_chroot_bash "$UBUNTU_DIR" -c "qrencode -t UTF8 -o - '$_qr_url'" 2>/dev/null)
                printf '%s

  %s
' "$_qr_render" "$_qr_url"                     | _fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── QR Code ──${NC}
${DIM}  Scan to open on any LAN device (mDNS)${NC}")"                           --no-multi --disabled >/dev/null 2>&1 || true ;;
                        *"File manager"*)
                local open_path="${install_path:-$INSTALLATIONS_DIR}"
                [[ -z "$open_path" ]] && { pause "No install path found."; continue; }
                xdg-open "$open_path" 2>/dev/null & disown 2>/dev/null || true ;;
            *"Terminal"*)
                local tsess_term="sdTerm_${cid}"
                local tip; tip=$(_cpath "$cid"); [[ -z "$tip" ]] && tip="$HOME"
                if ! tmux has-session -t "$tsess_term" 2>/dev/null; then
                    tmux new-session -d -s "$tsess_term" "cd $(printf '%q' "$tip") && exec bash" 2>/dev/null
                    tmux set-option -t "$tsess_term" detach-on-destroy off 2>/dev/null || true
                fi
                pause "$(printf "Opening terminal for '%s'\n\n  %s\n  Press %s to detach." "$name" "$tip" "${KB[tmux_detach]}")"
                tmux switch-client -t "$tsess_term" 2>/dev/null || true ;;
        esac
    done
}

_create_container() {
    local bname="$1" bfile="${2:-}"
    [[ -z "$bfile" ]] && bfile=$(_bp_path "$bname")
    local is_tmpfile=false
    if [[ -z "$bfile" || ! -f "$bfile" ]]; then
        local raw; raw=$(_get_persistent_bp "$bname"); [[ -z "$raw" ]] && { pause "Could not read blueprint '$bname'."; return 1; }
        bfile=$(mktemp "$TMP_DIR/.sd_pbp_XXXXXX.toml")
        printf '%s\n' "$raw" > "$bfile"; is_tmpfile=true
    fi
    _guard_space || { [[ "$is_tmpfile" == true ]] && rm -f "$bfile"; return 1; }

    if ! _bp_is_json "$bfile"; then
        declare -A _vc_META=(); declare -A _vc_ENV=()
        local _vc_saved_meta _vc_saved_env
        BP_META=() BP_ENV=() BP_STORAGE="" BP_DEPS="" BP_DIRS=""
        BP_GITHUB="" BP_NPM="" BP_BUILD="" BP_INSTALL="" BP_UPDATE="" BP_START=""
        BP_ACTIONS_NAMES=() BP_ACTIONS_SCRIPTS=() BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()
        if _bp_parse "$bfile"; then
            if ! _bp_validate; then
                local _errmsg; _errmsg=$(printf '%s\n' "${BP_ERRORS[@]}")
                [[ "$is_tmpfile" == true ]] && rm -f "$bfile"
                pause "$(printf '⚠  Blueprint validation failed:\n\n%s\n\n  Edit the blueprint and try again.' "$_errmsg")"
                return 1
            fi
        fi
    fi

    local suggested
    if _bp_is_json "$bfile"; then
        suggested=$(jq -r '.meta.name // empty' "$bfile" 2>/dev/null)
    else
        suggested=$(grep -m1 '^name[[:space:]]*=' "$bfile" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//')
    fi
    [[ -z "$suggested" ]] && suggested="$bname"

    local ct_name
    while true; do
        if ! finput "Container name (default: $suggested):"; then
            [[ "$is_tmpfile" == true ]] && rm -f "$bfile"; return 1
        fi
        ct_name="${FINPUT_RESULT//[^a-zA-Z0-9_\-]/}"
        [[ -z "$ct_name" ]] && ct_name="${suggested//[^a-zA-Z0-9_\-]/}"

        local dup=false
        for d in "$CONTAINERS_DIR"/*/; do
            [[ -f "$d/state.json" ]] || continue
            [[ "$(jq -r '.name // empty' "$d/state.json" 2>/dev/null)" == "$ct_name" ]] && dup=true && break
        done
        if [[ "$dup" == "true" ]]; then [[ "$is_tmpfile" == true ]] && rm -f "$bfile"; pause "A container named '$ct_name' already exists."; return 1; fi

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n%s\n' "$(printf "${GRN}▶  Continue${NC}")" "$(printf "${DIM}   Change name${NC}")" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Container name ──${NC}")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local name_choice; name_choice=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 ]] && return
        local name_choice_clean; name_choice_clean=$(printf '%s' "$name_choice" | _trim_s)
        [[ "$name_choice_clean" == *"Change name"* ]] && continue
        break
    done

    local cid; cid=$(_rand_id)
    mkdir -p "$CONTAINERS_DIR/$cid" 2>/dev/null
    jq -n --arg id "$cid" --arg n "$ct_name" --arg ip "$ct_name" \
        '{id:$id,name:$n,install_path:$ip,installed:false,hidden:false,trash:false}' \
        > "$CONTAINERS_DIR/$cid/state.json"
    cp "$bfile" "$CONTAINERS_DIR/$cid/service.src"
    [[ "$is_tmpfile" == true ]] && rm -f "$bfile"
    _compile_service "$cid" || { pause "Failed to compile blueprint."; return 1; }
    pause "Container '$ct_name' created. Select it to install."
}

_edit_container_bp() {
    local cid="$1"
    local src="$CONTAINERS_DIR/$cid/service.src"
    local _erun=false _einst=false
    tmux_up "$(tsess "$cid")" && _erun=true
    _is_installing "$cid"    && _einst=true
    [[ "$_erun" == "true" || "$_einst" == "true" ]] && { pause "⚠  Stop the container before editing."; return 1; }
    _guard_space || return 1; _ensure_src "$cid"
    ${EDITOR:-vi} "$src"
    if ! _bp_is_json "$src"; then
        BP_META=() BP_ENV=() BP_STORAGE="" BP_DEPS="" BP_DIRS=""
        BP_GITHUB="" BP_NPM="" BP_BUILD="" BP_INSTALL="" BP_UPDATE="" BP_START=""
        BP_ACTIONS_NAMES=() BP_ACTIONS_SCRIPTS=() BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()
        _bp_parse "$src" 2>/dev/null
        if ! _bp_validate; then
            local _ee; _ee=$(printf '%s\n' "${BP_ERRORS[@]}")
            pause "$(printf '⚠  Blueprint has errors (not saved):\n\n%s\n\n  Re-open editor to fix.' "$_ee")"
            return 1
        fi
    fi
    _compile_service "$cid" && [[ "$(_st "$cid" installed)" == "true" ]] && _build_start_script "$cid" 2>/dev/null || true
}

_rename_container() {
    local cid="$1" name; name=$(_cname "$cid")
    [[ "$(_st "$cid" installed)" == "true" ]] && { pause "Rename is only available for uninstalled containers."; return 1; }
    while true; do
        finput "New name for '$name':" || return 1
        local new_ct_name; new_ct_name="${FINPUT_RESULT//[^a-zA-Z0-9_\-]/}"
        [[ -z "$new_ct_name" ]] && { pause "Name cannot be empty."; continue; }
        local dup_found=false
        for dd in "$CONTAINERS_DIR"/*/; do
            [[ -f "$dd/state.json" ]] || continue
            local en; en=$(jq -r '.name // empty' "$dd/state.json" 2>/dev/null)
            [[ "$en" == "$new_ct_name" && "$(basename "$dd")" != "$cid" ]] && dup_found=true && break
        done
        [[ "$dup_found" == "true" ]] && { pause "A container named '$new_ct_name' already exists."; continue; }
        jq --arg n "$new_ct_name" '.name=$n' "$CONTAINERS_DIR/$cid/state.json" \
            > "$CONTAINERS_DIR/$cid/state.json.tmp" \
            && mv "$CONTAINERS_DIR/$cid/state.json.tmp" "$CONTAINERS_DIR/$cid/state.json" 2>/dev/null
        pause "Container renamed to '$new_ct_name'."; return 0
    done
}

_container_submenu() {
    local cid="$1"
    while true; do
        clear; _cleanup_stale_lock
        local name; name=$(_cname "$cid"); [[ -z "$name" ]] && name="(unnamed-$cid)"
        local installed; installed=$(_st "$cid" installed)
        local is_running=false; tmux_up "$(tsess "$cid")" && is_running=true
        local is_installing=false; _is_installing "$cid" && is_installing=true
        local ok_file="$CONTAINERS_DIR/$cid/.install_ok"
        local fail_file="$CONTAINERS_DIR/$cid/.install_fail"
        local install_done=false; [[ -f "$ok_file" || -f "$fail_file" ]] && install_done=true

        local svc_port; svc_port=$(jq -r '.meta.port // 0' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null); svc_port="${svc_port:-0}"
        local env_port; env_port=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        [[ -n "$env_port" ]] && svc_port="$env_port"

        local action_labels=() action_dsls=()
        local cron_names=() cron_intervals=() cron_idxs=()
        if [[ "$installed" == "true" && "$is_installing" == "false" ]]; then
            local sj="$CONTAINERS_DIR/$cid/service.json"
            local act_count; act_count=$(jq -r '.actions | length' "$sj" 2>/dev/null)
            if [[ -n "$act_count" && "$act_count" -gt 0 ]]; then
                for (( ai=0; ai<act_count; ai++ )); do
                    local lbl; lbl=$(jq -r --argjson i "$ai" '.actions[$i].label // empty' "$sj" 2>/dev/null)
                    local dsl; dsl=$(jq -r --argjson i "$ai" '.actions[$i].dsl // .actions[$i].script // empty' "$sj" 2>/dev/null)
                    [[ -z "$lbl" ]] && continue
                    [[ "${lbl,,}" == "open browser" ]] && continue
                    local _first_char; _first_char=$(printf '%s' "$lbl" | cut -c1)
                    if [[ "$_first_char" =~ ^[a-zA-Z0-9]$ ]]; then
                        lbl="⊙  $lbl"
                    fi
                    action_labels+=("$lbl"); action_dsls+=("$dsl")
                done
            fi
            local cron_count; cron_count=$(jq -r '.crons | length' "$sj" 2>/dev/null)
            if [[ -n "$cron_count" && "$cron_count" -gt 0 ]]; then
                for (( ci=0; ci<cron_count; ci++ )); do
                    local cn; cn=$(jq -r --argjson i "$ci" '.crons[$i].name // empty' "$sj" 2>/dev/null)
                    local civ; civ=$(jq -r --argjson i "$ci" '.crons[$i].interval // empty' "$sj" 2>/dev/null)
                    [[ -z "$cn" ]] && continue
                    cron_names+=("$cn"); cron_intervals+=("$civ"); cron_idxs+=("$ci")
                done
            fi
        fi

        local SEP_GEN SEP_ACT SEP_CRON SEP_MGT
        SEP_GEN="$(printf "${BLD}  ── General ──────────────────────────${NC}")"
        SEP_ACT="$(printf "${BLD}  ── Actions ──────────────────────────${NC}")"
        SEP_CRON="$(printf "${BLD}  ── Cron ─────────────────────────────${NC}")"
        SEP_MGT="$(printf "${BLD}  ── Management ───────────────────────${NC}")"
        local items=("$SEP_GEN")

        local _UPD_FILES=() _UPD_NAMES=() _UPD_VERS=() _UPD_SRCS=() _UPD_ISTMP=()
        local _UPD_ITEMS=() _UPD_IDX=()
        [[ "$is_installing" == "false" && "$is_running" == "false" ]] && {
            _build_update_items "$cid"
            [[ "$installed" == "true" ]] && _build_ubuntu_update_item "$cid"
            [[ "$installed" == "true" ]] && _build_pkg_update_item "$cid"
        }

        if [[ "$is_installing" == "true" || "$install_done" == "true" ]]; then
            if [[ "$install_done" == "true" ]]; then
                local _fin_lbl="${L[ct_finish_inst]}"
                [[ "$installed" == "true" ]] && _fin_lbl="✓  Finish update"
                items+=("$_fin_lbl")
            else
                items+=("${L[ct_attach_inst]}")
            fi
        elif [[ "$is_running" == "true" ]]; then
            items+=("${L[ct_stop]}" "${L[ct_restart]}" "${L[ct_attach]}" "${L[ct_open_in]}" "${L[ct_log]}")
            [[ "${#action_labels[@]}" -gt 0 ]] && items+=("$SEP_ACT" "${action_labels[@]}")
            if [[ "${#cron_names[@]}" -gt 0 ]]; then
                items+=("$SEP_CRON")
                for ci in "${!cron_names[@]}"; do
                    local _cidx="${cron_idxs[$ci]}"
                    local _csess; _csess=$(_cron_sess "$cid" "$_cidx")
                    if tmux_up "$_csess"; then
                        items+=("$(printf " ${CYN}⏱${NC}  ${DIM}%s  ${CYN}[%s]${NC}" "${cron_names[$ci]}" "${cron_intervals[$ci]}")")
                    else
                        items+=("$(printf " ${DIM}⏱  %s  [stopped]${NC}" "${cron_names[$ci]}")")
                    fi
                done
            fi
        elif [[ "$installed" == "true" ]]; then
            local SEP_STO SEP_DNG
            SEP_STO="$(printf "${BLD}  ── Storage ───────────────────────────${NC}")"
            SEP_DNG="$(printf "${BLD}  ── Caution ───────────────────────────${NC}")"
            items+=("${L[ct_start]}" "${L[ct_open_in]}")
            items+=("$SEP_STO" "${L[ct_backups]}" "${L[ct_profiles]}")
            items+=("${L[ct_edit]}")
            local _pending_upd=0
            for _ui_e in "${_UPD_ITEMS[@]}"; do
                printf '%s' "$_ui_e" | _strip_ansi | grep -qE 'Changes detected|→' && (( _pending_upd++ )) || true
            done
            local _upd_lbl=""
            if [[ "${#_UPD_ITEMS[@]}" -gt 0 ]]; then
                if [[ "$_pending_upd" -gt 0 ]]; then
                    _upd_lbl="$(printf " ${YLW}⬆  Updates${NC}")"
                else
                    _upd_lbl="⬆  Updates"
                fi
            fi
            items+=("$SEP_DNG")
            [[ -n "$_upd_lbl" ]] && items+=("$_upd_lbl")
            items+=("${L[ct_uninstall]}")
        else
            local SEP_DNG2; SEP_DNG2="$(printf "${BLD}  ── Caution ───────────────────────────${NC}")"
            items+=("${L[ct_install]}" "${L[ct_edit]}" "${L[ct_rename]}")
            items+=("$SEP_DNG2" "${L[ct_remove]}")
        fi

        local hdr_dot
        if   [[ "$is_installing" == "true" || "$install_done" == "true" ]]; then hdr_dot="${YLW}◈${NC}"
        elif [[ "$is_running" == "true" ]]; then
            if _health_check "$cid"; then hdr_dot="${GRN}◈${NC}"
            else hdr_dot="${YLW}◈${NC}"; fi
        elif [[ "$installed" == "true" ]]; then hdr_dot="${RED}◈${NC}"
        else hdr_dot="${DIM}◈${NC}"; fi
        local _ct_dlg; _ct_dlg=$(jq -r '.meta.dialogue // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local _hdr
        if [[ -n "$_ct_dlg" ]]; then
            _hdr="$(printf "%b  %s  ${DIM}— %s${NC}" "$hdr_dot" "$name" "$_ct_dlg")"
        else
            _hdr="$(printf "%b  %s" "$hdr_dot" "$name")"
        fi
        if [[ "$svc_port" != "0" && -n "$svc_port" ]]; then
            local _hdr_ip; _hdr_ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
            _hdr+="$(printf "  ${DIM}%s:%s${NC}" "$_hdr_ip" "$svc_port")"
        fi

        if [[ "$is_installing" == "true" || "$install_done" == "true" ]]; then
            _installing_menu "$cid" "$_hdr" "${items[@]}"
            case $? in 1) _cleanup_upd_tmps; return ;; 2) continue ;; esac
        else
            _menu "$_hdr" "${items[@]}"
            local _mrc=$?
            case $_mrc in 2) continue ;; 0) ;; *) _cleanup_upd_tmps; return ;; esac
        fi

        case "$REPLY" in
            "${L[ct_attach_inst]}") _tmux_attach_hint "installation" "$(_inst_sess "$cid")"; _cleanup_stale_lock ;;
            "${L[ct_finish_inst]}"|"✓  Finish update") _process_install_finish "$cid" ;;
            "${L[ct_install]}")
                _guard_install || continue
                _run_job install "$cid"; _cleanup_upd_tmps ;;
            "${L[ct_start]}")       _start_container "$cid"; _cleanup_upd_tmps ;;
            "${L[ct_attach]}")      _tmux_attach_hint "$name" "$(tsess "$cid")" ;;
            "${L[ct_stop]}")        confirm "Stop '$name'?" || continue; _stop_container "$cid" ;;
            "${L[ct_restart]}")     _stop_container "$cid"; sleep 0.3; _start_container "$cid" ;;
            "${L[ct_open_in]}")     _open_in_submenu "$cid" ;;
            *"⏱"*)
                local _cron_clicked; _cron_clicked=$(printf '%s' "$REPLY" | _strip_ansi | sed 's/^[[:space:]]*//' | grep -oP '(?<=⏱  )[^\[]+' | sed 's/[[:space:]]*$//')
                local _ci
                for _ci in "${!cron_names[@]}"; do
                    if [[ "${cron_names[$_ci]}" == "$_cron_clicked" ]]; then
                        local _csess; _csess=$(_cron_sess "$cid" "${cron_idxs[$_ci]}")
                        if tmux_up "$_csess"; then
                            _tmux_attach_hint "cron: ${cron_names[$_ci]}" "$_csess"
                        else
                            pause "Cron '${cron_names[$_ci]}' is not running."
                        fi
                        break
                    fi
                done ;;
            *"⬤  Exposure"*)
                local _new_mode; _new_mode=$(_exposure_next "$cid")
                _exposure_set "$cid" "$_new_mode"
                _exposure_apply "$cid"
                pause "$(printf "Port exposure set to: %b" "$(_exposure_label "$_new_mode")")" ;;
            "${L[ct_log]}")
                local _meta_log; _meta_log=$(jq -r '.meta.log // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
                local _lf
                if [[ -n "$_meta_log" ]]; then
                    _lf="$(_cpath "$cid")/$_meta_log"
                else
                    _lf=$(_log_path "$cid" "start")
                fi
                if [[ -f "$_lf" ]]; then
                    pause "$(tail -100 "$_lf" 2>/dev/null | cat)"
                else
                    pause "No log yet for '$name'."
                fi ;;
            "${L[ct_edit]}")  _edit_container_bp "$cid" || continue ;;
            "${L[ct_rename]}")  _rename_container "$cid" ;;
            "${L[ct_backups]}")  _container_backups_menu "$cid" ;;
            "${L[ct_profiles]}") _stor_ctx_cid="$cid"; _persistent_storage_menu "$cid"; _stor_ctx_cid="" ;;
            *"Clone container"*) _clone_container "$cid" ;;
            "⚙  Management"*) ;; # no-op, replaced by inline section
            "◦  Edit blueprint"|"${L[ct_edit]}"*)  _edit_container_bp "$cid" || continue ;;
            *"Installation"*) ;; # no-op, flattened
            "${L[ct_uninstall]}")
                local ip; ip=$(_cpath "$cid")
                confirm "$(printf "Uninstall '%s'?\n\n  ✕  Installation subvolume: %s\n  ✕  Snapshots\n\n  Persistent storage is kept.\n  Container entry stays — select Install to reinstall." "$name" "$ip")" || continue
                [[ -d "$ip" ]] && { sudo -n btrfs subvolume delete "$ip" &>/dev/null || btrfs subvolume delete "$ip" &>/dev/null || sudo -n rm -rf "$ip" 2>/dev/null || rm -rf "$ip" 2>/dev/null || true; }
                local sdir2; sdir2=$(_snap_dir "$cid")
                if [[ -d "$sdir2" ]]; then
                    for _sf in "$sdir2"/*/; do [[ -d "$_sf" ]] && _delete_snap "$_sf" || true; done
                    rm -rf "$sdir2" 2>/dev/null || true
                fi
                _set_st "$cid" installed false
                pause "'$name' uninstalled. Persistent storage kept." ;;
            "${L[ct_update]}")   _guard_install || continue; _run_job update "$cid" ;;
            "${L[ct_exposure]}"*)
                local _new_exp; _new_exp=$(_exposure_next "$cid")
                _exposure_set "$cid" "$_new_exp"
                tmux_up "$(tsess "$cid")" && _exposure_apply "$cid"
                pause "$(printf "Port exposure set to: %b\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network" "$(_exposure_label "$_new_exp")")" ;;
            "${L[ct_remove]}")
                confirm "$(printf "Remove container entry '%s'?\n\n  No installation or storage files deleted." "$name")" || continue
                rm -f "$CACHE_DIR/sd_size/$cid" "$CACHE_DIR/gh_tag/$cid" "$CACHE_DIR/gh_tag/$cid.inst" 2>/dev/null || true
                rm -rf "$CONTAINERS_DIR/$cid" 2>/dev/null
                _cleanup_upd_tmps; pause "'$name' removed."; return ;;
            *"⬆  Updates"*)
                [[ "${#_UPD_ITEMS[@]}" -eq 0 ]] && continue
                local _upd_menu_items=()
                for _umi in "${_UPD_ITEMS[@]}"; do _upd_menu_items+=("$_umi"); done
                _menu "Update — $name" "${_upd_menu_items[@]}" || continue
                local _upd_reply_clean; _upd_reply_clean=$(printf '%s' "$REPLY" | _trim_s)
                for ui in "${!_UPD_ITEMS[@]}"; do
                    local _ic; _ic=$(printf '%s' "${_UPD_ITEMS[$ui]}" | _trim_s)
                    if [[ "$_upd_reply_clean" == "$_ic" ]]; then
                        if [[ "${_UPD_IDX[$ui]}" == "__ubuntu__" ]]; then
                            _do_ubuntu_update "$cid"; continue 2
                        elif [[ "${_UPD_IDX[$ui]}" == "__pkgs__" ]]; then
                            _do_pkg_update "$cid"; continue 2
                        else
                            _do_blueprint_update "$cid" "${_UPD_IDX[$ui]}"; continue 2
                        fi
                    fi
                done ;;
            *)
                local _reply_clean; _reply_clean=$(printf '%s' "$REPLY" | _trim_s)
                for ui in "${!_UPD_ITEMS[@]}"; do
                    local _ic; _ic=$(printf '%s' "${_UPD_ITEMS[$ui]}" | _trim_s)
                    if [[ "$_reply_clean" == "$_ic" ]]; then
                        if [[ "${_UPD_IDX[$ui]}" == "__ubuntu__" ]]; then
                            _do_ubuntu_update "$cid"; continue 2
                        elif [[ "${_UPD_IDX[$ui]}" == "__pkgs__" ]]; then
                            _do_pkg_update "$cid"; continue 2
                        else
                            _do_blueprint_update "$cid" "${_UPD_IDX[$ui]}"; continue 2
                        fi
                    fi
                done
                printf '%s' "$REPLY" | grep -q '^──' && continue
                for ai in "${!action_labels[@]}"; do
                    [[ "$REPLY" != "${action_labels[$ai]}" ]] && continue
                    local ip; ip=$(_cpath "$cid")
                    local dsl="${action_dsls[$ai]}"
                    local arunner; arunner=$(mktemp "$TMP_DIR/.sd_action_XXXXXX.sh")
                    local sname="sdAction_${cid}_${ai}"
                    {
                        printf '#!/usr/bin/env bash\n'
                        _env_exports "$cid" "$ip"
                        printf 'cd "$CONTAINER_ROOT"\n'

                        if printf '%s' "$dsl" | grep -q '|'; then
                            local _input_var="" _select_var=""
                            local seg_idx=0
                            local IFS_BAK="$IFS"; IFS='|'
                            local segs=()
                            while IFS= read -r seg; do
                                seg=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                                [[ -n "$seg" ]] && segs+=("$seg")
                            done <<< "$(printf '%s' "$dsl" | tr '|' '\n')"
                            IFS="$IFS_BAK"

                            for seg in "${segs[@]}"; do
                                if [[ "$seg" == prompt:* ]]; then
                                    local ptxt; ptxt=$(printf '%s' "$seg" | sed 's/^prompt:[[:space:]]*//' | tr -d '"'"'")
                                    printf 'printf "%s\\n> "; read -r _sd_input\n' "$ptxt"
                                    printf '[[ -z "$_sd_input" ]] && exit 0\n'

                                elif [[ "$seg" == select:* ]]; then
                                    local scmd; scmd=$(printf '%s' "$seg" | sed 's/^select:[[:space:]]*//')
                                    local skip_hdr=0 col_n=1
                                    [[ "$scmd" == *"--skip-header"* ]] && skip_hdr=1
                                    if [[ "$scmd" =~ --col[[:space:]]+([0-9]+) ]]; then col_n="${BASH_REMATCH[1]}"; fi
                                    scmd=$(printf '%s' "$scmd" | sed 's/--skip-header//g;s/--col[[:space:]]*[0-9]*//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                                    local scmd_bin="${scmd%% *}" scmd_rest="${scmd#* }"
                                    [[ "$scmd_rest" == "$scmd_bin" ]] && scmd_rest=""
                                    local scmd_bin_p; scmd_bin_p=$(_cr_prefix "$scmd_bin")
                                    local full_scmd="${scmd_bin_p}${scmd_rest:+ $scmd_rest}"
                                    printf '_sd_list=$(%s 2>/dev/null)\n' "$full_scmd"
                                    printf '[[ -z "$_sd_list" ]] && { printf "Nothing found.\\n"; exit 0; }\n'
                                    if [[ $skip_hdr -eq 1 ]]; then
                                        printf '_sd_list=$(printf "%%s" "$_sd_list" | tail -n +2)\n'
                                    fi
                                    printf '_sd_selection=$(printf "%%s\\n" "$_sd_list" | awk '"'"'{print $%d}'"'"' | fzf --ansi --no-sort --prompt="  ❯ " --pointer="▶" --height=40%% --reverse --border=rounded --margin=1,2 --no-info 2>/dev/null) || exit 0\n' "$col_n"
                                    printf '[[ -z "$_sd_selection" ]] && exit 0\n'

                                else
                                    local cmd_out; cmd_out="$seg"
                                    local cmd_bin="${cmd_out%% *}" cmd_rest="${cmd_out#* }"
                                    [[ "$cmd_rest" == "$cmd_bin" ]] && cmd_rest=""
                                    local cmd_bin_p; cmd_bin_p=$(_cr_prefix "$cmd_bin")
                                    cmd_out="${cmd_bin_p}${cmd_rest:+ $cmd_rest}"
                                    cmd_out=$(printf '%s' "$cmd_out" | sed 's/{input}/$_sd_input/g; s/{selection}/$_sd_selection/g')
                                    printf '%s\n' "$cmd_out"
                                fi
                            done
                        else
                            printf '%s\n' "$dsl"
                        fi
                    } > "$arunner"; chmod +x "$arunner"
                    if tmux has-session -t "$sname" 2>/dev/null; then
                        pause "$(printf "Action '%s' is still running.\n\n  Press %s to detach." "${action_labels[$ai]}" "${KB[tmux_detach]}")"
                        tmux switch-client -t "$sname" 2>/dev/null || true
                    else
                        tmux new-session -d -s "$sname" \
                            "bash $(printf '%q' "$arunner"); rm -f $(printf '%q' "$arunner"); printf '\n\033[0;32m══ Done ══\033[0m\n'; printf 'Press Enter to return...\n'; read -rs _; tmux switch-client -t simpleDocker 2>/dev/null || true; tmux kill-session -t \"$sname\" 2>/dev/null || true" 2>/dev/null
                        tmux set-option -t "$sname" detach-on-destroy off 2>/dev/null || true
                        pause "$(printf "Starting '%s'...\n\n  Press %s to detach." "${action_labels[$ai]}" "${KB[tmux_detach]}")"
                        tmux switch-client -t "$sname" 2>/dev/null || true
                    fi
                    break
                done ;;
        esac
    done
}

_quit_all() {
    confirm "Stop all containers and quit?" || return
    _load_containers true
    for cid in "${CT_IDS[@]}"; do
        local sess; sess="$(tsess "$cid")"
        tmux_up "$sess" && { tmux send-keys -t "$sess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$sess" 2>/dev/null || true; }
        if _is_installing "$cid" && [[ ! -f "$CONTAINERS_DIR/$cid/.install_ok" && ! -f "$CONTAINERS_DIR/$cid/.install_fail" ]]; then
            touch "$CONTAINERS_DIR/$cid/.install_fail" 2>/dev/null || true
        fi
    done
    tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true; _tmux_set SD_INSTALLING ""
    _unmount_img; clear
    tmux kill-session -t "simpleDocker" 2>/dev/null || true; exit 0
}

_quit_menu() {
    _menu "${L[quit]}" "${L[detach]}" "${L[quit_stop_all]}" || return
    case "$REPLY" in
        "${L[detach]}")        _tmux_set SD_DETACH 1; tmux detach-client 2>/dev/null || true ;;
        "${L[quit_stop_all]}") _quit_all ;;
    esac
}

_active_processes_menu() {
    while true; do
        local gpu_hdr=""
        if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null 2>&1; then
            gpu_hdr=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
                --format=csv,noheader,nounits 2>/dev/null \
                | awk -F, 'NR==1{gsub(/ /,"",$1);gsub(/ /,"",$2);gsub(/ /,"",$3)
                             printf "  ·  GPU:%s%%  VRAM:%s/%s MiB",$1,$2,$3}')
        fi

        mapfile -t _sd_sessions < <(tmux list-sessions -F "#{session_name}" 2>/dev/null \
            | grep -E "^sd_[a-z0-9]{8}$|^sdInst_|^sdResize$|^sdTerm_|^sdAction_|^simpleDocker$")

        local display_lines=() display_sess=()
        local sess
        for sess in "${_sd_sessions[@]}"; do
            local label="" cid="" pid="" cpu="-" mem="-"
            pid=$(tmux list-panes -t "$sess" -F "#{pane_pid}" 2>/dev/null | head -1)
            if [[ -n "$pid" ]]; then
                local _rss=""; read -r cpu _rss _ < <(ps -p "$pid" -o pcpu=,rss=,comm= --no-headers 2>/dev/null)
                while read -r cc cr; do
                    [[ -n "$cc" ]] && cpu=$(awk "BEGIN{printf \"%.1f\",$cpu+$cc}")
                    [[ -n "$cr" ]] && _rss=$(( ${_rss:-0} + cr ))
                done < <(ps --ppid "$pid" -o pcpu=,rss= --no-headers 2>/dev/null)
                [[ -n "$_rss" ]] && mem="$(( _rss / 1024 ))M"
                [[ -n "$cpu"  ]] && cpu="${cpu}%"
            fi
            local stats; stats=$(printf "${DIM}CPU:%-6s RAM:%-6s${NC}" "$cpu" "$mem")
            case "$sess" in
                simpleDocker)   label="simpleDocker  (UI)" ;;
                sdInst_*)       local icid; icid=$(_installing_id)
                                local iname; [[ -n "$icid" ]] && iname=$(_cname "$icid") || iname="unknown"
                                label="Install › $iname" ;;
                sdResize)       label="Resize operation" ;;
                sdTerm_*)       cid="${sess#sdTerm_}"
                                label="Terminal › $(_cname "$cid" 2>/dev/null || printf '%s' "$cid")" ;;
                sdAction_*)     cid=$(printf '%s' "$sess" | sed 's/sdAction_\([a-z0-9]*\)_.*/\1/')
                                local aidx="${sess##*_}"
                                local albl; albl=$(jq -r --argjson i "$aidx" '.actions[$i].label // empty' \
                                    "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
                                label="Action › ${albl:-$aidx}  ($(_cname "$cid" 2>/dev/null || printf '%s' "$cid"))" ;;
                sd_*)           cid="${sess#sd_}"
                                label="$(_cname "$cid" 2>/dev/null || printf '%s' "$cid")" ;;
                *)              label="$sess" ;;
            esac
            display_lines+=("$(printf '  %-36s %s  PID:%-7s\t%s' "$label" "$stats" "${pid:--}" "$sess")"); display_sess+=("$sess")
        done

        [[ ${#display_lines[@]} -eq 0 ]] && { pause "No active processes."; return; }
        local _proc_entries=("${display_lines[@]}") _proc_sess=("${display_sess[@]}")
        display_lines=()
        display_sess=()
        display_lines+=("$(printf "${BLD}  ── Processes ────────────────────────${NC}\t__sep__")"); display_sess+=("__sep__")
        for i in "${!_proc_entries[@]}"; do
            display_lines+=("${_proc_entries[$i]}"); display_sess+=("${_proc_sess[$i]}")
        done
        display_lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}\t__sep__")"); display_sess+=("__sep__")
        display_lines+=("$(printf "${DIM} %s${NC}\t__back__" "${L[back]}")"); display_sess+=("__back__")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${display_lines[@]}" | fzf "${FZF_BASE[@]}" --with-nth=1 --delimiter=$'\t' --header="$(printf "${BLD}── Processes ──${NC}  ${DIM}[%d active]${NC}%s" "${#_proc_entries[@]}" "$gpu_hdr")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel_clean; sel_clean=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel_clean}" ]] && return
        local target_sess
        target_sess=$(printf '%s' "$sel_clean" | awk -F'\t' '{print $2}' | tr -d '[:space:]')
        [[ "$target_sess" == "__back__" || -z "$target_sess" ]] && return

        confirm "Kill '$target_sess'?" || continue
        tmux send-keys -t "$target_sess" C-c "" 2>/dev/null; sleep 0.3
        tmux kill-session -t "$target_sess" 2>/dev/null || true
        pause "Killed."
    done
}


_port_exposure_menu() {
    while true; do
        _load_containers false
        local lines=()
        local SEP_CT; SEP_CT="$(printf "${BLD}  ── Containers ───────────────────────${NC}")"
        lines+=("$SEP_CT")

        local cids=() cnames=()
        for i in "${!CT_IDS[@]}"; do
            local cid="${CT_IDS[$i]}"
            [[ "$(_st "$cid" installed)" != "true" ]] && continue
            local port; port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local ep; ep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            [[ -n "$ep" ]] && port="$ep"
            [[ -z "$port" || "$port" == "0" ]] && continue
            local mode; mode=$(_exposure_get "$cid")
            local name; name="${CT_NAMES[$i]}"
            lines+=("$(printf " %b  %s ${DIM}(%s)${NC}" "$(_exposure_label "$mode")" "$name" "$port")")
            cids+=("$cid"); cnames+=("$name")
        done

        [[ ${#cids[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no installed containers with ports)${NC}")")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local sel; sel=$(printf '%s
' "${lines[@]}"             | _fzf "${FZF_BASE[@]}"                   --header="$(printf "${BLD}── Port Exposure ──${NC}
${DIM}  Enter to cycle: isolated → localhost → public${NC}")"                   2>/dev/null) || return
        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" ]] && return

        for i in "${!cnames[@]}"; do
            [[ "$clean" != *"${cnames[$i]}"* ]] && continue
            local cid="${cids[$i]}"
            local _new; _new=$(_exposure_next "$cid")
            _exposure_set "$cid" "$_new"
            tmux_up "$(tsess "$cid")" && _exposure_apply "$cid"
            pause "$(printf "Port exposure set to: %b\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network" \
                "$(_exposure_label "$_new")")"
            break
        done
    done
}

_resources_cfg() { printf '%s/resources.json' "$CONTAINERS_DIR/$1"; }
_res_get() { jq -r ".$2 // empty" "$(_resources_cfg "$1")" 2>/dev/null; }
_res_set() {
    local f; f=$(_resources_cfg "$1")
    [[ ! -f "$f" ]] && printf '{}' > "$f"
    local tmp; tmp=$(mktemp); jq --arg k "$2" --arg v "$3" '.[$k]=$v' "$f" > "$tmp" && mv "$tmp" "$f"
}
_res_del() {
    local f; f=$(_resources_cfg "$1"); [[ ! -f "$f" ]] && return
    local tmp; tmp=$(mktemp); jq --arg k "$2" 'del(.[$k])' "$f" > "$tmp" && mv "$tmp" "$f"
}

_resources_menu() {
    _load_containers false
    [[ ${#CT_IDS[@]} -eq 0 ]] && { pause "No containers found."; return; }
    local copts=()
    copts+=("$(printf "${BLD}  ── Containers ───────────────────────${NC}")")
    for ci in "${CT_IDS[@]}"; do
        local rs; rs=""
        [[ "$(jq -r '.enabled // false' "$(_resources_cfg "$ci")" 2>/dev/null)" == "true" ]] \
            && rs="$(printf "  ${GRN}[cgroups on]${NC}")"
        copts+=("$(printf " ${DIM}◈${NC}  %s%b" "$(_cname "$ci")" "$rs")")
    done
    copts+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
    copts+=("$(printf "${DIM} %s${NC}" "${L[back]}")")
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${copts[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Resource limits ──${NC}  ${DIM}[%d containers]${NC}" "${#CT_IDS[@]}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; return; }
    [[ $_frc -ne 0 || -z "$sel" ]] && return
    local sel_clean; sel_clean=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*//')
    [[ "$sel_clean" == "${L[back]}" || "$sel_clean" == ──* || "$sel_clean" == "── "* ]] && return
    local cid=""; local ci
    local sel_name; sel_name=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*◈[[:space:]]*//' | awk '{print $1}')
    for ci in "${CT_IDS[@]}"; do [[ "$(_cname "$ci")" == "$sel_name" ]] && cid="$ci" && break; done
    [[ -z "$cid" ]] && return
    [[ ! -f "$(_resources_cfg "$cid")" ]] && printf '{"enabled":false}' > "$(_resources_cfg "$cid")"

    while true; do
        local enabled;    enabled=$(   _res_get "$cid" enabled);    enabled="${enabled:-false}"
        local cpu_quota;  cpu_quota=$( _res_get "$cid" cpu_quota);  cpu_quota="${cpu_quota:-(unlimited)}"
        local mem_max;    mem_max=$(   _res_get "$cid" mem_max);     mem_max="${mem_max:-(unlimited)}"
        local mem_swap;   mem_swap=$(  _res_get "$cid" mem_swap);    mem_swap="${mem_swap:-(unlimited)}"
        local cpu_weight; cpu_weight=$(jq -r '.cpu_weight // empty' "$(_resources_cfg "$cid")" 2>/dev/null); cpu_weight="${cpu_weight:-(default 100)}"
        local tog; [[ "$enabled" == "true" ]] && tog="${GRN}● Enabled${NC}" || tog="${RED}○ Disabled${NC}"
        local lines=(
            "$(printf "${BLD}  ── Configuration ────────────────────${NC}")"
            "$(printf ' %b  — toggle cgroups on/off (applies on next start)' "$tog")"
            "$(printf '  CPU quota    %b%s%b  — e.g. 200%% = 2 cores' "$CYN" "$cpu_quota" "$NC")"
            "$(printf '  Memory max   %b%s%b  — e.g. 8G, 512M' "$CYN" "$mem_max" "$NC")"
            "$(printf '  Memory+swap  %b%s%b  — e.g. 10G' "$CYN" "$mem_swap" "$NC")"
            "$(printf '  CPU weight   %b%s%b  — 1-10000, default=100 (relative priority)' "$CYN" "$cpu_weight" "$NC")"
            "$(printf "${BLD}  ── Info ──────────────────────────────${NC}")"
            "$(printf '  %bGPU/VRAM%b     not configurable via cgroups (planned separately)' "$DIM" "$NC")"
            "$(printf '  %bNetwork%b      not configurable via cgroups (planned separately)' "$DIM" "$NC")"
            "$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"
            "$(printf "${DIM} %s${NC}" "${L[back]}")"
        )
        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}── Resources: %s ──${NC}\n${DIM}  Limits apply on container restart via systemd cgroups.${NC}" "$(_cname "$cid")")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel2; sel2=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "$sel2" ]] && return
        local sc; sc=$(printf '%s' "$sel2" | _strip_ansi | sed 's/^[[:space:]]*//')
        case "$sc" in
            *"${L[back]}"*|"") return ;;
            *"toggle"*)
                [[ "$enabled" == "true" ]] && _res_set "$cid" enabled false || _res_set "$cid" enabled true ;;
            *"CPU quota"*)
                finput "CPU quota (e.g. 200% = 2 cores, blank = remove limit):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" cpu_quota || _res_set "$cid" cpu_quota "$FINPUT_RESULT" ;;
            *"Memory max"*)
                finput "Memory max (e.g. 8G, 512M, blank = remove limit):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" mem_max || _res_set "$cid" mem_max "$FINPUT_RESULT" ;;
            *"Memory+swap"*)
                finput "Memory+swap max (e.g. 10G, blank = remove limit):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" mem_swap || _res_set "$cid" mem_swap "$FINPUT_RESULT" ;;
            *"CPU weight"*)
                finput "CPU weight (1-10000, blank = default 100):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" cpu_weight || _res_set "$cid" cpu_weight "$FINPUT_RESULT" ;;
        esac
    done
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
    [[ -f "$sudoers_path" ]] && return 0
    local apt_bin; apt_bin=$(command -v apt-get 2>/dev/null || printf '/usr/bin/apt-get')
    local me; me=$(id -un)
    local sudoers_line; sudoers_line="${me} ALL=(ALL) NOPASSWD: ${apt_bin}"
    if printf '%s\n' "$sudoers_line" | sudo -n tee "$sudoers_path" >/dev/null 2>&1; then
        chmod 0440 "$sudoers_path" 2>/dev/null || sudo -n chmod 0440 "$sudoers_path" 2>/dev/null || true
        return 0
    fi
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
    command -v avahi-publish >/dev/null 2>&1 || return 1
    systemctl is-active --quiet avahi-daemon 2>/dev/null && return 0
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
    local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$lan_ip" ]] && return 1
    local conf; conf=$(_proxy_dns_conf)
    mkdir -p "$(dirname "$conf")" 2>/dev/null
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
    _proxy_dns_stop
    setsid sudo -n dnsmasq --conf-file="$(_proxy_dns_conf)" \
        --pid-file="$(_proxy_dns_pidfile)" </dev/null >>"$(_proxy_dns_log)" 2>&1 &
}

_proxy_dns_stop() {
    local pid; pid=$(cat "$(_proxy_dns_pidfile)" 2>/dev/null)
    if [[ -n "$pid" ]]; then
        sudo -n kill "$pid" 2>/dev/null || true
    else
        local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
        [[ -n "$lan_ip" ]] && sudo -n pkill -f "dnsmasq.*${lan_ip}" 2>/dev/null || true
    fi
    rm -f "$(_proxy_dns_pidfile)" 2>/dev/null || true
}

_proxy_write() {
    local cf; cf=$(_proxy_caddyfile)
    printf '{\n  admin off\n  local_certs\n}\n\n' > "$cf"
    local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

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
        _pw_stanza "$exp_mode" "$scheme" "$url" "$ct_ip" "$port" >> "$cf"
        local mdns_url; mdns_url=$(_avahi_mdns_name "$url")
        [[ "$mdns_url" != "$url" ]] && _pw_stanza "$exp_mode" "$scheme" "$mdns_url" "$ct_ip" "$port" >> "$cf"

    done < <(jq -c '.routes[]?' "$(_proxy_cfg)" 2>/dev/null)

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
        _pw_stanza "$_wexp" "http" "${_wcid}.local" "$_wct_ip" "$_wport" >> "$cf"
    done
}

_proxy_update_hosts() {
    local action="${1:-add}"
    local tmp; tmp=$(mktemp)
    grep -v '# simpleDocker' /etc/hosts > "$tmp" 2>/dev/null || cp /etc/hosts "$tmp"
    if [[ "$action" == "add" ]]; then
        local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
        [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        jq -c '.routes[]?' "$(_proxy_cfg)" 2>/dev/null \
            | while IFS= read -r r; do
                [[ -z "$r" ]] && continue
                local url; url=$(printf '%s' "$r" | jq -r '.url')
                local cid; cid=$(printf '%s' "$r" | jq -r '.cid')
                [[ -z "$url" ]] && continue
                local exp_mode; exp_mode=$(_exposure_get "$cid")
                local host_ip="127.0.0.1"
                [[ "$exp_mode" == "public" && -n "$lan_ip" ]] && host_ip="$lan_ip"
                printf '%s %s  # simpleDocker\n' "$host_ip" "$url"
                local _mdns; _mdns=$(_avahi_mdns_name "$url")
                [[ "$_mdns" != "$url" ]] && printf '%s %s  # simpleDocker\n' "$host_ip" "$_mdns"
                printf '127.0.0.1 %s.local  # simpleDocker\n' "$cid"
              done >> "$tmp"
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
    local bin; bin="$(_proxy_caddy_bin)"
    local dnsmasq_bin; dnsmasq_bin=$(command -v dnsmasq 2>/dev/null || true)
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
    local systemctl_bin; systemctl_bin=$(command -v systemctl 2>/dev/null || true)
    if [[ -n "$systemctl_bin" ]]; then
        [[ -n "$nopasswd_line" ]] && nopasswd_line+=", "
        nopasswd_line+="${systemctl_bin} start avahi-daemon, ${systemctl_bin} enable avahi-daemon"
    fi
    printf '%s ALL=(ALL) NOPASSWD: %s\n' "$(id -un)" "$nopasswd_line" \
        | sudo -n tee "$(_proxy_sudoers_path)" >/dev/null 2>/dev/null || true
}

_proxy_start() {
    local _bg=false; [[ "${1:-}" == "--background" ]] && _bg=true

    [[ ! -x "$(_proxy_caddy_bin)" ]] && { printf '[sd] caddy not installed\n' >>"$(_proxy_caddy_log)"; return 1; }
    [[ ! -f "$(_proxy_cfg)" ]] && return 0
    _proxy_write
    _proxy_update_hosts add
    _proxy_ensure_sudoers
    _proxy_dns_start
    systemctl is-active --quiet avahi-daemon 2>/dev/null \
        || sudo -n systemctl start avahi-daemon 2>/dev/null || true
    _avahi_start
    setsid sudo -n "$(_proxy_caddy_runner)" run --config "$(_proxy_caddyfile)" </dev/null >>"$(_proxy_caddy_log)" 2>&1 &
    printf '%d' "$!" > "$(_proxy_pidfile)"

    if [[ "$_bg" == "true" ]]; then
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

    sudo -n cp "$ca_crt" /usr/local/share/ca-certificates/simpleDocker-caddy.crt 2>/dev/null \
        && sudo -n update-ca-certificates 2>/dev/null \
        && printf '[sd] CA trusted via system store\n' >>"$(_proxy_caddy_log)" \
        || printf '[sd] system CA trust failed (update-ca-certificates not available?)\n' >>"$(_proxy_caddy_log)"

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

_qrencode_menu() {
    while true; do
        if [[ ! -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
            pause "$(printf "QRencode runs inside the Ubuntu base layer.\n\n  Install Ubuntu base first (Other → Ubuntu base).")"; return
        fi

        local _qr_sess=""
        tmux_up "sdQrInst"   && _qr_sess="sdQrInst"
        tmux_up "sdQrUninst" && _qr_sess="sdQrUninst"
        if [[ -n "$_qr_sess" ]]; then
            local _upkg_ok="$UBUNTU_DIR/.upkg_ok" _upkg_fail="$UBUNTU_DIR/.upkg_fail"
            _pkg_op_wait "$_qr_sess" "$_upkg_ok" "$_upkg_fail" "QRencode operation" && continue || return
        fi

        local _qr_installed=false
        _chroot_bash "$UBUNTU_DIR" -c 'command -v qrencode' >/dev/null 2>&1 && _qr_installed=true

        local _upkg_ok="$UBUNTU_DIR/.upkg_ok" _upkg_fail="$UBUNTU_DIR/.upkg_fail"
        rm -f "$_upkg_ok" "$_upkg_fail"

        sleep 0.15; _SD_USR1_FIRED=0

        if [[ "$_qr_installed" == "true" ]]; then
            _menu "QRencode" "$(printf "${CYN}↑${NC}  Update")" "$(printf "${RED}×${NC}  Uninstall")"
            local _mrc=$?
            [[ $_mrc -eq 2 ]] && { _SD_USR1_FIRED=0; continue; }
            [[ $_mrc -ne 0 ]] && return
            case "$REPLY" in
                *"Update"*)
                    _ubuntu_pkg_tmux "sdQrInst" "Update QRencode" \
                        "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode 2>&1"
                    continue ;;
                *"Uninstall"*)
                    confirm "Uninstall QRencode from Ubuntu?" || continue
                    _ubuntu_pkg_tmux "sdQrUninst" "Uninstall QRencode" \
                        "DEBIAN_FRONTEND=noninteractive apt-get remove -y qrencode 2>&1"
                    continue ;;
            esac
        else
            _menu "QRencode" "$(printf "${GRN}↓${NC}  Install")"
            local _mrc=$?
            [[ $_mrc -eq 2 ]] && { _SD_USR1_FIRED=0; continue; }
            [[ $_mrc -ne 0 ]] && return
            case "$REPLY" in
                *"Install"*)
                    _ubuntu_pkg_tmux "sdQrInst" "Install QRencode" \
                        "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode 2>&1"
                    continue ;;
            esac
        fi
    done
}

_proxy_install_caddy() {
    local _mode="${1:-install}"
    mkdir -p "$MNT_DIR/.sd/caddy" 2>/dev/null
    local caddy_dest; caddy_dest="$(_proxy_caddy_bin)"

    local log_file="$TMP_DIR/.sd_caddy_log_$$"

    _hostpkg_ensure_apt_sudoers

    local script; script=$(mktemp "$TMP_DIR/.sd_caddy_inst_XXXXXX.sh")
    {
        printf '#!/usr/bin/env bash\n'
        printf 'exec > >(tee -a %q) 2>&1\n' "$log_file"
        printf 'set -uo pipefail\n'
        printf 'die() { printf "\\033[0;31mFAIL: %%s\\033[0m\\n" "$*"; exit 1; }\n'

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

        printf 'printf "%%s ALL=(ALL) NOPASSWD: %%s\\n" "$(id -un)" %q \\\n' "$caddy_dest"
        printf '    | sudo -n tee %q >/dev/null 2>/dev/null || true\n' "$(_proxy_sudoers_path)"

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
                            printf '{"autostart":false,"routes":[]}' > "$(_proxy_cfg)"
                            _load_containers false 2>/dev/null || true
                            for _rcid in "${CT_IDS[@]}"; do
                                [[ -f "$(_exposure_file "$_rcid")" ]] && rm -f "$(_exposure_file "$_rcid")"
                            done
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

_ubuntu_pkg_list() {
    _chroot_bash "$UBUNTU_DIR" -c \
        "dpkg-query -W -f='\${Package}\t\${Version}\t\${Status}\t\${Essential}\t\${Priority}\n' 2>/dev/null \
         | awk -F'\t' '\$3~/installed/{sys=(\$4==\"yes\"||\$5==\"required\"||\$5==\"important\")?1:0; print \$1\"\t\"\$2\"\t\"sys}'" 2>/dev/null
}
_ubuntu_pkg_updates() {
    _chroot_bash "$UBUNTU_DIR" -c \
        "apt-get update -qq 2>/dev/null; apt-get --simulate upgrade 2>/dev/null \
         | awk '/^Inst /{print \$2}'" 2>/dev/null
}
_ubuntu_pkg_tmux() {
    local sess="$1" title="$2" cmd="$3" chroot_dir="${4:-$UBUNTU_DIR}"
    local ok_file="$UBUNTU_DIR/.upkg_ok" fail_file="$UBUNTU_DIR/.upkg_fail"
    rm -f "$ok_file" "$fail_file"
    local script; script=$(mktemp "$TMP_DIR/.sd_upkg_XXXXXX.sh")
    local _sd_cfn='_chroot_bash() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }'
    local inner_script; inner_script=$(mktemp "$TMP_DIR/.sd_upkg_inner_XXXXXX.sh")
    printf '#!/bin/sh\nset -e\n%s\n' "$cmd" > "$inner_script"
    chmod +x "$inner_script"
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$_sd_cfn"
        printf 'trap '\'''\'' INT\n'
        printf 'printf "\\033[1m── %s ──\\033[0m\\n\\n"\n' "$title"
        printf 'sudo -n mount --bind /proc %q/proc 2>/dev/null || true\n' "$chroot_dir"
        printf 'sudo -n mount --bind /sys  %q/sys  2>/dev/null || true\n' "$chroot_dir"
        printf 'sudo -n mount --bind /dev  %q/dev  2>/dev/null || true\n' "$chroot_dir"
        printf 'sudo -n mount --bind %q %q/tmp/.sd_upkg_inner.sh 2>/dev/null || cp %q %q/tmp/.sd_upkg_inner.sh 2>/dev/null || true\n' \
            "$inner_script" "$chroot_dir" "$inner_script" "$chroot_dir"
        printf 'if _chroot_bash %q /tmp/.sd_upkg_inner.sh; then\n' "$chroot_dir"
        printf '    touch %q\n' "$ok_file"
        printf '    printf "\\n\\033[0;32m✓ Done.\\033[0m\\n"\n'
        printf 'else\n'
        printf '    touch %q\n' "$fail_file"
        printf '    printf "\\n\\033[0;31m✗ Failed.\\033[0m\\n"\n'
        printf 'fi\n'
        printf 'sudo -n umount -lf %q/tmp/.sd_upkg_inner.sh 2>/dev/null || true\n' "$chroot_dir"
        printf 'sudo -n umount -lf %q/dev %q/sys %q/proc 2>/dev/null || true\n' "$chroot_dir" "$chroot_dir" "$chroot_dir"
        printf 'rm -f %q %q/tmp/.sd_upkg_inner.sh 2>/dev/null || true\n' "$inner_script" "$chroot_dir"
        printf 'sleep 1\n'
        printf 'tmux kill-session -t %q 2>/dev/null || true\n' "$sess"
    } > "$script"
    chmod +x "$script"

    local _tl_rc
    _tmux_launch "$sess" "$title" "$script"
    _tl_rc=$?
    [[ $_tl_rc -eq 1 ]] && { rm -f "$script"; return 1; }
    return 0
}

_guard_ubuntu_pkg() {
    tmux_up "sdUbuntuPkg" || return 0
    _menu "$(printf "${BLD}⚠  Ubuntu pkg operation in progress${NC}")" \
        "→  Attach" "×  Kill" || return 1
    case "$REPLY" in
        "→  Attach") _tmux_attach_hint "ubuntu pkg" "sdUbuntuPkg" || true; return 1 ;;
        "×  Kill")   confirm "Kill the running operation?" || return 1
                     tmux kill-session -t "sdUbuntuPkg" 2>/dev/null || true; return 0 ;;
        *) return 1 ;;
    esac
}

_pkg_op_wait() {
    local _sess="$1" _ok="$2" _fail="$3" _title="$4"
    local _fzf_out; _fzf_out=$(mktemp "$TMP_DIR/.sd_fzfout_XXXXXX")
    local _wflag;   _wflag=$(mktemp -u "$TMP_DIR/.sd_wflag_XXXXXX")
    printf '%s\n%s\n%s\n' \
        "${L[ct_attach_inst]}" \
        "$(printf "${BLD}  ── Navigation ───────────────────────${NC}")" \
        "$(printf "${DIM} ${L[back]}${NC}")" \
        | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}${YLW}◈${NC}  %s in progress${NC}\n${DIM}  Press %s to detach without stopping.${NC}" "$_title" "${KB[tmux_detach]}")" \
            >"$_fzf_out" 2>/dev/null &
    local _fzf_pid=$!
    printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    { while [[ ! -f "$_ok" && ! -f "$_fail" ]] && tmux_up "$_sess"; do sleep 0.3; done
      kill "$_fzf_pid" 2>/dev/null; touch "$_wflag"
    } &
    local _wpid=$!
    wait "$_fzf_pid" 2>/dev/null; local _frc=$?
    kill "$_wpid" 2>/dev/null; wait "$_wpid" 2>/dev/null
    stty sane 2>/dev/null
    while IFS= read -r -t 0 -n 256 _ 2>/dev/null; do :; done
    local _sel; _sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s)
    rm -f "$_fzf_out"
    if [[ -f "$_wflag" ]] || _sig_rc $_frc; then
        rm -f "$_wflag"; _SD_USR1_FIRED=0; return 0
    fi
    [[ "$_sel" == "${L[ct_attach_inst]}" ]] && { _tmux_attach_hint "$_title" "$_sess" || true; return 0; }
    return 1
}

_ubuntu_menu() {
    [[ -z "$UBUNTU_DIR" ]] && return
    while true; do
        local _ub_ok="$UBUNTU_DIR/.ubuntu_ok_flag" _ub_fail="$UBUNTU_DIR/.ubuntu_fail_flag"
        local _upkg_ok="$UBUNTU_DIR/.upkg_ok" _upkg_fail="$UBUNTU_DIR/.upkg_fail"
        if tmux_up "sdUbuntuSetup" || tmux_up "sdUbuntuPkg"; then
            local _running_sess; _running_sess=$(tmux_up "sdUbuntuSetup" && echo "sdUbuntuSetup" || echo "sdUbuntuPkg")
            local _running_ok;   _running_ok=$(  [[ "$_running_sess" == "sdUbuntuSetup" ]] && echo "$_ub_ok"   || echo "$_upkg_ok")
            local _running_fail; _running_fail=$([[ "$_running_sess" == "sdUbuntuSetup" ]] && echo "$_ub_fail" || echo "$_upkg_fail")
            _pkg_op_wait "$_running_sess" "$_running_ok" "$_running_fail" "Ubuntu operation" && continue || return
        fi

        if [[ ! -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
            confirm "Ubuntu base not installed. Download and install now?" || return
            _ensure_ubuntu
            continue
        fi

        _sd_ub_cache_read

        local ub_ver; ub_ver=$(grep PRETTY_NAME "$UBUNTU_DIR/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"')
        local ub_size; ub_size=$(du -sh "$UBUNTU_DIR" 2>/dev/null | cut -f1)

        local cur_default_pkgs=()
        read -ra cur_default_pkgs <<< "$DEFAULT_UBUNTU_PKGS"

        declare -A installed_map=()
        while IFS=$'\t' read -r pkg ver _is_sys; do
            [[ -n "$pkg" ]] && installed_map["$pkg"]="$ver"
        done < <(_ubuntu_pkg_list 2>/dev/null)

        _is_default_pkg() {
            local p="$1"
            for dp in "${cur_default_pkgs[@]+"${cur_default_pkgs[@]}"}"; do [[ "$dp" == "$p" ]] && return 0; done
            return 1
        }

        local def_pairs=() sys_pairs=() pkg_pairs=()
        while IFS=$'\t' read -r pkg ver is_sys; do
            [[ -z "$pkg" ]] && continue
            installed_map["$pkg"]="$ver"
            local line; line=$(printf " ${CYN}◈${NC}  %-28s ${DIM}%s${NC}" "$pkg" "$ver")
            local key="$pkg|$ver"
            if _is_default_pkg "$pkg"; then
                def_pairs+=("${line}	${key}")
            elif [[ "$is_sys" == "1" ]]; then
                sys_pairs+=("${line}	${key}")
            else
                pkg_pairs+=("${line}	${key}")
            fi
        done < <(_ubuntu_pkg_list 2>/dev/null)
        IFS=$'\n' def_pairs=($(printf '%s\n' "${def_pairs[@]+"${def_pairs[@]}"}" | sort))
        IFS=$'\n' sys_pairs=($(printf '%s\n' "${sys_pairs[@]+"${sys_pairs[@]}"}" | sort))
        IFS=$'\n' pkg_pairs=($(printf '%s\n' "${pkg_pairs[@]+"${pkg_pairs[@]}"}" | sort))
        unset IFS

        local def_lines=() def_keys=()
        for pair in "${def_pairs[@]+"${def_pairs[@]}"}"; do
            def_lines+=("${pair%	*}"); def_keys+=("${pair##*	}")
        done
        local sys_lines=() sys_keys=()
        for pair in "${sys_pairs[@]+"${sys_pairs[@]}"}"; do
            sys_lines+=("${pair%	*}"); sys_keys+=("${pair##*	}")
        done
        local pkg_lines=() pkg_keys=()
        for pair in "${pkg_pairs[@]+"${pkg_pairs[@]}"}"; do
            pkg_lines+=("${pair%	*}"); pkg_keys+=("${pair##*	}")
        done

        local _drift_tag _upd_tag
        if [[ "$_SD_UB_PKG_DRIFT" == true ]]; then
            _drift_tag="  $(printf "${YLW}[changes detected]${NC}")"
        else
            _drift_tag="  $(printf "${GRN}[up to date]${NC}")"
        fi
        if [[ "$_SD_UB_HAS_UPDATES" == true ]]; then
            _upd_tag="  $(printf "${YLW}[updates available]${NC}")"
        else
            _upd_tag="  $(printf "${GRN}[up to date]${NC}")"
        fi

        local lines=()
        lines+=("$(printf "${BLD} ── Actions ─────────────────────────────${NC}")")
        lines+=("$(printf " ${CYN}◈${NC}  Updates")")
        lines+=("$(printf " ${CYN}◈${NC}  Uninstall Ubuntu base")")
        lines+=("$(printf "${BLD} ── Default packages ────────────────────${NC}")")
        for l in "${def_lines[@]+"${def_lines[@]}"}"; do lines+=("$l"); done
        if [[ ${#def_lines[@]} -eq 0 ]]; then
            lines+=("$(printf " ${DIM} (none installed yet)${NC}")")
        fi
        lines+=("$(printf "${BLD} ── System packages ─────────────────────${NC}")")
        for l in "${sys_lines[@]+"${sys_lines[@]}"}"; do lines+=("$l"); done
        if [[ ${#sys_lines[@]} -eq 0 ]]; then
            lines+=("$(printf " ${DIM} (none)${NC}")")
        fi
        lines+=("$(printf "${BLD} ── Packages ────────────────────────────${NC}")")
        for l in "${pkg_lines[@]+"${pkg_lines[@]}"}"; do lines+=("$l"); done
        if [[ ${#pkg_lines[@]} -eq 0 ]]; then
            lines+=("$(printf " ${DIM} (no extra packages)${NC}")")
        fi
        lines+=("$(printf " ${GRN}+${NC}  Add package")")
        lines+=("$(printf "${BLD} ── Navigation ──────────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local header_info
        header_info="$(printf "${BLD}── Ubuntu base ──${NC}  ${DIM}%s${NC}  ${DIM}Size:${NC} %s  ${CYN}[P]${NC}" \
            "${ub_ver:-Ubuntu 24.04}" "${ub_size:-?}")"

        local _fzf_sel_out; _fzf_sel_out=$(mktemp "$TMP_DIR/.sd_fzf_sel_XXXXXX")
        printf '%s\n' "${lines[@]}" \
            | fzf "${FZF_BASE[@]}" \
                  --header="$header_info" \
                  >"$_fzf_sel_out" 2>/dev/null &
        local _fzf_sel_pid=$!
        printf '%s' "$_fzf_sel_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_sel_pid" 2>/dev/null
        local _fzf_rc=$?
        _sig_rc $_fzf_rc && { rm -f "$_fzf_sel_out"; stty sane 2>/dev/null; continue; }
        local sel; sel=$(cat "$_fzf_sel_out" 2>/dev/null); rm -f "$_fzf_sel_out"
        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" || -z "$clean" ]] && return
        [[ "$clean" == ──* || "$clean" == "── "* ]] && continue

        if [[ "$clean" == *"Updates"* ]]; then
            local _upd_lines=(
                "$(printf "${BLD} ── Updates ─────────────────────────────${NC}")"
                "$(printf " ${CYN}◈${NC}  Sync default pkgs%b" "$_drift_tag")"
                "$(printf " ${CYN}◈${NC}  Update all pkgs%b"   "$_upd_tag")"
                "$(printf "${BLD} ── Navigation ──────────────────────────${NC}")"
                "$(printf "${DIM} %s${NC}" "${L[back]}")"
            )
            local _upd_out; _upd_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
            printf '%s
' "${_upd_lines[@]}" | fzf "${FZF_BASE[@]}"                 --header="$(printf "${BLD}── Updates ──${NC}")"                 >"$_upd_out" 2>/dev/null &
            local _upd_pid=$!; printf '%s' "$_upd_pid" > "$TMP_DIR/.sd_active_fzf_pid"
            wait "$_upd_pid" 2>/dev/null; local _upd_frc=$?
            local _upd_sel; _upd_sel=$(cat "$_upd_out" 2>/dev/null | _trim_s); rm -f "$_upd_out"
            _sig_rc $_upd_frc && { stty sane 2>/dev/null; continue; }
            [[ $_upd_frc -ne 0 || -z "$_upd_sel" ]] && continue
            local _upd_clean; _upd_clean=$(printf '%s' "$_upd_sel" | _strip_ansi | sed 's/^[[:space:]]*//')
            case "$_upd_clean" in
                *"${L[back]}"*|"") continue ;;
                *"Sync default pkgs"*)
                    local _cur_missing=()
                    for dp in "${cur_default_pkgs[@]}"; do
                        [[ -z "${installed_map[$dp]+x}" ]] && _cur_missing+=("$dp")
                    done
                    if [[ ${#_cur_missing[@]} -eq 0 && "$_SD_UB_PKG_DRIFT" == false ]]; then
                        pause "Already up to date."; continue
                    fi
                    local _sync_pkgs="${_cur_missing[*]:-$DEFAULT_UBUNTU_PKGS}"
                    local sync_cmd="apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${_sync_pkgs} 2>&1"
                    _ubuntu_pkg_tmux "sdUbuntuPkg" "Sync default pkgs" "$sync_cmd" || continue
                    _pkg_op_wait "sdUbuntuPkg" "$_upkg_ok" "$_upkg_fail" "Sync default pkgs" || { continue; }
                    printf '%s
' "${cur_default_pkgs[@]}" > "$(_ubuntu_default_pkgs_file)" 2>/dev/null || true
                    _SD_UB_PKG_DRIFT=false; _SD_UB_CACHE_LOADED=true
                    continue ;;
                *"Update all pkgs"*)
                    local upd_cmd="apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1"
                    _ubuntu_pkg_tmux "sdUbuntuPkg" "Update all pkgs" "$upd_cmd" || continue
                    _pkg_op_wait "sdUbuntuPkg" "$_upkg_ok" "$_upkg_fail" "Update all pkgs" || { continue; }
                    _SD_UB_HAS_UPDATES=false; _SD_UB_CACHE_LOADED=true
                    continue ;;
            esac
            continue
        fi

        if [[ "$clean" == *"Uninstall Ubuntu base"* ]]; then
            confirm "$(printf "${YLW}⚠  Uninstall Ubuntu base?${NC}\n\nThis will wipe the Ubuntu chroot.\nAll installed packages will be lost.\nContainers that depend on it will stop working.")" || continue
            rm -rf "$UBUNTU_DIR" 2>/dev/null
            mkdir -p "$UBUNTU_DIR" 2>/dev/null
            pause "✓ Ubuntu base removed."
            return
        fi

        if [[ "$clean" == *"Add package"* ]]; then
            local pkg_name
            finput "Package name (e.g. ffmpeg, nodejs):" || continue
            pkg_name="${FINPUT_RESULT// /}"
            [[ -z "$pkg_name" ]] && continue
            local pkg_ver
            finput "$(printf "Version (leave blank for latest):")" || continue
            pkg_ver="${FINPUT_RESULT// /}"
            local apt_target="$pkg_name"
            [[ -n "$pkg_ver" ]] && apt_target="${pkg_name}=${pkg_ver}"
            local apt_cmd="DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${apt_target} 2>&1 || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${apt_target}; }"
            _ubuntu_pkg_tmux "sdUbuntuPkg" "Installing ${apt_target}" "$apt_cmd"
            continue
        fi

        local chosen_key=""
        for i in "${!def_lines[@]}"; do
            local lc; lc=$(printf '%s' "${def_lines[$i]}" | _trim_s)
            if [[ "$lc" == "$clean" ]]; then chosen_key="${def_keys[$i]}"; break; fi
        done
        if [[ -n "$chosen_key" ]]; then
            local cpkg="${chosen_key%%|*}"
            pause "$(printf "Protected package\n\n'%s' is a default Ubuntu package.\nUnable to modify this package." "$cpkg")"
            continue
        fi
        for i in "${!sys_lines[@]}"; do
            local lc; lc=$(printf '%s' "${sys_lines[$i]}" | _trim_s)
            if [[ "$lc" == "$clean" ]]; then chosen_key="${sys_keys[$i]}"; break; fi
        done
        if [[ -n "$chosen_key" ]]; then
            local cpkg="${chosen_key%%|*}"
            pause "$(printf "System package\n\n'%s' is an Ubuntu system package.\nRemoving it would break the system.\nUnable to modify this package." "$cpkg")"
            continue
        fi
        for i in "${!pkg_lines[@]}"; do
            local lc; lc=$(printf '%s' "${pkg_lines[$i]}" | _trim_s)
            if [[ "$lc" == "$clean" ]]; then chosen_key="${pkg_keys[$i]}"; break; fi
        done
        [[ -z "$chosen_key" ]] && continue

        local cpkg="${chosen_key%%|*}"
        local cver="${chosen_key#*|}"

        confirm "$(printf "Remove '${BLD}%s${NC}' from Ubuntu base?\n\n${DIM}%s${NC}" "$cpkg" "$cver")" || continue
        local rm_cmd="DEBIAN_FRONTEND=noninteractive apt-get remove -y ${cpkg} 2>&1"
        _ubuntu_pkg_tmux "sdUbuntuPkg" "Removing ${cpkg}" "$rm_cmd"
    done
}

_logs_browser() {
    while true; do
        [[ -z "$LOGS_DIR" || ! -d "$LOGS_DIR" ]] && { pause "No Logs folder found."; return; }
        local _files=()
        while IFS= read -r f; do
            _files+=("$(printf "${DIM}%s${NC}" "${f#$LOGS_DIR/}")")
        done < <(find "$LOGS_DIR" -type f -name "*.log" | sort -r)
        [[ ${#_files[@]} -eq 0 ]] && { pause "No log files yet."; return; }
        _files+=("$(printf "${DIM}%s${NC}" "${L[back]}")")
        local sel; sel=$(printf '%s\n' "${_files[@]}" \
            | _fzf "${FZF_BASE[@]}" \
                --header="$(printf "${BLD}── Logs ──${NC}")" 2>/dev/null) || return
        local sel_clean; sel_clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$sel_clean" == "${L[back]}" ]] && return
        local _path="$LOGS_DIR/$sel_clean"
        [[ ! -f "$_path" ]] && continue
        cat "$_path" \
            | _fzf "${FZF_BASE[@]}" \
                --header="$(printf "${BLD}── %s  ${DIM}(read only)${NC} ──${NC}" "$sel_clean")" \
                --no-multi --disabled >/dev/null 2>&1 || true
    done
}

_help_menu() {
    local _SEP_STORAGE _SEP_PLUGINS _SEP_ISOLATION _SEP_TOOLS _SEP_DANGER _SEP_NAV
    _SEP_STORAGE="$(  printf "${BLD}  ── Storage ───────────────────────────${NC}")"
    _SEP_PLUGINS="$(  printf "${BLD}  ── Plugins ───────────────────────────${NC}")"
    _SEP_TOOLS="$(    printf "${BLD}  ── Tools ─────────────────────────────${NC}")"
    _SEP_HELP="$(     printf "${BLD}  ── Help ──────────────────────────────${NC}")"
    _SEP_DANGER="$(   printf "${BLD}  ── Caution ───────────────────────────${NC}")"
    _SEP_NAV="$(      printf "${BLD}  ── Navigation ────────────────────────${NC}")"
    while true; do
        local ubuntu_status proxy_status ubuntu_upd_tag=""
        _sd_ub_cache_read
        if [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
            ubuntu_status="$(printf "${GRN}ready${NC}  ${CYN}[P]${NC}")"
            if [[ "$_SD_UB_PKG_DRIFT" == true || "$_SD_UB_HAS_UPDATES" == true ]]; then
                ubuntu_upd_tag="  $(printf "${YLW}Updates available${NC}")"
            fi
        else
            ubuntu_status="$(printf "${YLW}not installed${NC}")"
        fi
        _proxy_running                        && proxy_status="$(printf "${GRN}running${NC}")"  || proxy_status="$(printf "${DIM}stopped${NC}")"
        local lines=(
            "$_SEP_STORAGE"
            "$(printf "${DIM} ◈  Profiles & data${NC}")"
            "$(printf "${DIM} ◈  Backups${NC}")"
            "$(printf "${DIM} ◈  Blueprints${NC}")"
            "$_SEP_PLUGINS"
            "$(printf " ${CYN}◈${NC}${DIM}  Ubuntu base — %b%s${NC}" "$ubuntu_status" "$ubuntu_upd_tag")"
            "$(printf " ${CYN}◈${NC}${DIM}  Caddy — %b${NC}" "$proxy_status")"
            "$(printf " ${CYN}◈${NC}${DIM}  QRencode — %b${NC}" "$([[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && _chroot_bash "$UBUNTU_DIR" -c 'command -v qrencode' >/dev/null 2>&1 && printf "${GRN}installed${NC}" || printf "${DIM}not installed${NC}")")"

            "$_SEP_TOOLS"
            "$(printf "${DIM} ◈  Active processes${NC}")"
            "$(printf "${DIM} ◈  Resource limits${NC}")"
            "$(printf "${DIM} ≡  Blueprint preset${NC}")"

            "$_SEP_DANGER"
            "$(printf "${DIM} ≡  View logs${NC}")"
            "$(printf "${DIM} ⊘  Clear cache${NC}")"
            "$(printf "${DIM} ▷  Resize image${NC}")"
            "$(printf "${DIM} ◈  Manage Encryption${NC}")"
            "$(printf " ${RED}×${NC}${DIM}  Delete image file${NC}")"
            "$_SEP_NAV"
            "$(printf "${DIM} %s${NC}" "${L[back]}")"
        )
        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── %s ──${NC}  ${DIM}Ubuntu:${NC}%b  ${DIM}Proxy:${NC}%b" "${L[help]}" "$ubuntu_status" "$proxy_status")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        if _sig_rc $_frc; then stty sane 2>/dev/null; continue; fi
        [[ $_frc -ne 0 ]] && return
        local sel_clean; sel_clean=$(printf '%s' "$sel" | _trim_s)
        case "$sel_clean" in
            *"${L[back]}"*)         return ;;
            *"Clear cache"*)
                confirm "Clear all cached data?" || continue
                rm -rf "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null || true
                mkdir -p "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null
                pause "Cache cleared." ;;
            *"Resize image"*)       _resize_image ;;
            *"Manage Encryption"*)  _enc_menu ;;
            *"Profiles & data"*) _persistent_storage_menu; continue ;;
            *"Backups"*)            _manage_backups_menu ;;
            *"Blueprints"*)         _blueprints_settings_menu; continue ;;
            *"Active processes"*)   _active_processes_menu ;;
            *"Resource limits"*)  _resources_menu ;;
            *"Caddy"*)               _proxy_menu; continue ;;
            *"QRencode"*)
                _qrencode_menu; continue ;;
            *"Ubuntu base"*)
                _ubuntu_menu; continue ;;
            *"Blueprint preset"*)
                _blueprint_template \
                    | _fzf "${FZF_BASE[@]}" \
                          --header="$(printf "${BLD}── Blueprint preset  ${DIM}(read only)${NC} ──${NC}")" \
                          --no-multi --disabled >/dev/null 2>&1 || true ;;
            *"Blueprint example"*) ;;
            *"View logs"*|*"Logs"*)
                _logs_browser ;;
            *"Delete image file"*)
                [[ -z "$IMG_PATH" ]] && { pause "No image currently loaded."; continue; }
                local img_name; img_name=$(basename "$IMG_PATH")
                local img_path_save="$IMG_PATH"
                confirm "$(printf "PERMANENTLY DELETE IMAGE?\n\n  File: %s\n  Path: %s\n\n  THIS CANNOT BE UNDONE!" "$img_name" "$img_path_save")" || continue
                _load_containers true
                local dcid dsess
                for dcid in "${CT_IDS[@]}"; do
                    dsess="$(tsess "$dcid")"
                    tmux_up "$dsess" && { tmux send-keys -t "$dsess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$dsess" 2>/dev/null || true; }
                done
                tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true; _tmux_set SD_INSTALLING ""
                _unmount_img; rm -f "$img_path_save" 2>/dev/null
                IMG_PATH="" BLUEPRINTS_DIR="" CONTAINERS_DIR="" INSTALLATIONS_DIR="" BACKUP_DIR="" STORAGE_DIR=""
                pause "$(printf "✓ Image deleted: %s\n\n  Select or create a new image." "$img_name")"
                _setup_image; return ;;
        esac
    done
}

_SEP="$(printf     "${BLD}  ─────────────────────────────────────${NC}")"

main_menu() {
    while true; do
        clear; _cleanup_stale_lock; _validate_containers; _load_containers false
        local inst_id; inst_id=$(_installing_id)

        local n_running=0 n_groups=0 n_bps=0
        for cid in "${CT_IDS[@]}"; do tmux_up "$(tsess "$cid")" && (( n_running++ )) || true; done
        local grp_ids=(); mapfile -t grp_ids < <(_list_groups)
        n_groups=${#grp_ids[@]}
        local bp_names=(); mapfile -t bp_names < <(_list_blueprint_names)
        local pbp_names=(); mapfile -t pbp_names < <(_list_persistent_names)
        local ibp_names=(); mapfile -t ibp_names < <(_list_imported_names)
        n_bps=$(( ${#bp_names[@]} + ${#pbp_names[@]} + ${#ibp_names[@]} ))

        local ct_status="${DIM}${#CT_IDS[@]}${NC}"
        [[ $n_running -gt 0 ]] && ct_status="$(printf "${GRN}%d running${NC}${DIM}/%d${NC}" "$n_running" "${#CT_IDS[@]}")"

        local grp_n_active=0
        for gid in "${grp_ids[@]}"; do
            local grunning=0
            while IFS= read -r cname; do
                local gcid; gcid=$(_ct_id_by_name "$cname")
                [[ -n "$gcid" ]] && tmux_up "$(tsess "$gcid")" && (( grunning++ )) || true
            done < <(_grp_containers "$gid")
            [[ $grunning -gt 0 ]] && (( grp_n_active++ )) || true
        done
        local grp_status="${DIM}${n_groups}${NC}"
        [[ $grp_n_active -gt 0 ]] && grp_status="$(printf "${GRN}%d active${NC}${DIM}/%d${NC}" "$grp_n_active" "$n_groups")"

        local lines=(
            "$(printf " ${GRN}◈${NC}  %-28s %b" "Containers" "$ct_status")"
            "$(printf " ${CYN}▶${NC}  %-28s %b" "Groups" "$grp_status")"
            "$(printf " ${BLU}◈${NC}  %-28s ${DIM}%d${NC}" "Blueprints" "$n_bps")"
            "$_SEP"
            "$(printf "${DIM} ?  %s${NC}" "${L[help]}")"
            "$(printf "${RED} ×  %s${NC}" "${L[quit]}")"
        )

        local img_label=""
        if [[ -n "$IMG_PATH" ]] && mountpoint -q "$MNT_DIR" 2>/dev/null; then
            local used_kb total_bytes
            used_kb=$(df -k "$MNT_DIR" 2>/dev/null | awk 'NR==2{print $3}')
            total_bytes=$(stat -c%s "$IMG_PATH" 2>/dev/null)
            local used_gb total_gb
            used_gb=$(awk "BEGIN{printf \"%.1f\",${used_kb:-0}/1048576}")
            total_gb=$(awk "BEGIN{printf \"%.1f\",${total_bytes:-0}/1073741824}")
            img_label="$(printf "${DIM}  %s  [%s/%s GB]${NC}" "$(basename "$IMG_PATH")" "$used_gb" "$total_gb")"
        elif [[ -n "$IMG_PATH" ]]; then
            img_label="$(printf "${DIM}  %s${NC}" "$(basename "$IMG_PATH")")"
        fi

        local _fzf_sel_out; _fzf_sel_out=$(mktemp "$TMP_DIR/.sd_fzf_sel_XXXXXX")
        printf '%s\n' "${lines[@]}" \
            | fzf "${FZF_BASE[@]}" \
                  --header="$(printf "${BLD}── %s ──${NC}%s" "${L[title]}" "$img_label")" \
                  "--bind=${KB[quit]}:execute-silent(tmux set-environment -g SD_QUIT 1)+abort" \
                  >"$_fzf_sel_out" 2>/dev/null &
        local _fzf_sel_pid=$!
        printf '%s' "$_fzf_sel_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_sel_pid" 2>/dev/null
        local _fzf_rc=$?
        if [[ $_fzf_rc -eq 143 || $_fzf_rc -eq 138 || $_fzf_rc -eq 137 ]]; then
            rm -f "$_fzf_sel_out"; stty sane 2>/dev/null; continue
        fi
        local sel; sel=$(cat "$_fzf_sel_out" 2>/dev/null); rm -f "$_fzf_sel_out"
        if [[ -z "$sel" ]]; then
            if [[ "$(_tmux_get SD_QUIT)" == "1" ]]; then
                _tmux_set SD_QUIT 0; _quit_menu; continue
            fi
            _quit_all
        fi

        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ -z "$clean" ]] && continue

        case "$clean" in
            *"${L[quit]}"*) _quit_menu ;;
            *"${L[help]}"*) _help_menu ;;

            *"Containers"*) _containers_submenu ;;
            *"Groups"*)     _groups_menu ;;
            *"Blueprints"*) _blueprints_submenu ;;
        esac
    done
}

_containers_submenu() {
    while true; do
        clear
        stty sane 2>/dev/null
        while IFS= read -r -t 0.1 -n 256 _ 2>/dev/null; do :; done
        _load_containers false
        local inst_id; inst_id=$(_installing_id)
        local lines=() n_running_ct=0
        lines+=("$(printf "${BLD}  ── Containers ──────────────────────${NC}")")

        for i in "${!CT_IDS[@]}"; do
            local cid="${CT_IDS[$i]}" n="${CT_NAMES[$i]}"
            local dialogue; dialogue=$(jq -r '.meta.dialogue // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local dot
            local _cok="$CONTAINERS_DIR/$cid/.install_ok" _cfail="$CONTAINERS_DIR/$cid/.install_fail"
            if   _is_installing "$cid" || [[ -f "$_cok" || -f "$_cfail" ]]; then dot="${YLW}◈${NC}"
            elif tmux_up "$(tsess "$cid")"; then
                (( n_running_ct++ )) || true
                if _health_check "$cid"; then dot="${GRN}◈${NC}"
                else dot="${YLW}◈${NC}"; fi
            elif [[ "$(_st "$cid" installed)" == "true" ]]; then dot="${RED}◈${NC}"
            else dot="${DIM}◈${NC}"; fi
            local disp_name
            [[ -n "$dialogue" ]] \
                && disp_name="$(printf "%s  \033[2m— %s\033[0m" "$n" "$dialogue")" \
                || disp_name="$n"
            local _sz_lbl=""
            local _ipath; _ipath=$(_cpath "$cid")
            if [[ -d "$_ipath" ]]; then
                local _sz_cache="$CACHE_DIR/sd_size/$cid"
                if [[ -f "$_sz_cache" ]]; then
                    _sz_lbl="$(printf "${DIM}[%sgb]${NC}" "$(cat "$_sz_cache" 2>/dev/null)")"
                fi
                local _sz_age=999
                [[ -f "$_sz_cache" ]] && _sz_age=$(( $(date +%s) - $(date -r "$_sz_cache" +%s 2>/dev/null || echo 0) ))
                if [[ $_sz_age -gt 60 ]]; then
                    { mkdir -p "${_sz_cache%/*}" 2>/dev/null; du -sb "$_ipath" 2>/dev/null | awk '{printf "%.2f",$1/1073741824}' > "$_sz_cache.tmp" && mv "$_sz_cache.tmp" "$_sz_cache"; } 2>/dev/null &
                    disown 2>/dev/null || true
                fi
            fi
            local _list_port; _list_port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local _list_ep; _list_ep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            [[ -n "$_list_ep" ]] && _list_port="$_list_ep"
            local _list_ip_lbl=""
            if [[ -n "$_list_port" && "$_list_port" != "0" && "$(_st "$cid" installed)" == "true" ]]; then
                local _list_ip; _list_ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
                _list_ip_lbl="$(printf "\033[2m[%s:%s]\033[0m " "$_list_ip" "$_list_port")"
            fi
            lines+=("$(printf " %b  %b\033[0m\033[2m %b %s[%s]\033[0m" "$dot" "$disp_name" "$_sz_lbl" "$_list_ip_lbl" "$cid")")
        done

        local bps=(); mapfile -t bps < <(_list_blueprint_names)
        local pbps=(); mapfile -t pbps < <(_list_persistent_names)
        local all_bps=("${bps[@]}" "${pbps[@]}")

        [[ ${#CT_IDS[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no containers yet)${NC}")")
        lines+=("$(printf "${GRN} +  %s${NC}" "${L[new_container]}")")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        local _ct_hdr_extra; _ct_hdr_extra=$(printf "  ${DIM}[%d · ${GRN}%d ▶${NC}${DIM}]${NC}" "${#CT_IDS[@]}" "$n_running_ct")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Containers ──${NC}%s" "$_ct_hdr_extra")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel}" ]] && return

        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" ]] && return
        [[ -z "$clean" ]] && continue

        if [[ "$clean" == *"${L[new_container]}"* ]]; then
            _install_method_menu; continue
        fi

        local cid_tag
        cid_tag=$(printf '%s' "$clean" | grep -oP '(?<=\[)[a-z0-9]{8}(?=\]$)' || true)
        [[ -n "$cid_tag" && -d "$CONTAINERS_DIR/$cid_tag" ]] && _container_submenu "$cid_tag"
    done
}

_blueprints_settings_menu() {
    local _SEP_GEN _SEP_PATHS _SEP_NAV
    _SEP_GEN="$(printf "${BLD}  ── General ───────────────────────────${NC}")"
    _SEP_PATHS="$(printf "${BLD}  ── Scanned paths ─────────────────────${NC}")"
    _SEP_NAV="$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"
    while true; do
        local pers_enabled; _bp_persistent_enabled && pers_enabled=true || pers_enabled=false
        local pers_tog
        [[ "$pers_enabled" == "true" ]] \
            && pers_tog="$(printf "${GRN}[Enabled]${NC}")" \
            || pers_tog="$(printf "${RED}[Disabled]${NC}")"

        local ad_mode; ad_mode=$(_bp_autodetect_mode)
        local ad_lbl
        case "$ad_mode" in
            Home)       ad_lbl="$(printf "${GRN}[Home]${NC}")" ;;
            Root)       ad_lbl="$(printf "${YLW}[Root]${NC}")" ;;
            Everywhere) ad_lbl="$(printf "${CYN}[Everywhere]${NC}")" ;;
            Custom)     ad_lbl="$(printf "${BLU}[Custom]${NC}")" ;;
            Disabled)   ad_lbl="$(printf "${DIM}[Disabled]${NC}")" ;;
        esac

        local lines=(
            "$_SEP_GEN"
            "$(printf " ${DIM}◈${NC}  Persistent blueprints  %b  ${DIM}— toggle built-in visibility${NC}" "$pers_tog")"
            "$(printf " ${DIM}◈${NC}  Autodetect blueprints  %b  ${DIM}— scan for .container files${NC}" "$ad_lbl")"
        )

        if [[ "$ad_mode" == "Custom" ]]; then
            lines+=("$_SEP_PATHS")
            local _cpaths=(); mapfile -t _cpaths < <(_bp_custom_paths_get)
            if [[ ${#_cpaths[@]} -eq 0 ]]; then
                lines+=("$(printf "${DIM}  (no paths configured)${NC}")")
            else
                for _cp in "${_cpaths[@]}"; do
                    if [[ -d "$_cp" ]]; then
                        lines+=("$(printf " ${DIM}◈${NC}  ${DIM}%s${NC}" "$_cp")")
                    else
                        lines+=("$(printf " ${DIM}◈${NC}  ${DIM}%s${NC}  ${RED}[corrupted]${NC}" "$_cp")")
                    fi
                done
            fi
            lines+=("$(printf "${GRN} +  Add path${NC}")")
        fi

        lines+=("$_SEP_NAV")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" \
            | fzf "${FZF_BASE[@]}" \
                  --header="$(printf "${BLD}── Blueprints — Settings ──${NC}")" \
                  >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "$sel" ]] && return
        local sc; sc=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*//')
        case "$sc" in
            *"${L[back]}"*|"") return ;;
            *"Persistent blueprints"*)
                [[ "$pers_enabled" == "true" ]] \
                    && _bp_cfg_set persistent_blueprints false \
                    || _bp_cfg_set persistent_blueprints true ;;
            *"Autodetect blueprints"*)
                case "$ad_mode" in
                    Home)       _bp_cfg_set autodetect_blueprints Root ;;
                    Root)       _bp_cfg_set autodetect_blueprints Everywhere ;;
                    Everywhere) _bp_cfg_set autodetect_blueprints Custom ;;
                    Custom)     _bp_cfg_set autodetect_blueprints Disabled ;;
                    Disabled)   _bp_cfg_set autodetect_blueprints Home ;;
                esac ;;
            *"Add path"*)
                if ! command -v yazi >/dev/null 2>&1; then
                    pause "yazi is not installed on this system."; continue
                fi
                local _chosen_dir; _chosen_dir=$(mktemp -u "$TMP_DIR/.sd_yazi_XXXXXX")
                yazi --chooser-file="$_chosen_dir" 2>/dev/null
                local _picked; _picked=$(cat "$_chosen_dir" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//'); rm -f "$_chosen_dir"
                [[ -z "$_picked" ]] && continue
                [[ ! -d "$_picked" ]] && { pause "$(printf "Not a directory:\n  %s" "$_picked")"; continue; }
                _bp_custom_paths_add "$_picked"
                ;;
            *)
                local _cp
                while IFS= read -r _cp; do
                    if [[ "$sc" == *"$_cp"* ]]; then
                        confirm "$(printf "Remove path from scan list?\n\n  %s" "$_cp")" || break
                        _bp_custom_paths_remove "$_cp"
                        break
                    fi
                done < <(_bp_custom_paths_get)
                ;;
        esac
    done
}

_blueprints_submenu() {
    while true; do
        clear
        while IFS= read -r -t 0 -n 1 _ 2>/dev/null; do :; done
        local bps=(); mapfile -t bps < <(_list_blueprint_names)
        local pbps=(); mapfile -t pbps < <(_list_persistent_names)
        local ibps=(); mapfile -t ibps < <(_list_imported_names)
        local lines=()

        lines+=("$(printf "${BLD}  ── Blueprints ───────────────────────${NC}")")
        for n in "${bps[@]}";  do lines+=("$(printf "${DIM} ◈${NC}  %s" "$n")"); done
        for n in "${pbps[@]}"; do lines+=("$(printf "${BLU} ◈${NC}  %s  ${DIM}[Persistent]${NC}" "$n")"); done
        for n in "${ibps[@]}"; do lines+=("$(printf "${CYN} ◈${NC}  %s  ${DIM}[Imported]${NC}" "$n")"); done

        [[ ${#bps[@]} -eq 0 && ${#pbps[@]} -eq 0 && ${#ibps[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no blueprints yet)${NC}")")
        lines+=("$(printf "${GRN} +  %s${NC}" "${L[bp_new]}")")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}── Blueprints ──${NC}  ${DIM}[%d file · %d built-in · %d imported]${NC}" "${#bps[@]}" "${#pbps[@]}" "${#ibps[@]}")" \
            >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel}" ]] && return
        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" ]] && return

        local sc; sc=$(printf '%s' "$clean" | _strip_ansi | sed 's/^[[:space:]]*//')

        if [[ "$clean" == *"${L[bp_new]}"* ]]; then
            _guard_space || continue
            finput "Blueprint name:" || continue
            local bname; bname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"
            [[ -z "$bname" ]] && continue
            local bfile; bfile="$BLUEPRINTS_DIR/$bname.toml"
            [[ -f "$bfile" ]] && { pause "Blueprint '$bname' already exists."; continue; }
            _blueprint_template > "$bfile"
            pause "Blueprint '$bname' created. Select it to edit."
            continue
        fi

        if [[ "$clean" == *"[Persistent]"* ]]; then
            local pname; pname=$(printf '%s' "$clean" | sed 's/^[[:space:]]*◈[[:space:]]*//;s/[[:space:]]*\[Persistent\].*//')
            [[ -n "$pname" ]] && _view_persistent_bp "$pname"
            continue
        fi

        if [[ "$clean" == *"[Imported]"* ]]; then
            local iname; iname=$(printf '%s' "$clean" | sed 's/^[[:space:]]*◈[[:space:]]*//;s/[[:space:]]*\[Imported\].*//')
            local ipath; ipath=$(_get_imported_bp_path "$iname")
            if [[ -n "$ipath" && -f "$ipath" ]]; then
                cat "$ipath" \
                    | _fzf "${FZF_BASE[@]}" \
                          --header="$(printf "${BLD}── [Imported] %s  ${DIM}(%s)${NC} ──${NC}" "$iname" "$ipath")" \
                          --no-multi --disabled 2>/dev/null || true
            else
                pause "Could not locate imported blueprint '$iname'."
            fi
            continue
        fi

        for n in "${bps[@]}"; do
            if [[ "$clean" == *"$n"* ]]; then _blueprint_submenu "$n"; break; fi
        done
    done
}

_require_sudo
tmux set-environment SD_READY 1 2>/dev/null || true
for _sd_stale in "$SD_MNT_BASE"/mnt_*; do
    [[ -d "$_sd_stale" ]] || continue
    mountpoint -q "$_sd_stale" 2>/dev/null && sudo -n umount -lf "$_sd_stale" 2>/dev/null || true
done
unset _sd_stale
rm -rf "$SD_MNT_BASE" 2>/dev/null || true
mkdir -p "$SD_MNT_BASE" "$TMP_DIR" 2>/dev/null || true
_setup_image
main_menu 