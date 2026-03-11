#!/usr/bin/env bash
# simpleDocker — entry point
# Usage: main.sh           → TUI
#        main.sh <cmd> ... → CLI  (e.g. main.sh start mycontainer)

SD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source order matters: globals → utils → state → lib → tui/cli ──
source "$SD_ROOT/core/globals.sh"
source "$SD_ROOT/lib/sudo.sh"
source "$SD_ROOT/core/utils.sh"
source "$SD_ROOT/core/state.sh"

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
    # TUI mode — source TUI layer only when needed
    source "$SD_ROOT/tui/ui.sh"
    source "$SD_ROOT/tui/image.sh"
    source "$SD_ROOT/tui/containers.sh"
    source "$SD_ROOT/tui/groups.sh"
    source "$SD_ROOT/tui/blueprints.sh"
    source "$SD_ROOT/tui/storage.sh"
    source "$SD_ROOT/tui/backups.sh"
    source "$SD_ROOT/tui/other.sh"

    # Entry point (mirrors original services.sh)
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
else
    source "$SD_ROOT/cli/commands.sh"
    cli_dispatch "$@"
fi
