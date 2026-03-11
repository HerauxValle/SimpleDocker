#!/usr/bin/env bash
# tui/hooks.sh — dynamic entry builders for core/menu.sh
#
# Each hook prints tab-separated lines to stdout:
#   DISPLAY\tACTION
# where ACTION is "menu:X", "fn:FNAME\tARG", or "back"
# The renderer extracts field 2 with cut -d$'\t' -f2 and dispatches it.

# ── Container list ────────────────────────────────────────────────
_hook_container_list() {
    _load_containers false
    for i in "${!CT_IDS[@]}"; do
        local cid="${CT_IDS[$i]}" n="${CT_NAMES[$i]}"
        local dot disp_name

        if _is_installing "$cid" || [[ -f "$CONTAINERS_DIR/$cid/.install_ok" || -f "$CONTAINERS_DIR/$cid/.install_fail" ]]; then
            dot="${YLW}◈${NC}"; disp_name="$(printf "${YLW}%s${NC}" "$n")"
        elif tmux_up "$(tsess "$cid")"; then
            if _health_check "$cid"; then dot="${GRN}◈${NC}"; else dot="${YLW}◈${NC}"; fi
            disp_name="$(printf "${GRN}%s${NC}" "$n")"
        elif [[ "$(_st "$cid" installed)" == "true" ]]; then
            dot="${RED}◈${NC}"; disp_name="$(printf "${DIM}%s${NC}" "$n")"
        else
            dot="${DIM}◈${NC}"; disp_name="$(printf "${DIM}%s${NC}" "$n")"
        fi

        local dialogue; dialogue=$(jq -r '.meta.dialogue // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        [[ -n "$dialogue" ]] && disp_name+="$(printf "  ${DIM}— %s${NC}" "$dialogue")"

        local sz_lbl=""
        local sz_cache="$CACHE_DIR/sd_size/$cid"
        if [[ -f "$sz_cache" ]]; then
            sz_lbl="$(printf "${DIM}[%sgb]${NC} " "$(cat "$sz_cache")")"
        else
            local ipath; ipath=$(_cpath "$cid")
            if [[ -d "$ipath" ]]; then
                { mkdir -p "${sz_cache%/*}" 2>/dev/null
                  du -sb "$ipath" 2>/dev/null | awk '{printf "%.2f",$1/1073741824}' \
                      > "$sz_cache.tmp" && mv "$sz_cache.tmp" "$sz_cache"
                } 2>/dev/null &
                disown 2>/dev/null || true
            fi
        fi

        local svc_port; svc_port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local env_port; env_port=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        [[ -n "$env_port" ]] && svc_port="$env_port"
        local ip_lbl=""
        if [[ -n "$svc_port" && "$svc_port" != "0" && "$(_st "$cid" installed)" == "true" ]]; then
            local ip; ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
            ip_lbl="$(printf "${DIM}[%s:%s]${NC} " "$ip" "$svc_port")"
        fi

        local disp; disp=$(printf " %b  %b  %s%s${DIM}[%s]${NC}" \
            "$dot" "$disp_name" "$sz_lbl" "$ip_lbl" "$cid")
        printf '%s\t%s\n' "$disp" "fn:_container_submenu	$cid"
    done
}

# ── Container dynamic actions (from service.json .actions[]) ─────
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
        printf '%s' "$lbl" | grep -qi "open browser" && continue
        printf '%s' "$lbl" | grep -qP '^[A-Za-z]' && lbl="⊙  $lbl"
        local disp; disp=$(printf "${DIM} %s${NC}" "$lbl")
        printf '%s\t%s\n' "$disp" "fn:_run_container_action	${cid}:${ai}"
    done
}

# ── Container cron entries ────────────────────────────────────────
_hook_container_crons() {
    local cid="$1"
    [[ -z "$cid" ]] && return
    [[ "$(_st "$cid" installed)" != "true" ]] && return
    _is_installing "$cid" && return
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local cron_count; cron_count=$(jq -r '.crons | length' "$sj" 2>/dev/null)
    [[ -z "$cron_count" || "$cron_count" -eq 0 ]] && return
    for (( ci=0; ci<cron_count; ci++ )); do
        local cn; cn=$(jq -r --argjson i "$ci" '.crons[$i].name // empty' "$sj" 2>/dev/null)
        local civ; civ=$(jq -r --argjson i "$ci" '.crons[$i].interval // empty' "$sj" 2>/dev/null)
        [[ -z "$cn" ]] && continue
        local csess; csess=$(_cron_sess "$cid" "$ci")
        local disp
        if tmux_up "$csess"; then
            disp=$(printf " ${CYN}⏱${NC}  ${DIM}%s  ${CYN}[%s]${NC}" "$cn" "$civ")
        else
            disp=$(printf " ${DIM}⏱  %s  [stopped]${NC}" "$cn")
        fi
        printf '%s\t%s\n' "$disp" "fn:_attach_cron	${cid}:${ci}"
    done
}

# ── Container update items ────────────────────────────────────────
_hook_container_updates() {
    local cid="$1"
    [[ -z "$cid" ]] && return
    [[ "$(_st "$cid" installed)" != "true" ]] && return
    _is_installing "$cid" && return
    tmux_up "$(tsess "$cid")" && return  # don't show updates while running

    _build_update_items "$cid"
    _build_ubuntu_update_item "$cid"
    _build_pkg_update_item "$cid"

    local has_updates=false
    for ui in "${!_UPD_ITEMS[@]}"; do
        printf '%s' "${_UPD_ITEMS[$ui]}" | _strip_ansi | grep -qE 'Changes detected|→' && has_updates=true
    done

    [[ ${#_UPD_ITEMS[@]} -eq 0 ]] && return

    local upd_lbl
    if [[ "$has_updates" == true ]]; then
        upd_lbl="$(printf " ${YLW}⬆  Updates available${NC}")"
    else
        upd_lbl="$(printf " ${DIM}⬆  Updates${NC}")"
    fi
    printf '%s\t%s\n' "$upd_lbl" "fn:_updates_submenu	$cid"
}

# ── Group list ────────────────────────────────────────────────────
_hook_group_list() {
    local grp_ids=(); mapfile -t grp_ids < <(_list_groups)
    for gid in "${grp_ids[@]}"; do
        local gname; gname=$(_grp_read_field "$gid" name)
        [[ -z "$gname" ]] && gname="$gid"
        local gdesc; gdesc=$(_grp_read_field "$gid" desc)
        local grunning=0
        while IFS= read -r cname; do
            local gcid; gcid=$(_ct_id_by_name "$cname")
            [[ -n "$gcid" ]] && tmux_up "$(tsess "$gcid")" && (( grunning++ )) || true
        done < <(_grp_containers "$gid")
        local n_total; n_total=$(_grp_containers "$gid" | wc -l)
        local dot; [[ $grunning -gt 0 ]] && dot="${GRN}▶${NC}" || dot="${DIM}▶${NC}"
        local disp; disp=$(printf " %b  ${BLD}%s${NC}  ${DIM}%d/%d running%s${NC}" \
            "$dot" "$gname" "$grunning" "$n_total" "${gdesc:+  — $gdesc}")
        printf '%s\t%s\n' "$disp" "fn:_group_submenu	$gid"
    done
}

# ── Group sequence steps ──────────────────────────────────────────
_hook_group_steps() {
    local gid="$1"
    [[ -z "$gid" ]] && return
    local steps=(); mapfile -t steps < <(_grp_seq_steps "$gid")
    if [[ ${#steps[@]} -eq 0 ]]; then
        printf '%s\t%s\n' "$(printf "${DIM}  (empty — add a step below)${NC}")" '__sep__'
        return
    fi
    for i in "${!steps[@]}"; do
        local s="${steps[$i]}"
        local disp
        if [[ "${s,,}" =~ ^wait ]]; then
            disp=$(printf " ${YLW}⏱${NC}  ${DIM}%s${NC}" "$s")
        else
            local cid; cid=$(_ct_id_by_name "$s")
            local dot status_str
            if [[ -z "$cid" ]]; then
                dot="${RED}◈${NC}"; status_str="$(printf "${DIM} — not found${NC}")"
            elif tmux_up "$(tsess "$cid")"; then
                dot="${GRN}◈${NC}"; status_str="$(printf "  ${GRN}running${NC}")"
            else
                dot="${RED}◈${NC}"; status_str="$(printf "  ${DIM}stopped${NC}")"
            fi
            disp=$(printf " %b  %s%b" "$dot" "$s" "$status_str")
        fi
        printf '%s\t%s\n' "$disp" "fn:_edit_step_menu	${gid}:${i}"
    done
}

# ── Blueprint list ────────────────────────────────────────────────
_hook_blueprint_list() {
    local bps=();  mapfile -t bps  < <(_list_blueprint_names)
    local pbps=(); mapfile -t pbps < <(_list_persistent_names)
    local ibps=(); mapfile -t ibps < <(_list_imported_names)
    [[ ${#bps[@]} -eq 0 && ${#pbps[@]} -eq 0 && ${#ibps[@]} -eq 0 ]] && return
    for n in "${bps[@]}"; do
        local d; d=$(printf " ${DIM}◈  %s${NC}" "$n")
        printf '%s\t%s\n' "$d" "fn:_blueprint_submenu	$n"
    done
    for n in "${pbps[@]}"; do
        local d; d=$(printf " ${BLU}◈${NC}${DIM}  %s  [Persistent]${NC}" "$n")
        printf '%s\t%s\n' "$d" "fn:_blueprint_submenu	$n"
    done
    for n in "${ibps[@]}"; do
        local d; d=$(printf " ${CYN}◈${NC}${DIM}  %s  [Imported]${NC}" "$n")
        printf '%s\t%s\n' "$d" "fn:_blueprint_submenu	$n"
    done
}

# ── Status helpers (for status_fn in menu.json) ───────────────────
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
_caddy_status()   { _proxy_running && printf "${GRN}running${NC}" || printf "${DIM}stopped${NC}"; }
_qrencode_status() {
    [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && \
        _chroot_bash "$UBUNTU_DIR" -c 'command -v qrencode' >/dev/null 2>&1 \
        && printf "${GRN}installed${NC}" || printf "${DIM}not installed${NC}"
}

# ── Header functions (called from menu.json header_fn) ────────────
_container_header() {
    local cid="$1"; [[ -z "$cid" ]] && { printf "Container"; return; }
    local name; name=$(_cname "$cid"); [[ -z "$name" ]] && name="(unnamed-$cid)"
    local dot
    if   _is_installing "$cid" || [[ -f "$CONTAINERS_DIR/$cid/.install_ok" || -f "$CONTAINERS_DIR/$cid/.install_fail" ]]; then
        dot="${YLW}◈${NC}"
    elif tmux_up "$(tsess "$cid")"; then
        _health_check "$cid" && dot="${GRN}◈${NC}" || dot="${YLW}◈${NC}"
    elif [[ "$(_st "$cid" installed)" == "true" ]]; then
        dot="${RED}◈${NC}"
    else
        dot="${DIM}◈${NC}"
    fi
    local dlg; dlg=$(jq -r '.meta.dialogue // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
    local port; port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
    local ep; ep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
    [[ -n "$ep" ]] && port="$ep"
    local hdr; hdr=$(printf "%b  %s" "$dot" "$name")
    [[ -n "$dlg" ]] && hdr+=$(printf "  ${DIM}— %s${NC}" "$dlg")
    if [[ -n "$port" && "$port" != "0" ]]; then
        local ip; ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
        hdr+=$(printf "  ${DIM}%s:%s${NC}" "$ip" "$port")
    fi
    printf '%s' "$hdr"
}

_group_header() {
    local gid="$1"; [[ -z "$gid" ]] && { printf "Group"; return; }
    local gname; gname=$(_grp_read_field "$gid" name)
    local gdesc; gdesc=$(_grp_read_field "$gid" desc)
    local n_running=0
    while IFS= read -r cname; do
        local cid; cid=$(_ct_id_by_name "$cname")
        [[ -n "$cid" ]] && tmux_up "$(tsess "$cid")" && (( n_running++ )) || true
    done < <(_grp_containers "$gid")
    local dot; [[ $n_running -gt 0 ]] && dot="${GRN}▶${NC}" || dot="${DIM}▶${NC}"
    local hdr; hdr=$(printf "%b  ${BLD}%s${NC}" "$dot" "${gname:-$gid}")
    [[ -n "$gdesc" ]] && hdr+=$(printf "  ${DIM}— %s${NC}" "$gdesc")
    printf '%s' "$hdr"
}

_blueprint_header() {
    local name="$1"; [[ -z "$name" ]] && { printf "Blueprint"; return; }
    printf "${BLD}◈  %s${NC}" "$name"
}

# ── Action dispatch wrappers ──────────────────────────────────────
# Called with "cid:idx" arg from hooks

_run_container_action() {
    local spec="$1"; local cid="${spec%%:*}" idx="${spec##*:}"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local dsl; dsl=$(jq -r --argjson i "$idx" '.actions[$i].dsl // .actions[$i].script // empty' "$sj" 2>/dev/null)
    local lbl; lbl=$(jq -r --argjson i "$idx" '.actions[$i].label // empty' "$sj" 2>/dev/null)
    [[ -z "$dsl" ]] && return
    local sess="sdAction_${cid}_${idx}"
    local script; script=$(mktemp "$TMP_DIR/.sd_act_XXXXXX.sh")
    local ip; ip=$(_cpath "$cid")
    {   printf '#!/usr/bin/env bash\n'
        _env_exports "$cid" "$ip"
        printf 'cd "$CONTAINER_ROOT"\n'
        if printf '%s' "$dsl" | grep -q '|'; then
            # DSL with pipe segments
            local IFS_BAK="$IFS"; IFS='|'
            local segs=()
            while IFS= read -r seg; do
                seg=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -n "$seg" ]] && segs+=("$seg")
            done <<< "$(printf '%s' "$dsl" | tr '|' '\n')"
            IFS="$IFS_BAK"
            for seg in "${segs[@]}"; do
                if [[ "$seg" == prompt:* ]]; then
                    local ptxt; ptxt=$(printf '%s' "$seg" | sed 's/^prompt:[[:space:]]*//' | tr -d '"'"'")
                    printf 'printf "%s\\n> "; read -r _sd_input\n' "$ptxt"
                    printf '[[ -z "$_sd_input" ]] && exit 0\n'
                elif [[ "$seg" == select:* ]]; then
                    local scmd; scmd=$(printf '%s' "$seg" | sed 's/^select:[[:space:]]*//')
                    local skip_hdr=0 col_n=1
                    [[ "$scmd" == *"--skip-header"* ]] && skip_hdr=1
                    [[ "$scmd" =~ --col[[:space:]]+([0-9]+) ]] && col_n="${BASH_REMATCH[1]}"
                    scmd=$(printf '%s' "$scmd" | sed 's/--skip-header//g;s/--col[[:space:]]*[0-9]*//g;s/^[[:space:]]*//;s/[[:space:]]*$//')
                    local sbin="${scmd%% *}" srest="${scmd#* }"; [[ "$srest" == "$sbin" ]] && srest=""
                    local sbinp; sbinp=$(_cr_prefix "$sbin")
                    printf '_sd_list=$(%s 2>/dev/null)\n' "${sbinp}${srest:+ $srest}"
                    printf '[[ -z "$_sd_list" ]] && { printf "Nothing found.\\n"; exit 0; }\n'
                    [[ $skip_hdr -eq 1 ]] && printf '_sd_list=$(printf "%%s" "$_sd_list" | tail -n +2)\n'
                    printf '_sd_selection=$(printf "%%s\\n" "$_sd_list" | awk '"'"'{print $%d}'"'"' | fzf --ansi --no-sort --prompt="  ❯ " --pointer="▶" --height=40%% --reverse --border=rounded --margin=1,2 --no-info 2>/dev/null) || exit 0\n' "$col_n"
                    printf '[[ -z "$_sd_selection" ]] && exit 0\n'
                else
                    local cbin="${seg%% *}" crest="${seg#* }"; [[ "$crest" == "$cbin" ]] && crest=""
                    local cbinp; cbinp=$(_cr_prefix "$cbin")
                    local cmd_out="${cbinp}${crest:+ $crest}"
                    cmd_out=$(printf '%s' "$cmd_out" | sed 's/{input}/$_sd_input/g;s/{selection}/$_sd_selection/g')
                    printf '%s\n' "$cmd_out"
                fi
            done
        else
            printf '%s\n' "$dsl"
        fi
    } > "$script"; chmod +x "$script"
    if tmux has-session -t "$sess" 2>/dev/null; then
        sd_msg "$(printf "Action '%s' is still running.\n\n  Attach: tmux attach -t %s" "$lbl" "$sess")"
        tmux switch-client -t "$sess" 2>/dev/null || true
    else
        tmux new-session -d -s "$sess" \
            "bash $(printf '%q' "$script"); rm -f $(printf '%q' "$script"); printf '\n\033[0;32m══ Done ══\033[0m\n'; printf 'Press Enter...\n'; read -rs _; tmux switch-client -t simpleDocker 2>/dev/null || true; tmux kill-session -t \"$sess\" 2>/dev/null || true" 2>/dev/null
        tmux set-option -t "$sess" detach-on-destroy off 2>/dev/null || true
        sd_msg "$(printf "Starting '%s'...\n\n  Press %s to detach." "$lbl" "${KB[tmux_detach]}")"
        tmux switch-client -t "$sess" 2>/dev/null || true
    fi
}

_attach_cron() {
    local spec="$1"; local cid="${spec%%:*}" idx="${spec##*:}"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local cn; cn=$(jq -r --argjson i "$idx" '.crons[$i].name // empty' "$sj" 2>/dev/null)
    local csess; csess=$(_cron_sess "$cid" "$idx")
    if tmux_up "$csess"; then
        sd_attach "$csess" "cron: $cn"
    else
        sd_msg "Cron '$cn' is not running."
    fi
}

_updates_submenu() {
    local cid="$1"
    _build_update_items "$cid"
    _build_ubuntu_update_item "$cid"
    _build_pkg_update_item "$cid"
    [[ ${#_UPD_ITEMS[@]} -eq 0 ]] && { sd_msg "Nothing to update."; return; }
    local entries=()
    for ui in "${!_UPD_ITEMS[@]}"; do
        entries+=("${_UPD_ITEMS[$ui]}"$'\t'"fn:_do_update_by_idx	${cid}:${ui}")
    done
    local _out; _out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${entries[@]}" \
        | fzf "${FZF_BASE[@]}" --with-nth=1 --delimiter=$'\t' \
              --header="$(printf "${BLD}── Updates: %s ──${NC}" "$(_cname "$cid")")" \
        >"$_out" 2>/dev/null &
    local _pid=$!; printf '%s' "$_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_pid" 2>/dev/null; local _rc=$?
    local sel; sel=$(cat "$_out" 2>/dev/null); rm -f "$_out"
    _sig_rc $_rc && { stty sane 2>/dev/null; return; }
    [[ $_rc -ne 0 || -z "$sel" ]] && return
    local action; action=$(printf '%s' "$sel" | cut -d$'\t' -f2)
    [[ -n "$action" ]] && _menu_dispatch "$action"
}

_do_update_by_idx() {
    local spec="$1"; local cid="${spec%%:*}" ui="${spec##*:}"
    _build_update_items "$cid"; _build_ubuntu_update_item "$cid"; _build_pkg_update_item "$cid"
    [[ -z "${_UPD_IDX[$ui]:-}" ]] && return
    case "${_UPD_IDX[$ui]}" in
        __ubuntu__) _do_ubuntu_update "$cid";;
        __pkgs__)   _do_pkg_update "$cid";;
        *)          _do_blueprint_update "$cid" "${_UPD_IDX[$ui]}";;
    esac
}

_edit_step_menu() {
    local spec="$1"; local gid="${spec%%:*}" idx="${spec##*:}"
    local steps=(); mapfile -t steps < <(_grp_seq_steps "$gid")
    local opts=("Add before" "Edit" "Add after" "Remove")
    local _out; _out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${opts[@]}" | fzf "${FZF_BASE[@]}" \
        --header="$(printf "${BLD}── Edit step: %s ──${NC}" "${steps[$idx]:-?}")" \
        >"$_out" 2>/dev/null &
    local _pid=$!; printf '%s' "$_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_pid" 2>/dev/null; local _rc=$?
    local action; action=$(cat "$_out" 2>/dev/null | _trim_s); rm -f "$_out"
    _sig_rc $_rc && { stty sane 2>/dev/null; return; }
    [[ $_rc -ne 0 || -z "$action" ]] && return
    case "$action" in
        "Add before")
            _grp_pick_step || return
            steps=("${steps[@]:0:$idx}" "$SD_MSG" "${steps[@]:$idx}")
            _grp_seq_save "$gid" "${steps[@]}";;
        "Add after")
            _grp_pick_step || return
            local ins=$(( idx + 1 ))
            steps=("${steps[@]:0:$ins}" "$SD_MSG" "${steps[@]:$ins}")
            _grp_seq_save "$gid" "${steps[@]}";;
        "Edit")
            _grp_edit_step "${steps[$idx]}" || return
            steps[$idx]="$SD_MSG"
            _grp_seq_save "$gid" "${steps[@]}";;
        "Remove")
            steps=("${steps[@]:0:$idx}" "${steps[@]:$(( idx + 1 ))}")
            _grp_seq_save "$gid" "${steps[@]}";;
    esac
}

_container_submenu() { sd_menu "container_item" "$1"; }
_group_submenu()     { sd_menu "group_item"      "$1"; }
_blueprint_submenu() { sd_menu "blueprint_item"  "$1"; }

# Wrappers called from menu.json fn: entries
_create_group_menu() {
    sd_input "Group name:" || return
    _create_group "$SD_MSG"
}

_edit_group() {
    local gid="$1"
    local gname; gname=$(_grp_read_field "$gid" name)
    local gdesc; gdesc=$(_grp_read_field "$gid" desc)
    sd_input "Group name (${gname}):" && {
        local nn="${SD_MSG:-$gname}"
        sed -i "s|^name[[:space:]]*=.*|name = $nn|" "$(_grp_path "$gid")"
    }
    sd_input "Description (${gdesc}):" && {
        sed -i "s|^desc[[:space:]]*=.*|desc = ${SD_MSG}|" "$(_grp_path "$gid")"
    }
}

_delete_group() {
    local gid="$1"
    local gname; gname=$(_grp_read_field "$gid" name)
    sd_confirm "Delete group '${gname:-$gid}'?" || return
    rm -f "$(_grp_path "$gid")" 2>/dev/null
    sd_msg "Group deleted."
}

_add_group_step() {
    local gid="$1"
    _grp_pick_step || return
    local steps=(); mapfile -t steps < <(_grp_seq_steps "$gid")
    steps+=("$SD_MSG")
    _grp_seq_save "$gid" "${steps[@]}"
}

_new_blueprint_menu() {
    sd_input "Blueprint name:" || return
    local bname="$SD_MSG"
    local bfile="$BLUEPRINTS_DIR/${bname}.toml"
    [[ -f "$bfile" ]] && { sd_msg "Blueprint '$bname' already exists."; return; }
    _blueprint_template > "$bfile"
    "${EDITOR:-nano}" "$bfile"
}

_show_blueprint_preset() {
    _blueprint_template \
        | _fzf "${FZF_BASE[@]}" \
              --header="$(printf "${BLD}── Blueprint preset  ${DIM}(read only)${NC} ──${NC}")" \
              --no-multi --disabled >/dev/null 2>&1 || true
}

_clear_cache() {
    sd_confirm "Clear all cached data?" || return
    rm -rf "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null || true
    mkdir -p "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null
    sd_msg "Cache cleared."
}

_delete_image_file() {
    [[ -z "$IMG_PATH" ]] && { sd_msg "No image currently loaded."; return; }
    local img_name; img_name=$(basename "$IMG_PATH")
    local img_path_save="$IMG_PATH"
    sd_confirm "$(printf "PERMANENTLY DELETE IMAGE?\n\n  File: %s\n  Path: %s\n\n  THIS CANNOT BE UNDONE!" "$img_name" "$img_path_save")" || return
    _load_containers true
    for dcid in "${CT_IDS[@]}"; do
        local dsess; dsess="$(tsess "$dcid")"
        tmux_up "$dsess" && { tmux send-keys -t "$dsess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$dsess" 2>/dev/null || true; }
    done
    tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
    _tmux_set SD_INSTALLING ""
    _unmount_img; rm -f "$img_path_save" 2>/dev/null
    IMG_PATH="" BLUEPRINTS_DIR="" CONTAINERS_DIR="" INSTALLATIONS_DIR="" BACKUP_DIR="" STORAGE_DIR=""
    sd_msg "$(printf "✓ Image deleted: %s\n\n  Select or create a new image." "$img_name")"
    _setup_image
}

_install_container() {
    local cid="${1:-$SD_MENU_CTX}"
    _guard_install || return
    _run_job install "$cid"
    _cleanup_upd_tmps
}

_uninstall_container() {
    local cid="${1:-$SD_MENU_CTX}"
    local name; name=$(_cname "$cid")
    local ip; ip=$(_cpath "$cid")
    sd_confirm "$(printf "Uninstall '%s'?\n\n  ✕  Installation: %s\n  ✕  Snapshots\n\n  Persistent storage kept.\n  Container entry kept — reinstall any time." "$name" "$ip")" || return
    [[ -d "$ip" ]] && { sudo -n btrfs subvolume delete "$ip" &>/dev/null || rm -rf "$ip" 2>/dev/null || true; }
    local sdir; sdir=$(_snap_dir "$cid")
    if [[ -d "$sdir" ]]; then
        for sf in "$sdir"/*/; do [[ -d "$sf" ]] && _delete_snap "$sf" || true; done
        rm -rf "$sdir" 2>/dev/null || true
    fi
    _set_st "$cid" installed false
    sd_msg "'$name' uninstalled. Persistent storage kept."
}

_remove_container() {
    local cid="${1:-$SD_MENU_CTX}"
    local name; name=$(_cname "$cid")
    sd_confirm "$(printf "Remove container entry '%s'?\n\n  No installation or storage files deleted." "$name")" || return
    rm -f "$CACHE_DIR/sd_size/$cid" "$CACHE_DIR/gh_tag/$cid" "$CACHE_DIR/gh_tag/$cid.inst" 2>/dev/null || true
    rm -rf "$CONTAINERS_DIR/$cid" 2>/dev/null
    _cleanup_upd_tmps
    sd_msg "'$name' removed."
}

_restart_container() {
    local cid="${1:-$SD_MENU_CTX}"
    _stop_container "$cid"; sleep 0.3; _start_container "$cid"
}

_attach_container() {
    local cid="${1:-$SD_MENU_CTX}"
    _tmux_attach_hint "$(_cname "$cid")" "$(tsess "$cid")"
}

_terminal_container() {
    local cid="${1:-$SD_MENU_CTX}"
    local sess="sdTerm_${cid}"
    local ip; ip=$(_cpath "$cid")
    if ! tmux has-session -t "$sess" 2>/dev/null; then
        tmux new-session -d -s "$sess" \
            "cd $(printf '%q' "$ip") && bash" 2>/dev/null || return
    fi
    tmux switch-client -t "$sess" 2>/dev/null || true
}

_finish_install() {
    local cid="${1:-$SD_MENU_CTX}"
    _process_install_finish "$cid"
}

_attach_install() {
    local cid="${1:-$SD_MENU_CTX}"
    _cleanup_stale_lock
    _tmux_attach_hint "installation" "$(_inst_sess "$cid")"
}

_toggle_exposure() {
    local cid="${1:-$SD_MENU_CTX}"
    local new_mode; new_mode=$(_exposure_next "$cid")
    _exposure_set "$cid" "$new_mode"
    tmux_up "$(tsess "$cid")" && _exposure_apply "$cid"
    sd_msg "$(printf "Port exposure: %b\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network" "$(_exposure_label "$new_mode")")"
}

_rename_container_menu() {
    local cid="${1:-$SD_MENU_CTX}"
    local name; name=$(_cname "$cid")
    [[ "$(_st "$cid" installed)" == "true" ]] && { sd_msg "Rename only available for uninstalled containers."; return; }
    while true; do
        sd_input "New name for '$name':" || return
        local new_name="${SD_MSG//[^a-zA-Z0-9_\-]/}"
        [[ -z "$new_name" ]] && { sd_msg "Name cannot be empty."; continue; }
        local dup=false
        for dd in "$CONTAINERS_DIR"/*/; do
            [[ -f "$dd/state.json" ]] || continue
            local en; en=$(jq -r '.name // empty' "$dd/state.json" 2>/dev/null)
            [[ "$en" == "$new_name" && "$(basename "$dd")" != "$cid" ]] && dup=true && break
        done
        [[ "$dup" == true ]] && { sd_msg "A container named '$new_name' already exists."; continue; }
        jq --arg n "$new_name" '.name=$n' "$CONTAINERS_DIR/$cid/state.json" \
            > "$CONTAINERS_DIR/$cid/state.json.tmp" \
            && mv "$CONTAINERS_DIR/$cid/state.json.tmp" "$CONTAINERS_DIR/$cid/state.json"
        sd_msg "Renamed to '$new_name'."; return
    done
}
