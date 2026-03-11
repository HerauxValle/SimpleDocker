#!/usr/bin/env bash

_clone_source_submenu() {
    local src_cid="$1"
    local src_name; src_name=$(_cname "$src_cid")
    local src_path; src_path=$(_cpath "$src_cid")
    local sdir; sdir=$(_snap_dir "$src_cid")
    tmux_up "$(tsess "$src_cid")" && { pause "Stop '$src_name' before cloning."; return; }
    [[ ! -d "$src_path" ]] && { pause "Container not installed."; return; }

    local lines=()
    lines+=("$(printf "${BLD}  ── Main ─────────────────────────────${NC}\t__sep__")")
    lines+=("$(printf "   ${DIM}◈${NC}  Current state\tcurrent")")
    local pi_path="$sdir/Post-Installation"
    [[ -d "$pi_path" ]] && {
        local pi_ts; pi_ts=$(_snap_meta_get "$sdir" "Post-Installation" ts)
        lines+=("$(printf "   ${DIM}◈${NC}  Post-Installation${DIM}  (%s)${NC}\tpost" "${pi_ts:-?}")")
    }

    local other_ids=() other_ts=()
    for f in "$sdir"/*.meta; do
        [[ -f "$f" ]] || continue
        local fid; fid=$(basename "$f" .meta)
        [[ "$fid" == "Post-Installation" || ! -d "$sdir/$fid" ]] && continue
        other_ids+=("$fid"); other_ts+=("$(_snap_meta_get "$sdir" "$fid" ts)")
    done
    lines+=("$(printf "${BLD}  ── Other ────────────────────────────${NC}\t__sep__")")
    if [[ ${#other_ids[@]} -gt 0 ]]; then
        for i in "${!other_ids[@]}"; do
            local oid="${other_ids[$i]}" ots="${other_ts[$i]}"
            local de="$(printf "   ${DIM}◈${NC}  %s" "$oid")"
            [[ -n "$ots" ]] && de+="$(printf "${DIM}  (%s)${NC}" "$ots")"
            lines+=("$de\t$oid")
        done
    else
        lines+=("$(printf "${DIM}  No other backups found${NC}\t__sep__")")
    fi
    lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}\t__sep__")")
    lines+=("$(printf "${DIM} %s${NC}\t__back__" "${L[back]}")")

    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --with-nth=1 --delimiter=$'\t' \
        --header="$(printf "${BLD}── Clone '%s' from ──${NC}" "$src_name")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local sel; sel=$(cat "$_fzf_out" 2>/dev/null); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; return; }
    [[ $_frc -ne 0 || -z "$sel" ]] && return
    local tag; tag=$(printf '%s' "$sel" | awk -F'\t' '{print $2}' | tr -d '[:space:]')
    [[ "$tag" == "__back__" || "$tag" == "__sep__" || -z "$tag" ]] && return
    case "$tag" in
        current) _clone_container "$src_cid" ;;
        post)    _clone_from_snap "$src_cid" "$pi_path" "Post-Installation" ;;
        *)       _clone_from_snap "$src_cid" "$sdir/$tag" "$tag" ;;
    esac
}

_install_method_menu() {
    local bps=(); mapfile -t bps < <(_list_blueprint_names)
    local pbps=(); mapfile -t pbps < <(_list_persistent_names)
    local ibps=(); mapfile -t ibps < <(_list_imported_names)
    local lines=()
    lines+=("$(printf "${BLD}  ── Install from blueprint ───────────${NC}\t__sep__")")
    if [[ ${#bps[@]} -gt 0 || ${#pbps[@]} -gt 0 || ${#ibps[@]} -gt 0 ]]; then
        for n in "${bps[@]}";  do lines+=("$(printf "   ${DIM}◈${NC}  %s\tbp:%s" "$n" "$n")"); done
        for n in "${pbps[@]}"; do lines+=("$(printf "   ${BLU}◈${NC}  %s  ${DIM}[Persistent]${NC}\tpbp:%s" "$n" "$n")"); done
        for n in "${ibps[@]}"; do lines+=("$(printf "   ${CYN}◈${NC}  %s  ${DIM}[Imported]${NC}\tibp:%s" "$n" "$n")"); done
    else
        lines+=("$(printf "${DIM}  No blueprints found${NC}\t__sep__")")
    fi

    lines+=("$(printf "${BLD}  ── Clone existing container ─────────${NC}\t__sep__")")
    _load_containers false
    local has_inst=false
    for i in "${!CT_IDS[@]}"; do
        [[ "$(_st "${CT_IDS[$i]}" installed)" != "true" ]] && continue
        has_inst=true
        lines+=("$(printf "   ${DIM}◈${NC}  %s\tclone:%s" "${CT_NAMES[$i]}" "${CT_IDS[$i]}")")
    done
    [[ "$has_inst" == "false" ]] && lines+=("$(printf "${DIM}  No installed containers found${NC}\t__sep__")")

    lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}\t__sep__")")
    lines+=("$(printf "${DIM} %s${NC}\t__back__" "${L[back]}")")

    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --with-nth=1 --delimiter=$'\t' \
        --header="$(printf "${BLD}── Select installation method ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local sel; sel=$(cat "$_fzf_out" 2>/dev/null); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; return 2; }
    [[ $_frc -ne 0 || -z "$sel" ]] && return 1
    local tag; tag=$(printf '%s' "$sel" | awk -F'\t' '{print $2}' | tr -d '[:space:]')
    [[ "$tag" == "__back__" || "$tag" == "__sep__" || -z "$tag" ]] && return 1
    case "$tag" in
        bp:*)    _create_container "${tag#bp:}" ;;
        pbp:*)   _create_container "${tag#pbp:}" "" ;;
        ibp:*)
            local _iname="${tag#ibp:}"
            local _ipath; _ipath=$(_get_imported_bp_path "$_iname")
            [[ -z "$_ipath" ]] && { pause "Could not locate imported blueprint '$_iname'."; return 1; }
            _create_container "$_iname" "$_ipath" ;;
        clone:*) _clone_source_submenu "${tag#clone:}" ;;
    esac
}

_clone_container() {
    local src_cid="$1"
    local src_name; src_name=$(_cname "$src_cid")
    local src_path; src_path=$(_cpath "$src_cid")

    [[ -z "$src_path" || ! -d "$src_path" ]] && { pause "Container not installed — nothing to clone."; return 1; }
    tmux_up "$(tsess "$src_cid")" && { pause "Stop '$src_name' before cloning."; return 1; }

    finput "Name for the clone:" || return 1
    local clone_name="$FINPUT_RESULT"
    [[ -z "$clone_name" ]] && { pause "No name given."; return 1; }

    # Generate new cid
    local clone_cid; clone_cid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
        | tr -dc 'a-z0-9' | head -c 8 || tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
    local clone_dir="$CONTAINERS_DIR/$clone_cid"
    local clone_path="$INSTALLATIONS_DIR/$clone_cid"

    mkdir -p "$clone_dir" 2>/dev/null

    # Copy container metadata
    cp "$CONTAINERS_DIR/$src_cid/service.json"  "$clone_dir/service.json" 2>/dev/null || true
    cp "$CONTAINERS_DIR/$src_cid/state.json"    "$clone_dir/state.json" 2>/dev/null || true
    [[ -f "$CONTAINERS_DIR/$src_cid/resources.json" ]] && \
        cp "$CONTAINERS_DIR/$src_cid/resources.json" "$clone_dir/resources.json" 2>/dev/null || true

    # Update name and install_path in state.json
    local rel_path; rel_path=$(basename "$clone_path")
    jq --arg n "$clone_name" --arg p "$rel_path" \
        '.name = $n | .install_path = $p' \
        "$clone_dir/state.json" > "$clone_dir/state.json.tmp" 2>/dev/null \
        && mv "$clone_dir/state.json.tmp" "$clone_dir/state.json"

    # btrfs CoW snapshot — instant, shares unchanged blocks with source
    if btrfs subvolume snapshot "$src_path" "$clone_path" &>/dev/null; then
        pause "$(printf "Cloned '%s' → '%s'\n\nThe clone is independent — changes won't affect the original.\nShared blocks are copy-on-write so initial disk usage is near zero." \
            "$src_name" "$clone_name")"
    else
        # Fallback: plain copy
        cp -a "$src_path" "$clone_path" 2>/dev/null \
            || { rm -rf "$clone_dir" "$clone_path" 2>/dev/null; pause "Clone failed."; return 1; }
        pause "$(printf "Cloned '%s' → '%s' (plain copy — btrfs snapshot unavailable)" \
            "$src_name" "$clone_name")"
    fi
}

_installing_menu() {
    local cid="$1" header="$2"; shift 2
    local ok_file="$CONTAINERS_DIR/$cid/.install_ok"
    local fail_file="$CONTAINERS_DIR/$cid/.install_fail"
    local lines=()
    for x in "$@"; do
        printf '%s' "$x" | grep -q $'\033' && lines+=("$x") || lines+=("$(printf "${DIM} %s${NC}" "$x")")
    done
    local _nav; _nav="$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"
    lines+=("$_nav" "$(printf "${DIM} %s${NC}" "${L[back]}")")
    local _fzf_out; _fzf_out=$(mktemp "$TMP_DIR/.sd_fzfout_XXXXXX")
    local _wflag;   _wflag=$(mktemp -u "$TMP_DIR/.sd_wflag_XXXXXX")
    local _wpid=""
    printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$header" >"$_fzf_out" 2>/dev/null &
    local _fzf_pid=$!
    if [[ ! -f "$ok_file" && ! -f "$fail_file" ]]; then
        { while [[ ! -f "$ok_file" && ! -f "$fail_file" ]]; do sleep 0.3; done
          touch "$_wflag"; kill "$_fzf_pid" 2>/dev/null
        } &
        _wpid=$!
    fi
    wait "$_fzf_pid" 2>/dev/null
    [[ -n "$_wpid" ]] && { kill "$_wpid" 2>/dev/null; wait "$_wpid" 2>/dev/null; }
    if [[ -f "$_wflag" ]]; then
        rm -f "$_wflag" "$_fzf_out"
        stty sane 2>/dev/null
        return 2
    fi
    REPLY=$(cat "$_fzf_out" 2>/dev/null | _trim_s)
    rm -f "$_fzf_out"
    [[ -z "$REPLY" || "$REPLY" == "${L[back]}" ]] && return 1
    return 0
}

_open_in_submenu() {
    local cid="$1"; local name; name=$(_cname "$cid")
    local is_running=false; tmux_up "$(tsess "$cid")" && is_running=true
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local svc_port; svc_port=$(jq -r '.meta.port // 0' "$sj" 2>/dev/null); svc_port="${svc_port:-0}"
    local env_port; env_port=$(jq -r '.environment.PORT // empty' "$sj" 2>/dev/null)
    [[ -n "$env_port" ]] && svc_port="$env_port"
    local install_path; install_path=$(_cpath "$cid")

    # Prefer proxy URL over localhost:port if a route exists for this container
    _open_in_best_url() {
        local _cid="$1" _port="$2"
        local _route_url _https
        _route_url=$(jq -r --arg c "$_cid" '.routes[] | select(.cid==$c) | .url' "$(_proxy_cfg)" 2>/dev/null | head -1)
        if [[ -n "$_route_url" ]]; then
            _https=$(jq -r --arg c "$_cid" '.routes[] | select(.cid==$c) | (.https // "false")' "$(_proxy_cfg)" 2>/dev/null | head -1)
            [[ "$_https" == "true" ]] && printf 'https://%s' "$_route_url" || printf 'http://%s' "$_route_url"
        else
            printf 'http://localhost:%s' "$_port"
        fi
    }

    while true; do
        local opts=()
        [[ "$svc_port" != "0" && -n "$svc_port" ]] && opts+=("⊕  Browser")
        [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && _chroot_bash "$UBUNTU_DIR" -c 'command -v qrencode' >/dev/null 2>&1 \
            && [[ "$svc_port" != "0" && -n "$svc_port" ]] && opts+=("⊞  Show QR code")
        opts+=("◧  File manager" "◉  Terminal")
        _menu "$(printf "Open in — %s" "$name")" "${opts[@]}"
        case $? in 2) continue ;; 0) ;; *) return ;; esac
        case "$REPLY" in
            *"Browser"*)
                [[ "$is_running" == "false" ]] && { pause "Please start the container first."; continue; }
                _sd_open_url "$(_open_in_best_url "$cid" "$svc_port")" >/dev/null 2>&1
                return ;;
            *"QR code"*)
                [[ "$is_running" == "false" ]] && { pause "Please start the container first."; continue; }
                local _qr_exp; _qr_exp=$(_exposure_get "$cid")
                if [[ "$_qr_exp" != "public" ]]; then
                    pause "$(printf "Exposure is %b — QR code requires public.\n\n  Set this container to public in Reverse Proxy → Port exposure." "$(_exposure_label "$_qr_exp")")"
                    continue
                fi
                local _qr_url="http://${cid}.local"
                local _qr_render; _qr_render=$(_chroot_bash "$UBUNTU_DIR" -c "qrencode -t UTF8 -o - '$_qr_url'" 2>/dev/null)
                printf '%s

  %s
' "$_qr_render" "$_qr_url"                     | _fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── QR Code ──${NC}
${DIM}  Scan to open on any LAN device (mDNS)${NC}")"                           --no-multi --disabled >/dev/null 2>&1 || true ;;
                        *"File manager"*)
                local open_path="${install_path:-$INSTALLATIONS_DIR}"
                [[ -z "$open_path" ]] && { pause "No install path found."; continue; }
                xdg-open "$open_path" 2>/dev/null & disown 2>/dev/null || true ;;
            *"Terminal"*)
                local tsess_term="sdTerm_${cid}"
                local tip; tip=$(_cpath "$cid"); [[ -z "$tip" ]] && tip="$HOME"
                if ! tmux has-session -t "$tsess_term" 2>/dev/null; then
                    tmux new-session -d -s "$tsess_term" "cd $(printf '%q' "$tip") && exec bash" 2>/dev/null
                    tmux set-option -t "$tsess_term" detach-on-destroy off 2>/dev/null || true
                fi
                pause "$(printf "Opening terminal for '%s'\n\n  %s\n  Press %s to detach." "$name" "$tip" "${KB[tmux_detach]}")"
                tmux switch-client -t "$tsess_term" 2>/dev/null || true ;;
        esac
    done
}

_create_container() {
    local bname="$1" bfile="${2:-}"
    [[ -z "$bfile" ]] && bfile=$(_bp_path "$bname")
    local is_tmpfile=false
    if [[ -z "$bfile" || ! -f "$bfile" ]]; then
        local raw; raw=$(_get_persistent_bp "$bname"); [[ -z "$raw" ]] && { pause "Could not read blueprint '$bname'."; return 1; }
        bfile=$(mktemp "$TMP_DIR/.sd_pbp_XXXXXX.toml")
        printf '%s\n' "$raw" > "$bfile"; is_tmpfile=true
    fi
    _guard_space || { [[ "$is_tmpfile" == true ]] && rm -f "$bfile"; return 1; }

    # Pre-validate before asking for a name — fail fast on bad blueprints
    if ! _bp_is_json "$bfile"; then
        declare -A _vc_META=(); declare -A _vc_ENV=()
        local _vc_saved_meta _vc_saved_env
        # Save/restore globals around a parse-only run
        BP_META=() BP_ENV=() BP_STORAGE="" BP_DEPS="" BP_DIRS=""
        BP_GITHUB="" BP_NPM="" BP_BUILD="" BP_INSTALL="" BP_UPDATE="" BP_START=""
        BP_ACTIONS_NAMES=() BP_ACTIONS_SCRIPTS=() BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()
        if _bp_parse "$bfile"; then
            if ! _bp_validate; then
                local _errmsg; _errmsg=$(printf '%s\n' "${BP_ERRORS[@]}")
                [[ "$is_tmpfile" == true ]] && rm -f "$bfile"
                pause "$(printf '⚠  Blueprint validation failed:\n\n%s\n\n  Edit the blueprint and try again.' "$_errmsg")"
                return 1
            fi
        fi
    fi

    local suggested
    if _bp_is_json "$bfile"; then
        suggested=$(jq -r '.meta.name // empty' "$bfile" 2>/dev/null)
    else
        suggested=$(grep -m1 '^name[[:space:]]*=' "$bfile" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//')
    fi
    [[ -z "$suggested" ]] && suggested="$bname"

    local ct_name
    while true; do
        if ! finput "Container name (default: $suggested):"; then
            [[ "$is_tmpfile" == true ]] && rm -f "$bfile"; return 1
        fi
        ct_name="${FINPUT_RESULT//[^a-zA-Z0-9_\-]/}"
        [[ -z "$ct_name" ]] && ct_name="${suggested//[^a-zA-Z0-9_\-]/}"

        local dup=false
        for d in "$CONTAINERS_DIR"/*/; do
            [[ -f "$d/state.json" ]] || continue
            [[ "$(jq -r '.name // empty' "$d/state.json" 2>/dev/null)" == "$ct_name" ]] && dup=true && break
        done
        if [[ "$dup" == "true" ]]; then [[ "$is_tmpfile" == true ]] && rm -f "$bfile"; pause "A container named '$ct_name' already exists."; return 1; fi

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n%s\n' "$(printf "${GRN}▶  Continue${NC}")" "$(printf "${DIM}   Change name${NC}")" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Container name ──${NC}")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local name_choice; name_choice=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 ]] && return
        local name_choice_clean; name_choice_clean=$(printf '%s' "$name_choice" | _trim_s)
        [[ "$name_choice_clean" == *"Change name"* ]] && continue
        break
    done

    local cid; cid=$(_rand_id)
    mkdir -p "$CONTAINERS_DIR/$cid" 2>/dev/null
    jq -n --arg id "$cid" --arg n "$ct_name" --arg ip "$ct_name" \
        '{id:$id,name:$n,install_path:$ip,installed:false,hidden:false,trash:false}' \
        > "$CONTAINERS_DIR/$cid/state.json"
    cp "$bfile" "$CONTAINERS_DIR/$cid/service.src"
    [[ "$is_tmpfile" == true ]] && rm -f "$bfile"
    _compile_service "$cid" || { pause "Failed to compile blueprint."; return 1; }
    pause "Container '$ct_name' created. Select it to install."
}

_edit_container_bp() {
    local cid="$1"
    local src="$CONTAINERS_DIR/$cid/service.src"
    local _erun=false _einst=false
    tmux_up "$(tsess "$cid")" && _erun=true
    _is_installing "$cid"    && _einst=true
    [[ "$_erun" == "true" || "$_einst" == "true" ]] && { pause "⚠  Stop the container before editing."; return 1; }
    _guard_space || return 1; _ensure_src "$cid"
    ${EDITOR:-vi} "$src"
    if ! _bp_is_json "$src"; then
        BP_META=() BP_ENV=() BP_STORAGE="" BP_DEPS="" BP_DIRS=""
        BP_GITHUB="" BP_NPM="" BP_BUILD="" BP_INSTALL="" BP_UPDATE="" BP_START=""
        BP_ACTIONS_NAMES=() BP_ACTIONS_SCRIPTS=() BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()
        _bp_parse "$src" 2>/dev/null
        if ! _bp_validate; then
            local _ee; _ee=$(printf '%s\n' "${BP_ERRORS[@]}")
            pause "$(printf '⚠  Blueprint has errors (not saved):\n\n%s\n\n  Re-open editor to fix.' "$_ee")"
            return 1
        fi
    fi
    _compile_service "$cid" && [[ "$(_st "$cid" installed)" == "true" ]] && _build_start_script "$cid" 2>/dev/null || true
}

_rename_container() {
    local cid="$1" name; name=$(_cname "$cid")
    [[ "$(_st "$cid" installed)" == "true" ]] && { pause "Rename is only available for uninstalled containers."; return 1; }
    while true; do
        finput "New name for '$name':" || return 1
        local new_ct_name; new_ct_name="${FINPUT_RESULT//[^a-zA-Z0-9_\-]/}"
        [[ -z "$new_ct_name" ]] && { pause "Name cannot be empty."; continue; }
        local dup_found=false
        for dd in "$CONTAINERS_DIR"/*/; do
            [[ -f "$dd/state.json" ]] || continue
            local en; en=$(jq -r '.name // empty' "$dd/state.json" 2>/dev/null)
            [[ "$en" == "$new_ct_name" && "$(basename "$dd")" != "$cid" ]] && dup_found=true && break
        done
        [[ "$dup_found" == "true" ]] && { pause "A container named '$new_ct_name' already exists."; continue; }
        jq --arg n "$new_ct_name" '.name=$n' "$CONTAINERS_DIR/$cid/state.json" \
            > "$CONTAINERS_DIR/$cid/state.json.tmp" \
            && mv "$CONTAINERS_DIR/$cid/state.json.tmp" "$CONTAINERS_DIR/$cid/state.json" 2>/dev/null
        pause "Container renamed to '$new_ct_name'."; return 0
    done
}

_container_submenu() {
    local cid="$1"
    while true; do
        clear; _cleanup_stale_lock
        local name; name=$(_cname "$cid"); [[ -z "$name" ]] && name="(unnamed-$cid)"
        local installed; installed=$(_st "$cid" installed)
        local is_running=false; tmux_up "$(tsess "$cid")" && is_running=true
        local is_installing=false; _is_installing "$cid" && is_installing=true
        local ok_file="$CONTAINERS_DIR/$cid/.install_ok"
        local fail_file="$CONTAINERS_DIR/$cid/.install_fail"
        local install_done=false; [[ -f "$ok_file" || -f "$fail_file" ]] && install_done=true

        local svc_port; svc_port=$(jq -r '.meta.port // 0' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null); svc_port="${svc_port:-0}"
        local env_port; env_port=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        [[ -n "$env_port" ]] && svc_port="$env_port"

        local action_labels=() action_dsls=()
        local cron_names=() cron_intervals=() cron_idxs=()
        if [[ "$installed" == "true" && "$is_installing" == "false" ]]; then
            local sj="$CONTAINERS_DIR/$cid/service.json"
            local act_count; act_count=$(jq -r '.actions | length' "$sj" 2>/dev/null)
            if [[ -n "$act_count" && "$act_count" -gt 0 ]]; then
                for (( ai=0; ai<act_count; ai++ )); do
                    local lbl; lbl=$(jq -r --argjson i "$ai" '.actions[$i].label // empty' "$sj" 2>/dev/null)
                    # Support both new .dsl and legacy .script field
                    local dsl; dsl=$(jq -r --argjson i "$ai" '.actions[$i].dsl // .actions[$i].script // empty' "$sj" 2>/dev/null)
                    [[ -z "$lbl" ]] && continue
                    # Skip "Open browser" — user opens via Open in → Browser
                    [[ "${lbl,,}" == "open browser" ]] && continue
                    # Auto-prepend a run icon if the label doesn't already start with a non-ASCII symbol
                    local _first_char; _first_char=$(printf '%s' "$lbl" | cut -c1)
                    if [[ "$_first_char" =~ ^[a-zA-Z0-9]$ ]]; then
                        lbl="⊙  $lbl"
                    fi
                    action_labels+=("$lbl"); action_dsls+=("$dsl")
                done
            fi
            local cron_count; cron_count=$(jq -r '.crons | length' "$sj" 2>/dev/null)
            if [[ -n "$cron_count" && "$cron_count" -gt 0 ]]; then
                for (( ci=0; ci<cron_count; ci++ )); do
                    local cn; cn=$(jq -r --argjson i "$ci" '.crons[$i].name // empty' "$sj" 2>/dev/null)
                    local civ; civ=$(jq -r --argjson i "$ci" '.crons[$i].interval // empty' "$sj" 2>/dev/null)
                    [[ -z "$cn" ]] && continue
                    cron_names+=("$cn"); cron_intervals+=("$civ"); cron_idxs+=("$ci")
                done
            fi
        fi

        local SEP_GEN SEP_ACT SEP_CRON SEP_MGT
        SEP_GEN="$(printf "${BLD}  ── General ──────────────────────────${NC}")"
        SEP_ACT="$(printf "${BLD}  ── Actions ──────────────────────────${NC}")"
        SEP_CRON="$(printf "${BLD}  ── Cron ─────────────────────────────${NC}")"
        SEP_MGT="$(printf "${BLD}  ── Management ───────────────────────${NC}")"
        local items=("$SEP_GEN")

        local _UPD_FILES=() _UPD_NAMES=() _UPD_VERS=() _UPD_SRCS=() _UPD_ISTMP=()
        local _UPD_ITEMS=() _UPD_IDX=()
        [[ "$is_installing" == "false" && "$is_running" == "false" ]] && {
            _build_update_items "$cid"
            [[ "$installed" == "true" ]] && _build_ubuntu_update_item "$cid"
            [[ "$installed" == "true" ]] && _build_pkg_update_item "$cid"
        }

        if [[ "$is_installing" == "true" || "$install_done" == "true" ]]; then
            if [[ "$install_done" == "true" ]]; then
                local _fin_lbl="${L[ct_finish_inst]}"
                [[ "$installed" == "true" ]] && _fin_lbl="✓  Finish update"
                items+=("$_fin_lbl")
            else
                items+=("${L[ct_attach_inst]}")
            fi
        elif [[ "$is_running" == "true" ]]; then
            items+=("${L[ct_stop]}" "${L[ct_restart]}" "${L[ct_attach]}" "${L[ct_open_in]}" "${L[ct_log]}")
            [[ "${#action_labels[@]}" -gt 0 ]] && items+=("$SEP_ACT" "${action_labels[@]}")
            # Cron section — show static interval from blueprint declaration
            if [[ "${#cron_names[@]}" -gt 0 ]]; then
                items+=("$SEP_CRON")
                for ci in "${!cron_names[@]}"; do
                    local _cidx="${cron_idxs[$ci]}"
                    local _csess; _csess=$(_cron_sess "$cid" "$_cidx")
                    if tmux_up "$_csess"; then
                        items+=("$(printf " ${CYN}⏱${NC}  ${DIM}%s  ${CYN}[%s]${NC}" "${cron_names[$ci]}" "${cron_intervals[$ci]}")")
                    else
                        items+=("$(printf " ${DIM}⏱  %s  [stopped]${NC}" "${cron_names[$ci]}")")
                    fi
                done
            fi
        elif [[ "$installed" == "true" ]]; then
            local SEP_STO SEP_DNG
            SEP_STO="$(printf "${BLD}  ── Storage ───────────────────────────${NC}")"
            SEP_DNG="$(printf "${BLD}  ── Caution ───────────────────────────${NC}")"
            items+=("${L[ct_start]}" "${L[ct_open_in]}")
            items+=("$SEP_STO" "${L[ct_backups]}" "${L[ct_profiles]}")
            items+=("${L[ct_edit]}")
            # Count actually pending updates
            local _pending_upd=0
            for _ui_e in "${_UPD_ITEMS[@]}"; do
                printf '%s' "$_ui_e" | _strip_ansi | grep -qE 'Changes detected|→' && (( _pending_upd++ )) || true
            done
            local _upd_lbl=""
            if [[ "${#_UPD_ITEMS[@]}" -gt 0 ]]; then
                if [[ "$_pending_upd" -gt 0 ]]; then
                    _upd_lbl="$(printf " ${YLW}⬆  Updates${NC}")"
                else
                    _upd_lbl="⬆  Updates"
                fi
            fi
            items+=("$SEP_DNG")
            [[ -n "$_upd_lbl" ]] && items+=("$_upd_lbl")
            items+=("${L[ct_uninstall]}")
        else
            local SEP_DNG2; SEP_DNG2="$(printf "${BLD}  ── Caution ───────────────────────────${NC}")"
            items+=("${L[ct_install]}" "${L[ct_edit]}" "${L[ct_rename]}")
            items+=("$SEP_DNG2" "${L[ct_remove]}")
        fi

        local hdr_dot
        if   [[ "$is_installing" == "true" || "$install_done" == "true" ]]; then hdr_dot="${YLW}◈${NC}"
        elif [[ "$is_running" == "true" ]]; then
            if _health_check "$cid"; then hdr_dot="${GRN}◈${NC}"
            else hdr_dot="${YLW}◈${NC}"; fi
        elif [[ "$installed" == "true" ]]; then hdr_dot="${RED}◈${NC}"
        else hdr_dot="${DIM}◈${NC}"; fi
        local _ct_dlg; _ct_dlg=$(jq -r '.meta.dialogue // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local _hdr
        if [[ -n "$_ct_dlg" ]]; then
            _hdr="$(printf "%b  %s  ${DIM}— %s${NC}" "$hdr_dot" "$name" "$_ct_dlg")"
        else
            _hdr="$(printf "%b  %s" "$hdr_dot" "$name")"
        fi
        if [[ "$svc_port" != "0" && -n "$svc_port" ]]; then
            local _hdr_ip; _hdr_ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
            _hdr+="$(printf "  ${DIM}%s:%s${NC}" "$_hdr_ip" "$svc_port")"
        fi

        if [[ "$is_installing" == "true" || "$install_done" == "true" ]]; then
            _installing_menu "$cid" "$_hdr" "${items[@]}"
            case $? in 1) _cleanup_upd_tmps; return ;; 2) continue ;; esac
        else
            _menu "$_hdr" "${items[@]}"
            local _mrc=$?
            case $_mrc in 2) continue ;; 0) ;; *) _cleanup_upd_tmps; return ;; esac
        fi

        case "$REPLY" in
            "${L[ct_attach_inst]}") _tmux_attach_hint "installation" "$(_inst_sess "$cid")"; _cleanup_stale_lock ;;
            "${L[ct_finish_inst]}"|"✓  Finish update") _process_install_finish "$cid" ;;
            "${L[ct_install]}")
                _guard_install || continue
                _run_job install "$cid"; _cleanup_upd_tmps ;;
            "${L[ct_start]}")       _start_container "$cid"; _cleanup_upd_tmps ;;
            "${L[ct_attach]}")      _tmux_attach_hint "$name" "$(tsess "$cid")" ;;
            "${L[ct_stop]}")        confirm "Stop '$name'?" || continue; _stop_container "$cid" ;;
            "${L[ct_restart]}")     _stop_container "$cid"; sleep 0.3; _start_container "$cid" ;;
            "${L[ct_open_in]}")     _open_in_submenu "$cid" ;;
            *"⏱"*)
                # Cron entry clicked — match by name and attach to its session
                local _cron_clicked; _cron_clicked=$(printf '%s' "$REPLY" | _strip_ansi | sed 's/^[[:space:]]*//' | grep -oP '(?<=⏱  )[^\[]+' | sed 's/[[:space:]]*$//')
                local _ci
                for _ci in "${!cron_names[@]}"; do
                    if [[ "${cron_names[$_ci]}" == "$_cron_clicked" ]]; then
                        local _csess; _csess=$(_cron_sess "$cid" "${cron_idxs[$_ci]}")
                        if tmux_up "$_csess"; then
                            _tmux_attach_hint "cron: ${cron_names[$_ci]}" "$_csess"
                        else
                            pause "Cron '${cron_names[$_ci]}' is not running."
                        fi
                        break
                    fi
                done ;;
            *"⬤  Exposure"*)
                local _new_mode; _new_mode=$(_exposure_next "$cid")
                _exposure_set "$cid" "$_new_mode"
                _exposure_apply "$cid"
                pause "$(printf "Port exposure set to: %b" "$(_exposure_label "$_new_mode")")" ;;
            "${L[ct_log]}")
                local _meta_log; _meta_log=$(jq -r '.meta.log // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
                local _lf
                if [[ -n "$_meta_log" ]]; then
                    _lf="$(_cpath "$cid")/$_meta_log"
                else
                    _lf=$(_log_path "$cid" "start")
                fi
                if [[ -f "$_lf" ]]; then
                    pause "$(tail -100 "$_lf" 2>/dev/null | cat)"
                else
                    pause "No log yet for '$name'."
                fi ;;
            "${L[ct_edit]}")  _edit_container_bp "$cid" || continue ;;
            "${L[ct_rename]}")  _rename_container "$cid" ;;
            "${L[ct_backups]}")  _container_backups_menu "$cid" ;;
            "${L[ct_profiles]}") _stor_ctx_cid="$cid"; _persistent_storage_menu "$cid"; _stor_ctx_cid="" ;;
            *"Clone container"*) _clone_container "$cid" ;;
            "⚙  Management"*) ;; # no-op, replaced by inline section
            "◦  Edit blueprint"|"${L[ct_edit]}"*)  _edit_container_bp "$cid" || continue ;;
            *"Installation"*) ;; # no-op, flattened
            "${L[ct_uninstall]}")
                local ip; ip=$(_cpath "$cid")
                confirm "$(printf "Uninstall '%s'?\n\n  ✕  Installation subvolume: %s\n  ✕  Snapshots\n\n  Persistent storage is kept.\n  Container entry stays — select Install to reinstall." "$name" "$ip")" || continue
                [[ -d "$ip" ]] && { sudo -n btrfs subvolume delete "$ip" &>/dev/null || btrfs subvolume delete "$ip" &>/dev/null || sudo -n rm -rf "$ip" 2>/dev/null || rm -rf "$ip" 2>/dev/null || true; }
                local sdir2; sdir2=$(_snap_dir "$cid")
                if [[ -d "$sdir2" ]]; then
                    for _sf in "$sdir2"/*/; do [[ -d "$_sf" ]] && _delete_snap "$_sf" || true; done
                    rm -rf "$sdir2" 2>/dev/null || true
                fi
                _set_st "$cid" installed false
                pause "'$name' uninstalled. Persistent storage kept." ;;
            "${L[ct_update]}")   _guard_install || continue; _run_job update "$cid" ;;
            "${L[ct_exposure]}"*)
                local _new_exp; _new_exp=$(_exposure_next "$cid")
                _exposure_set "$cid" "$_new_exp"
                tmux_up "$(tsess "$cid")" && _exposure_apply "$cid"
                pause "$(printf "Port exposure set to: %b\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network" "$(_exposure_label "$_new_exp")")" ;;
            "${L[ct_remove]}")
                confirm "$(printf "Remove container entry '%s'?\n\n  No installation or storage files deleted." "$name")" || continue
                rm -f "$CACHE_DIR/sd_size/$cid" "$CACHE_DIR/gh_tag/$cid" "$CACHE_DIR/gh_tag/$cid.inst" 2>/dev/null || true
                rm -rf "$CONTAINERS_DIR/$cid" 2>/dev/null
                _cleanup_upd_tmps; pause "'$name' removed."; return ;;
            *"⬆  Updates"*)
                [[ "${#_UPD_ITEMS[@]}" -eq 0 ]] && continue
                # Build submenu with the update items
                local _upd_menu_items=()
                for _umi in "${_UPD_ITEMS[@]}"; do _upd_menu_items+=("$_umi"); done
                _menu "Update — $name" "${_upd_menu_items[@]}" || continue
                local _upd_reply_clean; _upd_reply_clean=$(printf '%s' "$REPLY" | _trim_s)
                for ui in "${!_UPD_ITEMS[@]}"; do
                    local _ic; _ic=$(printf '%s' "${_UPD_ITEMS[$ui]}" | _trim_s)
                    if [[ "$_upd_reply_clean" == "$_ic" ]]; then
                        if [[ "${_UPD_IDX[$ui]}" == "__ubuntu__" ]]; then
                            _do_ubuntu_update "$cid"; continue 2
                        elif [[ "${_UPD_IDX[$ui]}" == "__pkgs__" ]]; then
                            _do_pkg_update "$cid"; continue 2
                        else
                            _do_blueprint_update "$cid" "${_UPD_IDX[$ui]}"; continue 2
                        fi
                    fi
                done ;;
            *)
                local _reply_clean; _reply_clean=$(printf '%s' "$REPLY" | _trim_s)
                for ui in "${!_UPD_ITEMS[@]}"; do
                    local _ic; _ic=$(printf '%s' "${_UPD_ITEMS[$ui]}" | _trim_s)
                    if [[ "$_reply_clean" == "$_ic" ]]; then
                        if [[ "${_UPD_IDX[$ui]}" == "__ubuntu__" ]]; then
                            _do_ubuntu_update "$cid"; continue 2
                        elif [[ "${_UPD_IDX[$ui]}" == "__pkgs__" ]]; then
                            _do_pkg_update "$cid"; continue 2
                        else
                            _do_blueprint_update "$cid" "${_UPD_IDX[$ui]}"; continue 2
                        fi
                    fi
                done
                printf '%s' "$REPLY" | grep -q '^──' && continue
                for ai in "${!action_labels[@]}"; do
                    [[ "$REPLY" != "${action_labels[$ai]}" ]] && continue
                    local ip; ip=$(_cpath "$cid")
                    local dsl="${action_dsls[$ai]}"
                    local arunner; arunner=$(mktemp "$TMP_DIR/.sd_action_XXXXXX.sh")
                    local sname="sdAction_${cid}_${ai}"
                    {
                        printf '#!/usr/bin/env bash\n'
                        _env_exports "$cid" "$ip"
                        printf 'cd "$CONTAINER_ROOT"\n'

                        # Determine if this is new DSL (contains |) or legacy bash block
                        if printf '%s' "$dsl" | grep -q '|'; then
                            # ── DSL action: parse pipe-separated segments ──
                            # Segments:
                            #   prompt: "text"          → read input, bind to {input}
                            #   select: cmd [--col N] [--skip-header]  → fzf pick, bind to {selection}
                            #   bare cmd [with {input} or {selection}] → execute
                            local _input_var="" _select_var=""
                            local seg_idx=0
                            # Split on | — use printf trick to avoid subshell
                            local IFS_BAK="$IFS"; IFS='|'
                            local segs=()
                            while IFS= read -r seg; do
                                seg=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                                [[ -n "$seg" ]] && segs+=("$seg")
                            done <<< "$(printf '%s' "$dsl" | tr '|' '\n')"
                            IFS="$IFS_BAK"

                            for seg in "${segs[@]}"; do
                                if [[ "$seg" == prompt:* ]]; then
                                    # prompt: "text"
                                    local ptxt; ptxt=$(printf '%s' "$seg" | sed 's/^prompt:[[:space:]]*//' | tr -d '"'"'")
                                    printf 'printf "%s\\n> "; read -r _sd_input\n' "$ptxt"
                                    printf '[[ -z "$_sd_input" ]] && exit 0\n'

                                elif [[ "$seg" == select:* ]]; then
                                    # select: cmd [--skip-header] [--col N]
                                    local scmd; scmd=$(printf '%s' "$seg" | sed 's/^select:[[:space:]]*//')
                                    local skip_hdr=0 col_n=1
                                    [[ "$scmd" == *"--skip-header"* ]] && skip_hdr=1
                                    if [[ "$scmd" =~ --col[[:space:]]+([0-9]+) ]]; then col_n="${BASH_REMATCH[1]}"; fi
                                    scmd=$(printf '%s' "$scmd" | sed 's/--skip-header//g;s/--col[[:space:]]*[0-9]*//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                                    # Auto-prefix relative command path
                                    local scmd_bin="${scmd%% *}" scmd_rest="${scmd#* }"
                                    [[ "$scmd_rest" == "$scmd_bin" ]] && scmd_rest=""
                                    local scmd_bin_p; scmd_bin_p=$(_cr_prefix "$scmd_bin")
                                    local full_scmd="${scmd_bin_p}${scmd_rest:+ $scmd_rest}"
                                    printf '_sd_list=$(%s 2>/dev/null)\n' "$full_scmd"
                                    printf '[[ -z "$_sd_list" ]] && { printf "Nothing found.\\n"; exit 0; }\n'
                                    if [[ $skip_hdr -eq 1 ]]; then
                                        printf '_sd_list=$(printf "%%s" "$_sd_list" | tail -n +2)\n'
                                    fi
                                    printf '_sd_selection=$(printf "%%s\\n" "$_sd_list" | awk '"'"'{print $%d}'"'"' | fzf --ansi --no-sort --prompt="  ❯ " --pointer="▶" --height=40%% --reverse --border=rounded --margin=1,2 --no-info 2>/dev/null) || exit 0\n' "$col_n"
                                    printf '[[ -z "$_sd_selection" ]] && exit 0\n'

                                else
                                    # Bare command — substitute {input} and {selection}
                                    local cmd_out; cmd_out="$seg"
                                    # Auto-prefix relative command
                                    local cmd_bin="${cmd_out%% *}" cmd_rest="${cmd_out#* }"
                                    [[ "$cmd_rest" == "$cmd_bin" ]] && cmd_rest=""
                                    local cmd_bin_p; cmd_bin_p=$(_cr_prefix "$cmd_bin")
                                    cmd_out="${cmd_bin_p}${cmd_rest:+ $cmd_rest}"
                                    # Substitute placeholders
                                    cmd_out=$(printf '%s' "$cmd_out" | sed 's/{input}/$_sd_input/g; s/{selection}/$_sd_selection/g')
                                    printf '%s\n' "$cmd_out"
                                fi
                            done
                        else
                            # ── Legacy bash block ──
                            printf '%s\n' "$dsl"
                        fi
                    } > "$arunner"; chmod +x "$arunner"
                    if tmux has-session -t "$sname" 2>/dev/null; then
                        pause "$(printf "Action '%s' is still running.\n\n  Press %s to detach." "${action_labels[$ai]}" "${KB[tmux_detach]}")"
                        tmux switch-client -t "$sname" 2>/dev/null || true
                    else
                        tmux new-session -d -s "$sname" \
                            "bash $(printf '%q' "$arunner"); rm -f $(printf '%q' "$arunner"); printf '\n\033[0;32m══ Done ══\033[0m\n'; printf 'Press Enter to return...\n'; read -rs _; tmux switch-client -t simpleDocker 2>/dev/null || true; tmux kill-session -t \"$sname\" 2>/dev/null || true" 2>/dev/null
                        tmux set-option -t "$sname" detach-on-destroy off 2>/dev/null || true
                        pause "$(printf "Starting '%s'...\n\n  Press %s to detach." "${action_labels[$ai]}" "${KB[tmux_detach]}")"
                        tmux switch-client -t "$sname" 2>/dev/null || true
                    fi
                    break
                done ;;
        esac
    done
}

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
