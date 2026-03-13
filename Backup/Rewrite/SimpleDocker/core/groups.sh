#!/usr/bin/env bash
# core/groups.sh — group definitions, start/stop group, sequence builder helpers

_grp_path()        { printf '%s/%s.toml' "$GROUPS_DIR" "$1"; }
_grp_read_field()  { grep -m1 "^$2[[:space:]]*=" "$(_grp_path "$1")" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//' ; }
_list_groups()     { for f in "$GROUPS_DIR"/*.toml; do [[ -f "$f" ]] && basename "${f%.toml}"; done; }

_grp_containers() {
    # Returns unique container names from sequence (for status display etc.)
    local gid="$1"
    local raw; raw=$(grep -m1 '^start[[:space:]]*=' "$(_grp_path "$gid")" 2>/dev/null \
        | sed 's/^start[[:space:]]*=[[:space:]]*//' | tr -d '{}')
    printf '%s' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' \
        | grep -iv '^wait' | sort -u
}

_grp_seq_steps() {
    # Returns each step on its own line, in order
    local gid="$1"
    local raw; raw=$(grep -m1 '^start[[:space:]]*=' "$(_grp_path "$gid")" 2>/dev/null \
        | sed 's/^start[[:space:]]*=[[:space:]]*//' | tr -d '{}')
    printf '%s' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
}

_grp_seq_save() {
    # Write steps array back to toml start field
    local gid="$1"; shift
    local steps=("$@")
    local joined; joined=$(printf '%s, ' "${steps[@]}")
    joined="${joined%, }"
    local toml; toml="$(_grp_path "$gid")"
    if grep -q '^start[[:space:]]*=' "$toml" 2>/dev/null; then
        sed -i "s|^start[[:space:]]*=.*|start = { ${joined} }|" "$toml"
    else
        printf 'start = { %s }\n' "$joined" >> "$toml"
    fi
    # Also update containers field to match unique container names
    local cts; cts=$(printf '%s\n' "${steps[@]}" | grep -iv '^wait' | sort -u | tr '\n' ', ' | sed 's/, $//')
    if grep -q '^containers[[:space:]]*=' "$toml" 2>/dev/null; then
        sed -i "s|^containers[[:space:]]*=.*|containers = ${cts}|" "$toml"
    else
        printf 'containers = %s\n' "$cts" >> "$toml"
    fi
}

_ct_id_by_name() {
    local cname="$1"
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        [[ "$(_cname "$cid")" == "$cname" ]] && printf '%s' "$cid" && return
    done
}

_start_group() {
    local gid="$1"
    local gname; gname=$(_grp_read_field "$gid" name)
    local batch=()
    _flush_batch() {
        [[ ${#batch[@]} -eq 0 ]] && return
        for bname in "${batch[@]}"; do
            local bcid; bcid=$(_ct_id_by_name "$bname")
            if [[ -n "$bcid" ]]; then
                tmux_up "$(tsess "$bcid")" \
                    && printf '[%s] already running\n' "$bname" \
                    || { _start_container "$bcid" --auto || true; }
            else
                printf '[!] Container not found: %s\n' "$bname" >&2
            fi
        done
        batch=()
    }
    while IFS= read -r step; do
        step=$(printf '%s' "$step" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$step" ]] && continue
        if [[ "${step,,}" =~ ^wait[[:space:]]+([0-9]+)$ ]]; then
            _flush_batch
            sleep "${BASH_REMATCH[1]}"
        elif [[ "${step,,}" =~ ^wait[[:space:]]+for[[:space:]]+(.+)$ ]]; then
            _flush_batch
            local wait_name="${BASH_REMATCH[1]}"
            local wait_cid; wait_cid=$(_ct_id_by_name "$wait_name")
            if [[ -n "$wait_cid" ]]; then
                local waited=0
                while ! tmux_up "$(tsess "$wait_cid")" && [[ $waited -lt 60 ]]; do
                    sleep 1; (( waited++ )) || true
                done
                sleep 2
            fi
        else
            batch+=("$step")
        fi
    done < <(_grp_seq_steps "$gid")
    _flush_batch
}

_stop_group() {
    local gid="$1"
    # Stop in reverse sequence order, skip Wait steps, skip containers shared with other active groups
    local steps=(); mapfile -t steps < <(_grp_seq_steps "$gid")
    local i
    for (( i=${#steps[@]}-1; i>=0; i-- )); do
        local step="${steps[$i]}"
        [[ "${step,,}" =~ ^wait ]] && continue
        local cid; cid=$(_ct_id_by_name "$step")
        [[ -z "$cid" ]] && continue
        tmux_up "$(tsess "$cid")" || continue
        # Check if shared with another active group
        local in_other=false
        for gf in "$GROUPS_DIR"/*.toml; do
            [[ -f "$gf" ]] || continue
            local ogid; ogid=$(basename "${gf%.toml}")
            [[ "$ogid" == "$gid" ]] && continue
            _grp_containers "$ogid" | grep -q "^${step}$" || continue
            while IFS= read -r oc; do
                [[ "$oc" == "$step" ]] && continue
                local ocid; ocid=$(_ct_id_by_name "$oc")
                [[ -n "$ocid" ]] && tmux_up "$(tsess "$ocid")" && in_other=true && break
            done < <(_grp_containers "$ogid")
            [[ "$in_other" == true ]] && break
        done
        if [[ "$in_other" == false ]]; then
            _stop_container "$cid" || true
        else
            printf '[%s] shared with active group — leaving running\n' "$step"
        fi
    done
}

# ── Sequence step picker helpers ──────────────────────────────────────────────

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

# ── Group submenu with sequence builder ──────────────────────────────────────

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

_create_group() {
    finput "Group name:" || return 1
    local gname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"
    [[ -z "$gname" ]] && { pause "Name cannot be empty."; return 1; }
    local gid; gid=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
    printf 'name = %s\ndesc =\ncontainers =\nstart = {  }\n' "$gname" > "$(_grp_path "$gid")"
    pause "Group '$gname' created."
}

#  BACKUP SYSTEM
