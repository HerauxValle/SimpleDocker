#!/usr/bin/env bash

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
    # Auto-derive exposure from HOST env only on first start (no exposure file yet).
    # Once the user has cycled exposure manually, that choice is permanent — HOST env is ignored.
    if [[ ! -f "$(_exposure_file "$cid")" ]]; then
        local _host_env; _host_env=$(jq -r '.environment.HOST // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        if [[ "$_host_env" == "0.0.0.0" ]]; then
            _exposure_set "$cid" "public"
        elif [[ "$_host_env" == "127.0.0.1" || "$_host_env" == "localhost" ]]; then
            _exposure_set "$cid" "localhost"
        fi
    fi
    _exposure_apply "$cid"
    # Write persistent sudoers for mount/umount so start.sh tmux session can use sudo -n
    local _sd_me; _sd_me=$(id -un)
    local _sd_sudoers="/etc/sudoers.d/simpledocker_${_sd_me}"
    : # sudoers written at startup by _sd_outer_sudo

    # Apply cgroups via systemd-run --user --scope if resources are enabled for this container
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
    # Kill session when process exits (Ctrl+C, crash) so tmux_up returns false immediately
    tmux set-hook -t "$sess" pane-exited "kill-session -t $sess" 2>/dev/null || true
    # Watcher: send SIGUSR1 to refresh menu when session ends
    { while tmux_up "$sess" 2>/dev/null; do sleep 0.5; done
      kill -USR1 "$SD_SHELL_PID" 2>/dev/null || true
    } &
    disown $! 2>/dev/null || true
    # Start any cron jobs defined in the blueprint
    _cron_start_all "$cid"
    # Drop capabilities after container process is up
    { sleep 2; _cap_drop_apply "$cid"; _seccomp_apply "$cid"; } &>/dev/null &
    disown $! 2>/dev/null || true
    if [[ "$_auto" == "true" ]]; then
        sleep 0.5
        return 0
    fi
    sleep 0.5
    sd_start_prompt "$sess" "$(_cname "$cid")"
}

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
    # Drop caps from all children of the pane shell (the actual service processes)
    pgrep -P "$pane_pid" 2>/dev/null | while IFS= read -r cpid; do
        sudo -n capsh --drop="$_SD_CAP_DROP_DEFAULT" --pid="$cpid" 2>/dev/null || true
    done
}

_seccomp_enabled() {
    local v; v=$(jq -r '.meta.seccomp // "true"' "$CONTAINERS_DIR/$1/service.json" 2>/dev/null)
    [[ "$v" != "false" ]]
}

_seccomp_apply() {
    local cid="$1"
    _seccomp_enabled "$cid" || return 0

    # Method 1: systemd-run scope already running — add SystemCallFilter
    if [[ -f "$CONTAINERS_DIR/$cid/resources.json" ]] && \
       [[ "$(jq -r '.enabled // false' "$CONTAINERS_DIR/$cid/resources.json" 2>/dev/null)" == "true" ]]; then
        local unit="sd-${cid}.scope"
        if systemctl --user is-active "$unit" &>/dev/null; then
            local block_str; block_str=$(printf '~%s ' "${_SD_SECCOMP_BLOCKLIST[@]}")
            systemctl --user set-property "$unit" "SystemCallFilter=${block_str}" 2>/dev/null || true
            return 0
        fi
    fi

    # Method 2: write seccomp profile to container dir and apply via nsenter to service pids
    # This is best-effort — requires libseccomp/scmp_sys_resolver or similar
    # For now: write the profile file so it can be picked up by future tooling
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
    # Send SIGINT to the foreground process group (same as pressing Ctrl-C manually)
    tmux send-keys -t "$sess" C-c "" 2>/dev/null || true
    # Wait up to 8s for the session to die naturally (pane-exited hook kills it on process exit)
    local _w=0
    while tmux_up "$sess" 2>/dev/null && [[ $_w -lt 40 ]]; do
        sleep 0.2; (( _w++ )) || true
    done
    # Force-kill if still alive after grace period
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
    sd_msg "'$(_cname "$cid")' stopped."
    _update_size_cache "$cid"
}

_ct_main_pid() {
    # Get the main process PID from the tmux session (first child of the shell)
    local sess; sess="$(tsess "$1")"
    tmux list-panes -t "$sess" -F "#{pane_pid}" 2>/dev/null | head -1
}
