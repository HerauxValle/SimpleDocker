# menus/logs_help.sh — _logs_browser, _help_menu
# Sourced by main.sh — do NOT run directly

# ── Other / help menu ────────────────────────────────────────────
_logs_browser() {
    while true; do
        [[ -z "$LOGS_DIR" || ! -d "$LOGS_DIR" ]] && { pause "No Logs folder found."; return; }
        local _files=()
        while IFS= read -r f; do
            _files+=("$(printf "${DIM}%s${NC}" "${f#$LOGS_DIR/}")")
        done < <(find "$LOGS_DIR" -type f -name "*.log" | sort -r)
        [[ ${#_files[@]} -eq 0 ]] && { pause "No log files yet."; return; }
        _files+=("$(printf "${DIM}%s${NC}" "${L[back]}")")
        local sel; sel=$(printf '%s\n' "${_files[@]}" \
            | _fzf "${FZF_BASE[@]}" \
                --header="$(printf "${BLD}── Logs ──${NC}")" 2>/dev/null) || return
        local sel_clean; sel_clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$sel_clean" == "${L[back]}" ]] && return
        local _path="$LOGS_DIR/$sel_clean"
        [[ ! -f "$_path" ]] && continue
        cat "$_path" \
            | _fzf "${FZF_BASE[@]}" \
                --header="$(printf "${BLD}── %s  ${DIM}(read only)${NC} ──${NC}" "$sel_clean")" \
                --no-multi --disabled >/dev/null 2>&1 || true
    done
}

_help_menu() {
    local _SEP_STORAGE _SEP_PLUGINS _SEP_ISOLATION _SEP_TOOLS _SEP_DANGER _SEP_NAV
    _SEP_STORAGE="$(  printf "${BLD}  ── Storage ───────────────────────────${NC}")"
    _SEP_PLUGINS="$(  printf "${BLD}  ── Plugins ───────────────────────────${NC}")"
    _SEP_TOOLS="$(    printf "${BLD}  ── Tools ─────────────────────────────${NC}")"
    _SEP_HELP="$(     printf "${BLD}  ── Help ──────────────────────────────${NC}")"
    _SEP_DANGER="$(   printf "${BLD}  ── Caution ───────────────────────────${NC}")"
    _SEP_NAV="$(      printf "${BLD}  ── Navigation ────────────────────────${NC}")"
    while true; do
        local ubuntu_status proxy_status ubuntu_upd_tag=""
        _sd_ub_cache_read
        if [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
            ubuntu_status="$(printf "${GRN}ready${NC}  ${CYN}[P]${NC}")"
            if [[ "$_SD_UB_PKG_DRIFT" == true || "$_SD_UB_HAS_UPDATES" == true ]]; then
                ubuntu_upd_tag="  $(printf "${YLW}Updates available${NC}")"
            fi
        else
            ubuntu_status="$(printf "${YLW}not installed${NC}")"
        fi
        _proxy_running                        && proxy_status="$(printf "${GRN}running${NC}")"  || proxy_status="$(printf "${DIM}stopped${NC}")"
        local lines=(
            "$_SEP_STORAGE"
            "$(printf "${DIM} ◈  Profiles & data${NC}")"
            "$(printf "${DIM} ◈  Backups${NC}")"
            "$(printf "${DIM} ◈  Blueprints${NC}")"
            "$_SEP_PLUGINS"
            "$(printf " ${CYN}◈${NC}${DIM}  Ubuntu base — %b%s${NC}" "$ubuntu_status" "$ubuntu_upd_tag")"
            "$(printf " ${CYN}◈${NC}${DIM}  Caddy — %b${NC}" "$proxy_status")"
            "$(printf " ${CYN}◈${NC}${DIM}  QRencode — %b${NC}" "$([[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && _chroot_bash "$UBUNTU_DIR" -c 'command -v qrencode' >/dev/null 2>&1 && printf "${GRN}installed${NC}" || printf "${DIM}not installed${NC}")")"

            "$_SEP_TOOLS"
            "$(printf "${DIM} ◈  Active processes${NC}")"
            "$(printf "${DIM} ◈  Resource limits${NC}")"
            "$(printf "${DIM} ≡  Blueprint preset${NC}")"

            "$_SEP_DANGER"
            "$(printf "${DIM} ≡  View logs${NC}")"
            "$(printf "${DIM} ⊘  Clear cache${NC}")"
            "$(printf "${DIM} ▷  Resize image${NC}")"
            "$(printf "${DIM} ◈  Manage Encryption${NC}")"
            "$(printf " ${RED}×${NC}${DIM}  Delete image file${NC}")"
            "$_SEP_NAV"
            "$(printf "${DIM} %s${NC}" "${L[back]}")"
        )
        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── %s ──${NC}  ${DIM}Ubuntu:${NC}%b  ${DIM}Proxy:${NC}%b" "${L[help]}" "$ubuntu_status" "$proxy_status")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        if _sig_rc $_frc; then stty sane 2>/dev/null; continue; fi
        [[ $_frc -ne 0 ]] && return
        local sel_clean; sel_clean=$(printf '%s' "$sel" | _trim_s)
        case "$sel_clean" in
            *"${L[back]}"*)         return ;;
            *"Clear cache"*)
                confirm "Clear all cached data?" || continue
                rm -rf "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null || true
                mkdir -p "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null
                pause "Cache cleared." ;;
            *"Resize image"*)       _resize_image ;;
            *"Manage Encryption"*)  _enc_menu ;;
            *"Profiles & data"*) _persistent_storage_menu; continue ;;
            *"Backups"*)            _manage_backups_menu ;;
            *"Blueprints"*)         _blueprints_settings_menu; continue ;;
            *"Active processes"*)   _active_processes_menu ;;
            *"Resource limits"*)  _resources_menu ;;
            *"Caddy"*)               _proxy_menu; continue ;;
            *"QRencode"*)
                _qrencode_menu; continue ;;
            *"Ubuntu base"*)
                _ubuntu_menu; continue ;;
            *"Blueprint preset"*)
                _blueprint_template \
                    | _fzf "${FZF_BASE[@]}" \
                          --header="$(printf "${BLD}── Blueprint preset  ${DIM}(read only)${NC} ──${NC}")" \
                          --no-multi --disabled >/dev/null 2>&1 || true ;;
            *"Blueprint example"*) ;;
            *"View logs"*|*"Logs"*)
                _logs_browser ;;
            *"Delete image file"*)
                [[ -z "$IMG_PATH" ]] && { pause "No image currently loaded."; continue; }
                local img_name; img_name=$(basename "$IMG_PATH")
                local img_path_save="$IMG_PATH"
                confirm "$(printf "PERMANENTLY DELETE IMAGE?\n\n  File: %s\n  Path: %s\n\n  THIS CANNOT BE UNDONE!" "$img_name" "$img_path_save")" || continue
                _load_containers true
                local dcid dsess
                for dcid in "${CT_IDS[@]}"; do
                    dsess="$(tsess "$dcid")"
                    tmux_up "$dsess" && { tmux send-keys -t "$dsess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$dsess" 2>/dev/null || true; }
                done
                tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true; _tmux_set SD_INSTALLING ""
                _unmount_img; rm -f "$img_path_save" 2>/dev/null
                IMG_PATH="" BLUEPRINTS_DIR="" CONTAINERS_DIR="" INSTALLATIONS_DIR="" BACKUP_DIR="" STORAGE_DIR=""
                pause "$(printf "✓ Image deleted: %s\n\n  Select or create a new image." "$img_name")"
                _setup_image; return ;;
        esac
    done
}

#  MAIN MENU  —  Containers / Groups / Blueprints as submenus
_SEP="$(printf     "${BLD}  ─────────────────────────────────────${NC}")"

