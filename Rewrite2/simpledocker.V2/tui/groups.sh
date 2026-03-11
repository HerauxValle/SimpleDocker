#!/usr/bin/env bash

_grp_pick_container() {
    # Returns selected container name via FINPUT_RESULT
    local names=()
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        local cn; cn=$(_cname "$cid")
        [[ -n "$cn" ]] && names+=("$cn")
    done
    [[ ${#names[@]} -eq 0 ]] && { pause "No containers found."; return 1; }
    local sel
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${names[@]}" | fzf "${FZF_BASE[@]}" --header="Select container" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 || -z "$sel" ]] && return
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s' "$sel" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Select container ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local FINPUT_RESULT; FINPUT_RESULT=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 || -z "${FINPUT_RESULT}" ]] && return
    sel=$(printf '%s' "$sel" | _trim_s)
    if [[ "$sel" == "Wait seconds" ]]; then
        finput "Seconds to wait:" || return 1
        local n="${FINPUT_RESULT//[^0-9]/}"
        [[ -z "$n" ]] && { pause "Invalid number."; return 1; }
        FINPUT_RESULT="Wait $n"
    else
        _grp_pick_container || return 1
        FINPUT_RESULT="Wait for ${FINPUT_RESULT}"
    fi
}

_grp_pick_step() {
    # Picks container or wait step, returns via FINPUT_RESULT
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "Container" "Wait" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Add step ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 || -z "${sel}" ]] && return
    sel=$(printf '%s' "$sel" | _trim_s)
    if [[ "$sel" == "Container" ]]; then
        _grp_pick_container || return 1
    else
        _grp_pick_wait || return 1
    fi
}

_grp_edit_step() {
    # Edit an existing step in place, returns new value via FINPUT_RESULT
    local step="$1"
    if [[ "${step,,}" =~ ^wait ]]; then
        _grp_pick_wait || return 1
    else
        _grp_pick_container || return 1
    fi
}

_group_submenu() {
    local gid="$1"
    # Display strings (with ANSI) and match strings (plain, what REPLY contains after strip)
    local D_START; D_START="$(printf " ${GRN}▶  Start group${NC}")"
    local D_STOP;  D_STOP="$(printf " ${RED}■  Stop group${NC}")"
    local D_EDIT;  D_EDIT="$(printf " ${BLU}≡  Edit name/desc${NC}")"
    local D_DEL;   D_DEL="$(printf " ${RED}×  Delete group${NC}")"
    local D_ADD;   D_ADD="$(printf " ${GRN}+  Add step${NC}")"
    local M_START="▶  Start group"
    local M_STOP="■  Stop group"
    local M_EDIT="≡  Edit name/desc"
    local M_DEL="×  Delete group"
    local M_ADD="+  Add step"

    while true; do
        clear
        local gname; gname=$(_grp_read_field "$gid" name)
        local gdesc;  gdesc=$(_grp_read_field "$gid" desc)

        local n_running=0
        while IFS= read -r cname; do
            [[ -z "$cname" ]] && continue
            local cid; cid=$(_ct_id_by_name "$cname")
            [[ -n "$cid" ]] && tmux_up "$(tsess "$cid")" && (( n_running++ )) || true
        done < <(_grp_containers "$gid")
        local is_running=false
        [[ $n_running -gt 0 ]] && is_running=true

        local steps=(); mapfile -t steps < <(_grp_seq_steps "$gid")

        local SEP_GEN SEP_SEQ
        SEP_GEN="$(printf "${BLD}  ── General ──────────────────────────${NC}")"
        SEP_SEQ="$(printf "${BLD}  ── Sequence ─────────────────────────${NC}")"

        local items=("$SEP_GEN")
        if [[ "$is_running" == "true" ]]; then
            items+=("$D_STOP")
        else
            items+=("$D_START" "$D_EDIT" "$D_DEL")
        fi

        items+=("$SEP_SEQ")

        local i
        for (( i=0; i<${#steps[@]}; i++ )); do
            local s="${steps[$i]}"
            if [[ "${s,,}" =~ ^wait ]]; then
                items+=("$(printf " ${YLW}⏱${NC}  ${DIM}%s${NC}" "$s")")
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
                items+=("$(printf " ${dot}  %s%b" "$s" "$status_str")")
            fi
        done

        [[ ${#steps[@]} -eq 0 ]] && items+=("$(printf " ${DIM}(empty — add a step below)${NC}")")
        items+=("$D_ADD")

        local hdr_dot
        [[ "$is_running" == "true" ]] && hdr_dot="${GRN}▶${NC}" || hdr_dot="${DIM}▶${NC}"
        local hdr; hdr="$(printf "%b  ${BLD}%s${NC}" "$hdr_dot" "${gname:-$gid}")"
        [[ -n "$gdesc" ]] && hdr+="$(printf "  ${DIM}— %s${NC}" "$gdesc")"

        _menu "$hdr" "${items[@]}"
        case $? in 2) continue ;; 0) ;; *) return ;; esac

        case "$REPLY" in
            "$M_START") _start_group "$gid" ;;
            "$M_STOP")  _stop_group  "$gid" ;;
            "$M_EDIT")
                finput "Group name (${gname}):" && {
                    local nn="${FINPUT_RESULT:-$gname}"
                    sed -i "s|^name[[:space:]]*=.*|name = $nn|" "$(_grp_path "$gid")"
                }
                finput "Description (${gdesc}):" && {
                    sed -i "s|^desc[[:space:]]*=.*|desc = ${FINPUT_RESULT}|" "$(_grp_path "$gid")"
                }
                ;;
            "$M_DEL")
                confirm "Delete group '${gname:-$gid}'?" || continue
                rm -f "$(_grp_path "$gid")" 2>/dev/null
                pause "Group deleted."; return ;;
            "$M_ADD"|"(empty — add a step below)")
                _grp_pick_step || continue
                steps+=("$FINPUT_RESULT")
                _grp_seq_save "$gid" "${steps[@]}"
                ;;
            *)
                local matched_idx=-1
                for (( i=0; i<${#steps[@]}; i++ )); do
                    [[ "$REPLY" == *"${steps[$i]}"* ]] && { matched_idx=$i; break; }
                done
                [[ $matched_idx -lt 0 ]] && continue

                local _fzf_out _fzf_pid _frc
                _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
                printf '%s\n' "Add before" "Edit" "Add after" "Remove" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Edit step ──${NC}")" >"$_fzf_out" 2>/dev/null &
                _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
                wait "$_fzf_pid" 2>/dev/null; _frc=$?
                local action; action=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
                _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
                [[ $_frc -ne 0 || -z "${action}" ]] && continue
                action=$(printf '%s' "$action" | _trim_s)

                case "$action" in
                    "Add before")
                        _grp_pick_step || continue
                        steps=("${steps[@]:0:$matched_idx}" "$FINPUT_RESULT" "${steps[@]:$matched_idx}")
                        _grp_seq_save "$gid" "${steps[@]}"
                        ;;
                    "Add after")
                        _grp_pick_step || continue
                        local ins=$(( matched_idx + 1 ))
                        steps=("${steps[@]:0:$ins}" "$FINPUT_RESULT" "${steps[@]:$ins}")
                        _grp_seq_save "$gid" "${steps[@]}"
                        ;;
                    "Edit")
                        _grp_edit_step "${steps[$matched_idx]}" || continue
                        steps[$matched_idx]="$FINPUT_RESULT"
                        _grp_seq_save "$gid" "${steps[@]}"
                        ;;
                    "Remove")
                        steps=("${steps[@]:0:$matched_idx}" "${steps[@]:$(( matched_idx + 1 ))}")
                        _grp_seq_save "$gid" "${steps[@]}"
                        ;;
                esac
                ;;
        esac
    done
}

_groups_menu() {
    while true; do
        clear
        while IFS= read -r -t 0 -n 1 _ 2>/dev/null; do :; done
        local groups=(); mapfile -t groups < <(_list_groups)
        local SEP_GRP
        SEP_GRP="$(printf "${BLD}  ── Groups ───────────────────────────${NC}")"

        local lines=("$SEP_GRP")
        for gid in "${groups[@]}"; do
            local gname; gname=$(_grp_read_field "$gid" name)
            local n_running=0
            while IFS= read -r cname; do
                [[ -z "$cname" ]] && continue
                local cid; cid=$(_ct_id_by_name "$cname")
                [[ -n "$cid" ]] && tmux_up "$(tsess "$cid")" && (( n_running++ )) || true
            done < <(_grp_containers "$gid")
            local n_total; n_total=$(_grp_containers "$gid" | wc -l)
            local dot
            [[ $n_running -gt 0 ]] && dot="$(printf "${GRN}▶${NC}")" || dot="$(printf "${DIM}▶${NC}")"
            lines+=("$(printf " %b  %-24s ${DIM}%d/%d running${NC}" "$dot" "${gname:-$gid}" "$n_running" "$n_total")")
        done

        [[ ${#groups[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no groups yet)${NC}")")
        lines+=("$(printf "${GRN} +  ${L[grp_new]}${NC}")")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        local _n_grp_active=0
        for gid in "${groups[@]}"; do
            while IFS= read -r cname; do
                [[ -z "$cname" ]] && continue
                local _gcc; _gcc=$(_ct_id_by_name "$cname")
                [[ -n "$_gcc" ]] && tmux_up "$(tsess "$_gcc")" && { (( _n_grp_active++ )); break; } || true
            done < <(_grp_containers "$gid")
        done
        local _grp_hdr_extra
        _grp_hdr_extra=$(printf "  \033[2m[%d · \033[0;32m%d active\033[0m\033[2m]\033[0m" "${#groups[@]}" "$_n_grp_active")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Groups ──${NC}%s" "$_grp_hdr_extra")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel}" ]] && return
        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" ]] && return
        [[ "$clean" == *"${L[grp_new]}"* ]] && { _create_group; continue; }

        for gid in "${groups[@]}"; do
            local gname; gname=$(_grp_read_field "$gid" name)
            if [[ "$clean" == *"${gname:-$gid}"* ]]; then
                _group_submenu "$gid"; break
            fi
        done
    done
}
