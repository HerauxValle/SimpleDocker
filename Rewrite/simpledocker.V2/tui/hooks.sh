#!/usr/bin/env bash
# tui/hooks.sh — dynamic entry builders for core/menu.sh
#
# Hook functions print tab-separated lines to stdout:
#   DISPLAY_LINE\tACTION[\tARG]
# where ACTION is "menu:X", "fn:X", or "back"
#
# These are the only parts of the TUI that can't be declared statically
# in menu.json because they depend on runtime state.

# ── Container list ────────────────────────────────────────────────
_hook_container_list() {
    _load_containers false
    local inst_id; inst_id=$(_installing_id)

    for i in "${!CT_IDS[@]}"; do
        local cid="${CT_IDS[$i]}" n="${CT_NAMES[$i]}"
        local dot disp_name

        # Status dot
        if [[ "$inst_id" == "$cid" ]] || _is_installing "$cid"; then
            dot="${YLW}⟳${NC}"; disp_name="$(printf "${YLW}%s${NC}" "$n")"
        elif tmux_up "$(tsess "$cid")"; then
            dot="${GRN}●${NC}"; disp_name="$(printf "${GRN}%s${NC}" "$n")"
        elif [[ "$(_st "$cid" installed)" == "true" ]]; then
            dot="${DIM}●${NC}"; disp_name="$(printf "${DIM}%s${NC}" "$n")"
        else
            dot="${DIM}○${NC}"; disp_name="$(printf "${DIM}%s${NC}" "$n")"
        fi

        local dialogue; dialogue=$(jq -r '.meta.dialogue // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local sz_lbl=""
        local sz_file="$CACHE_DIR/sd_size/$cid"
        [[ -f "$sz_file" ]] && sz_lbl="$(printf "${DIM}%s${NC}  " "$(cat "$sz_file")")"

        local svc_port; svc_port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local env_port; env_port=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        [[ -n "$env_port" ]] && svc_port="$env_port"

        local ip_lbl=""
        if [[ -n "$svc_port" && "$svc_port" != "0" && "$(_st "$cid" installed)" == "true" ]]; then
            local ip; ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
            ip_lbl="$(printf "${DIM}[%s:%s]${NC} " "$ip" "$svc_port")"
        fi

        local disp; disp=$(printf " %b  %b\033[0m\033[2m %b %s[%s]\033[0m" \
            "$dot" "$disp_name" "$sz_lbl" "$ip_lbl" "$cid")
        printf '%s\tfn:_container_submenu\t%s\n' "$disp" "$cid"
    done
}

# ── Container custom actions (from service.json [actions]) ────────
_hook_container_actions() {
    local cid="$1"
    [[ -z "$cid" ]] && return
    [[ "$(_st "$cid" installed)" != "true" ]] && return
    _is_installing "$cid" && return

    local sj="$CONTAINERS_DIR/$cid/service.json"
    local act_count; act_count=$(jq -r '.actions | length' "$sj" 2>/dev/null)
    [[ -z "$act_count" || "$act_count" -eq 0 ]] && return

    for (( ai=0; ai<act_count; ai++ )); do
        local lbl; lbl=$(jq -r --argjson i "$ai" '.actions[$i].label // empty' "$sj" 2>/dev/null)
        [[ -z "$lbl" ]] && continue
        # Skip "Open browser" - handled by open_in submenu
        printf '%s' "$lbl" | grep -qi "open browser" && continue
        # Auto-prepend ⊙ if label starts with plain letter
        printf '%s' "$lbl" | grep -qP '^[A-Za-z]' && lbl="⊙  $lbl"
        local disp; disp=$(printf "${DIM} %s${NC}" "$lbl")
        printf '%s\tfn:_run_container_action\t%s:%d\n' "$disp" "$cid" "$ai"
    done
}

# ── Group list ────────────────────────────────────────────────────
_hook_group_list() {
    local grp_ids=(); mapfile -t grp_ids < <(_list_groups)
    for gid in "${grp_ids[@]}"; do
        local gname; gname=$(_grp_read_field "$gid" name)
        [[ -z "$gname" ]] && gname="$gid"
        local gdesc; gdesc=$(_grp_read_field "$gid" desc)

        # Count running containers in group
        local grunning=0
        while IFS= read -r cname; do
            local gcid; gcid=$(_ct_id_by_name "$cname")
            [[ -n "$gcid" ]] && tmux_up "$(tsess "$gcid")" && (( grunning++ )) || true
        done < <(_grp_containers "$gid")

        local dot
        [[ $grunning -gt 0 ]] && dot="${GRN}▶${NC}" || dot="${DIM}▶${NC}"
        local disp; disp=$(printf " %b  ${BLD}%s${NC}${DIM}%s${NC}" \
            "$dot" "$gname" "${gdesc:+  — $gdesc}")
        printf '%s\tfn:_group_submenu\t%s\n' "$disp" "$gid"
    done
}

# ── Group sequence steps (for group_item menu) ────────────────────
_hook_group_steps() {
    local gid="$1"
    [[ -z "$gid" ]] && return
    local steps=(); mapfile -t steps < <(_grp_seq_steps "$gid")
    [[ ${#steps[@]} -eq 0 ]] && {
        printf "${DIM}  (no steps)${NC}\t__sep__\n"
        return
    }
    printf "${BLD}  ── Sequence ──────────────────────────${NC}\t__sep__\n"
    for i in "${!steps[@]}"; do
        local step="${steps[$i]}"
        local disp; disp=$(printf "   ${DIM}%d.${NC}  %s" "$((i+1))" "$step")
        printf '%s\tfn:_grp_edit_step_by_idx\t%s:%d\n' "$disp" "$gid" "$i"
    done
    printf "${DIM} +  Add step${NC}\tfn:_grp_add_step\t%s\n" "$gid"
}

# ── Blueprint list ────────────────────────────────────────────────
_hook_blueprint_list() {
    local bps=();  mapfile -t bps  < <(_list_blueprint_names)
    local pbps=(); mapfile -t pbps < <(_list_persistent_names)
    local ibps=(); mapfile -t ibps < <(_list_imported_names)

    [[ ${#bps[@]} -gt 0 ]] && \
        printf "${BLD}  ── Blueprints ────────────────────────${NC}\t__sep__\n"
    for n in "${bps[@]}"; do
        printf " ${DIM}◈  %s${NC}\tfn:_blueprint_submenu\t%s\n" "$n" "$n"
    done

    [[ ${#pbps[@]} -gt 0 ]] && \
        printf "${BLD}  ── Persistent ───────────────────────${NC}\t__sep__\n"
    for n in "${pbps[@]}"; do
        printf " ${BLU}◈${NC}${DIM}  %s  [Persistent]${NC}\tfn:_blueprint_submenu\t%s\n" "$n" "$n"
    done

    [[ ${#ibps[@]} -gt 0 ]] && \
        printf "${BLD}  ── Imported ─────────────────────────${NC}\t__sep__\n"
    for n in "${ibps[@]}"; do
        printf " ${CYN}◈${NC}${DIM}  %s  [Imported]${NC}\tfn:_blueprint_submenu\t%s\n" "$n" "$n"
    done
}

# ── Status helpers (called via status_fn in menu.json) ───────────
_ubuntu_status() {
    _sd_ub_cache_read 2>/dev/null
    if [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
        local upd=""
        [[ "$_SD_UB_PKG_DRIFT" == true || "$_SD_UB_HAS_UPDATES" == true ]] && \
            upd="  $(printf "${YLW}updates available${NC}")"
        printf "${GRN}ready${NC}  ${CYN}[P]${NC}%s" "$upd"
    else
        printf "${YLW}not installed${NC}"
    fi
}

_caddy_status() {
    _proxy_running && printf "${GRN}running${NC}" || printf "${DIM}stopped${NC}"
}

_qrencode_status() {
    [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && \
        _chroot_bash "$UBUNTU_DIR" -c 'command -v qrencode' >/dev/null 2>&1 \
        && printf "${GRN}installed${NC}" || printf "${DIM}not installed${NC}"
}

# ── Thin action wrappers needed by hooks ─────────────────────────
# These are called with "cid:idx" arg from container_actions hook
_run_container_action() {
    local spec="$1"
    local cid="${spec%%:*}" idx="${spec##*:}"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local dsl; dsl=$(jq -r --argjson i "$idx" '.actions[$i].dsl // .actions[$i].script // empty' "$sj" 2>/dev/null)
    local lbl; lbl=$(jq -r --argjson i "$idx" '.actions[$i].label // empty' "$sj" 2>/dev/null)
    [[ -z "$dsl" ]] && return
    local sess; sess="sdAct_${cid}_${idx}"
    local script; script=$(mktemp "$TMP_DIR/.sd_act_XXXXXX.sh")
    printf '#!/usr/bin/env bash\n%s\n' "$dsl" > "$script"; chmod +x "$script"
    _tmux_launch "$sess" "$lbl" "$script"
}

_grp_add_step() {
    local gid="$1"
    _grp_pick_step || return
    local steps=(); mapfile -t steps < <(_grp_seq_steps "$gid")
    steps+=("$FINPUT_RESULT")
    _grp_seq_save "$gid" "${steps[@]}"
}

_grp_edit_step_by_idx() {
    local spec="$1"
    local gid="${spec%%:*}" idx="${spec##*:}"
    local steps=(); mapfile -t steps < <(_grp_seq_steps "$gid")
    _grp_edit_step "${steps[$idx]}" || return
    steps[$idx]="$FINPUT_RESULT"
    _grp_seq_save "$gid" "${steps[@]}"
}

_create_group_menu() {
    finput "Group name:" || return
    local gname="$FINPUT_RESULT"
    _create_group "$gname"
}

_clear_cache() {
    confirm "Clear all cached data?" || return
    rm -rf "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null || true
    mkdir -p "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null
    pause "Cache cleared."
}

_delete_image_file() {
    [[ -z "$IMG_PATH" ]] && { pause "No image currently loaded."; return; }
    local img_name; img_name=$(basename "$IMG_PATH")
    confirm "$(printf "PERMANENTLY DELETE IMAGE?\n\n  File: %s\n\n  THIS CANNOT BE UNDONE!" "$img_name")" || return
    _load_containers true
    for dcid in "${CT_IDS[@]}"; do
        local dsess; dsess="$(tsess "$dcid")"
        tmux_up "$dsess" && { tmux send-keys -t "$dsess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$dsess" 2>/dev/null || true; }
    done
    tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
    _tmux_set SD_INSTALLING ""
    local img_path_save="$IMG_PATH"
    _unmount_img; rm -f "$img_path_save" 2>/dev/null
    IMG_PATH="" BLUEPRINTS_DIR="" CONTAINERS_DIR="" INSTALLATIONS_DIR="" BACKUP_DIR="" STORAGE_DIR=""
    pause "$(printf "✓ Image deleted: %s\n\n  Select or create a new image." "$img_name")"
    _setup_image
}

_show_blueprint_preset() {
    _blueprint_template \
        | _fzf "${FZF_BASE[@]}" \
              --header="$(printf "${BLD}── Blueprint preset  ${DIM}(read only)${NC} ──${NC}")" \
              --no-multi --disabled >/dev/null 2>&1 || true
}

_new_blueprint_menu() {
    finput "Blueprint name:" || return
    local bname="$FINPUT_RESULT"
    local bfile="$BLUEPRINTS_DIR/${bname}.toml"
    [[ -f "$bfile" ]] && { pause "Blueprint '$bname' already exists."; return; }
    _blueprint_template > "$bfile"
    "${EDITOR:-nano}" "$bfile"
}
