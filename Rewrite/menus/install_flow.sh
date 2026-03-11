# menus/install_flow.sh — Install progress UI: _installing_menu, _process_install_finish,
#                          _tmux_launch, _tmux_attach_hint, _open_in_submenu
# Sourced by main.sh — do NOT run directly

# ── Install completion watcher ────────────────────────────────────
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
        # Stale if ok_file is older than 10 minutes and tmux session is gone
        local _ok_age; _ok_age=$(( $(date +%s) - $(date -r "$ok_file" +%s 2>/dev/null || echo 0) ))
        if [[ "$_ok_age" -gt 600 ]] && ! tmux_up "$(_inst_sess "$cid")"; then
            rm -f "$ok_file"; pause "⚠  Installation result is stale. Please reinstall."; return
        fi
        rm -f "$ok_file"
        # Pkg update: container already installed — just update manifest + show done
        if [[ "$(_st "$cid" installed)" == "true" ]]; then
            _write_pkg_manifest "$cid"
            pause "$(printf "'%s' packages updated." "$name")"
            return
        fi
        # Fresh install
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
    # Shared attach/background launcher
    # Usage: _tmux_launch [--no-prompt] [--post-launch ok_file fail_file] sess title script
    #   --no-prompt        : skip fzf ask, always attach immediately (e.g. sdResize)
    #   --post-launch f1 f2: launch first, sleep 0.25, check ok/fail, then ask (e.g. storage)
    # Returns 2 if session finished while prompt open (caller should 'continue' to refresh)
    # Returns 1 if user cancelled
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

    # ── No-prompt: start and attach immediately ──
    if [[ "$_no_prompt" == "true" ]]; then
        tmux kill-session -t "$sess" 2>/dev/null || true
        tmux new-session -d -s "$sess" "bash $(printf '%q' "$script")${_logcmd}; rm -f $(printf '%q' "$script")" 2>/dev/null
        tmux switch-client -t "$sess" 2>/dev/null || true
        sleep 0.1; stty sane 2>/dev/null
        while IFS= read -r -t 0 -n 256 _ 2>/dev/null; do :; done
        return 0
    fi

    # ── Ask first, then start ──
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

    # ── Now start the session ──
    tmux kill-session -t "$sess" 2>/dev/null || true
    tmux new-session -d -s "$sess" "bash $(printf '%q' "$script")${_logcmd}; rm -f $(printf '%q' "$script")" 2>/dev/null
    tmux set-option -t "$sess" detach-on-destroy off 2>/dev/null || true

    if printf '%s' "$choice" | grep -qi "attach"; then
        tmux switch-client -t "$sess" 2>/dev/null || true
        # Ctrl+C or detach can leave terminal in raw/doubled state — full restore
        sleep 0.2; stty sane 2>/dev/null
        while IFS= read -r -t 0.2 -n 256 _ 2>/dev/null; do :; done
        tput reset 2>/dev/null || clear
        # Attached: return naturally re-renders the menu — no USR1 needed
    else
        # Background: terminal stayed here but key presses made while fzf
        # was open may have buffered — drain them so they don't leak into
        # the next fzf invocation.
        sleep 0.1; stty sane 2>/dev/null
        while IFS= read -r -t 0.15 -n 256 _ 2>/dev/null; do :; done
        # Background: fire USR1 when done so the menu refreshes automatically
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

# ── Open in submenu ───────────────────────────────────────────────
_open_in_submenu() {
    local cid="$1"; local name; name=$(_cname "$cid")
    local is_running=false; tmux_up "$(tsess "$cid")" && is_running=true
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local svc_port; svc_port=$(jq -r '.meta.port // 0' "$sj" 2>/dev/null); svc_port="${svc_port:-0}"
    local env_port; env_port=$(jq -r '.environment.PORT // empty' "$sj" 2>/dev/null)
    [[ -n "$env_port" ]] && svc_port="$env_port"
    local install_path; install_path=$(_cpath "$cid")

    # Prefer proxy URL over localhost:port if a route exists for this container
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

