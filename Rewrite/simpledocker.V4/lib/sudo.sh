#!/usr/bin/env bash

_sudo_keepalive() {
    ( while true; do sudo -n true 2>/dev/null; sleep 55; done ) &
    disown "$!" 2>/dev/null || true
}

_require_sudo() {
    # Sudoers is written in the outer shell (before tmux) where a real tty exists.
    # Inside tmux we just need the keepalive — sudo -n commands work because the rule is already written.
    _sudo_keepalive
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
