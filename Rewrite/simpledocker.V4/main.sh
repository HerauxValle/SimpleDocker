#!/usr/bin/env bash
# simpleDocker — entry point
# Usage: ./main.sh          → TUI (interactive fzf menus)
#        ./main.sh <cmd>... → CLI (e.g. ./main.sh start mycontainer)

SD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SD_ROOT/core/globals.sh"
source "$SD_ROOT/core/state.sh"
source "$SD_ROOT/core/utils.sh"
source "$SD_ROOT/lib/sudo.sh"

for _f in \
    "$SD_ROOT/lib/image.sh" \
    "$SD_ROOT/lib/blueprints.sh" \
    "$SD_ROOT/lib/containers.sh" \
    "$SD_ROOT/lib/groups.sh" \
    "$SD_ROOT/lib/storage.sh" \
    "$SD_ROOT/lib/jobs.sh" \
    "$SD_ROOT/lib/cron.sh" \
    "$SD_ROOT/lib/backups.sh" \
    "$SD_ROOT/lib/networking.sh" \
    "$SD_ROOT/lib/resources.sh" \
    "$SD_ROOT/lib/updates.sh"; do
    source "$_f"
done

for _f in \
    "$SD_ROOT/plugins/encryption.sh" \
    "$SD_ROOT/plugins/ubuntu.sh" \
    "$SD_ROOT/plugins/caddy.sh" \
    "$SD_ROOT/plugins/qrencode.sh"; do
    source "$_f"
done

if [[ $# -eq 0 ]]; then
    # ── TUI mode ──────────────────────────────────────────────────
    source "$SD_ROOT/core/io.sh"
    source "$SD_ROOT/tui/image.sh"
    source "$SD_ROOT/tui/containers.sh"
    source "$SD_ROOT/tui/groups.sh"
    source "$SD_ROOT/tui/blueprints.sh"
    source "$SD_ROOT/tui/storage.sh"
    source "$SD_ROOT/tui/other.sh"

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
else
    # ── CLI mode ──────────────────────────────────────────────────
    source "$SD_ROOT/cli/commands.sh"
    _require_sudo
    _setup_image_headless 2>/dev/null || true
    _load_containers false
    cli_dispatch "$@"
fi
