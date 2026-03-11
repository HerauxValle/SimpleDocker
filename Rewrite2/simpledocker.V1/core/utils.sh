#!/usr/bin/env bash

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
    # $1=cid $2=mode(start|install|update)
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
    # Trim log file to last 8MB if it exceeds 10MB
    local f="$1"
    [[ ! -f "$f" ]] && return
    local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [[ "$sz" -gt 10485760 ]] && tail -c 8388608 "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || true
}

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

_update_size_cache() {
    local cid="$1"
    local _ipath; _ipath=$(_cpath "$cid")
    [[ -d "$_ipath" ]] || return
    local _sz; _sz=$(du -sb "$_ipath" 2>/dev/null | awk '{printf "%.2f",$1/1073741824}')
    [[ -n "$_sz" ]] && printf '%s' "$_sz" > "$CACHE_DIR/sd_size/$cid"
}
