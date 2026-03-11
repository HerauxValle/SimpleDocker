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

# ── Resolve script location (works regardless of where main.sh is called from)
SD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source all lib files (order matters: config first, then helpers, then everything else)
source "$SD_DIR/lib/config.sh"
source "$SD_DIR/lib/helpers.sh"
source "$SD_DIR/lib/image.sh"
source "$SD_DIR/lib/network.sh"
source "$SD_DIR/lib/encryption.sh"
source "$SD_DIR/lib/ui.sh"
source "$SD_DIR/lib/mount.sh"
source "$SD_DIR/lib/blueprint.sh"
source "$SD_DIR/lib/install.sh"
source "$SD_DIR/lib/container.sh"
source "$SD_DIR/lib/groups.sh"
source "$SD_DIR/lib/backup.sh"
source "$SD_DIR/lib/storage.sh"
source "$SD_DIR/lib/updates.sh"

# ── Source all menu files
source "$SD_DIR/menus/install_flow.sh"
source "$SD_DIR/menus/containers.sh"
source "$SD_DIR/menus/system.sh"
source "$SD_DIR/menus/proxy.sh"
source "$SD_DIR/menus/ubuntu.sh"
source "$SD_DIR/menus/logs_help.sh"
source "$SD_DIR/menus/main_menu.sh"

# ── ENTRY POINT
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
