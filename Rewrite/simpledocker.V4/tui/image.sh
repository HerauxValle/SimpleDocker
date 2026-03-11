#!/usr/bin/env bash

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

_resize_image() {
    [[ -z "$IMG_PATH" || ! -f "$IMG_PATH" ]] && { pause "No image mounted."; return 1; }
    local cur_bytes; cur_bytes=$(stat -c%s "$IMG_PATH" 2>/dev/null)
    local cur_gib;   cur_gib=$(awk "BEGIN{printf \"%.1f\",$cur_bytes/1073741824}")
    local used_bytes=0
    if mountpoint -q "$MNT_DIR" 2>/dev/null; then
        used_bytes=$(btrfs filesystem usage -b "$MNT_DIR" 2>/dev/null \
            | grep -i 'used' | head -1 | grep -oP '[0-9]+' | tail -1 || echo 0)
        [[ -z "$used_bytes" || "$used_bytes" == "0" ]] && \
            used_bytes=$(df -k "$MNT_DIR" 2>/dev/null | awk 'NR==2{print $3*1024}')
    fi
    local used_gib; used_gib=$(awk "BEGIN{printf \"%.1f\",$used_bytes/1073741824}")
    local min_gib;  min_gib=$(awk "BEGIN{print int($used_bytes/1073741824)+1+10}")
    local new_gib_raw
    finput "$(printf 'Current: %s GB   Used: %s GB   Minimum: %s GB\n\nNew size in GB:' "$cur_gib" "$used_gib" "$min_gib")" || return 0
    new_gib_raw="${FINPUT_RESULT//[^0-9]/}"
    if [[ -z "$new_gib_raw" || "$new_gib_raw" -lt "$min_gib" ]]; then
        pause "$(printf 'Invalid size. Must be a whole number ≥ %s GB.' "$min_gib")"; return 1
    fi
    local new_gib="$new_gib_raw" new_bytes=$(( new_gib_raw * 1073741824 ))

    local running_names=()
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local _cid; _cid=$(basename "$d")
        tmux_up "$(tsess "$_cid")" && running_names+=("$(jq -r '.name // empty' "$d/state.json" 2>/dev/null)")
    done
    # per-container install sessions checked per-cid below

    local confirm_msg
    if [[ ${#running_names[@]} -gt 0 ]]; then
        local list; list=$(printf '  • %s\n' "${running_names[@]}")
        confirm_msg="$(printf 'Running services will be stopped:\n%s\n\nResize image from %s GB → %s GB?' "$list" "$cur_gib" "$new_gib")"
    else
        confirm_msg="$(printf 'Resize image from %s GB → %s GB?' "$cur_gib" "$new_gib")"
    fi
    confirm "$confirm_msg" || return 0

    if [[ ${#running_names[@]} -gt 0 ]]; then
        for d in "$CONTAINERS_DIR"/*/; do
            [[ -f "$d/state.json" ]] || continue
            local _cid; _cid=$(basename "$d"); local _sess; _sess="$(tsess "$_cid")"
            tmux_up "$_sess" && { tmux send-keys -t "$_sess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$_sess" 2>/dev/null || true; }
        done
        tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
        _tmux_set SD_INSTALLING ""
        sleep 0.5
    fi

    local img_to_resize="$IMG_PATH"
    # Sentinel files must survive image unmount — use SD_MNT_BASE/.tmp not TMP_DIR
    mkdir -p "$SD_MNT_BASE/.tmp" 2>/dev/null
    local ok_file;   ok_file=$(mktemp "$SD_MNT_BASE/.tmp/.sd_resize_ok_XXXXXX")
    local fail_file; fail_file=$(mktemp "$SD_MNT_BASE/.tmp/.sd_resize_fail_XXXXXX")
    rm -f "$ok_file" "$fail_file"
    local resize_script; resize_script=$(mktemp "$SD_MNT_BASE/.tmp/.sd_resize_XXXXXX.sh")
    # Compute the known LUKS mapper name (same logic as _luks_mapper) so we can close it directly
    local _known_mapper; _known_mapper="sd_$(basename "${img_to_resize%.img}" | tr -dc 'a-zA-Z0-9_')"
    cat > "$resize_script" <<RESIZESCRIPT
#!/usr/bin/env bash
mnt_dir=$(printf '%q' "$MNT_DIR")
img=$(printf '%q' "$img_to_resize")
ok_f=$(printf '%q' "$ok_file")
fail_f=$(printf '%q' "$fail_file")
known_mapper=$(printf '%q' "$_known_mapper")
auto_pass=$(printf '%q' "$SD_VERIFICATION_CIPHER")

_fail() {
    printf '\n\033[0;31m══ Resize failed ══\033[0m\n'
    touch "\$fail_f" 2>/dev/null
    printf 'Press Enter to return…\n'; read -r _
    tmux switch-client -t simpleDocker 2>/dev/null || true
    tmux kill-session -t sdResize 2>/dev/null || true
}
trap '' INT

# ── 1. Unmount and fully detach the image ────────────────────────
printf '\033[0;33mUnmounting image…\033[0m\n'
# Force-unmount fs first, then close LUKS mapper, then detach loop
sudo -n umount -lf "\$mnt_dir" 2>/dev/null || true
sudo -n cryptsetup close "\$known_mapper" 2>/dev/null || true
# Find and detach backing loop device via /sys
_lodev=""
for _lo in /sys/block/loop*/backing_file; do
    [[ -f "\$_lo" ]] || continue
    if [[ "\$(cat "\$_lo" 2>/dev/null)" == "\$img" ]]; then
        _lodev="/dev/\$(basename "\$(dirname "\$_lo")")"
        break
    fi
done
printf '[unmount] lodev=%s\n' "\$_lodev"
if [[ -n "\$_lodev" ]]; then
    sudo -n losetup -d "\$_lodev" 2>/dev/null || true
else
    printf '[unmount] no loop device found via /sys — will let losetup --find pick a fresh one\n'
fi

# ── 2. LUKS-aware mount helper ───────────────────────────────────
# Usage: _do_mount img mntpoint mapper_name
# Globals: lodev/mapper for current mount, saved passphrase for reuse
_mounted_lodev="" _mounted_mapper="" _saved_pp=""
_do_mount() {
    local _img="\$1" _mnt="\$2" _mname="\$3"
    mkdir -p "\$_mnt" 2>/dev/null
    _mounted_lodev=\$(sudo -n losetup --find --show "\$_img" 2>/dev/null)
    printf '[mount] lodev=%s mapper=%s\n' "\$_mounted_lodev" "\$_mname"
    if [[ -z "\$_mounted_lodev" ]]; then printf 'ERROR: losetup failed\n'; return 1; fi
    if sudo -n cryptsetup isLuks "\$_mounted_lodev" 2>/dev/null; then
        _mounted_mapper="\$_mname"
        # Close stale mapper if already open
        if [[ -b "/dev/mapper/\$_mounted_mapper" ]]; then
            printf '[mount] stale mapper found, closing\n'
            sudo -n cryptsetup close "\$_mounted_mapper" 2>/dev/null || true
            sleep 0.3
        fi
        local _luks_ok=false
        for _try_pass in "\$auto_pass" "\$_saved_pp"; do
            [[ -z "\$_try_pass" ]] && continue
            local _e; _e=\$(printf '%s' "\$_try_pass" | sudo -n cryptsetup open --key-file=- "\$_mounted_lodev" "\$_mounted_mapper" 2>&1)
            if [[ \$? -eq 0 ]]; then _luks_ok=true; printf '[mount] auto-unlock OK\n'; break; fi
        done
        if [[ "\$_luks_ok" != true ]]; then
            printf '[mount] auto-unlock disabled, using passphrase\n'
            printf '  \033[1mPassphrase:\033[0m '; IFS= read -rs _saved_pp; printf '\n'
            local _e2; _e2=\$(printf '%s' "\$_saved_pp" | sudo -n cryptsetup open --key-file=- "\$_mounted_lodev" "\$_mounted_mapper" 2>&1)
            if [[ \$? -eq 0 ]]; then _luks_ok=true; printf '[mount] passphrase open OK\n'
            else printf '[mount] passphrase open failed: %s\n' "\$_e2"; fi
        fi
        if [[ "\$_luks_ok" != true ]]; then
            sudo -n losetup -d "\$_mounted_lodev" 2>/dev/null
            printf 'ERROR: LUKS open failed\n'; return 1
        fi
        if ! sudo -n mount -o compress=zstd "/dev/mapper/\$_mounted_mapper" "\$_mnt"; then
            sudo -n cryptsetup close "\$_mounted_mapper" 2>/dev/null
            sudo -n losetup -d "\$_mounted_lodev" 2>/dev/null
            printf 'ERROR: mount failed\n'; return 1
        fi
    else
        _mounted_mapper=""
        printf '[mount] not LUKS, mounting plain\n'
        if ! sudo -n mount -o compress=zstd "\$_mounted_lodev" "\$_mnt"; then
            sudo -n losetup -d "\$_mounted_lodev" 2>/dev/null
            printf 'ERROR: mount failed\n'; return 1
        fi
    fi
    printf '[mount] done\n'
}
_do_umount() {
    local _mnt="\$1"
    printf '[umount] mnt=%s mapper=%s lodev=%s\n' "\$_mnt" "\$_mounted_mapper" "\$_mounted_lodev"
    sudo -n umount "\$_mnt" 2>/dev/null || true
    if [[ -n "\$_mounted_mapper" ]]; then
        sudo -n cryptsetup close "\$_mounted_mapper" 2>/dev/null || true
        # Wait until mapper device node is gone before detaching loop
        local _w=0
        while [[ -b "/dev/mapper/\$_mounted_mapper" && \$_w -lt 50 ]]; do
            sleep 0.1; ((_w++))
        done
        printf '[umount] waited %d ticks for mapper release\n' "\$_w"
    fi
    [[ -n "\$_mounted_lodev" ]] && sudo -n losetup -d "\$_mounted_lodev" 2>/dev/null || true
    _mounted_lodev="" _mounted_mapper=""
    printf '[umount] done\n'
}

# ── 3. Resize ────────────────────────────────────────────────────
tmp_mnt=\$(mktemp -d /tmp/.sd_mnt_XXXXXX)
cur_bytes=\$(stat -c%s "\$img")
if [[ ${new_bytes} -ge \$cur_bytes ]]; then
    printf '\033[0;33mGrowing: file ${new_gib} GB → expand fs…\033[0m\n'
    truncate -s ${new_bytes} "\$img" || { _fail; exit 1; }
    _do_mount "\$img" "\$tmp_mnt" "sd_rsz_\${\$}" || { rm -rf "\$tmp_mnt"; _fail; exit 1; }
    sudo -n btrfs filesystem resize max "\$tmp_mnt" 2>/dev/null || { printf 'ERROR: btrfs resize failed\n'; _do_umount "\$tmp_mnt"; rm -rf "\$tmp_mnt"; _fail; exit 1; }
    _do_umount "\$tmp_mnt"
else
    printf '\033[0;33mShrinking: shrink fs first, then file…\033[0m\n'
    _do_mount "\$img" "\$tmp_mnt" "sd_rsz_\${\$}" || { rm -rf "\$tmp_mnt"; _fail; exit 1; }
    sudo -n btrfs filesystem resize ${new_bytes} "\$tmp_mnt" 2>/dev/null || { printf 'ERROR: btrfs resize failed\n'; _do_umount "\$tmp_mnt"; rm -rf "\$tmp_mnt"; _fail; exit 1; }
    _do_umount "\$tmp_mnt"
    truncate -s ${new_bytes} "\$img" || { _fail; exit 1; }
fi
rm -rf "\$tmp_mnt"

# ── 4. Remount ───────────────────────────────────────────────────
printf '\033[0;33mRemounting image…\033[0m\n'
mkdir -p "\$mnt_dir" 2>/dev/null
if [[ -b "/dev/mapper/\$known_mapper" ]]; then
    printf '[remount] mapper already open, mounting directly\n'
    if ! sudo -n mount -o compress=zstd "/dev/mapper/\$known_mapper" "\$mnt_dir"; then
        printf 'ERROR: final remount failed\n'; _fail; exit 1
    fi
else
    _do_mount "\$img" "\$mnt_dir" "\$known_mapper" || { printf 'ERROR: final remount failed\n'; _fail; exit 1; }
fi
sudo -n chown "\$(id -u):\$(id -g)" "\$mnt_dir" 2>/dev/null || true
touch "\$ok_f"
printf '\n\033[0;32m══ Resized to ${new_gib} GB successfully ══\033[0m\n'
printf 'Press Enter to return…\n'; read -r _
tmux switch-client -t simpleDocker 2>/dev/null || true
tmux kill-session -t sdResize 2>/dev/null || true
RESIZESCRIPT
    chmod +x "$resize_script"
    _tmux_launch --no-prompt "sdResize" "Resize image" "$resize_script"
    sleep 0.5
    while tmux_up "sdResize"; do
        sleep 0.3
        [[ -f "$ok_file" || -f "$fail_file" ]] && break
        if ! tmux list-clients -t "sdResize" 2>/dev/null | grep -q .; then
            [[ -f "$ok_file" || -f "$fail_file" ]] && break
            printf '%s\n' "  Attach to resize log" \
                | _fzf "${FZF_BASE[@]}" \
                      --header="$(printf "${BLD}── Resize in progress ──${NC}\n${DIM}  Press Enter to reattach${NC}")" \
                      --no-multi --bind=esc:ignore 2>/dev/null || true
            [[ -f "$ok_file" || -f "$fail_file" ]] && break
            tmux_up "sdResize" && tmux switch-client -t "sdResize" 2>/dev/null || true
        fi
    done
    clear; IMG_PATH="$img_to_resize"; _set_img_dirs
    if [[ -f "$ok_file" ]]; then
        rm -f "$ok_file" "$fail_file"
        for d in "$CONTAINERS_DIR"/*/; do
            [[ -f "$d/state.json" ]] || continue
            tmux kill-session -t "sd_$(basename "$d")" 2>/dev/null || true
        done
        tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
        _unmount_img
        exec bash "$(realpath "$0" 2>/dev/null || printf '%s' "$0")"
    else
        rm -f "$ok_file" "$fail_file"
        TMP_DIR="$SD_MNT_BASE/.tmp"; mkdir -p "$TMP_DIR" 2>/dev/null
        pause "Resize failed. Check that sudo commands succeeded."
        mountpoint -q "$MNT_DIR" 2>/dev/null || _mount_img "$img_to_resize"
    fi
}
