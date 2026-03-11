#!/usr/bin/env bash

_blueprint_submenu() {
    local bname="$1" bfile; bfile=$(_bp_path "$bname")
    while true; do
        _menu "Blueprint: $bname" "${L[bp_edit]}" "${L[bp_rename]}" "${L[bp_delete]}"
        case $? in 2) continue ;; 0) ;; *) return ;; esac
        case "$REPLY" in
            "${L[bp_edit]}")
                _guard_space || continue
                ${EDITOR:-vi} "$bfile" ;;
            "${L[bp_rename]}")
                while true; do
                    finput "New name for blueprint '$bname':" || break
                    local new_bname; new_bname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"
                    [[ -z "$new_bname" ]] && { pause "Name cannot be empty."; continue; }
                    local ext="${bfile##*.}"
                    local new_bfile="$BLUEPRINTS_DIR/$new_bname.$ext"
                    [[ -f "$new_bfile" ]] && { pause "Blueprint '$new_bname' already exists."; continue; }
                    mv "$bfile" "$new_bfile" 2>/dev/null || { pause "Could not rename."; break; }
                    pause "Blueprint renamed to '$new_bname'."; return
                done ;;
            "${L[bp_delete]}")
                confirm "$(printf "Delete blueprint '%s'?\nThis cannot be undone." "$bname")" || continue
                rm -f "$bfile" 2>/dev/null || { pause "Could not delete."; continue; }
                pause "Blueprint '$bname' deleted."; return ;;
        esac
    done
}

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
