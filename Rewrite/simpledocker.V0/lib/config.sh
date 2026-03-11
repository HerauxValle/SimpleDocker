# lib/config.sh — Configuration variables, constants, baked blueprints & presets
# Sourced by main.sh — do NOT run directly

# ── Basic ─────────────────────────────────────────────────────────
DEFAULT_IMG=""                # path to .img file to auto-mount on launch (leave empty to prompt)
DEFAULT_UBUNTU_PKGS="curl git wget ca-certificates zstd tar xz-utils python3 python3-venv python3-pip build-essential"
ROOT_DIR="$HOME/.config/simpleDocker"  # where image list and config are stored

# Keyboard shortcuts
declare -A KB=(
    [detach]="ctrl-d"         # detach from tmux session
    [quit]="ctrl-q"           # quit simpleDocker
    [tmux_detach]="ctrl-\\"   # detach inside tmux
)

# UI colors (ANSI escape codes)
GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[0;33m'; BLU='\033[0;34m'
CYN='\033[0;36m'; BLD='\033[1m';    DIM='\033[2m';     NC='\033[0m'

# Verification cipher — derived from machine-id, unique per host, used for verified system auto-unlock
SD_VERIFICATION_CIPHER=$(sha256sum /etc/machine-id 2>/dev/null | cut -c1-32 || printf '%s' "simpledocker_fallback")
# Default keyword — slot 1 reserved, weakest params, present when System Agnostic is enabled
SD_DEFAULT_KEYWORD="1991316125415311518"
# Key slot allocation: slot 0=authkey, slot 1=default keyword, 2-6=reserved, 7-31=user pool (25 slots)
SD_LUKS_KEY_SLOT_MIN=7
SD_LUKS_KEY_SLOT_MAX=31

# ── Advanced ──────────────────────────────────────────────────────
# Unlock attempt order — space-separated list of: "verified_system" "default_keyword" "prompt"
# verified_system = machine-id derived cipher (SD_VERIFICATION_CIPHER, auto-unlock)
# default_keyword  = static weak key (SD_DEFAULT_KEYWORD, system agnostic / slot 1)
# prompt           = ask user for passphrase
SD_UNLOCK_ORDER="verified_system default_keyword prompt"

SD_MNT_BASE="${XDG_RUNTIME_DIR:-$HOME/.local/share}/simpleDocker"  # host mount points only
TMP_DIR="$SD_MNT_BASE/.tmp"  # pre-mount bootstrap; reset to inside img after mount
CACHE_DIR=""                  # set after mount to $MNT_DIR/.cache
SD_SHELL_PID=$$               # main shell pid — watcher sends SIGUSR1 here to force fzf refresh
SD_ACTIVE_FZF_PID=""          # pid of currently blocking fzf, updated by _fzf()
trap '_sd_usr1_handler() { _SD_USR1_FIRED=1; kill "$(cat "$TMP_DIR/.sd_active_fzf_pid" 2>/dev/null)" 2>/dev/null || true; sleep 0.2; stty sane 2>/dev/null; while IFS= read -r -t 0.15 -n 256 _ 2>/dev/null; do :; done; }; _sd_usr1_handler' USR1
_SD_USR1_FIRED=0
# Per-mount Ubuntu status cache (computed once after mount, never rechecked until remount)
_SD_UB_PKG_DRIFT=false    # true if DEFAULT_UBUNTU_PKGS differ from .ubuntu_default_pkgs
_SD_UB_HAS_UPDATES=false  # true if apt-get --simulate upgrade has pending upgrades
_SD_UB_CACHE_LOADED=false # guard — cache_read runs exactly once per mount

# ── Persistent blueprints baked into the script ───────────────────
# Format: one # [Name] line followed by the blueprint DSL block.
# Read-only — edit directly in this script.
# ─────────────────────────────────────────────────────────────────
: << 'SD_PERSISTENT_END'

# [Counter]
[container]
[meta]
name         = counter-test
version      = 2.0.0
port         = 8833
dialogue     = Feature test
storage_type = counter-test
health       = true
log          = logs/counter.log

[dirs]
logs

[install]
for i in $(seq 1 10); do
    printf '%d\n' "$i"
    sleep 0.2
done
printf 'Install done.\n'

[start]
mkdir -p "$CONTAINER_ROOT/logs"
n=1
while true; do
    printf '[%s] tick %d\n' "$(date '+%H:%M:%S')" "$n" | tee -a "$CONTAINER_ROOT/logs/counter.log"
    (( n++ ))
    sleep 1
done

[actions]
Reset log      | printf '' > "$CONTAINER_ROOT/logs/counter.log" && printf 'Log cleared.\n'
Show log tail  | tail -20 "$CONTAINER_ROOT/logs/counter.log"

[cron]
10s [ping]     | printf '[cron] ping at %s\n' "$(date '+%H:%M:%S')" >> logs/counter.log
1m [minutely]  | printf '[cron] 1min heartbeat\n' >> logs/counter.log

[/container]

SD_PERSISTENT_END

# ══════════════════════════════════════════════════════════════════════════
# ── Blueprint presets ─────────────────────────────────────────────────────
# Shown in Other → Blueprint preset and used as template for new blueprints
# ══════════════════════════════════════════════════════════════════════════

read -r -d '' SD_BLUEPRINT_PRESET <<'SD_PRESET_END' || true
[container]

[meta]
name         = my-service
version      = 1.0.0
dialogue     = Short label shown in the container list
description  = Longer notes about this service.
port         = 8080
storage_type = my-service
entrypoint   = bin/my-service --port 8080
# log        = logs/service.log        # log file shown in View log (default: start.log)
# health     = [true | false]          # enable health check ping on port
# gpu        = [nvidia | amd]          # pass GPU into container
# cap_drop   = [true | false]          # drop Linux capabilities (default: true)
# seccomp    = [true | false]          # apply seccomp profile (default: true)

[env]
PORT     = 8080
HOST     = 127.0.0.1
DATA_DIR = data
# API_KEY = secret

[storage]
# Paths inside CONTAINER_ROOT that persist across reinstalls
data, logs

[deps]
# apt packages installed into the container chroot
curl, tar

[dirs]
# Directories created automatically inside CONTAINER_ROOT
# Supports nested:  lib(subdir1, subdir2)
bin, data, logs

[pip]
# Python packages installed into CONTAINER_ROOT/venv
# Supports version pins: requests==2.31.0  or bare: requests

[npm]
# Node packages installed into CONTAINER_ROOT/node_modules
# e.g. express, lodash

[git]
# org/repo                              → auto-detect archive/binary, extract to CONTAINER_ROOT
# org/repo [asset-name.tar.zst]         → match exact release asset filename, then extract
# org/repo [asset-name][TYPE]           → match asset and filter by type before selecting
# org/repo → subdir/                    → extract to subdir
# org/repo source                       → git clone to src/
# TYPE tokens: [BIN] raw binary  [ZIP] .zip  [TAR] .tar.gz/.tar.zst/etc  (default: auto/ZIP)

[build]
# Compile steps — run once during install, after git source clone
# cd src && make

[install]
# Extra setup steps run once after deps/dirs/git

[update]
# Steps run when manually triggering Update from the container menu

[start]
# Script run to start the container (runs inside namespace+chroot)
# $CONTAINER_ROOT is always available and points to the install path

[cron]
# interval [name] [--sudo] [--unjailed] | command
# interval: [N][s|m|h]  e.g. 30s, 5m, 1h
# --unjailed: run on host instead of inside container
# --sudo:     wrap command with sudo
# 5m [heartbeat] | printf '[cron] ping\n' >> logs/cron.log

[actions]
# One action per line:  Label | [prompt: "text" |] [select: cmd [--skip-header] [--col N] |] cmd [{input}|{selection}]
# ⊙ auto-prepended if label starts with a plain letter
Show logs | tail -f logs/service.log

[/container]
SD_PRESET_END
# ─────────────────────────────────────────────────────────────────

declare -A L=(
    [title]="simpleDocker"
    [detach]="⊙  Detach"
    [quit]="Quit"
    [quit_stop_all]="■  Stop all & quit"
    [new_container]="New container"
    [help]="Other"
    [help_resize]="Resize image"
    [help_storage]="Persistent storage"
    [ct_start]="▶  Start"
    [ct_stop]="■  Stop"
    [ct_restart]="↺  Restart"
    [ct_attach]="→  Attach"
    [ct_install]="↓  Install"
    [ct_edit]="◦  Edit toml"
    [ct_terminal]="◉  Terminal"
    [ct_update]="↑  Update"
    [ct_uninstall]="○  Uninstall"
    [ct_remove]="×  Remove"
    [ct_rename]="✎  Rename"
    [ct_backups]="◈  Backups"
    [ct_profiles]="◧  Profiles"
    [ct_open_in]="⊕  Open in"
    [ct_exposure]="⬤  Port exposure"
    [ct_attach_inst]="→  Attach to installation"
    [ct_kill_inst]="×  Kill installation"
    [ct_finish_inst]="✓  Finish installation"
    [ct_log]="≡  View log"
    [bp_new]="New blueprint"
    [bp_edit]="◦  Edit"
    [bp_delete]="×  Delete"
    [bp_rename]="✎  Rename"
    [grp_new]="New group"
    [stor_rename]="✎  Rename"
    [stor_delete]="×  Delete"
    [back]="← Back"
    [yes]="Yes, confirm"
    [no]="No"
    [ok_press]="Press Enter or ESC to continue"
    [type_enter]="Type and press Enter  (ESC to cancel)"
    [msg_install_running]="An installation is already running"
    [msg_install_ok]="installed successfully."
    [msg_install_fail]="Installation failed — attach to check output."
    [img_select]="Select existing image"
    [img_create]="Create new image"
)

mkdir -p "$SD_MNT_BASE" "$TMP_DIR" 2>/dev/null

MNT_DIR=""
IMG_PATH=""
BLUEPRINTS_DIR=""
CONTAINERS_DIR=""
INSTALLATIONS_DIR=""
BACKUP_DIR=""
STORAGE_DIR=""
UBUNTU_DIR=""
GROUPS_DIR=""
LOGS_DIR=""

_stor_ctx_cid=""  # set before calling _persistent_storage_menu from container context

