# lib/image.sh — Image & directory management: _set_img_dirs, Ubuntu status cache,
#                 _mount_img, _unmount_img, _create_img, _setup_image, _ensure_ubuntu,
#                 _guard_space, _yazi_pick
# Sourced by main.sh — do NOT run directly

# ── Image / directory management ─────────────────────────────────
_set_img_dirs() {
    BLUEPRINTS_DIR="$MNT_DIR/Blueprints"    CONTAINERS_DIR="$MNT_DIR/Containers"
    INSTALLATIONS_DIR="$MNT_DIR/Installations" BACKUP_DIR="$MNT_DIR/Backup"
    STORAGE_DIR="$MNT_DIR/Storage"
    UBUNTU_DIR="$MNT_DIR/Ubuntu"
    GROUPS_DIR="$MNT_DIR/Groups"
    LOGS_DIR="$MNT_DIR/Logs"
    mkdir -p "$BLUEPRINTS_DIR" "$CONTAINERS_DIR" "$INSTALLATIONS_DIR" "$BACKUP_DIR" \
             "$STORAGE_DIR" "$UBUNTU_DIR" "$GROUPS_DIR" "$LOGS_DIR" 2>/dev/null
    sudo -n chown "$(id -u):$(id -g)" \
        "$BLUEPRINTS_DIR" "$CONTAINERS_DIR" "$INSTALLATIONS_DIR" "$BACKUP_DIR" \
        "$STORAGE_DIR" "$UBUNTU_DIR" "$GROUPS_DIR" "$LOGS_DIR" 2>/dev/null || true
    _sd_ub_cache_check &  # background — results written to tmp files, read on first menu open
}

# Compute Ubuntu status once per mount — results stored in _SD_UB_PKG_DRIFT / _SD_UB_HAS_UPDATES
# Runs in background after mount — writes results to tmp files under SD_MNT_BASE/.tmp/
_sd_ub_cache_check() {
    [[ ! -f "$UBUNTU_DIR/.ubuntu_ready" ]] && return
    mkdir -p "$SD_MNT_BASE/.tmp" 2>/dev/null
    local _drift_f="$SD_MNT_BASE/.tmp/.sd_ub_drift_$$"
    local _upd_f="$SD_MNT_BASE/.tmp/.sd_ub_upd_$$"
    # Drift: fast local file compare — done immediately
    local _saved_pkgs_file="$UBUNTU_DIR/.ubuntu_default_pkgs"
    if [[ -f "$_saved_pkgs_file" ]]; then
        local _cur_sorted; _cur_sorted=$(printf '%s
' $DEFAULT_UBUNTU_PKGS | sort)
        local _saved_sorted; _saved_sorted=$(sort "$_saved_pkgs_file" 2>/dev/null)
        [[ "$_cur_sorted" != "$_saved_sorted" ]] && printf 'true' > "$_drift_f" || printf 'false' > "$_drift_f"
    else
        printf 'true' > "$_drift_f"
    fi
    # Updates: apt simulate — slow, runs last
    local _sim; _sim=$(_chroot_bash "$UBUNTU_DIR" -c         "apt-get update -qq 2>/dev/null; apt-get --simulate upgrade 2>/dev/null | grep -c '^Inst '" 2>/dev/null)
    [[ "${_sim:-0}" -gt 0 ]] && printf 'true' > "$_upd_f" || printf 'false' > "$_upd_f"
}

# Called lazily on first Ubuntu menu open — reads tmp files written by background check
# Guarded by _SD_UB_CACHE_LOADED so it only ever runs once per mount session
_sd_ub_cache_read() {
    [[ "$_SD_UB_CACHE_LOADED" == true ]] && return
    _SD_UB_CACHE_LOADED=true
    local _drift_f="$SD_MNT_BASE/.tmp/.sd_ub_drift_$$"
    local _upd_f="$SD_MNT_BASE/.tmp/.sd_ub_upd_$$"
    # Wait up to 3s for the background job to finish writing (usually already done)
    local _w=0
    while [[ ! -f "$_drift_f" && $_w -lt 30 ]]; do sleep 0.1; (( _w++ )); done
    [[ -f "$_drift_f" ]] && _SD_UB_PKG_DRIFT=$(cat "$_drift_f")   || _SD_UB_PKG_DRIFT=false
    [[ -f "$_upd_f"   ]] && _SD_UB_HAS_UPDATES=$(cat "$_upd_f")   || _SD_UB_HAS_UPDATES=false
    rm -f "$_drift_f" "$_upd_f"
}



_mount_img() {
    IMG_PATH="$1"
    MNT_DIR="${SD_MNT_BASE}/mnt_$(basename "${1%.img}")"
    mkdir -p "$MNT_DIR" 2>/dev/null
    if _img_is_luks "$1"; then
        _luks_open "$1" || { rmdir "$MNT_DIR" 2>/dev/null; pause "Failed to unlock image."; return 1; }
        sudo -n mount -o compress=zstd "$(_luks_dev "$1")" "$MNT_DIR" 2>/dev/null
    else
        sudo -n mount -o loop,compress=zstd "$1" "$MNT_DIR" 2>/dev/null
    fi
    sudo -n chown "$(id -u):$(id -g)" "$MNT_DIR" 2>/dev/null || true
    rm -rf "$TMP_DIR" 2>/dev/null || true
    _set_img_dirs
    TMP_DIR="$MNT_DIR/.tmp"
    mkdir -p "$TMP_DIR" "$MNT_DIR/.sd" 2>/dev/null
    rm -rf "$TMP_DIR" 2>/dev/null || true
    mkdir -p "$TMP_DIR" 2>/dev/null
    CACHE_DIR="$MNT_DIR/.cache"
    mkdir -p "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null
    _netns_setup "$MNT_DIR"
    rm -f "$MNT_DIR/Logs/"*.log 2>/dev/null || true
    if [[ -f "$MNT_DIR/.sd/proxy.json" ]] && \
       [[ "$(jq -r '.autostart // false' "$MNT_DIR/.sd/proxy.json" 2>/dev/null)" == "true" ]]; then
        _proxy_start --background
    fi
}

_yazi_pick() {
    local filter="${1:-}"
    local tmp; tmp=$(mktemp "$TMP_DIR/.sd_tmp_XXXXXX" 2>/dev/null) || { pause "mktemp failed (TMP_DIR=$TMP_DIR)"; return 1; }
    yazi --chooser-file="$tmp" 2>/dev/null
    local chosen; chosen=$(head -1 "$tmp" 2>/dev/null | tr -d '

'); rm -f "$tmp"
    [[ -z "$chosen" ]] && return 1
    if [[ -n "$filter" && "${chosen##*.}" != "$filter" ]]; then
        pause "Please select a .$filter file."; return 1
    fi
    printf '%s' "${chosen%/}"
}
_pick_img() { _yazi_pick img; }
_pick_dir() { _yazi_pick; }

_unmount_img() {
    [[ -z "$MNT_DIR" ]] && return 0
    mountpoint -q "$MNT_DIR" 2>/dev/null || { rmdir "$MNT_DIR" 2>/dev/null; return 0; }
    _proxy_stop 2>/dev/null || true
    _netns_teardown "$MNT_DIR"
    sudo -n umount -lf "$MNT_DIR" 2>/dev/null || true
    rmdir "$MNT_DIR" 2>/dev/null || true
    [[ -n "$IMG_PATH" ]] && _luks_close "$IMG_PATH" 2>/dev/null || true
    TMP_DIR="$SD_MNT_BASE/.tmp"
    mkdir -p "$TMP_DIR" 2>/dev/null || true
}

_create_img() {
    local name size_gb dir imgfile
    finput "$(printf "Image name (e.g. simpleDocker):\n\n  %b  The name cannot be changed after creation." "${RED}⚠  WARNING:${NC}")" || return 1
    name="${FINPUT_RESULT//[^a-zA-Z0-9_\-]/}"
    [[ -z "$name" ]] && { pause "No name given."; return 1; }
    finput "Max size in GB (sparse — only uses actual disk space, leave blank for 50 GB):" || return 1
    size_gb="$FINPUT_RESULT"
    [[ -z "$size_gb" ]] && size_gb=50
    [[ ! "$size_gb" =~ ^[0-9]+$ || "$size_gb" -lt 1 ]] && { pause "Invalid size."; return 1; }
    dir=$(_pick_dir) || { pause "No directory selected."; return 1; }
    imgfile="$dir/$name.img"
    [[ -f "$imgfile" ]] && { pause "Already exists: $imgfile"; return 1; }
    truncate -s "${size_gb}G" "$imgfile" 2>/dev/null || { pause "Failed to allocate image file."; return 1; }

    # Format as LUKS2 — use slot 31 as bootstrap (slot 0 reserved for authkey)
    printf '%s' "$SD_VERIFICATION_CIPHER" | sudo -n cryptsetup luksFormat \
        --type luks2 --batch-mode \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
        --key-slot 31 --key-file=- "$imgfile" &>/dev/null \
        || { rm -f "$imgfile"; pause "luksFormat failed."; return 1; }

    local _mapper; _mapper=$(_luks_mapper "$imgfile")
    printf '%s' "$SD_VERIFICATION_CIPHER" | sudo -n cryptsetup open --key-file=- "$imgfile" "$_mapper" &>/dev/null \
        || { rm -f "$imgfile"; pause "LUKS open failed."; return 1; }

    sudo -n mkfs.btrfs -q -f "/dev/mapper/$_mapper" &>/dev/null \
        || { sudo -n cryptsetup close "$_mapper"; rm -f "$imgfile"; pause "mkfs.btrfs failed."; return 1; }

    MNT_DIR="${SD_MNT_BASE}/mnt_$(basename "${imgfile%.img}")"
    mkdir -p "$MNT_DIR" 2>/dev/null
    if ! sudo -n mount -o compress=zstd "/dev/mapper/$_mapper" "$MNT_DIR" 2>/dev/null; then
        sudo -n cryptsetup close "$_mapper"; rm -f "$imgfile"; rmdir "$MNT_DIR" 2>/dev/null
        pause "Mount failed."; return 1
    fi
    sudo -n chown "$(id -u):$(id -g)" "$MNT_DIR" 2>/dev/null || true
    IMG_PATH="$imgfile"
    TMP_DIR="$MNT_DIR/.tmp"
    mkdir -p "$TMP_DIR" "$MNT_DIR/.sd" 2>/dev/null

    # Add authkey to slot 0 (authorizing with bootstrap slot 31)
    local _tf_img_auth; _tf_img_auth=$(mktemp "$TMP_DIR/.sd_imgauth_XXXXXX")
    printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_img_auth"
    _enc_authkey_create "$_tf_img_auth" || { rm -f "$_tf_img_auth"; pause "Auth keyfile creation failed."; return 1; }

    # Kill bootstrap slot 31 — authkey (slot 0) takes over as the master key
    sudo -n cryptsetup luksKillSlot --batch-mode \
        --key-file "$(_enc_authkey_path)" "$imgfile" 31 &>/dev/null || true
    rm -f "$_tf_img_auth"

    # Add default keyword to slot 1 (system agnostic — any machine can open)
    local _tf_dk_a; _tf_dk_a=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
    local _tf_dk_p; _tf_dk_p=$(mktemp "$TMP_DIR/.sd_new_XXXXXX")
    cp "$(_enc_authkey_path)" "$_tf_dk_a"
    printf '%s' "$SD_DEFAULT_KEYWORD" > "$_tf_dk_p"
    sudo -n cryptsetup luksAddKey --batch-mode \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
        --key-slot 1 --key-file "$_tf_dk_a" \
        "$imgfile" "$_tf_dk_p" &>/dev/null || true
    rm -f "$_tf_dk_a" "$_tf_dk_p"

    # Auto-verify this system — add derived pass to lowest free slot in user range
    local _img_vs_slot; _img_vs_slot=$(_enc_free_slot)
    if [[ -n "$_img_vs_slot" ]]; then
        local _tf_vs_a; _tf_vs_a=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
        local _tf_vs_p; _tf_vs_p=$(mktemp "$TMP_DIR/.sd_new_XXXXXX")
        cp "$(_enc_authkey_path)" "$_tf_vs_a"
        printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_vs_p"
        sudo -n cryptsetup luksAddKey --batch-mode \
            --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
            --key-slot "$_img_vs_slot" --key-file "$_tf_vs_a" \
            "$imgfile" "$_tf_vs_p" &>/dev/null
        [[ $? -eq 0 ]] && _enc_vs_write "$(_enc_verified_id)" "$_img_vs_slot"
        rm -f "$_tf_vs_a" "$_tf_vs_p"
    fi
    for sv in Blueprints Containers Installations Backup Storage Ubuntu Groups; do
        sudo -n btrfs subvolume create "$MNT_DIR/$sv" &>/dev/null || true
    done
    _set_img_dirs
    _netns_setup "$MNT_DIR"
    pause "Image created: $imgfile"
    return 0
}

_setup_image() {
    # Auto-enter if already mounted (resuming session), otherwise always show selection
    if mountpoint -q "$MNT_DIR" 2>/dev/null; then _set_img_dirs; return 0; fi
    if [[ -n "$DEFAULT_IMG" && -f "$DEFAULT_IMG" ]]; then _mount_img "$DEFAULT_IMG"; return 0; fi
    while true; do
        # Detect compatible SD images in $HOME live (no cache) — BTRFS .img files
        local detected_imgs=()
        while IFS= read -r -d '' _df; do
            { file "$_df" 2>/dev/null | grep -q 'BTRFS' || _img_is_luks "$_df"; } && detected_imgs+=("$_df")
        done < <(find "$HOME" -maxdepth 4 -name '*.img' -type f -print0 2>/dev/null)

        local lines=()
        lines+=("$(printf " ${CYN}◈${NC}  ${L[img_select]}")")
        lines+=("$(printf " ${CYN}◈${NC}  ${L[img_create]}")")

        if [[ ${#detected_imgs[@]} -gt 0 ]]; then
            lines+=("$(printf "${DIM}  ── Detected images ──────────────────${NC}")")
            for _di in "${detected_imgs[@]}"; do
                lines+=("$(printf " ${CYN}◈${NC}  %s  ${DIM}(%s)${NC}" "$(basename "$_di")" "$(dirname "$_di")")")
            done
        fi

        local choice
        choice=$(printf '%s\n' "${lines[@]}" \
            | fzf --ansi --no-sort --prompt="  ❯ " --pointer="▶" \
                  --height=40% --reverse --border=rounded --margin=1,2 --no-info \
                  --header="$(printf "${BLD}── simpleDocker ──${NC}")" 2>/dev/null) || { clear; exit 0; }
        local clean; clean=$(printf '%s' "$choice" | _strip_ansi | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$clean" in
            *"${L[img_select]}"*) local picked; picked=$(_pick_img) && { _mount_img "$picked" && return 0; } ;;
            *"${L[img_create]}"*) _create_img && return 0 ;;
            *)
                for _di in "${detected_imgs[@]}"; do
                    if [[ "$clean" == *"$(basename "$_di")"* ]]; then
                        _mount_img "$_di" && return 0
                        break
                    fi
                done ;;
        esac
    done
}

# ── Ubuntu bootstrap ─────────────────────────────────────────────
# Downloads Ubuntu 24.04 LTS minirootfs into $UBUNTU_DIR — base for all containers.
# Uses glibc so PyPI wheels and system packages work correctly.
# Prompts attach/background like container installs.
_ubuntu_default_pkgs_file() { printf '%s/.ubuntu_default_pkgs' "$UBUNTU_DIR"; }

_ensure_ubuntu() {
    [[ -z "$UBUNTU_DIR" ]] && return 0
    if [[ -f "$UBUNTU_DIR/.ubuntu_ready" && ! -f "$UBUNTU_DIR/usr/bin/apt-get" ]]; then
        rm -f "$UBUNTU_DIR/.ubuntu_ready"
    fi
    [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && return 0
    [[ ! -d "$UBUNTU_DIR" ]] && mkdir -p "$UBUNTU_DIR" 2>/dev/null

    local arch; arch=$(uname -m)
    local ub_arch
    case "$arch" in
        x86_64)  ub_arch="amd64" ;;
        aarch64) ub_arch="arm64" ;;
        armv7l)  ub_arch="armhf" ;;
        *)       ub_arch="amd64" ;;
    esac

    # Ubuntu 24.04 LTS (Noble) minimal rootfs — resolve latest point release dynamically
    local base_index="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/"
    local ver_full; ver_full=$(curl -fsSL "$base_index" 2>/dev/null \
        | grep -oP "ubuntu-base-\K[0-9]+\.[0-9]+\.[0-9]+-base-${ub_arch}" | head -1)
    [[ -z "$ver_full" ]] && ver_full="24.04.3-base-${ub_arch}"
    local url="${base_index}ubuntu-base-${ver_full}.tar.gz"
    local tmp; tmp=$(mktemp "$TMP_DIR/.sd_ubuntu_XXXXXX.tar.gz")
    local ok_flag="$UBUNTU_DIR/.ubuntu_ok_flag" fail_flag="$UBUNTU_DIR/.ubuntu_fail_flag"
    rm -f "$ok_flag" "$fail_flag"
    mkdir -p "$UBUNTU_DIR" 2>/dev/null

    local ubuntu_script; ubuntu_script=$(mktemp "$TMP_DIR/.sd_ubuntu_dl_XXXXXX.sh")
    local _sd_chroot_fn='_chroot_bash() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }'
    cat > "$ubuntu_script" <<UBUNTUSCRIPT
#!/usr/bin/env bash
$_sd_chroot_fn
trap '' INT
printf '\033[1m── simpleDocker — Ubuntu base setup ──\033[0m\n\n'
printf 'Downloading Ubuntu 24.04 LTS Noble base...\n'
if curl -fsSL --progress-bar $(printf '%q' "$url") -o $(printf '%q' "$tmp"); then
    printf 'Extracting...\n'
    tar -xzf $(printf '%q' "$tmp") -C $(printf '%q' "$UBUNTU_DIR") 2>&1 || true
    rm -f $(printf '%q' "$tmp")
    # Ensure /bin -> usr/bin symlink exists (Ubuntu Noble merged-usr)
    if [[ ! -e $(printf '%q' "$UBUNTU_DIR/bin") ]]; then
        ln -sf usr/bin $(printf '%q' "$UBUNTU_DIR/bin") 2>/dev/null || true
    fi
    if [[ ! -e $(printf '%q' "$UBUNTU_DIR/lib") ]]; then
        ln -sf usr/lib $(printf '%q' "$UBUNTU_DIR/lib") 2>/dev/null || true
    fi
    if [[ ! -e $(printf '%q' "$UBUNTU_DIR/lib64") ]]; then
        ln -sf usr/lib64 $(printf '%q' "$UBUNTU_DIR/lib64") 2>/dev/null || true
    fi
    printf 'nameserver 8.8.8.8\n' > $(printf '%q' "$UBUNTU_DIR/etc/resolv.conf") 2>/dev/null || true
    # Suppress apt warnings in chroot
    printf 'APT::Sandbox::User "root";\n' > $(printf '%q' "$UBUNTU_DIR/etc/apt/apt.conf.d/99sandbox") 2>/dev/null || true
        printf 'Pre-installing common packages...\n'
    _chroot_bash "$UBUNTU_DIR" -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $DEFAULT_UBUNTU_PKGS 2>&1" || true
    touch $(printf '%q' "$UBUNTU_DIR/.ubuntu_ready")
    date '+%Y-%m-%d' > $(printf '%q' "$UBUNTU_DIR/.sd_ubuntu_stamp")
    printf '%s\n' $DEFAULT_UBUNTU_PKGS > $(printf '%q' "$UBUNTU_DIR/.ubuntu_default_pkgs") 2>/dev/null || true
    touch $(printf '%q' "$ok_flag")
    printf '\n\033[0;32m✓ Ubuntu base ready.\033[0m\n'
else
    rm -f $(printf '%q' "$tmp")
    touch $(printf '%q' "$fail_flag")
    printf '\n\033[0;31m✗ Download failed.\033[0m\n'
fi
sleep 1
tmux kill-session -t sdUbuntuSetup 2>/dev/null || true
UBUNTUSCRIPT
    chmod +x "$ubuntu_script"

    local _tl_rc
    _tmux_launch "sdUbuntuSetup" "Ubuntu base setup" "$ubuntu_script"
    _tl_rc=$?
    [[ $_tl_rc -eq 1 ]] && { rm -f "$ubuntu_script"; return 1; }
}

# Run a command inside Ubuntu chroot
# ── Chroot mount/umount helpers ──────────────────────────────────
_chroot_mount()     { local d="$1"
    sudo -n mount --bind /proc "$d/proc" 2>/dev/null || true
    sudo -n mount --bind /sys  "$d/sys"  2>/dev/null || true
    sudo -n mount --bind /dev  "$d/dev"  2>/dev/null || true; }
_chroot_umount()    { local d="$1"
    sudo -n umount -lf "$d/dev" "$d/sys" "$d/proc" 2>/dev/null || true; }
_chroot_mount_mnt() { _chroot_mount "$1"
    [[ -n "${2:-}" ]] && sudo -n mount --bind "$2" "$1/mnt" 2>/dev/null || true; }
_chroot_umount_mnt(){ sudo -n umount -lf "$1/mnt" 2>/dev/null || true; _chroot_umount "$1"; }

_guard_space() {
    [[ -z "$MNT_DIR" ]] && return 0
    mountpoint -q "$MNT_DIR" 2>/dev/null || return 0
    local avail_kb; avail_kb=$(df -k "$MNT_DIR" 2>/dev/null | awk 'NR==2{print $4}')
    [[ -z "$avail_kb" || "$avail_kb" -ge 2097152 ]] && return 0
    pause "$(printf '⚠  Less than 2 GiB free in the image.\nUse Other → Resize image to increase the size first.')"
    return 1
}

