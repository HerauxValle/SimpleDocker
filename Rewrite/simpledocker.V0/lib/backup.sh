# lib/backup.sh — Snapshot/backup engine: _rand_snap_id, _snap_meta_set, _delete_snap,
#                  _rotate_and_snapshot, _do_restore_snap, _create_manual_backup,
#                  _clone_container, _container_backups_menu, _manage_backups_menu
# Sourced by main.sh — do NOT run directly

_rand_snap_id() {
    local sdir="$1" id
    while true; do
        id=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
        [[ ! -d "$sdir/$id" ]] && printf '%s' "$id" && return
    done
}
_snap_meta_get() { local f="$1/$2.meta"; [[ -f "$f" ]] && grep -m1 "^$3=" "$f" 2>/dev/null | cut -d= -f2- || printf ''; }
_snap_meta_set() {
    local sdir="$1" snap_id="$2"; shift 2
    local f="$sdir/$snap_id.meta"; local tmp; tmp=$(mktemp)
    [[ -f "$f" ]] && cp "$f" "$tmp" || true
    for pair in "$@"; do
        local k="${pair%%=*}" v="${pair#*=}"
        sed -i "/^${k}=/d" "$tmp" 2>/dev/null || true
        printf '%s=%s\n' "$k" "$v" >> "$tmp"
    done
    mv "$tmp" "$f" 2>/dev/null || true
}
_delete_snap() {
    local path="$1"; [[ -z "$path" || ! -d "$path" ]] && return 0
    btrfs property set "$path" ro false &>/dev/null || true
    btrfs subvolume delete "$path" &>/dev/null || rm -rf "$path" 2>/dev/null || true
}
_delete_backup() { local sdir="$1" snap_id="$2"; _delete_snap "$sdir/$snap_id"; rm -f "$sdir/$snap_id.meta" 2>/dev/null || true; }

_rotate_and_snapshot() {
    local cid="$1" install_path; install_path=$(_cpath "$cid")
    [[ -z "$install_path" || ! -d "$install_path" ]] && return 1
    local sdir; sdir=$(_snap_dir "$cid"); mkdir -p "$sdir" 2>/dev/null
    local auto_ids=()
    for f in "$sdir"/*.meta; do
        [[ -f "$f" ]] || continue
        local fid; fid=$(basename "$f" .meta)
        [[ "$(_snap_meta_get "$sdir" "$fid" type)" == "auto" ]] && auto_ids+=("$fid")
    done
    while [[ ${#auto_ids[@]} -ge 2 ]]; do
        _delete_backup "$sdir" "${auto_ids[0]}"; auto_ids=("${auto_ids[@]:1}")
    done
    local new_id; new_id=$(_rand_snap_id "$sdir")
    local ts; ts=$(date '+%Y-%m-%d %H:%M')
    btrfs subvolume snapshot -r "$install_path" "$sdir/$new_id" &>/dev/null || return 1
    _snap_meta_set "$sdir" "$new_id" "type=auto" "ts=$ts"
}

_do_restore_snap() {
    local cid="$1" snap_path="$2" snap_label="$3"
    local name; name=$(_cname "$cid"); local install_path; install_path=$(_cpath "$cid")
    confirm "$(printf "Restore '%s' from '%s'?\n\n  Current installation will be overwritten.\n  Persistent storage profiles are untouched." "$name" "$snap_label")" || return 0
    btrfs property set "$snap_path" ro false &>/dev/null || true
    btrfs subvolume delete "$install_path" &>/dev/null || rm -rf "$install_path" 2>/dev/null
    if ! btrfs subvolume snapshot "$snap_path" "$install_path" &>/dev/null; then
        cp -a "$snap_path/." "$install_path/" 2>/dev/null
    fi
    btrfs property set "$snap_path" ro true &>/dev/null || true
    pause "$(printf "Restored '%s' from '%s'." "$name" "$snap_label")"
}

_prompt_backup_name() {
    local sdir="$1"; local default_id; default_id=$(_rand_snap_id "$sdir")
    while true; do
        local input
        if ! finput "$(printf 'Backup name:\n  (leave blank for random: %s)' "$default_id")"; then
            input="$default_id"
        else
            input="${FINPUT_RESULT//[^a-zA-Z0-9_\-]/}"
            [[ -z "$input" ]] && input="$default_id"
        fi
        [[ -d "$sdir/$input" ]] && { pause "A backup named '$input' already exists."; continue; }
        printf '%s' "$input"; return 0
    done
}

_create_manual_backup() {
    local cid="$1" name; name=$(_cname "$cid")
    local install_path; install_path=$(_cpath "$cid")
    [[ -z "$install_path" || ! -d "$install_path" ]] && { pause "No installation found for '$name'."; return 1; }
    local sdir; sdir=$(_snap_dir "$cid"); mkdir -p "$sdir" 2>/dev/null
    local snap_id; snap_id=$(_prompt_backup_name "$sdir"); [[ -z "$snap_id" ]] && return 1
    local ts; ts=$(date '+%Y-%m-%d %H:%M')
    if ! btrfs subvolume snapshot -r "$install_path" "$sdir/$snap_id" &>/dev/null; then
        cp -a "$install_path" "$sdir/$snap_id" 2>/dev/null || { pause "Snapshot failed."; return 1; }
    fi
    _snap_meta_set "$sdir" "$snap_id" "type=manual" "ts=$ts"
    pause "$(printf "Backup '%s' created." "$snap_id")"
}

# ── Clone container ───────────────────────────────────────────────
# Instant CoW btrfs snapshot of the installation dir + copied metadata.
# The clone is a new independent container — changes don't affect original.
_clone_from_snap() {
    local src_cid="$1" snap_path="$2" snap_label="$3"
    local src_name; src_name=$(_cname "$src_cid")
    [[ ! -d "$snap_path" ]] && { pause "Snapshot not found."; return 1; }
    finput "Name for the clone:" || return 1
    local clone_name="$FINPUT_RESULT"
    [[ -z "$clone_name" ]] && { pause "No name given."; return 1; }
    local clone_cid; clone_cid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -dc 'a-z0-9' | head -c 8 || tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
    local clone_dir="$CONTAINERS_DIR/$clone_cid"
    local clone_path="$INSTALLATIONS_DIR/$clone_cid"
    mkdir -p "$clone_dir" 2>/dev/null
    cp "$CONTAINERS_DIR/$src_cid/service.json" "$clone_dir/service.json" 2>/dev/null || true
    cp "$CONTAINERS_DIR/$src_cid/state.json"   "$clone_dir/state.json"   2>/dev/null || true
    [[ -f "$CONTAINERS_DIR/$src_cid/resources.json" ]] && cp "$CONTAINERS_DIR/$src_cid/resources.json" "$clone_dir/resources.json" 2>/dev/null || true
    jq --arg n "$clone_name" --arg p "$(basename "$clone_path")" '.name=$n | .install_path=$p' \
        "$clone_dir/state.json" > "$clone_dir/state.json.tmp" 2>/dev/null \
        && mv "$clone_dir/state.json.tmp" "$clone_dir/state.json"
    if btrfs subvolume snapshot "$snap_path" "$clone_path" &>/dev/null; then
        btrfs property set "$clone_path" ro false &>/dev/null || true
        pause "$(printf "Cloned '%s' (%s) → '%s'" "$src_name" "$snap_label" "$clone_name")"
    else
        cp -a "$snap_path/." "$clone_path/" 2>/dev/null \
            || { rm -rf "$clone_dir" "$clone_path" 2>/dev/null; pause "Clone failed."; return 1; }
        pause "$(printf "Cloned '%s' (%s) → '%s' (plain copy)" "$src_name" "$snap_label" "$clone_name")"
    fi
}

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

#  PERSISTENT STORAGE
_stor_path()          { printf '%s/%s' "$STORAGE_DIR" "$1"; }
_stor_meta_path()     { printf '%s/.sd_meta.json' "$(_stor_path "$1")"; }
