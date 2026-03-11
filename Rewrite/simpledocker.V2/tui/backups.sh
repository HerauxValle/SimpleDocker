#!/usr/bin/env bash

_container_backups_menu() {
    local cid="$1" name; name=$(_cname "$cid")
    local sdir; sdir=$(_snap_dir "$cid")
    local SEP_AUTO SEP_MAN
    SEP_AUTO="$(printf "${BLD}  ── Automatic backups ────────────────${NC}")"
    SEP_MAN="$(printf  "${BLD}  ── Manual backups ───────────────────${NC}")"

    while true; do
        mkdir -p "$sdir" 2>/dev/null
        local auto_ids=() auto_ts=() man_ids=() man_ts=()
        for f in "$sdir"/*.meta; do
            [[ -f "$f" ]] || continue
            local fid; fid=$(basename "$f" .meta); [[ ! -d "$sdir/$fid" ]] && continue
            local ftype fts
            ftype=$(_snap_meta_get "$sdir" "$fid" type); fts=$(_snap_meta_get "$sdir" "$fid" ts)
            if [[ "$ftype" == "auto" ]]; then auto_ids+=("$fid"); auto_ts+=("$fts")
            else man_ids+=("$fid"); man_ts+=("$fts"); fi
        done

        local lines=() line_ids=()
        lines+=("$SEP_AUTO"); line_ids+=("")
        if [[ ${#auto_ids[@]} -gt 0 ]]; then
            for i in "${!auto_ids[@]}"; do
                local aid="${auto_ids[$i]}" ats="${auto_ts[$i]}"
                local disp; disp="$(printf "${DIM} ◈  %s${NC}" "$aid")"
                [[ -n "$ats" ]] && disp+="$(printf "${DIM}  (%s)${NC}" "$ats")"
                lines+=("$disp"); line_ids+=("$aid")
            done
        else lines+=("$(printf "${DIM}  (none yet)${NC}")"); line_ids+=(""); fi

        lines+=("$SEP_MAN"); line_ids+=("")
        if [[ ${#man_ids[@]} -gt 0 ]]; then
            for i in "${!man_ids[@]}"; do
                local mid="${man_ids[$i]}" mts="${man_ts[$i]}"
                local disp; disp="$(printf "${DIM} ◈  %s${NC}" "$mid")"
                [[ -n "$mts" ]] && disp+="$(printf "${DIM}  (%s)${NC}" "$mts")"
                lines+=("$disp"); line_ids+=("$mid")
            done
        else lines+=("$(printf "${DIM}  (none yet)${NC}")"); line_ids+=(""); fi

        lines+=("$(printf "${BLD}  ── Actions ──────────────────────────${NC}")"); line_ids+=("")
        lines+=("$(printf "${GRN}+${NC}${DIM}  Create manual backup${NC}")"); line_ids+=("__create__")
        lines+=("$(printf "${RED}×${NC}${DIM}  Remove all backups${NC}")");     line_ids+=("__remove_all__")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"); line_ids+=("")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")"); line_ids+=("__back__")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Backups: %s ──${NC}" "$name")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel_line; sel_line=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel_line}" ]] && return

        local sel_clean; sel_clean=$(printf '%s' "$sel_line" | _trim_s)
        local sel_id=""
        for i in "${!lines[@]}"; do
            local lc; lc=$(printf '%s' "${lines[$i]}" | _trim_s)
            if [[ "$lc" == "$sel_clean" ]]; then sel_id="${line_ids[$i]}"; break; fi
        done
        [[ -z "$sel_id" || "$sel_id" == "__back__" ]] && return

        if [[ "$sel_id" == "__create__" ]]; then
            tmux_up "$(tsess "$cid")" && { pause "Stop the container before creating a backup."; continue; }
            confirm "$(printf "Create manual backup of '%s'?" "$name")" && _create_manual_backup "$cid"
            continue
        fi

        if [[ "$sel_id" == "__remove_all__" ]]; then
            tmux_up "$(tsess "$cid")" && { pause "Stop the container before removing backups."; continue; }
            _menu "Remove backups: $name" "All automatic" "All manual" "All (automatic + manual)" || continue
            local rm_choice="$REPLY"
            local rm_auto=false rm_man=false
            case "$rm_choice" in
                "All automatic")           rm_auto=true ;;
                "All manual")              rm_man=true ;;
                "All (automatic + manual)") rm_auto=true; rm_man=true ;;
            esac
            local rm_count=0
            [[ "$rm_auto" == "true" ]] && for id in "${auto_ids[@]}"; do _delete_backup "$sdir" "$id"; (( rm_count++ )) || true; done
            [[ "$rm_man"  == "true" ]] && for id in "${man_ids[@]}";  do _delete_backup "$sdir" "$id"; (( rm_count++ )) || true; done
            pause "$(printf "%d backup(s) removed." "$rm_count")"
            continue
        fi

        # Selected a specific backup
        [[ ! -d "$sdir/$sel_id" ]] && { pause "Backup not found."; continue; }
        local bts; bts=$(_snap_meta_get "$sdir" "$sel_id" ts)
        _menu "$(printf "Backup: %s  (%s)" "$sel_id" "${bts:-?}")" "Restore" "Create clone" "Delete" || continue
        case "$REPLY" in
            "Restore")      tmux_up "$(tsess "$cid")" && { pause "Stop the container before restoring."; continue; }
                            _do_restore_snap "$cid" "$sdir/$sel_id" "$sel_id" ;;
            "Create clone") tmux_up "$(tsess "$cid")" && { pause "Stop the container before cloning."; continue; }
                            _clone_from_snap "$cid" "$sdir/$sel_id" "$sel_id" ;;
            "Delete")       confirm "Delete backup '$sel_id'?" || continue
                            _delete_backup "$sdir" "$sel_id"
                            pause "Backup '$sel_id' deleted." ;;
        esac
    done
}

_manage_backups_menu() {
    _load_containers false
    [[ ${#CT_IDS[@]} -eq 0 ]] && { pause "No containers found."; return; }
    local lines=()
    for i in "${!CT_IDS[@]}"; do
        lines+=("$(printf "${DIM} ◈${NC}  %s" "${CT_NAMES[$i]}")")
    done
    _menu "Manage backups" "${lines[@]}" || return
    for i in "${!CT_IDS[@]}"; do
        [[ "$REPLY" == *"${CT_NAMES[$i]}"* ]] && { _container_backups_menu "${CT_IDS[$i]}"; return; }
    done
}
