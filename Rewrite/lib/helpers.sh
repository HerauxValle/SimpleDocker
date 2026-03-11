# lib/helpers.sh — Core helpers: dependency check, sudo keepalive, tmux bootstrap,
#                   log write/rotate, health check, URL opener
# Sourced by main.sh — do NOT run directly

# Resolve bash inside a chroot target (Ubuntu Noble uses merged /usr, /bin→usr/bin)
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

# ── Dependency check ─────────────────────────────────────────────────
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

# ── User namespace: intentionally NOT used ───────────────────────────
# --map-root-user/--user creates a child user namespace where the caller
# appears as root, but the kernel marks all mounts inherited from the initial
# user namespace as MNT_LOCKED. Inside that namespace, bind-mounting /sys,
# /dev, or any loop-backed path fails with EPERM — exactly the opposite of
# what we want. sudo already gives real CAP_SYS_ADMIN; the plain
# --mount --pid --uts --ipc unshare flags are sufficient for full isolation.
SD_USERNS_OK=false   # kept for compatibility; never set to true

# ── BTRFS kernel pre-flight ───────────────────────────────────────
grep -qw btrfs /proc/filesystems 2>/dev/null || {
    clear
    printf '\n  \033[0;31m✗  BTRFS is not available in your kernel.\033[0m\n'
    printf '  \033[2m  Enable CONFIG_BTRFS_FS or install the btrfs kernel module.\033[0m\n\n'
    exit 1
}

tmux bind-key -n 'C-\\' detach-client 2>/dev/null || true

# ── Sudo keep-alive ─────────────────────────────────────────────────
_sudo_keepalive() {
    ( while true; do sudo -n true 2>/dev/null; sleep 55; done ) &
    disown "$!" 2>/dev/null || true
}

_require_sudo() {
    # Sudoers is written in the outer shell (before tmux) where a real tty exists.
    # Inside tmux we just need the keepalive — sudo -n commands work because the rule is already written.
    _sudo_keepalive
}

# ── Tmux bootstrap ────────────────────────────────────────────────
if [[ -z "$TMUX" ]]; then
    _self="$(realpath "$0" 2>/dev/null || printf '%s' "$0")"
    # ── Sudo auth + sudoers write happens HERE, in the outer shell with a real tty ──
    # Inside tmux there is no tty, so sudo password prompts and plain 'sudo tee' fail silently.
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
    # If a session exists and is stuck (SD_READY not set = still in auth or crashed), kill it
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
            # If install was in progress with no result yet, mark as failed
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

# ── Core helpers ──────────────────────────────────────────────────
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
# Write to a capped log file (max 10 MB — truncate to last 80% on overflow)
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
    # $1=cid $2=mode(start|install|update)
    local cname; cname=$(_cname "$1" 2>/dev/null || printf '%s' "$1")
    printf '%s/%s-%s-%s.log' "$LOGS_DIR" "$cname" "$1" "$2"
}

# Port-based health check for containers with health=true in [meta]
# Returns 0 (healthy) or 1 (unhealthy/no port)
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
    # Trim log file to last 8MB if it exceeds 10MB
    local f="$1"
    [[ ! -f "$f" ]] && return
    local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [[ "$sz" -gt 10485760 ]] && tail -c 8388608 "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || true
}
_rand_id()    { local id
                while true; do id=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
                    [[ ! -d "$CONTAINERS_DIR/$id" ]] && printf '%s' "$id" && return; done; }

# ── Open URL in existing browser tab (not a new profile/window) ───
# xdg-open launches the browser fresh which triggers new-profile setup on
# Vivaldi/Chrome. Instead we detect the default browser and call it directly
# with --new-tab so it reuses an already-running instance.
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
            # Unknown browser — try gtk-launch with the URL first (opens new tab
            # if already running for most browsers), fall back to xdg-open.
            { [[ -n "$browser" ]] && gtk-launch "$browser" "$url" 2>/dev/null; } & disown \
            || xdg-open "$url" 2>/dev/null & disown ;;
    esac
}

