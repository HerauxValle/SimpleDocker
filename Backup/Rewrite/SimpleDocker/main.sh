#!/usr/bin/env bash

#  simpleDocker — native container orchestrator
#  BTRFS image → subvolumes per container | no Docker, no daemons
#
#  Image structure:
#    /Blueprints/      — blueprint .toml files
#    /Containers/<id>/ — state.json + service.src per container
#    /Installations/   — one BTRFS subvolume per installed container
#    /Groups/          — group definitions
#    /Storage/         — persistent storage profiles
#    /Backup/          — container snapshots
#
#  Blueprint format (.toml-like DSL):
#    [container]            outer wrapper
#    [meta]                 name, version, dialogue, description, port, storage_type,
#                           entrypoint, log, health, gpu, cap_drop, seccomp
#    [env]                  KEY = VALUE  (auto-prefixes relative paths with $CONTAINER_ROOT)
#    [storage]              path1, path2, ...  (persists across reinstalls)
#    [deps]                 apt packages installed into the chroot
#    [dirs]                 directories created inside CONTAINER_ROOT (supports nested)
#    [pip]                  python packages installed into CONTAINER_ROOT/venv
#    [npm]                  node packages installed into CONTAINER_ROOT/node_modules
#    [git]                  org/repo  → auto-extract | source | → subdir/
#    [build]                compile steps, run once during install after git clone
#    [install]              setup script run once after deps/dirs/git
#    [update]               script run when Update is triggered from the menu
#    [start]                script run to start the container (inside namespace+chroot)
#    [cron]                 interval [name] [--sudo] [--unjailed] | command
#    [Any custom name]      custom action shown in the container menu
#    [/container]           close outer wrapper
#
#  Next [section] implicitly ends the previous one.
#  # comments work everywhere outside bash blocks.
#  $CONTAINER_ROOT is auto-injected and relative paths are auto-prefixed.

# ── Basic ─────────────────────────────────────────────────────────

# ── Source modules ───────────────────────────────────────────────
SD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SD_DIR/core/state.sh"
source "$SD_DIR/core/system.sh"
source "$SD_DIR/core/blueprints.sh"
source "$SD_DIR/core/containers.sh"
source "$SD_DIR/core/groups.sh"
source "$SD_DIR/core/storage.sh"
source "$SD_DIR/tui/menus.sh"

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

#  ENTRY POINT
_require_sudo
tmux set-environment SD_READY 1 2>/dev/null || true
# Clean up stale mounts and entire SD_MNT_BASE from crashed/killed sessions
for _sd_stale in "$SD_MNT_BASE"/mnt_*; do
    [[ -d "$_sd_stale" ]] || continue
    mountpoint -q "$_sd_stale" 2>/dev/null && sudo -n umount -lf "$_sd_stale" 2>/dev/null || true
done
unset _sd_stale
rm -rf "$SD_MNT_BASE" 2>/dev/null || true
mkdir -p "$SD_MNT_BASE" "$TMP_DIR" 2>/dev/null || true
_setup_image
main_menu