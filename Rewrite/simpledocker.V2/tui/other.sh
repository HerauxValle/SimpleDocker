#!/usr/bin/env bash

_quit_all() {
    confirm "Stop all containers and quit?" || return
    _load_containers true
    for cid in "${CT_IDS[@]}"; do
        local sess; sess="$(tsess "$cid")"
        tmux_up "$sess" && { tmux send-keys -t "$sess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$sess" 2>/dev/null || true; }
        # Mark any in-progress install as failed before killing its session
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

main_menu() {
    # Main menu is now driven by menu.json via sd_menu (core/menu.sh).
    # The image label in the header is injected here before each render.
    while true; do
        clear; _cleanup_stale_lock; _validate_containers; _load_containers false

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

        # Temporarily override header to include img_label
        SD_MAIN_IMG_LABEL="$img_label"
        sd_menu "main"

        # sd_menu returns on back/ESC — at root that means quit prompt
        _quit_all
    done
}
