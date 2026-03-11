#!/usr/bin/env bash

_stor_ctx_cid=""

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

_pick_storage_profile() {
    local cid="$1"
    local stype; stype=$(_stor_type_from_sj "$cid")
    [[ "$(_stor_count "$cid")" -eq 0 ]] && return 0
    [[ -z "$STORAGE_DIR" || ! -d "$STORAGE_DIR" ]] && { _stor_create_profile "$cid" "$stype"; return; }

    local options=() scid_map=()
    local new_label; new_label="$(printf "${GRN}+  New profile…${NC}")"
    for sdir in "$STORAGE_DIR"/*/; do
        [[ -d "$sdir" ]] || continue
        local scid; scid=$(basename "$sdir")
        [[ "$(_stor_read_type "$scid")" != "$stype" ]] && continue
        local pname; pname=$(_stor_read_name "$scid"); [[ -z "$pname" ]] && pname="(unnamed)"
        local ssize; ssize=$(du -sh "$sdir" 2>/dev/null | cut -f1)
        local active_cid; active_cid=$(_stor_read_active "$scid")
        if [[ -n "$active_cid" && "$active_cid" != "$cid" ]]; then
            if tmux_up "$(tsess "$active_cid")"; then
                options+=("$(printf "${DIM}○  %s  [%s]  %s  — in use by %s${NC}" "$pname" "$scid" "$ssize" "$(_cname "$active_cid")")")
                scid_map+=("__inuse__"); continue
            else
                _stor_clear_active "$scid"
            fi
        fi
        options+=("$(printf "●  %s  [%s]  %s" "$pname" "$scid" "$ssize")"); scid_map+=("$scid")
    done
    options+=("$new_label"); scid_map+=("__new__")

    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${options[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Storage profile ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local chosen; chosen=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 || -z "${chosen}" ]] && return
    local chosen_clean; chosen_clean=$(printf '%s' "$chosen" | _trim_s)
    local i
    for i in "${!options[@]}"; do
        [[ "$(printf '%s' "${options[$i]}" | _trim_s)" == "$chosen_clean" ]] && break
    done
    local mapped="${scid_map[$i]:-}"
    [[ "$mapped" == "__inuse__" ]] && { pause "That profile is in use by another running container."; return 1; }
    [[ "$mapped" == "__new__"   ]] && { _stor_create_profile "$cid" "$stype"; return; }
    [[ -n "$mapped" ]] && printf '%s' "$mapped"
}

_stor_create_profile() {
    local cid="$1" stype="$2"
    local existing_names=()
    for sdir in "$STORAGE_DIR"/*/; do
        [[ -d "$sdir" ]] || continue
        local sn; sn=$(_stor_read_name "$(basename "$sdir")")
        [[ "$(_stor_read_type "$(basename "$sdir")")" == "$stype" && -n "$sn" ]] && existing_names+=("$sn")
    done
    local pname=""
    while true; do
        if ! finput "$(printf 'New storage profile name:\n  (leave blank for Default)')"; then
            printf ''; return 1
        fi
        pname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"; [[ -z "$pname" ]] && pname="Default"
        local dup=false
        for en in "${existing_names[@]}"; do [[ "$en" == "$pname" ]] && dup=true && break; done
        [[ "$dup" == "true" ]] && { pause "A profile named '$pname' already exists for this type."; continue; }
        break
    done
    local new_scid
    while true; do
        new_scid=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
        [[ ! -d "$(_stor_path "$new_scid")" ]] && break
    done
    mkdir -p "$(_stor_path "$new_scid")" 2>/dev/null
    _stor_meta_set "$new_scid" storage_type "$stype" name "$pname" created "$(date +%Y-%m-%d)" active_container ""
    printf '%s' "$new_scid"
}

_persistent_storage_menu() {
    local _ctx="${1:-}"
    while true; do
        [[ -z "$STORAGE_DIR" || ! -d "$STORAGE_DIR" ]] && { pause "No storage directory found."; return; }

        local _all_cids=()
        for _cd in "$CONTAINERS_DIR"/*/; do
            [[ -f "$_cd/state.json" ]] && _all_cids+=("$(basename "$_cd")")
        done

        local entries=() scids=()
        for sdir in "$STORAGE_DIR"/*/; do
            [[ -d "$sdir" ]] || continue
            local scid; scid=$(basename "$sdir")
            local ssize; ssize=$(du -sh "$sdir" 2>/dev/null | cut -f1)
            local pname; pname=$(_stor_read_name "$scid"); [[ -z "$pname" ]] && pname="(unnamed)"
            local stype; stype=$(_stor_read_type "$scid")
            local active_cid; active_cid=$(_stor_read_active "$scid")

            # Find which container (if any) has this as default
            local def_for=""
            for _cid2 in "${_all_cids[@]}"; do
                local _d; _d=$(_state_get "$_cid2" default_storage_id)
                [[ "$_d" == "$scid" ]] && { def_for="$(_cname "$_cid2")"; break; }
            done

            local base_info; base_info="$(printf "${BLD}%s${NC}  ${DIM}[%s]${NC}" "$pname" "$scid")"
            [[ -n "$stype" ]] && base_info+="$(printf "  ${DIM}(%s)${NC}" "$stype")"

            # Dot: shape reflects default (★/☆), color reflects status (green=running, yellow=stale, dim=free)
            local dot label
            if [[ -n "$active_cid" ]] && tmux_up "$(tsess "$active_cid")"; then
                [[ -n "$def_for" ]] && dot="${GRN}★${NC}" || dot="${GRN}●${NC}"
                label="$(printf "${dot}  %-40b  ${DIM}%s  — running in %s${NC}" "$base_info" "$ssize" "$(_cname "$active_cid")")"
            elif [[ -n "$active_cid" ]]; then
                _stor_clear_active "$scid"
                [[ -n "$def_for" ]] && dot="${YLW}★${NC}" || dot="${YLW}○${NC}"
                label="$(printf "${dot}  %-40b  ${DIM}%s  [stale]${NC}" "$base_info" "$ssize")"
            else
                [[ -n "$def_for" ]] && dot="${DIM}★${NC}" || dot="${DIM}○${NC}"
                label="$(printf "${dot}  %-40b  ${DIM}%s${NC}" "$base_info" "$ssize")"
            fi
            entries+=("$label"); scids+=("$scid")
        done

        local SEP_BACKUP
        SEP_BACKUP="$(printf "${BLD}  ── Backup data ──────────────────────${NC}")"
        entries+=("$SEP_BACKUP"); scids+=("")

        local export_running=false import_running=false
        tmux has-session -t "sdStorExport" 2>/dev/null && export_running=true
        tmux has-session -t "sdStorImport" 2>/dev/null && import_running=true

        if [[ "$export_running" == "true" ]]; then
            entries+=("$(printf "${YLW}↑${NC}${DIM}  Export running — click to manage${NC}")"); scids+=("__export_running__")
        else entries+=("$(printf "${DIM}↑  Export${NC}")"); scids+=("__export__"); fi
        if [[ "$import_running" == "true" ]]; then
            entries+=("$(printf "${YLW}↓${NC}${DIM}  Import running — click to manage${NC}")"); scids+=("__import_running__")
        else entries+=("$(printf "${DIM}↓  Import${NC}")"); scids+=("__import__"); fi

        local hdr
        if [[ -n "$_ctx" ]]; then
            hdr="$(printf "${BLD}── Profiles: %s ──${NC}\n${DIM}  ${GRN}●${NC}${DIM} running  ${YLW}○${NC}${DIM} stale  ○ free  ${YLW}★${NC}${DIM} default${NC}" "$(_cname "$_ctx")")"
        else
            hdr="$(printf "${BLD}── Persistent storage ──${NC}\n${DIM}  ${GRN}●${NC}${DIM} running  ${YLW}○${NC}${DIM} stale  ○ free  ${YLW}★${NC}${DIM} default${NC}")"
        fi

        local numbered=()
        local idx
        for (( idx=0; idx<${#entries[@]}; idx++ )); do
            numbered+=("$(printf '%04d\t%s' "$idx" "${entries[$idx]}")")
        done

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${numbered[@]}" | fzf "${FZF_BASE[@]}" --delimiter=$'\t' --with-nth=2.. --header="$hdr" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel_line; sel_line=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel_line}" ]] && return

        local sel_idx; sel_idx=$(printf '%s' "$sel_line" | _strip_ansi | cut -d$'\t' -f1 | tr -dc '0-9')
        [[ -z "$sel_idx" ]] && continue
        local sel_scid="${scids[$sel_idx]:-}"
        [[ -z "$sel_scid" ]] && continue

        case "$sel_scid" in
            "__export__")   _stor_export_menu ;;
            "__export_running__")
                _menu "Export running" "Attach to export" "Kill export" || continue
                case "$REPLY" in
                    "Attach to export") _tmux_attach_hint "export" "sdStorExport" ;;
                    "Kill export") confirm "Kill the running export?" || continue
                        tmux kill-session -t "sdStorExport" 2>/dev/null || true; pause "Export killed." ;;
                esac ;;
            "__import__")   _stor_import_menu ;;
            "__import_running__")
                _menu "Import running" "Attach to import" "Kill import" || continue
                case "$REPLY" in
                    "Attach to import") _tmux_attach_hint "import" "sdStorImport" ;;
                    "Kill import") confirm "Kill the running import?" || continue
                        tmux kill-session -t "sdStorImport" 2>/dev/null || true; pause "Import killed." ;;
                esac ;;
            *)
                local active_cid2; active_cid2=$(_stor_read_active "$sel_scid")
                if [[ -n "$active_cid2" ]] && tmux_up "$(tsess "$active_cid2")"; then
                    pause "$(printf "Storage is currently running in '%s'.\nStop the container first." "$(_cname "$active_cid2")")"; continue
                fi
                local pname2; pname2=$(_stor_read_name "$sel_scid"); [[ -z "$pname2" ]] && pname2="(unnamed)"
                local stype2; stype2=$(_stor_read_type "$sel_scid")

                # Check if this is currently a default for any container
                local cur_def_cid=""
                for _cid2b in "${_all_cids[@]}"; do
                    local _db; _db=$(_state_get "$_cid2b" default_storage_id)
                    [[ "$_db" == "$sel_scid" ]] && { cur_def_cid="$_cid2b"; break; }
                done

                # Resolve action context
                local _action_ctx="$_ctx"
                if [[ -z "$_action_ctx" && -n "$stype2" ]]; then
                    local _mc=0 _last_cid=""
                    for _cid3 in "${_all_cids[@]}"; do
                        [[ "$(_stor_type_from_sj "$_cid3")" == "$stype2" ]] && { _last_cid="$_cid3"; ((_mc++)) || true; }
                    done
                    [[ $_mc -eq 1 ]] && _action_ctx="$_last_cid"
                fi

                # Build action items
                local act_items=()
                if [[ -n "$cur_def_cid" ]]; then
                    act_items+=("☆  Unset default")
                else
                    act_items+=("★  Set as default")
                fi
                act_items+=("${L[stor_rename]}" "${L[stor_delete]}")

                _menu "$(printf "Storage: %s" "$pname2")" "${act_items[@]}" || continue

                case "$REPLY" in
                    "☆  Unset default")
                        _set_st "$cur_def_cid" default_storage_id '""'
                        pause "$(printf "'%s' is no longer the default for %s." "$pname2" "$(_cname "$cur_def_cid")")" ;;
                    "★  Set as default")
                        if [[ -z "$_action_ctx" ]]; then
                            local _ct_names=() _ct_ids=()
                            for _cid4 in "${_all_cids[@]}"; do
                                _ct_names+=("$(_cname "$_cid4")"); _ct_ids+=("$_cid4")
                            done
                            local _fzf_out _fzf_pid _frc
                            _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
                            printf '%s\n' "${_ct_names[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Assign container ──${NC}")" >"$_fzf_out" 2>/dev/null &
                            _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
                            wait "$_fzf_pid" 2>/dev/null; _frc=$?
                            local _chosen_ct; _chosen_ct=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
                            _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
                            [[ $_frc -ne 0 || -z "${_chosen_ct}" ]] && continue
                            _chosen_ct=$(printf '%s' "$_chosen_ct" | _trim_s)
                            for i in "${!_ct_names[@]}"; do
                                [[ "${_ct_names[$i]}" == "$_chosen_ct" ]] && { _action_ctx="${_ct_ids[$i]}"; break; }
                            done
                        fi
                        [[ -z "$_action_ctx" ]] && continue
                        local old_def; old_def=$(_state_get "$_action_ctx" default_storage_id)
                        if [[ -n "$old_def" && "$old_def" != "$sel_scid" ]]; then
                            local old_type; old_type=$(_stor_read_type "$old_def")
                            [[ "$old_type" == "$stype2" ]] && _set_st "$_action_ctx" default_storage_id '""'
                        fi
                        _set_st "$_action_ctx" default_storage_id "\"$sel_scid\""
                        pause "$(printf "'%s' set as default for %s." "$pname2" "$(_cname "$_action_ctx")")" ;;
                    "${L[stor_rename]}")
                        while true; do
                            finput "New name for '$pname2':" || break
                            local new_sname; new_sname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"
                            [[ -z "$new_sname" ]] && { pause "Name cannot be empty."; continue; }
                            local dup_s=false
                            for sd2 in "$STORAGE_DIR"/*/; do
                                [[ -d "$sd2" ]] || continue
                                local scid2; scid2=$(basename "$sd2"); [[ "$scid2" == "$sel_scid" ]] && continue
                                [[ "$(_stor_read_name "$scid2")" == "$new_sname" && "$(_stor_read_type "$scid2")" == "$stype2" ]] && dup_s=true && break
                            done
                            [[ "$dup_s" == "true" ]] && { pause "A profile named '$new_sname' already exists for this type."; continue; }
                            _stor_meta_set "$sel_scid" name "$new_sname"
                            pause "Storage renamed to '$new_sname'."; break
                        done ;;
                    "${L[stor_delete]}")
                        confirm "$(printf "Permanently delete storage profile?\n\n  Name: %s\n  ID:   %s\n  Size: %s\n\n  This cannot be undone." \
                            "$pname2" "$sel_scid" "$(du -sh "$STORAGE_DIR/$sel_scid" 2>/dev/null | cut -f1)")" || continue
                        for _cid5 in "${_all_cids[@]}"; do
                            local _d5; _d5=$(_state_get "$_cid5" default_storage_id)
                            [[ "$_d5" == "$sel_scid" ]] && _set_st "$_cid5" default_storage_id '""'
                        done
                        btrfs subvolume delete "$STORAGE_DIR/$sel_scid" &>/dev/null \
                            || sudo -n btrfs subvolume delete "$STORAGE_DIR/$sel_scid" &>/dev/null \
                            || sudo -n rm -rf "$STORAGE_DIR/$sel_scid" 2>/dev/null \
                            || rm -rf "$STORAGE_DIR/$sel_scid" 2>/dev/null
                        [[ -d "$STORAGE_DIR/$sel_scid" ]] \
                            && pause "Could not delete '$pname2' — try stopping all containers first." \
                            || pause "Storage '$pname2' deleted." ;;
                esac ;;
        esac
    done
}

_stor_export_menu() {
    [[ -z "$STORAGE_DIR" || ! -d "$STORAGE_DIR" ]] && { pause "No storage directory found."; return; }
    local sel_entries=() sel_scids=()
    for sdir in "$STORAGE_DIR"/*/; do
        [[ -d "$sdir" ]] || continue
        local scid; scid=$(basename "$sdir")
        local pname; pname=$(_stor_read_name "$scid"); [[ -z "$pname" ]] && pname="(unnamed)"
        local stype; stype=$(_stor_read_type "$scid")
        local ssize; ssize=$(du -sh "$sdir" 2>/dev/null | cut -f1)
        sel_entries+=("$(printf "${DIM} ◈${NC}  %s  ${DIM}(%s)  %s${NC}" "$pname" "${stype:-no type}" "$ssize")")
        sel_scids+=("$scid")
    done
    [[ "${#sel_entries[@]}" -eq 0 ]] && { pause "No storage profiles to export."; return; }

    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${sel_entries[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Export storage ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local chosen_lines; chosen_lines=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 || -z "${chosen_lines}" ]] && return

    local selected_scids=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local lc; lc=$(printf '%s' "$line" | _trim_s)
        for ii in "${!sel_entries[@]}"; do
            local ec; ec=$(printf '%s' "${sel_entries[$ii]}" | _trim_s)
            [[ "$ec" == "$lc" ]] && { selected_scids+=("${sel_scids[$ii]}"); break; }
        done
    done <<< "$chosen_lines"
    [[ "${#selected_scids[@]}" -eq 0 ]] && { pause "No profiles selected."; return; }

    local _confirm_names=""
    for scid in "${selected_scids[@]}"; do
        local _n; _n=$(_stor_read_name "$scid"); [[ -z "$_n" ]] && _n="$scid"
        _confirm_names+="$(printf "\n    ◈  %s" "$_n")"
    done
    confirm "$(printf "Export %d profile(s)?%s" "${#selected_scids[@]}" "$_confirm_names")" || return

    pause "$(printf "Select destination folder.\n\n  Press Enter to open file manager.")"
    local dest_dir; dest_dir=$(_pick_dir) || { pause "No destination selected."; return; }
    [[ ! -d "$dest_dir" ]] && { pause "Selected path is not a directory."; return; }

    local default_fname; default_fname="Data backup $(date '+%Y-%m-%d | %H-%M-%S')"
    local fname dest_path
    while true; do
        finput "$(printf 'Archive filename (without extension):\n  Default: %s' "$default_fname")" || return
        fname="${FINPUT_RESULT}"; [[ -z "$fname" ]] && fname="$default_fname"
        dest_path="$dest_dir/${fname}.tar.zst"
        [[ ! -f "$dest_path" ]] && break
        pause "$(printf "File already exists:\n  %s\n\nPlease choose a different name." "$dest_path")"
    done

    local stor_dirs=()
    for scid in "${selected_scids[@]}"; do stor_dirs+=("$STORAGE_DIR/$scid"); done

    local export_script; export_script=$(mktemp "$TMP_DIR/.sd_export_XXXXXX.sh")
    local ok_flag; ok_flag=$(mktemp -u "$TMP_DIR/.sd_export_ok_XXXXXX")
    {
        printf '#!/usr/bin/env bash\n'
        printf 'OK_FLAG=%q\n' "$ok_flag"
        printf '_finish() {\n  local c=$?\n'
        printf '  [[ $c -eq 0 ]] && touch "$OK_FLAG" && printf "\\n\\033[0;32m══ Export complete ══\\033[0m\\n"\n'
        printf '              || printf "\\n\\033[0;31m══ Export failed ══\\033[0m\\n"\n'
        printf '  tmux list-clients -t sdStorExport 2>/dev/null | grep -q . && { printf "Press Enter to return...\\n"; read -r _; tmux switch-client -t simpleDocker 2>/dev/null || true; }\n'
        printf '  tmux kill-session -t sdStorExport 2>/dev/null || true\n}\n'
        printf 'trap _finish EXIT\n\n'
        printf 'cd %q\n' "$STORAGE_DIR"
        local base_dirs=()
        for d in "${stor_dirs[@]}"; do base_dirs+=("$(basename "$d")"); done
        printf 'printf "Compressing %d profile(s) → %s\\n" %d %q\n' "${#stor_dirs[@]}" "$dest_path" "${#stor_dirs[@]}" "$dest_path"
        printf 'tar --zstd -cf %q' "$dest_path"
        for d in "${base_dirs[@]}"; do printf ' %q' "$d"; done
        printf ' 2>&1\n'
    } > "$export_script"
    chmod +x "$export_script"
    _tmux_launch --post-launch "$ok_flag" "" "sdStorExport" "Exporting storage" "$export_script"
    if [[ -f "$ok_flag" ]]; then rm -f "$ok_flag"; pause "✓ Exported successfully."; fi
}

_stor_import_menu() {
    [[ -z "$STORAGE_DIR" || ! -d "$STORAGE_DIR" ]] && { pause "No storage directory found."; return; }
    pause "$(printf "Select a storage archive (.tar.zst) to import.\n\n  Press Enter to open file manager.")"
    local archive; archive=$(_yazi_pick) || { pause "No file selected."; return; }
    [[ ! -f "$archive" ]] && { pause "File not found: $archive"; return; }

    confirm "$(printf "Import storage from:\n  %s\n\nThis will add new profiles to your storage." "$archive")" || return

    local import_script; import_script=$(mktemp "$TMP_DIR/.sd_import_XXXXXX.sh")
    local ok_flag; ok_flag=$(mktemp -u "$TMP_DIR/.sd_import_ok_XXXXXX")
    {
        printf '#!/usr/bin/env bash\n'
        printf 'STORAGE_DIR=%q\nARCHIVE=%q\nOK_FLAG=%q\n' "$STORAGE_DIR" "$archive" "$ok_flag"
        cat <<'IMPORT_BODY'
_finish() {
  local c=$?
  [[ $c -eq 0 ]] && touch "$OK_FLAG" && printf "\n\033[0;32m══ Import complete ══\033[0m\n" \
                 || printf "\n\033[0;31m══ Import failed ══\033[0m\n"
  tmux list-clients -t sdStorImport 2>/dev/null | grep -q . && { printf "Press Enter to return...\n"; read -r _; tmux switch-client -t simpleDocker 2>/dev/null || true; }
  tmux kill-session -t sdStorImport 2>/dev/null || true
}
trap _finish EXIT
TMPEXTRACT=$(mktemp -d "$STORAGE_DIR/.sd_import_XXXXXX")
printf "Extracting archive...\n"
tar --zstd -xf "$ARCHIVE" -C "$TMPEXTRACT" 2>&1 || exit 1
imported=0
for sdir in "$TMPEXTRACT"/*/; do
    [[ -d "$sdir" ]] || continue
    meta="$sdir/.sd_meta.json"
    orig_name=$(jq -r '.name // empty' "$meta" 2>/dev/null); [[ -z "$orig_name" ]] && orig_name="$(basename "$sdir")"
    stype=$(jq -r '.storage_type // empty' "$meta" 2>/dev/null)
    candidate="$orig_name"; counter=2
    while true; do
        found=false
        for existing in "$STORAGE_DIR"/*/; do
            [[ -f "$existing/.sd_meta.json" ]] || continue
            en=$(jq -r '.name // empty' "$existing/.sd_meta.json" 2>/dev/null)
            et=$(jq -r '.storage_type // empty' "$existing/.sd_meta.json" 2>/dev/null)
            [[ "$en" == "$candidate" && "$et" == "$stype" ]] && { found=true; break; }
        done
        [[ "$found" == "false" ]] && break
        candidate="${orig_name} ${counter}"; counter=$(( counter + 1 ))
    done
    while true; do
        new_scid=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
        [[ ! -d "$STORAGE_DIR/$new_scid" ]] && break
    done
    dest="$STORAGE_DIR/$new_scid"
    if cp -a "$sdir" "$dest"; then
        jq --arg n "$candidate" '.name=$n | .active_container=""' "$dest/.sd_meta.json" > "$dest/.sd_meta.json.tmp" \
            && mv "$dest/.sd_meta.json.tmp" "$dest/.sd_meta.json" || true
        echo "[+] Imported: ${orig_name} -> ${candidate} [${new_scid}]"
        imported=$(( imported + 1 ))
    else
        echo "[!] Failed to copy: $sdir"
    fi
done
rm -rf "$TMPEXTRACT"
echo "[+] Imported ${imported} profile(s)."
IMPORT_BODY
    } > "$import_script"
    chmod +x "$import_script"
    _tmux_launch --post-launch "$ok_flag" "" "sdStorImport" "Importing storage" "$import_script"
    if [[ -f "$ok_flag" ]]; then rm -f "$ok_flag"; pause "✓ Imported successfully."; fi
}
