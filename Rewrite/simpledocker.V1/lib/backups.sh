#!/usr/bin/env bash

_snap_dir()     { printf '%s/%s' "$BACKUP_DIR" "$(_cname "$1")"; }

_rand_snap_id() {
    local sdir="$1" id
    while true; do
        id=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
        [[ ! -d "$sdir/$id" ]] && printf '%s' "$id" && return
    done
}

_snap_meta_get() { local f="$1/$2.meta"; [[ -f "$f" ]] && grep -m1 "^$3=" "$f" 2>/dev/null | cut -d= -f2- || printf ''; }

_snap_meta_set() {
    local sdir="$1" snap_id="$2"; shift 2
    local f="$sdir/$snap_id.meta"; local tmp; tmp=$(mktemp)
    [[ -f "$f" ]] && cp "$f" "$tmp" || true
    for pair in "$@"; do
        local k="${pair%%=*}" v="${pair#*=}"
        sed -i "/^${k}=/d" "$tmp" 2>/dev/null || true
        printf '%s=%s\n' "$k" "$v" >> "$tmp"
    done
    mv "$tmp" "$f" 2>/dev/null || true
}

_delete_snap() {
    local path="$1"; [[ -z "$path" || ! -d "$path" ]] && return 0
    btrfs property set "$path" ro false &>/dev/null || true
    btrfs subvolume delete "$path" &>/dev/null || rm -rf "$path" 2>/dev/null || true
}

_delete_backup() { local sdir="$1" snap_id="$2"; _delete_snap "$sdir/$snap_id"; rm -f "$sdir/$snap_id.meta" 2>/dev/null || true; }

_rotate_and_snapshot() {
    local cid="$1" install_path; install_path=$(_cpath "$cid")
    [[ -z "$install_path" || ! -d "$install_path" ]] && return 1
    local sdir; sdir=$(_snap_dir "$cid"); mkdir -p "$sdir" 2>/dev/null
    local auto_ids=()
    for f in "$sdir"/*.meta; do
        [[ -f "$f" ]] || continue
        local fid; fid=$(basename "$f" .meta)
        [[ "$(_snap_meta_get "$sdir" "$fid" type)" == "auto" ]] && auto_ids+=("$fid")
    done
    while [[ ${#auto_ids[@]} -ge 2 ]]; do
        _delete_backup "$sdir" "${auto_ids[0]}"; auto_ids=("${auto_ids[@]:1}")
    done
    local new_id; new_id=$(_rand_snap_id "$sdir")
    local ts; ts=$(date '+%Y-%m-%d %H:%M')
    btrfs subvolume snapshot -r "$install_path" "$sdir/$new_id" &>/dev/null || return 1
    _snap_meta_set "$sdir" "$new_id" "type=auto" "ts=$ts"
}

_do_restore_snap() {
    local cid="$1" snap_path="$2" snap_label="$3"
    local name; name=$(_cname "$cid"); local install_path; install_path=$(_cpath "$cid")
    confirm "$(printf "Restore '%s' from '%s'?\n\n  Current installation will be overwritten.\n  Persistent storage profiles are untouched." "$name" "$snap_label")" || return 0
    btrfs property set "$snap_path" ro false &>/dev/null || true
    btrfs subvolume delete "$install_path" &>/dev/null || rm -rf "$install_path" 2>/dev/null
    if ! btrfs subvolume snapshot "$snap_path" "$install_path" &>/dev/null; then
        cp -a "$snap_path/." "$install_path/" 2>/dev/null
    fi
    btrfs property set "$snap_path" ro true &>/dev/null || true
    pause "$(printf "Restored '%s' from '%s'." "$name" "$snap_label")"
}

_prompt_backup_name() {
    local sdir="$1"; local default_id; default_id=$(_rand_snap_id "$sdir")
    while true; do
        local input
        if ! finput "$(printf 'Backup name:\n  (leave blank for random: %s)' "$default_id")"; then
            input="$default_id"
        else
            input="${FINPUT_RESULT//[^a-zA-Z0-9_\-]/}"
            [[ -z "$input" ]] && input="$default_id"
        fi
        [[ -d "$sdir/$input" ]] && { pause "A backup named '$input' already exists."; continue; }
        printf '%s' "$input"; return 0
    done
}

_create_manual_backup() {
    local cid="$1" name; name=$(_cname "$cid")
    local install_path; install_path=$(_cpath "$cid")
    [[ -z "$install_path" || ! -d "$install_path" ]] && { pause "No installation found for '$name'."; return 1; }
    local sdir; sdir=$(_snap_dir "$cid"); mkdir -p "$sdir" 2>/dev/null
    local snap_id; snap_id=$(_prompt_backup_name "$sdir"); [[ -z "$snap_id" ]] && return 1
    local ts; ts=$(date '+%Y-%m-%d %H:%M')
    if ! btrfs subvolume snapshot -r "$install_path" "$sdir/$snap_id" &>/dev/null; then
        cp -a "$install_path" "$sdir/$snap_id" 2>/dev/null || { pause "Snapshot failed."; return 1; }
    fi
    _snap_meta_set "$sdir" "$snap_id" "type=manual" "ts=$ts"
    pause "$(printf "Backup '%s' created." "$snap_id")"
}

_clone_from_snap() {
    local src_cid="$1" snap_path="$2" snap_label="$3"
    local src_name; src_name=$(_cname "$src_cid")
    [[ ! -d "$snap_path" ]] && { pause "Snapshot not found."; return 1; }
    finput "Name for the clone:" || return 1
    local clone_name="$FINPUT_RESULT"
    [[ -z "$clone_name" ]] && { pause "No name given."; return 1; }
    local clone_cid; clone_cid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -dc 'a-z0-9' | head -c 8 || tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
    local clone_dir="$CONTAINERS_DIR/$clone_cid"
    local clone_path="$INSTALLATIONS_DIR/$clone_cid"
    mkdir -p "$clone_dir" 2>/dev/null
    cp "$CONTAINERS_DIR/$src_cid/service.json" "$clone_dir/service.json" 2>/dev/null || true
    cp "$CONTAINERS_DIR/$src_cid/state.json"   "$clone_dir/state.json"   2>/dev/null || true
    [[ -f "$CONTAINERS_DIR/$src_cid/resources.json" ]] && cp "$CONTAINERS_DIR/$src_cid/resources.json" "$clone_dir/resources.json" 2>/dev/null || true
    jq --arg n "$clone_name" --arg p "$(basename "$clone_path")" '.name=$n | .install_path=$p' \
        "$clone_dir/state.json" > "$clone_dir/state.json.tmp" 2>/dev/null \
        && mv "$clone_dir/state.json.tmp" "$clone_dir/state.json"
    if btrfs subvolume snapshot "$snap_path" "$clone_path" &>/dev/null; then
        btrfs property set "$clone_path" ro false &>/dev/null || true
        pause "$(printf "Cloned '%s' (%s) → '%s'" "$src_name" "$snap_label" "$clone_name")"
    else
        cp -a "$snap_path/." "$clone_path/" 2>/dev/null \
            || { rm -rf "$clone_dir" "$clone_path" 2>/dev/null; pause "Clone failed."; return 1; }
        pause "$(printf "Cloned '%s' (%s) → '%s' (plain copy)" "$src_name" "$snap_label" "$clone_name")"
    fi
}

_process_install_finish() {
    local cid="$1" name; name=$(_cname "$cid")
    local ok_file="$CONTAINERS_DIR/$cid/.install_ok"
    local fail_file="$CONTAINERS_DIR/$cid/.install_fail"
    tmux kill-session -t "$(_inst_sess "$cid")" 2>/dev/null || true; _tmux_set SD_INSTALLING ""
    if [[ -f "$ok_file" ]]; then
        # Stale if ok_file is older than 10 minutes and tmux session is gone
        local _ok_age; _ok_age=$(( $(date +%s) - $(date -r "$ok_file" +%s 2>/dev/null || echo 0) ))
        if [[ "$_ok_age" -gt 600 ]] && ! tmux_up "$(_inst_sess "$cid")"; then
            rm -f "$ok_file"; pause "⚠  Installation result is stale. Please reinstall."; return
        fi
        rm -f "$ok_file"
        # Pkg update: container already installed — just update manifest + show done
        if [[ "$(_st "$cid" installed)" == "true" ]]; then
            _write_pkg_manifest "$cid"
            pause "$(printf "'%s' packages updated." "$name")"
            return
        fi
        # Fresh install
        _set_st "$cid" installed true
        _write_pkg_manifest "$cid"
        local _ipath; _ipath=$(_cpath "$cid")
        [[ -n "$_ipath" && -f "$UBUNTU_DIR/.sd_ubuntu_stamp" ]] && cp "$UBUNTU_DIR/.sd_ubuntu_stamp" "$_ipath/.sd_ubuntu_stamp" 2>/dev/null || true
        if confirm "$(printf "'%s' ${L[msg_install_ok]}\n\nCreate a Post-Install backup?\n  (Instant revert to clean install)" "$name")"; then
            local _pi_sdir; _pi_sdir=$(_snap_dir "$cid"); mkdir -p "$_pi_sdir" 2>/dev/null
            local _pi_id="Post-Installation" _pi_path; _pi_path=$(_cpath "$cid")
            local _pi_ts; _pi_ts=$(date '+%Y-%m-%d %H:%M')
            [[ -d "$_pi_sdir/$_pi_id" ]] && _delete_backup "$_pi_sdir" "$_pi_id"
            if btrfs subvolume snapshot -r "$_pi_path" "$_pi_sdir/$_pi_id" &>/dev/null; then
                _snap_meta_set "$_pi_sdir" "$_pi_id" "type=manual" "ts=$_pi_ts"
                pause "$(printf "Backup 'Post-Installation' created for '%s'." "$name")"
            else
                cp -a "$_pi_path" "$_pi_sdir/$_pi_id" 2>/dev/null \
                    && _snap_meta_set "$_pi_sdir" "$_pi_id" "type=manual" "ts=$_pi_ts" \
                    && pause "$(printf "Backup 'Post-Installation' created for '%s'." "$name")" \
                    || pause "$(printf "Backup failed for '%s' — disk full?" "$name")"
            fi
        else
            pause "'$name' ${L[msg_install_ok]}"
        fi
    elif [[ -f "$fail_file" ]]; then
        rm -f "$fail_file"; pause "${L[msg_install_fail]}"
    fi
    _update_size_cache "$cid"
}
