#!/usr/bin/env bash
# core/state.sh — configuration, globals, state helpers, blueprint parser

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


_stor_ctx_cid=""  # set before calling _persistent_storage_menu from container context

# Resolve bash inside a chroot target (Ubuntu Noble uses merged /usr, /bin→usr/bin)
_chroot_bash() {
    local root="$1"; shift
    local bash_bin
    if [[ -f "$root/bin/bash" || -L "$root/bin/bash" ]]; then
        bash_bin=/bin/bash
    elif [[ -f "$root/usr/bin/bash" ]]; then
        bash_bin=/usr/bin/bash
    else
        bash_bin=/bin/bash  # fallback, let chroot report the error
    fi
    sudo -n chroot "$root" "$bash_bin" "$@"
}

# ── Dependency check ─────────────────────────────────────────────────
_check_deps() {
    local missing=()
    for t in jq tmux yazi fzf btrfs sudo curl ip; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    [[ ${#missing[@]} -eq 0 ]] && return
    clear
    local ans
    ans=$(printf '%s\n' "Yes, install them" "No, exit" \
        | fzf --ansi --no-sort --prompt="  ❯ " --pointer="▶" \
              --height=40% --reverse --border=rounded --margin=1,2 --no-info \
              --header="$(printf "  Required: jq tmux yazi fzf btrfs-progs sudo curl iproute2\n  Missing:  %s\n\n  Install missing tools?" "${missing[*]}")" \
              2>/dev/null)
    [[ "$ans" != "Yes, install them" ]] && clear && exit 1
    local pm_cmd=""
    if   command -v pacman  &>/dev/null; then pm_cmd="sudo pacman -S --noconfirm"
    elif command -v apt-get &>/dev/null; then pm_cmd="sudo apt-get install -y"
    elif command -v dnf     &>/dev/null; then pm_cmd="sudo dnf install -y"
    elif command -v zypper  &>/dev/null; then pm_cmd="sudo zypper install -y"
    else echo "No known package manager found"; exit 1; fi
    for t in "${missing[@]}"; do
        [[ "$t" == "btrfs" ]] && t="btrfs-progs"
        [[ "$t" == "ip"    ]] && t="iproute2"
        $pm_cmd "$t" &>/dev/null
    done
}
_check_deps

# ── User namespace: intentionally NOT used ───────────────────────────
# --map-root-user/--user creates a child user namespace where the caller
# appears as root, but the kernel marks all mounts inherited from the initial
# user namespace as MNT_LOCKED. Inside that namespace, bind-mounting /sys,
# /dev, or any loop-backed path fails with EPERM — exactly the opposite of
# what we want. sudo already gives real CAP_SYS_ADMIN; the plain
# --mount --pid --uts --ipc unshare flags are sufficient for full isolation.
SD_USERNS_OK=false   # kept for compatibility; never set to true

# ── BTRFS kernel pre-flight ───────────────────────────────────────
grep -qw btrfs /proc/filesystems 2>/dev/null || {
    clear
    printf '\n  \033[0;31m✗  BTRFS is not available in your kernel.\033[0m\n'
    printf '  \033[2m  Enable CONFIG_BTRFS_FS or install the btrfs kernel module.\033[0m\n\n'
    exit 1
}

tmux bind-key -n 'C-\\' detach-client 2>/dev/null || true

# ── Sudo keep-alive ─────────────────────────────────────────────────
_sudo_keepalive() {
    ( while true; do sudo -n true 2>/dev/null; sleep 55; done ) &
    disown "$!" 2>/dev/null || true
}

_require_sudo() {
    # Sudoers is written in the outer shell (before tmux) where a real tty exists.
    # Inside tmux we just need the keepalive — sudo -n commands work because the rule is already written.
    _sudo_keepalive
}

# ── Tmux bootstrap ────────────────────────────────────────────────

# ── Core helpers ──────────────────────────────────────────────────
_tmux_get()   { tmux show-environment -g "$1" 2>/dev/null | cut -d= -f2-; }
_tmux_set()   { tmux set-environment -g "$1" "$2" 2>/dev/null; }
_st()         { jq -r ".$2 // empty" "$CONTAINERS_DIR/$1/state.json" 2>/dev/null; }
_set_st()     { local f="$CONTAINERS_DIR/$1/state.json"
                jq ".$2 = $3" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null; }
_state_get()  { _st "$1" "$2"; }
_cname()      { _st "$1" name; }
_cpath()      { local r; r=$(_st "$1" install_path); [[ -n "$r" ]] && printf '%s/%s' "$INSTALLATIONS_DIR" "$r"; }
tsess()       { printf 'sd_%s' "$1"; }
tmux_up()     { tmux has-session -t "$1" 2>/dev/null; }
_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
_trim_s()    { _strip_ansi | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
_sig_rc()    { [[ ${1:-0} -eq 143 || ${1:-0} -eq 138 || ${1:-0} -eq 137 ]]; }
# Write to a capped log file (max 10 MB — truncate to last 80% on overflow)
_log_write() {
    local f="$1"; shift
    local max=10485760  # 10 MB
    printf '%s\n' "$@" >> "$f" 2>/dev/null || true
    local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [[ "$sz" -gt "$max" ]]; then
        local keep=$(( max * 8 / 10 ))
        local tmp; tmp=$(mktemp "$TMP_DIR/.sd_log_tmp_XXXXXX" 2>/dev/null) || return
        tail -c "$keep" "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    fi
}
_log_path() {
    # $1=cid $2=mode(start|install|update)
    local cname; cname=$(_cname "$1" 2>/dev/null || printf '%s' "$1")
    printf '%s/%s-%s-%s.log' "$LOGS_DIR" "$cname" "$1" "$2"
}

# Port-based health check for containers with health=true in [meta]
# Returns 0 (healthy) or 1 (unhealthy/no port)
_health_check() {
    local cid="$1"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local health; health=$(jq -r '.meta.health // empty' "$sj" 2>/dev/null)
    [[ "$health" != "true" ]] && return 1
    local port; port=$(jq -r '.meta.port // empty' "$sj" 2>/dev/null)
    [[ -z "$port" || "$port" == "0" ]] && return 1
    nc -z -w1 127.0.0.1 "$port" 2>/dev/null
}
_log_rotate() {
    # Trim log file to last 8MB if it exceeds 10MB
    local f="$1"
    [[ ! -f "$f" ]] && return
    local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [[ "$sz" -gt 10485760 ]] && tail -c 8388608 "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || true
}
_rand_id()    { local id
                while true; do id=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
                    [[ ! -d "$CONTAINERS_DIR/$id" ]] && printf '%s' "$id" && return; done; }

# ── Open URL in existing browser tab (not a new profile/window) ───
# xdg-open launches the browser fresh which triggers new-profile setup on
# Vivaldi/Chrome. Instead we detect the default browser and call it directly
# with --new-tab so it reuses an already-running instance.
_sd_open_url() {
    local url="$1"
    local browser; browser=$(xdg-settings get default-web-browser 2>/dev/null)
    browser="${browser%.desktop}"
    case "${browser,,}" in
        firefox*|librewolf*|waterfox*|floorp*)
            { firefox --new-tab "$url" 2>/dev/null || \
              librewolf --new-tab "$url" 2>/dev/null || \
              floorp --new-tab "$url" 2>/dev/null; } & disown ;;
        vivaldi*)
            { vivaldi-stable --new-tab "$url" 2>/dev/null || \
              vivaldi --new-tab "$url" 2>/dev/null; } & disown ;;
        google-chrome*|chrome*)
            { google-chrome-stable --new-tab "$url" 2>/dev/null || \
              google-chrome --new-tab "$url" 2>/dev/null; } & disown ;;
        chromium*|chromium-browser*)
            chromium --new-tab "$url" 2>/dev/null & disown ;;
        brave*|brave-browser*)
            { brave-browser --new-tab "$url" 2>/dev/null || \
              brave --new-tab "$url" 2>/dev/null; } & disown ;;
        microsoft-edge*|msedge*)
            microsoft-edge --new-tab "$url" 2>/dev/null & disown ;;
        *)
            # Unknown browser — try gtk-launch with the URL first (opens new tab
            # if already running for most browsers), fall back to xdg-open.
            { [[ -n "$browser" ]] && gtk-launch "$browser" "$url" 2>/dev/null; } & disown \
            || xdg-open "$url" 2>/dev/null & disown ;;
    esac
}

# ── Image / directory management ─────────────────────────────────

CT_IDS=(); CT_NAMES=()
_load_containers() {
    CT_IDS=(); CT_NAMES=()
    local show_hidden="${1:-false}"
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        local hidden n
        { read -r hidden; IFS= read -r n; } < <(jq -r '.hidden // false, .name // empty' "$d/state.json" 2>/dev/null)
        [[ "$show_hidden" == "false" && "$hidden" == "true" ]] && continue
        [[ -z "$n" ]] && n="(unnamed-$cid)"
        CT_IDS+=("$cid"); CT_NAMES+=("$n")
    done
}

_validate_containers() {
    [[ -z "$CONTAINERS_DIR" ]] && return
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        [[ "$(_st "$cid" installed)" != "true" ]] && continue
        local ip; ip=$(_cpath "$cid")
        [[ -n "$ip" && -d "$ip" ]] || _set_st "$cid" installed false
    done
}

# ── Install lock ──────────────────────────────────────────────────
_installing_id()      { _tmux_get SD_INSTALLING; }
_inst_sess()          { printf 'sdInst_%s' "$1"; }
_is_installing()      { local cid="$1"; tmux_up "$(_inst_sess "$cid")"; }
_cleanup_stale_lock() {
    local cur; cur=$(_installing_id)
    [[ -z "$cur" ]] && return 0
    tmux_up "$(_inst_sess "$cur")" && return 0
    _tmux_set SD_INSTALLING ""
}

#  NEW BLUEPRINT PARSER  (DSL format)

# Parse a blueprint file/string and emit fields to stdout as:
#   SECTION<RS>VALUE<RS>...
# Returns parsed data into associative arrays via _bp_parse().

# Global associative arrays — declare -A at global scope so string keys work
# correctly when called outside _bp_compile_to_json (which shadows with a local declare -A).

declare -A BP_META=()
declare -A BP_ENV=()

# _bp_parse FILE
# Sets globals: BP_META[], BP_ENV[], BP_STORAGE, BP_DEPS, BP_DIRS, BP_PIP,
#               BP_GITHUB, BP_BUILD, BP_INSTALL, BP_UPDATE, BP_START,
#               BP_ACTIONS_NAMES[], BP_ACTIONS_SCRIPTS[], BP_CRON_NAMES[], BP_CRON_INTERVALS[], BP_CRON_CMDS[]
_bp_parse() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1
    BP_META=() BP_ENV=() BP_STORAGE="" BP_DEPS="" BP_DIRS="" BP_PIP=""
    BP_GITHUB="" BP_NPM="" BP_BUILD="" BP_INSTALL="" BP_UPDATE="" BP_START=""
    BP_ACTIONS_NAMES=() BP_ACTIONS_SCRIPTS=() BP_ACTIONS=() BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=() BP_CRON_FLAGS=()
    BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()

    local cur_section="" cur_content="" in_container=0 action_name=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # strip inline comments only outside bash blocks
        local stripped; stripped=$(printf '%s' "$line" | sed 's/#.*//' | sed 's/[[:space:]]*$//')

        # detect section headers
        if [[ "$stripped" =~ ^\[([^/][^]]*)\]$ ]]; then
            local new_sec="${BASH_REMATCH[1]}"
            # flush previous section
            _bp_flush_section "$cur_section" "$cur_content"
            cur_section="$new_sec"
            cur_content=""

            if [[ "$new_sec" == "container" || "$new_sec" == "blueprint" ]]; then
                in_container=1; cur_section=""; continue
            fi
            continue
        fi

        # detect closing tag [/container] or [/blueprint] or [/end]
        if [[ "$stripped" =~ ^\[/(container|blueprint|end)\]$ ]]; then
            _bp_flush_section "$cur_section" "$cur_content"
            cur_section=""; cur_content=""; in_container=0
            continue
        fi

        # accumulate content
        [[ -n "$cur_section" ]] && cur_content+="$line"$'\n'
    done < "$file"

    # flush final
    _bp_flush_section "$cur_section" "$cur_content"
}

_bp_flush_section() {
    local sec="$1" content="$2"
    [[ -z "$sec" ]] && return
    # trim trailing newlines
    content=$(printf '%s' "$content" | sed 's/[[:space:]]*$//')

    case "${sec,,}" in
        meta)
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" ]] && continue
                local k="${l%%=*}" v="${l#*=}"
                k=$(printf '%s' "$k" | sed 's/[[:space:]]*$//')
                v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//')
                BP_META["$k"]="$v"
            done <<< "$content" ;;
        env)
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" ]] && continue
                local k="${l%%=*}" v="${l#*=}"
                k=$(printf '%s' "$k" | sed 's/[[:space:]]*$//')
                v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//')
                BP_ENV["$k"]="$v"
            done <<< "$content" ;;
        storage)     BP_STORAGE="$content" ;;
        dependencies|deps) BP_DEPS="$content" ;;
        dirs)        BP_DIRS="$content" ;;
        pip|pypi)    BP_PIP="$content" ;;
        git)          BP_GITHUB="$content" ;;
        npm)         BP_NPM="$content" ;;
        build)       BP_BUILD="$content" ;;
        install)     BP_INSTALL="$content" ;;
        update)      BP_UPDATE="$content" ;;
        start)       BP_START="$content" ;;
        actions)
            # New DSL actions: one per line  label | type: args | cmd
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" || "$l" == \#* ]] && continue
                # Split on first |  to get label
                local albl="${l%%|*}"; albl=$(printf '%s' "$albl" | sed 's/[[:space:]]*$//')
                local arest="${l#*|}"; arest=$(printf '%s' "$arest" | sed 's/^[[:space:]]*//')
                [[ -z "$albl" ]] && continue
                BP_ACTIONS_NAMES+=("$albl")
                BP_ACTIONS_SCRIPTS+=("$arest")
            done <<< "$content" ;;
        cron)
            # Format: interval [name] [--sudo] [--unjailed] | command
            # --sudo    : prefix command with sudo (skipped if cmd already has sudo)
            # --unjailed: run on the host outside the container namespace
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" || "$l" == \#* ]] && continue
                # Split on first |
                local cinterval_name="${l%%|*}"; cinterval_name=$(printf '%s' "$cinterval_name" | sed 's/[[:space:]]*$//')
                local ccmd="${l#*|}"; ccmd=$(printf '%s' "$ccmd" | sed 's/^[[:space:]]*//')
                [[ -z "$ccmd" ]] && continue
                # Extract flags --sudo and --unjailed from the pre-pipe part
                local cflags=""
                printf '%s' "$cinterval_name" | grep -q -- '--sudo'    && cflags="$cflags --sudo"
                printf '%s' "$cinterval_name" | grep -q -- '--unjailed' && cflags="$cflags --unjailed"
                cflags=$(printf '%s' "$cflags" | sed 's/^[[:space:]]*//')
                # Strip flags before parsing interval/name
                cinterval_name=$(printf '%s' "$cinterval_name" | sed 's/--sudo//g;s/--unjailed//g' | sed 's/[[:space:]]*$//')
                # Extract interval (first token) and name (rest in brackets or remainder)
                local cinterval cname
                cinterval=$(printf '%s' "$cinterval_name" | awk '{print $1}')
                # Name: rest after interval, strip surrounding brackets if present
                cname=$(printf '%s' "$cinterval_name" | sed 's/^[^[:space:]]*//' | sed 's/^[[:space:]]*//' | sed 's/^\[//;s/\]$//')
                [[ -z "$cname" ]] && cname="$cinterval job"
                BP_CRON_NAMES+=("$cname")
                BP_CRON_INTERVALS+=("$cinterval")
                # Auto-prefix unquoted relative paths after >> with $CONTAINER_ROOT
                local ccmd_prefixed; ccmd_prefixed=$(printf '%s' "$ccmd" | \
                    sed 's#>>[[:space:]]*\([[:alpha:]_][^[:space:]]*\)#>> $CONTAINER_ROOT/\1#g')
                BP_CRON_CMDS+=("$ccmd_prefixed")
                BP_CRON_FLAGS+=("$cflags")
            done <<< "$content" ;;
        *)
            # Legacy freeform custom actions (block syntax)
            BP_ACTIONS_NAMES+=("$sec")
            BP_ACTIONS_SCRIPTS+=("$content") ;;
    esac
}

# ── Blueprint validator ───────────────────────────────────────────
# Call after _bp_parse. Populates BP_ERRORS[] with human-readable messages.
# Returns 1 if any errors found, 0 if clean.
BP_ERRORS=()
_bp_validate() {
    BP_ERRORS=()

    # ── [meta] name required ──────────────────────────────────────
    [[ -z "${BP_META[name]:-}" ]] && BP_ERRORS+=("  [meta]  'name' is required")

    # ── entrypoint or [start] required ───────────────────────────
    local has_entry=0
    [[ -n "${BP_META[entrypoint]:-}" ]] && has_entry=1
    [[ -n "$BP_START" ]] && has_entry=1
    [[ $has_entry -eq 0 ]] && BP_ERRORS+=("  [meta]  'entrypoint' or a [start] block is required")

    # ── port must be numeric if present ──────────────────────────
    local port; port=$(printf '%s' "${BP_META[port]:-}" | sed 's/[[:space:]]//g')
    [[ -n "$port" && ! "$port" =~ ^[0-9]+$ ]] && BP_ERRORS+=("  [meta]  'port' must be a number, got: $port")

    # ── storage_type required when [storage] is non-empty ────────
    if [[ -n "$BP_STORAGE" ]]; then
        local st; st=$(printf '%s' "$BP_STORAGE" | tr ',' '\n' | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | head -1)
        [[ -n "$st" && -z "${BP_META[storage_type]:-}" ]] && \
            BP_ERRORS+=("  [storage]  'storage_type' in [meta] is required when [storage] paths are declared")
    fi

    # ── [git] lines must look like org/repo ───────────────────
    if [[ -n "$BP_GITHUB" ]]; then
        local gln=0
        while IFS= read -r gl; do
            (( gln++ )) || true
            gl=$(printf '%s' "$gl" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$gl" ]] && continue
            # strip optional varname= prefix
            [[ "$gl" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*=[[:space:]]*(.*) ]] && gl="${BASH_REMATCH[1]}"
            local repo; repo=$(printf '%s' "$gl" | awk '{print $1}')
            [[ ! "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] && \
                BP_ERRORS+=("  [git]  line $gln: invalid repo format '$repo' (expected org/repo)")
        done <<< "$BP_GITHUB"
    fi

    # ── [dirs] parentheses must be balanced ──────────────────────
    if [[ -n "$BP_DIRS" ]]; then
        local open=0 close=0 ch di=0 dlen=${#BP_DIRS}
        while [[ $di -lt $dlen ]]; do
            ch="${BP_DIRS:$di:1}"
            [[ "$ch" == '(' ]] && (( open++ ))  || true
            [[ "$ch" == ')' ]] && (( close++ )) || true
            (( di++ )) || true
        done
        [[ $open -ne $close ]] && \
            BP_ERRORS+=("  [dirs]  unbalanced parentheses (${open} open, ${close} close)")
    fi

    # ── [actions] DSL consistency ─────────────────────────────────
    local ai=0
    for i in "${!BP_ACTIONS_NAMES[@]}"; do
        (( ai++ )) || true
        local lbl="${BP_ACTIONS_NAMES[$i]}" dsl="${BP_ACTIONS_SCRIPTS[$i]}"
        # Only validate new DSL-style (contains |)
        printf '%s' "$dsl" | grep -q '|' || continue
        local has_prompt=0 has_select=0
        local seg
        while IFS= read -r seg; do
            seg=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ "$seg" == prompt:* ]] && has_prompt=1
            [[ "$seg" == select:* ]] && has_select=1
        done <<< "$(printf '%s' "$dsl" | tr '|' '\n')"
        # {input} without prompt
        printf '%s' "$dsl" | grep -q '{input}' && [[ $has_prompt -eq 0 ]] && \
            BP_ERRORS+=("  [actions]  '$lbl': uses {input} but no 'prompt:' segment")
        # {selection} without select
        printf '%s' "$dsl" | grep -q '{selection}' && [[ $has_select -eq 0 ]] && \
            BP_ERRORS+=("  [actions]  '$lbl': uses {selection} but no 'select:' segment")
        # empty label
        [[ -z "$lbl" ]] && BP_ERRORS+=("  [actions]  action $ai has an empty label")
    done

    # ── [pip] requires python3 in deps ──
    if [[ -n "$BP_PIP" ]]; then
        local has_py=0
        if [[ -n "$BP_DEPS" ]]; then
            printf '%s' "$BP_DEPS" | tr ',' ' ' | grep -qE 'python3' && has_py=1
        fi
        [[ $has_py -eq 0 ]] && \
            BP_ERRORS+=("  [pip]  requires 'python3' in [deps]")
    fi

    # [npm] does NOT require nodejs in [deps] — Node is auto-installed by the npm handler

    [[ ${#BP_ERRORS[@]} -eq 0 ]] && return 0 || return 1
}

# Convert parsed blueprint to service.json (internal runtime format)
