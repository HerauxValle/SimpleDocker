# menus/main_menu.sh — main_menu (top-level post-mount), _containers_submenu,
#                       _blueprints_settings_menu, _blueprints_submenu
# Sourced by main.sh — do NOT run directly

main_menu() {
    while true; do
        clear; _cleanup_stale_lock; _validate_containers; _load_containers false
        local inst_id; inst_id=$(_installing_id)

        # Count summaries
        local n_running=0 n_groups=0 n_bps=0
        for cid in "${CT_IDS[@]}"; do tmux_up "$(tsess "$cid")" && (( n_running++ )) || true; done
        local grp_ids=(); mapfile -t grp_ids < <(_list_groups)
        n_groups=${#grp_ids[@]}
        local bp_names=(); mapfile -t bp_names < <(_list_blueprint_names)
        local pbp_names=(); mapfile -t pbp_names < <(_list_persistent_names)
        local ibp_names=(); mapfile -t ibp_names < <(_list_imported_names)
        n_bps=$(( ${#bp_names[@]} + ${#pbp_names[@]} + ${#ibp_names[@]} ))

        # Status indicators for submenu items
        local ct_status="${DIM}${#CT_IDS[@]}${NC}"
        [[ $n_running -gt 0 ]] && ct_status="$(printf "${GRN}%d running${NC}${DIM}/%d${NC}" "$n_running" "${#CT_IDS[@]}")"

        local grp_n_active=0
        for gid in "${grp_ids[@]}"; do
            local grunning=0
            while IFS= read -r cname; do
                local gcid; gcid=$(_ct_id_by_name "$cname")
                [[ -n "$gcid" ]] && tmux_up "$(tsess "$gcid")" && (( grunning++ )) || true
            done < <(_grp_containers "$gid")
            [[ $grunning -gt 0 ]] && (( grp_n_active++ )) || true
        done
        local grp_status="${DIM}${n_groups}${NC}"
        [[ $grp_n_active -gt 0 ]] && grp_status="$(printf "${GRN}%d active${NC}${DIM}/%d${NC}" "$grp_n_active" "$n_groups")"

        local lines=(
            "$(printf " ${GRN}◈${NC}  %-28s %b" "Containers" "$ct_status")"
            "$(printf " ${CYN}▶${NC}  %-28s %b" "Groups" "$grp_status")"
            "$(printf " ${BLU}◈${NC}  %-28s ${DIM}%d${NC}" "Blueprints" "$n_bps")"
            "$_SEP"
            "$(printf "${DIM} ?  %s${NC}" "${L[help]}")"
            "$(printf "${RED} ×  %s${NC}" "${L[quit]}")"
        )

        local img_label=""
        if [[ -n "$IMG_PATH" ]] && mountpoint -q "$MNT_DIR" 2>/dev/null; then
            local used_kb total_bytes
            used_kb=$(df -k "$MNT_DIR" 2>/dev/null | awk 'NR==2{print $3}')
            total_bytes=$(stat -c%s "$IMG_PATH" 2>/dev/null)
            local used_gb total_gb
            used_gb=$(awk "BEGIN{printf \"%.1f\",${used_kb:-0}/1048576}")
            total_gb=$(awk "BEGIN{printf \"%.1f\",${total_bytes:-0}/1073741824}")
            img_label="$(printf "${DIM}  %s  [%s/%s GB]${NC}" "$(basename "$IMG_PATH")" "$used_gb" "$total_gb")"
        elif [[ -n "$IMG_PATH" ]]; then
            img_label="$(printf "${DIM}  %s${NC}" "$(basename "$IMG_PATH")")"
        fi

        local _fzf_sel_out; _fzf_sel_out=$(mktemp "$TMP_DIR/.sd_fzf_sel_XXXXXX")
        printf '%s\n' "${lines[@]}" \
            | fzf "${FZF_BASE[@]}" \
                  --header="$(printf "${BLD}── %s ──${NC}%s" "${L[title]}" "$img_label")" \
                  "--bind=${KB[quit]}:execute-silent(tmux set-environment -g SD_QUIT 1)+abort" \
                  >"$_fzf_sel_out" 2>/dev/null &
        local _fzf_sel_pid=$!
        printf '%s' "$_fzf_sel_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_sel_pid" 2>/dev/null
        local _fzf_rc=$?
        if [[ $_fzf_rc -eq 143 || $_fzf_rc -eq 138 || $_fzf_rc -eq 137 ]]; then
            rm -f "$_fzf_sel_out"; stty sane 2>/dev/null; continue
        fi
        local sel; sel=$(cat "$_fzf_sel_out" 2>/dev/null); rm -f "$_fzf_sel_out"
        if [[ -z "$sel" ]]; then
            if [[ "$(_tmux_get SD_QUIT)" == "1" ]]; then
                _tmux_set SD_QUIT 0; _quit_menu; continue
            fi
            _quit_all
        fi

        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ -z "$clean" ]] && continue

        case "$clean" in
            *"${L[quit]}"*) _quit_menu ;;
            *"${L[help]}"*) _help_menu ;;

            *"Containers"*) _containers_submenu ;;
            *"Groups"*)     _groups_menu ;;
            *"Blueprints"*) _blueprints_submenu ;;
        esac
    done
}

# ── Containers submenu ────────────────────────────────────────────
_containers_submenu() {
    while true; do
        clear
        # drain any buffered terminal input so it doesn't leak into fzf's query
        stty sane 2>/dev/null
        while IFS= read -r -t 0.1 -n 256 _ 2>/dev/null; do :; done
        _load_containers false
        local inst_id; inst_id=$(_installing_id)
        local lines=() n_running_ct=0
        lines+=("$(printf "${BLD}  ── Containers ──────────────────────${NC}")")

        for i in "${!CT_IDS[@]}"; do
            local cid="${CT_IDS[$i]}" n="${CT_NAMES[$i]}"
            local dialogue; dialogue=$(jq -r '.meta.dialogue // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local dot
            local _cok="$CONTAINERS_DIR/$cid/.install_ok" _cfail="$CONTAINERS_DIR/$cid/.install_fail"
            if   _is_installing "$cid" || [[ -f "$_cok" || -f "$_cfail" ]]; then dot="${YLW}◈${NC}"
            elif tmux_up "$(tsess "$cid")"; then
                (( n_running_ct++ )) || true
                if _health_check "$cid"; then dot="${GRN}◈${NC}"
                else dot="${YLW}◈${NC}"; fi
            elif [[ "$(_st "$cid" installed)" == "true" ]]; then dot="${RED}◈${NC}"
            else dot="${DIM}◈${NC}"; fi
            local disp_name
            [[ -n "$dialogue" ]] \
                && disp_name="$(printf "%s  \033[2m— %s\033[0m" "$n" "$dialogue")" \
                || disp_name="$n"
            local _sz_lbl=""
            local _ipath; _ipath=$(_cpath "$cid")
            if [[ -d "$_ipath" ]]; then
                local _sz_cache="$CACHE_DIR/sd_size/$cid"
                # Show cached value instantly, refresh in background
                if [[ -f "$_sz_cache" ]]; then
                    _sz_lbl="$(printf "${DIM}[%sgb]${NC}" "$(cat "$_sz_cache" 2>/dev/null)")"
                fi
                # Refresh cache in background if missing or older than 60s
                local _sz_age=999
                [[ -f "$_sz_cache" ]] && _sz_age=$(( $(date +%s) - $(date -r "$_sz_cache" +%s 2>/dev/null || echo 0) ))
                if [[ $_sz_age -gt 60 ]]; then
                    { mkdir -p "${_sz_cache%/*}" 2>/dev/null; du -sb "$_ipath" 2>/dev/null | awk '{printf "%.2f",$1/1073741824}' > "$_sz_cache.tmp" && mv "$_sz_cache.tmp" "$_sz_cache"; } 2>/dev/null &
                    disown 2>/dev/null || true
                fi
            fi
            local _list_port; _list_port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local _list_ep; _list_ep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            [[ -n "$_list_ep" ]] && _list_port="$_list_ep"
            local _list_ip_lbl=""
            if [[ -n "$_list_port" && "$_list_port" != "0" && "$(_st "$cid" installed)" == "true" ]]; then
                local _list_ip; _list_ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
                _list_ip_lbl="$(printf "\033[2m[%s:%s]\033[0m " "$_list_ip" "$_list_port")"
            fi
            lines+=("$(printf " %b  %b\033[0m\033[2m %b %s[%s]\033[0m" "$dot" "$disp_name" "$_sz_lbl" "$_list_ip_lbl" "$cid")")
        done

        local bps=(); mapfile -t bps < <(_list_blueprint_names)
        local pbps=(); mapfile -t pbps < <(_list_persistent_names)
        local all_bps=("${bps[@]}" "${pbps[@]}")

        [[ ${#CT_IDS[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no containers yet)${NC}")")
        lines+=("$(printf "${GRN} +  %s${NC}" "${L[new_container]}")")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        local _ct_hdr_extra; _ct_hdr_extra=$(printf "  ${DIM}[%d · ${GRN}%d ▶${NC}${DIM}]${NC}" "${#CT_IDS[@]}" "$n_running_ct")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Containers ──${NC}%s" "$_ct_hdr_extra")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel}" ]] && return

        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" ]] && return
        [[ -z "$clean" ]] && continue

        if [[ "$clean" == *"${L[new_container]}"* ]]; then
            _install_method_menu; continue
        fi

        local cid_tag
        cid_tag=$(printf '%s' "$clean" | grep -oP '(?<=\[)[a-z0-9]{8}(?=\]$)' || true)
        [[ -n "$cid_tag" && -d "$CONTAINERS_DIR/$cid_tag" ]] && _container_submenu "$cid_tag"
    done
}

# ── Blueprint settings menu ───────────────────────────────────────
_blueprints_settings_menu() {
    local _SEP_GEN _SEP_PATHS _SEP_NAV
    _SEP_GEN="$(printf "${BLD}  ── General ───────────────────────────${NC}")"
    _SEP_PATHS="$(printf "${BLD}  ── Scanned paths ─────────────────────${NC}")"
    _SEP_NAV="$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"
    while true; do
        local pers_enabled; _bp_persistent_enabled && pers_enabled=true || pers_enabled=false
        local pers_tog
        [[ "$pers_enabled" == "true" ]] \
            && pers_tog="$(printf "${GRN}[Enabled]${NC}")" \
            || pers_tog="$(printf "${RED}[Disabled]${NC}")"

        local ad_mode; ad_mode=$(_bp_autodetect_mode)
        local ad_lbl
        case "$ad_mode" in
            Home)       ad_lbl="$(printf "${GRN}[Home]${NC}")" ;;
            Root)       ad_lbl="$(printf "${YLW}[Root]${NC}")" ;;
            Everywhere) ad_lbl="$(printf "${CYN}[Everywhere]${NC}")" ;;
            Custom)     ad_lbl="$(printf "${BLU}[Custom]${NC}")" ;;
            Disabled)   ad_lbl="$(printf "${DIM}[Disabled]${NC}")" ;;
        esac

        local lines=(
            "$_SEP_GEN"
            "$(printf " ${DIM}◈${NC}  Persistent blueprints  %b  ${DIM}— toggle built-in visibility${NC}" "$pers_tog")"
            "$(printf " ${DIM}◈${NC}  Autodetect blueprints  %b  ${DIM}— scan for .container files${NC}" "$ad_lbl")"
        )

        # Scanned paths section only visible in Custom mode
        if [[ "$ad_mode" == "Custom" ]]; then
            lines+=("$_SEP_PATHS")
            local _cpaths=(); mapfile -t _cpaths < <(_bp_custom_paths_get)
            if [[ ${#_cpaths[@]} -eq 0 ]]; then
                lines+=("$(printf "${DIM}  (no paths configured)${NC}")")
            else
                for _cp in "${_cpaths[@]}"; do
                    if [[ -d "$_cp" ]]; then
                        lines+=("$(printf " ${DIM}◈${NC}  ${DIM}%s${NC}" "$_cp")")
                    else
                        lines+=("$(printf " ${DIM}◈${NC}  ${DIM}%s${NC}  ${RED}[corrupted]${NC}" "$_cp")")
                    fi
                done
            fi
            lines+=("$(printf "${GRN} +  Add path${NC}")")
        fi

        lines+=("$_SEP_NAV")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" \
            | fzf "${FZF_BASE[@]}" \
                  --header="$(printf "${BLD}── Blueprints — Settings ──${NC}")" \
                  >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "$sel" ]] && return
        local sc; sc=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*//')
        case "$sc" in
            *"${L[back]}"*|"") return ;;
            *"Persistent blueprints"*)
                [[ "$pers_enabled" == "true" ]] \
                    && _bp_cfg_set persistent_blueprints false \
                    || _bp_cfg_set persistent_blueprints true ;;
            *"Autodetect blueprints"*)
                # Cycle: Home → Root → Everywhere → Custom → Disabled → Home
                case "$ad_mode" in
                    Home)       _bp_cfg_set autodetect_blueprints Root ;;
                    Root)       _bp_cfg_set autodetect_blueprints Everywhere ;;
                    Everywhere) _bp_cfg_set autodetect_blueprints Custom ;;
                    Custom)     _bp_cfg_set autodetect_blueprints Disabled ;;
                    Disabled)   _bp_cfg_set autodetect_blueprints Home ;;
                esac ;;
            *"Add path"*)
                # Pick folder via yazi
                if ! command -v yazi >/dev/null 2>&1; then
                    pause "yazi is not installed on this system."; continue
                fi
                local _chosen_dir; _chosen_dir=$(mktemp -u "$TMP_DIR/.sd_yazi_XXXXXX")
                yazi --chooser-file="$_chosen_dir" 2>/dev/null
                local _picked; _picked=$(cat "$_chosen_dir" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//'); rm -f "$_chosen_dir"
                [[ -z "$_picked" ]] && continue
                [[ ! -d "$_picked" ]] && { pause "$(printf "Not a directory:\n  %s" "$_picked")"; continue; }
                _bp_custom_paths_add "$_picked"
                ;;
            *)
                # Check if sc matches one of the custom paths (path removal)
                local _cp
                while IFS= read -r _cp; do
                    if [[ "$sc" == *"$_cp"* ]]; then
                        confirm "$(printf "Remove path from scan list?\n\n  %s" "$_cp")" || break
                        _bp_custom_paths_remove "$_cp"
                        break
                    fi
                done < <(_bp_custom_paths_get)
                ;;
        esac
    done
}

# ── Blueprints submenu ────────────────────────────────────────────
_blueprints_submenu() {
    while true; do
        clear
        while IFS= read -r -t 0 -n 1 _ 2>/dev/null; do :; done
        local bps=(); mapfile -t bps < <(_list_blueprint_names)
        local pbps=(); mapfile -t pbps < <(_list_persistent_names)
        local ibps=(); mapfile -t ibps < <(_list_imported_names)
        local lines=()

        lines+=("$(printf "${BLD}  ── Blueprints ───────────────────────${NC}")")
        for n in "${bps[@]}";  do lines+=("$(printf "${DIM} ◈${NC}  %s" "$n")"); done
        for n in "${pbps[@]}"; do lines+=("$(printf "${BLU} ◈${NC}  %s  ${DIM}[Persistent]${NC}" "$n")"); done
        for n in "${ibps[@]}"; do lines+=("$(printf "${CYN} ◈${NC}  %s  ${DIM}[Imported]${NC}" "$n")"); done

        [[ ${#bps[@]} -eq 0 && ${#pbps[@]} -eq 0 && ${#ibps[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no blueprints yet)${NC}")")
        lines+=("$(printf "${GRN} +  %s${NC}" "${L[bp_new]}")")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}── Blueprints ──${NC}  ${DIM}[%d file · %d built-in · %d imported]${NC}" "${#bps[@]}" "${#pbps[@]}" "${#ibps[@]}")" \
            >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel}" ]] && return
        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" ]] && return

        local sc; sc=$(printf '%s' "$clean" | _strip_ansi | sed 's/^[[:space:]]*//')

        if [[ "$clean" == *"${L[bp_new]}"* ]]; then
            _guard_space || continue
            finput "Blueprint name:" || continue
            local bname; bname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"
            [[ -z "$bname" ]] && continue
            local bfile; bfile="$BLUEPRINTS_DIR/$bname.toml"
            [[ -f "$bfile" ]] && { pause "Blueprint '$bname' already exists."; continue; }
            _blueprint_template > "$bfile"
            pause "Blueprint '$bname' created. Select it to edit."
            continue
        fi

        if [[ "$clean" == *"[Persistent]"* ]]; then
            local pname; pname=$(printf '%s' "$clean" | sed 's/^[[:space:]]*◈[[:space:]]*//;s/[[:space:]]*\[Persistent\].*//')
            [[ -n "$pname" ]] && _view_persistent_bp "$pname"
            continue
        fi

        if [[ "$clean" == *"[Imported]"* ]]; then
            local iname; iname=$(printf '%s' "$clean" | sed 's/^[[:space:]]*◈[[:space:]]*//;s/[[:space:]]*\[Imported\].*//')
            local ipath; ipath=$(_get_imported_bp_path "$iname")
            if [[ -n "$ipath" && -f "$ipath" ]]; then
                cat "$ipath" \
                    | _fzf "${FZF_BASE[@]}" \
                          --header="$(printf "${BLD}── [Imported] %s  ${DIM}(%s)${NC} ──${NC}" "$iname" "$ipath")" \
                          --no-multi --disabled 2>/dev/null || true
            else
                pause "Could not locate imported blueprint '$iname'."
            fi
            continue
        fi

        for n in "${bps[@]}"; do
            if [[ "$clean" == *"$n"* ]]; then _blueprint_submenu "$n"; break; fi
        done
    done
}

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
