#!/usr/bin/env bash

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

    # Resolve --sudo: wrap cmd in sudo -n bash -c unless it already starts with sudo
    local _use_sudo=false _unjailed=false
    printf '%s' "$cflags" | grep -q -- '--sudo'    && _use_sudo=true
    printf '%s' "$cflags" | grep -q -- '--unjailed' && _unjailed=true
    if [[ "$_use_sudo" == "true" ]]; then
        local _cmd_trimmed; _cmd_trimmed=$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//')
        if [[ "$_cmd_trimmed" != sudo* ]]; then
            # Bake CONTAINER_ROOT into the cmd so sudo's clean shell has the right path
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
            # Jailed: run inside namespace+chroot, cd to install path inside the chroot (/mnt)
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
            # Unjailed: run on host with CONTAINER_ROOT set to install path
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
    # Remove all next-time files so running loops exit cleanly
    rm -f "$CONTAINERS_DIR/$cid"/cron_*_next 2>/dev/null
    while IFS= read -r sess; do
        tmux kill-session -t "$sess" 2>/dev/null || true
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdCron_${cid}_")
}
