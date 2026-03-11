#!/usr/bin/env bash

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

_guard_space() {
    [[ -z "$MNT_DIR" ]] && return 0
    mountpoint -q "$MNT_DIR" 2>/dev/null || return 0
    local avail_kb; avail_kb=$(df -k "$MNT_DIR" 2>/dev/null | awk 'NR==2{print $4}')
    [[ -z "$avail_kb" || "$avail_kb" -ge 2097152 ]] && return 0
    pause "$(printf '⚠  Less than 2 GiB free in the image.\nUse Other → Resize image to increase the size first.')"
    return 1
}
