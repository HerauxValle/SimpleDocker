# lib/encryption.sh — LUKS2 helpers, verified system, key slots, auth keyfile,
#                      encryption menu (_enc_menu)
# Sourced by main.sh — do NOT run directly

# ── LUKS2 helpers ─────────────────────────────────────────────────
_luks_mapper()  { printf 'sd_%s' "$(basename "${1%.img}" | tr -dc 'a-zA-Z0-9_')"; }
_luks_dev()     { printf '/dev/mapper/%s' "$(_luks_mapper "$1")"; }
_luks_is_open() { [[ -b "$(_luks_dev "$1")" ]]; }
_img_is_luks()  { sudo -n cryptsetup isLuks "$1" 2>/dev/null; }

# Slot 0 auto-unlock: try SD_VERIFICATION_CIPHER first, prompt on fail
_luks_open() {
    local img="$1" mapper pass attempts=0
    mapper=$(_luks_mapper "$img")
    _luks_is_open "$img" && return 0
    # Try each method in SD_UNLOCK_ORDER
    local _method
    for _method in $SD_UNLOCK_ORDER; do
        case "$_method" in
            verified_system)
                printf '%s' "$SD_VERIFICATION_CIPHER" | sudo -n cryptsetup open --key-file=- "$img" "$mapper" &>/dev/null \
                    && return 0 ;;
            default_keyword)
                printf '%s' "$SD_DEFAULT_KEYWORD" | sudo -n cryptsetup open --key-file=- "$img" "$mapper" &>/dev/null \
                    && return 0 ;;
            prompt)
                while [[ $attempts -lt 3 ]]; do
                    clear
                    printf '\n  \033[1m── simpleDocker ──\033[0m\n'
                    printf '  \033[2m%s is encrypted. Enter passphrase.\033[0m\n\n' "$(basename "$img")"
                    printf '  \033[1mPassphrase:\033[0m '
                    IFS= read -rs pass; printf '\n\n'
                    if printf '%s' "$pass" | sudo -n cryptsetup open --key-file=- "$img" "$mapper" &>/dev/null; then
                        clear; return 0
                    fi
                    printf '  \033[31mWrong passphrase.\033[0m\n'; (( attempts++ ))
                done
                clear; return 1 ;;
        esac
    done
    clear; return 1
}
_luks_close() { _luks_is_open "$1" && sudo -n cryptsetup close "$(_luks_mapper "$1")" &>/dev/null || true; }

# ── Encryption menu ───────────────────────────────────────────────
_enc_auto_unlock_enabled() {
    # True if this machine's verification cipher works (verified system slot active)
    printf '%s' "$SD_VERIFICATION_CIPHER" | sudo -n cryptsetup open \
        --test-passphrase --key-file=- "$IMG_PATH" &>/dev/null
}

_enc_system_agnostic_enabled() {
    # True if slot 1 (SD_DEFAULT_KEYWORD) is active
    printf '%s' "$SD_DEFAULT_KEYWORD" | sudo -n cryptsetup open \
        --test-passphrase --key-slot 1 --key-file=- "$IMG_PATH" &>/dev/null
}

# Path to the stored auth keyfile inside the mounted image
_enc_authkey_path() { printf '%s' "$MNT_DIR/.sd/auth.key"; }

# Path to file storing which LUKS slot the auth keyfile occupies
_enc_authkey_slot_file() { printf '%s' "$MNT_DIR/.sd/auth.slot"; }

# ── Verified system helpers ───────────────────────────────────
_enc_verified_dir()  { printf '%s' "$MNT_DIR/.sd/verified"; }
_enc_verified_id()   { sha256sum /etc/machine-id 2>/dev/null | cut -c1-8; }
_enc_verified_pass() { sha256sum /etc/machine-id 2>/dev/null | cut -c1-32 || printf '%s' "simpledocker_fallback"; }
_enc_verified_path() { printf '%s/%s' "$(_enc_verified_dir)" "$(_enc_verified_id)"; }
_enc_is_verified()   { [[ -f "$(_enc_verified_path)" ]]; }

# Get slot stored in cache file for a given 8-char ID (line 2)
_enc_vs_slot()    { local _f="$(_enc_verified_dir)/$1"; [[ -f "$_f" ]] && sed -n '2p' "$_f" 2>/dev/null || printf ''; }
# Get hostname stored in cache file for a given 8-char ID (line 1)
_enc_vs_hostname(){ local _f="$(_enc_verified_dir)/$1"; [[ -f "$_f" ]] && sed -n '1p' "$_f" 2>/dev/null || printf "$1"; }
# Get derived pass stored in cache file for a given 8-char ID (line 3)
_enc_vs_pass()    { local _f="$(_enc_verified_dir)/$1"; [[ -f "$_f" ]] && sed -n '3p' "$_f" 2>/dev/null || printf ''; }

# Write/update cache file: line1=hostname line2=slot line3=derived_pass
_enc_vs_write() {
    local _id="$1" _slot="$2"
    local _vdir; _vdir=$(_enc_verified_dir)
    mkdir -p "$_vdir" 2>/dev/null
    printf '%s
%s
%s
' "$(cat /etc/hostname 2>/dev/null | tr -d "[:space:]" || printf "unknown")" "$_slot" "$(_enc_verified_pass)" > "$_vdir/$_id"
}

# Returns lowest free slot in SD_LUKS_KEY_SLOT_MIN..SD_LUKS_KEY_SLOT_MAX, or empty if full
_enc_free_slot() {
    local _dump; _dump=$(sudo -n cryptsetup luksDump "$IMG_PATH" 2>/dev/null)
    local _s
    for (( _s=SD_LUKS_KEY_SLOT_MIN; _s<=SD_LUKS_KEY_SLOT_MAX; _s++ )); do
        printf '%s' "$_dump" | grep -qE "^\s+$_s: luks2" || { printf '%s' "$_s"; return 0; }
    done
    return 1
}

# Count used slots in user range (SD_LUKS_KEY_SLOT_MIN..SD_LUKS_KEY_SLOT_MAX)
_enc_slots_used() {
    sudo -n cryptsetup luksDump "$IMG_PATH" 2>/dev/null         | grep -oP '^\s+\K[0-9]+(?=: luks2)'         | awk -v mn="$SD_LUKS_KEY_SLOT_MIN" -v mx="$SD_LUKS_KEY_SLOT_MAX"               '$1+0>=mn && $1+0<=mx' | wc -l
}

# Returns the slot number the auth keyfile is in (or empty)
_enc_authkey_slot() {
    local _sf; _sf=$(_enc_authkey_slot_file)
    [[ -f "$_sf" ]] && cat "$_sf" 2>/dev/null || printf ''
}

# True if a valid auth keyfile exists and works against the image
_enc_authkey_valid() {
    local _kf; _kf=$(_enc_authkey_path)
    [[ -f "$_kf" ]] || return 1
    local _aslot; _aslot=$(_enc_authkey_slot)
    if [[ -n "$_aslot" ]]; then
        sudo -n cryptsetup open --test-passphrase --key-slot "$_aslot" --key-file "$_kf" "$IMG_PATH" &>/dev/null
    else
        sudo -n cryptsetup open --test-passphrase --key-file "$_kf" "$IMG_PATH" &>/dev/null
    fi
}

# Generate a new auth keyfile (random 64 bytes, cheapest LUKS params) and add it
# as the lowest free slot >= 1, authorizing with the provided key-file path.
# Usage: _enc_authkey_create <auth_keyfile_path>
_enc_authkey_create() {
    local _auth_kf="$1"
    local _kf; _kf=$(_enc_authkey_path)
    mkdir -p "$(dirname "$_kf")" 2>/dev/null
    # Generate random keyfile
    dd if=/dev/urandom bs=64 count=1 2>/dev/null > "$_kf"
    chmod 600 "$_kf"
    # Auth keyfile always goes in slot 0
    sudo -n cryptsetup luksAddKey \
        --batch-mode \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
        --key-slot 0 \
        --key-file "$_auth_kf" \
        "$IMG_PATH" "$_kf" &>/dev/null
    local _arc=$?
    [[ $_arc -eq 0 ]] && printf '0' > "$(_enc_authkey_slot_file)"
    return $_arc
}

_enc_menu() {
    while true; do
        local _auto _auto_label _agnostic _agnostic_label
        if _enc_auto_unlock_enabled;       then _auto=true;     _auto_label="${GRN}Enabled${NC}"
        else                                    _auto=false;    _auto_label="${RED}Disabled${NC}"
        fi
        if _enc_system_agnostic_enabled;   then _agnostic=true;  _agnostic_label="${GRN}Enabled${NC}"
        else                                    _agnostic=false; _agnostic_label="${RED}Disabled${NC}"
        fi
        local _nf="$MNT_DIR/.sd/keyslot_names.json"
        local _authslot; _authslot=$(_enc_authkey_slot)
        local _vdir; _vdir=$(_enc_verified_dir)
        local _vid;  _vid=$(_enc_verified_id)
        local _slots_used; _slots_used=$(_enc_slots_used)
        local _slots_total=$(( SD_LUKS_KEY_SLOT_MAX - SD_LUKS_KEY_SLOT_MIN + 1 ))

        # Collect verified system IDs from cache
        local _vs_ids=()
        if [[ -d "$_vdir" ]]; then
            while IFS= read -r -d '' _vf; do
                _vs_ids+=("$(basename "$_vf")")
            done < <(find "$_vdir" -maxdepth 1 -type f -print0 2>/dev/null)
        fi

        # Collect active LUKS slots in user range; split into passkeys vs verified
        local dump; dump=$(sudo -n cryptsetup luksDump "$IMG_PATH" 2>/dev/null)
        local _vs_slot_set=()
        for _vsid in "${_vs_ids[@]}"; do
            local _vslot; _vslot=$(_enc_vs_slot "$_vsid")
            [[ -n "$_vslot" && "$_vslot" != "0" ]] && _vs_slot_set+=("$_vslot")
        done
        _is_vs_slot() { local _x; for _x in "${_vs_slot_set[@]}"; do [[ "$_x" == "$1" ]] && return 0; done; return 1; }

        local _key_lines=() _key_slots=()
        local _has_passkeys=false
        while IFS= read -r _line; do
            if [[ "$_line" =~ ^[[:space:]]+([0-9]+):\ luks2 ]]; then
                local _sid="${BASH_REMATCH[1]}"
                [[ "$_sid" == "0" ]] && continue
                [[ "$_sid" == "$_authslot" ]] && continue
                [[ "$_sid" -lt "$SD_LUKS_KEY_SLOT_MIN" ]] && continue   # reserved range (incl. slot 1 default keyword)
                _is_vs_slot "$_sid" && continue
                _has_passkeys=true
                local _sname; _sname=$(jq -r --arg s "$_sid" '.[$s] // empty' "$_nf" 2>/dev/null)
                [[ -z "$_sname" ]] && _sname="Key $_sid"
                _key_lines+=("$(printf " ${DIM}◈  %s  [s:%s]${NC}" "$_sname" "$_sid")")
                _key_slots+=("$_sid")
            fi
        done <<< "$dump"

        local _SEP_G _SEP_VS _SEP_K _SEP_NAV
        _SEP_G="$(  printf "${BLD}  ── General ─────────────────────────${NC}")"
        _SEP_VS="$( printf "${BLD}  ── Verified Systems ────────────────${NC}")"
        _SEP_K="$(  printf "${BLD}  ── Passkeys ────────────────────────${NC}")"
        _SEP_NAV="$(printf "${BLD}  ── Navigation ──────────────────────${NC}")"

        local lines=(
            "$_SEP_G"
            "$(printf " ${DIM}◈  System Agnostic: %b${NC}" "$_agnostic_label")"
            "$(printf " ${DIM}◈  Auto-Unlock: %b${NC}" "$_auto_label")"
            "$(printf " ${DIM}◈  Reset Auth Token${NC}")"
            "$_SEP_VS"
        )
        for _vsid in "${_vs_ids[@]}"; do
            local _vshost; _vshost=$(_enc_vs_hostname "$_vsid")
            local _vslot2; _vslot2=$(_enc_vs_slot "$_vsid")
            lines+=("$(printf " ${DIM}◈  %s  [vs:%s]${NC}" "$_vshost" "$_vsid")")
        done
        lines+=("$(printf " ${GRN}+  Verify this system${NC}")")
        lines+=("$_SEP_K")
        if [[ "$_has_passkeys" == false ]]; then
            lines+=("$(printf "${DIM}  (no passkeys added yet)${NC}")")
        else
            lines+=("${_key_lines[@]}")
        fi
        lines+=("$(printf " ${GRN}+  Add Key${NC}")")
        lines+=("$_SEP_NAV")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out; _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}── Manage Encryption ──${NC}  ${DIM}%s/%s slots${NC}" "$_slots_used" "$_slots_total")" \
            >"$_fzf_out" 2>/dev/null &
        local _pid=$!; printf '%s' "$_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_pid" 2>/dev/null; local _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "$sel" ]] && return
        local sc; sc=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*//')
        case "$sc" in
            *"${L[back]}"*|"") return ;;

            *"System Agnostic"*)
                if [[ "$_agnostic" == true ]]; then
                    # Disable: ensure at least one other unlock method exists
                    local _sa_vs_count=0
                    for _sa_vsid in "${_vs_ids[@]}"; do
                        local _sa_slot; _sa_slot=$(_enc_vs_slot "$_sa_vsid")
                        [[ -n "$_sa_slot" && "$_sa_slot" != "0" ]] && (( _sa_vs_count++ ))
                    done
                    if [[ "$_has_passkeys" == false && "$_sa_vs_count" -eq 0 ]]; then
                        pause "$(printf 'Cannot disable — no other unlock method exists.\nAdd a passkey or verify a system first.')"
                        continue
                    fi
                    confirm "Disable System Agnostic? This image will no longer open on unknown machines." || continue
                    local _tf_sa_kill; _tf_sa_kill=$(mktemp "$TMP_DIR/.sd_sakill_XXXXXX")
                    _enc_authkey_valid && cp "$(_enc_authkey_path)" "$_tf_sa_kill" || printf '%s' "$SD_DEFAULT_KEYWORD" > "$_tf_sa_kill"
                    sudo -n cryptsetup luksKillSlot --batch-mode --key-file "$_tf_sa_kill" "$IMG_PATH" 1 &>/dev/null
                    local _sa_rc=$?; rm -f "$_tf_sa_kill"; clear
                    [[ $_sa_rc -eq 0 ]] && pause "System Agnostic disabled." || pause "Failed."
                else
                    # Enable: add SD_DEFAULT_KEYWORD back to slot 1
                    if ! _enc_authkey_valid; then
                        pause "$(printf 'Auth keyfile missing or invalid.\nUse Reset Auth Token first.')"
                        continue
                    fi
                    local _tf_sa_auth; _tf_sa_auth=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
                    local _tf_sa_key;  _tf_sa_key=$(mktemp "$TMP_DIR/.sd_new_XXXXXX")
                    cp "$(_enc_authkey_path)" "$_tf_sa_auth"
                    printf '%s' "$SD_DEFAULT_KEYWORD" > "$_tf_sa_key"
                    sudo -n cryptsetup luksAddKey --batch-mode \
                        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
                        --key-slot 1 --key-file "$_tf_sa_auth" \
                        "$IMG_PATH" "$_tf_sa_key" &>/dev/null
                    local _sa_erc=$?; rm -f "$_tf_sa_auth" "$_tf_sa_key"; clear
                    [[ $_sa_erc -eq 0 ]] && pause "System Agnostic enabled." || pause "Failed."
                fi ;;

            *"Auto-Unlock"*)
                if [[ "$_auto" == true ]]; then
                    if [[ "$_has_passkeys" == false ]]; then
                        pause "$(printf 'No passkeys exist.\nAdd a passkey first,\nthen disable Auto-Unlock.')"
                        continue
                    fi
                    confirm "Disable Auto-Unlock? All verified system slots will be removed (cache kept)." || continue
                    clear
                    printf '\n  \033[1m── Disable Auto-Unlock ──\033[0m\n'
                    printf '  \033[2mRemoving verified system slots...\033[0m\n\n'
                    local _tf_dis; _tf_dis=$(mktemp "$TMP_DIR/.sd_dis_XXXXXX")
                    _enc_authkey_valid && cp "$(_enc_authkey_path)" "$_tf_dis" || printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_dis"
                    local _dis_ok=true
                    for _vsid in "${_vs_ids[@]}"; do
                        local _dslot; _dslot=$(_enc_vs_slot "$_vsid")
                        [[ -z "$_dslot" || "$_dslot" == "0" ]] && continue
                        sudo -n cryptsetup luksKillSlot --batch-mode --key-file "$_tf_dis" "$IMG_PATH" "$_dslot" &>/dev/null || _dis_ok=false
                        local _dhost; _dhost=$(_enc_vs_hostname "$_vsid")
                        local _dpass; _dpass=$(_enc_vs_pass "$_vsid")
                        printf '%s\n%s\n%s\n' "$_dhost" "" "$_dpass" > "$_vdir/$_vsid"
                    done
                    rm -f "$_tf_dis"; clear
                    "$_dis_ok" && pause "Auto-Unlock disabled." || pause "Failed (some slots may remain)."
                else
                    if ! _enc_authkey_valid; then
                        pause "$(printf 'Auth keyfile missing or invalid.\nUse Reset Auth first.')"
                        continue
                    fi
                    clear
                    printf '\n  \033[1m── Enable Auto-Unlock ──\033[0m\n'
                    printf '  \033[2mRe-adding verified system keys...\033[0m\n\n'
                    local _tf_en_auth; _tf_en_auth=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
                    cp "$(_enc_authkey_path)" "$_tf_en_auth"
                    local _en_ok=true _en_count=0
                    for _vsid in "${_vs_ids[@]}"; do
                        local _vspass; _vspass=$(_enc_vs_pass "$_vsid")
                        [[ -z "$_vspass" ]] && continue
                        local _free_s; _free_s=$(_enc_free_slot)
                        if [[ -z "$_free_s" ]]; then
                            pause "$(printf 'No free slots (slots %s-%s full).' "$SD_LUKS_KEY_SLOT_MIN" "$SD_LUKS_KEY_SLOT_MAX")"
                            _en_ok=false; break
                        fi
                        local _tf_vsp; _tf_vsp=$(mktemp "$TMP_DIR/.sd_vsp_XXXXXX")
                        printf '%s' "$_vspass" > "$_tf_vsp"
                        sudo -n cryptsetup luksAddKey --batch-mode \
                            --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
                            --key-slot "$_free_s" --key-file "$_tf_en_auth" \
                            "$IMG_PATH" "$_tf_vsp" &>/dev/null
                        if [[ $? -eq 0 ]]; then
                            local _vshost4; _vshost4=$(_enc_vs_hostname "$_vsid")
                            printf '%s\n%s\n%s\n' "$_vshost4" "$_free_s" "$_vspass" > "$_vdir/$_vsid"
                            (( _en_count++ ))
                        else
                            _en_ok=false
                        fi
                        rm -f "$_tf_vsp"
                    done
                    rm -f "$_tf_en_auth"; clear
                    if "$_en_ok"; then
                        [[ $_en_count -eq 0 ]] \
                            && pause "No verified systems to restore. Use '+ Verify this system'." \
                            || pause "$(printf 'Auto-Unlock enabled (%s system(s) restored).' "$_en_count")"
                    else
                        pause "Partially failed — some systems may not have been restored."
                    fi
                fi ;;

            *"Reset Auth Token"*)
                clear
                printf '\n  \033[1m── Reset Auth ──\033[0m\n'
                printf '  \033[2mEnter any existing passphrase to authorize.\033[0m\n\n'
                printf '  \033[1mPassphrase:\033[0m '
                local _ra_pass; IFS= read -rs _ra_pass; printf '\n\n'; clear
                printf '\n  \033[1m── Reset Auth ──\033[0m\n'
                printf '  \033[2mGenerating auth keyfile, please wait...\033[0m\n\n'
                local _tf_ra; _tf_ra=$(mktemp "$TMP_DIR/.sd_ra_XXXXXX")
                printf '%s' "$_ra_pass" > "$_tf_ra"
                local _old_kf; _old_kf=$(_enc_authkey_path)
                if [[ -f "$_old_kf" ]] && sudo -n cryptsetup open \
                        --test-passphrase --key-file "$_old_kf" "$IMG_PATH" &>/dev/null; then
                    sudo -n cryptsetup luksKillSlot --batch-mode \
                        --key-file "$_tf_ra" "$IMG_PATH" 0 &>/dev/null || true
                fi
                rm -f "$_old_kf"
                _enc_authkey_create "$_tf_ra"
                local _rrc=$?; rm -f "$_tf_ra"; clear
                [[ $_rrc -eq 0 ]] && pause "Auth keyfile reset." || pause "Failed — wrong passphrase?" ;;

            *"Verify this system"*)
                if _enc_is_verified; then
                    local _my_slot; _my_slot=$(_enc_vs_slot "$_vid")
                    if [[ -n "$_my_slot" && "$_my_slot" != "0" ]]; then
                        pause "$(printf 'Already verified: %s (slot %s).' "$(cat /etc/hostname 2>/dev/null | tr -d "[:space:]" || printf "unknown")" "$_my_slot")"
                    else
                        pause "$(printf 'System cached but Auto-Unlock is disabled.\nEnable Auto-Unlock to activate it.')"
                    fi
                    continue
                fi
                local _free_vs; _free_vs=$(_enc_free_slot)
                if [[ "$_auto" == true && -z "$_free_vs" ]]; then
                    pause "$(printf 'No free slots (slots %s-%s full).' "$SD_LUKS_KEY_SLOT_MIN" "$SD_LUKS_KEY_SLOT_MAX")"
                    continue
                fi
                if ! _enc_authkey_valid; then
                    pause "$(printf 'Auth keyfile missing or invalid.\nUse Reset Auth first.')"
                    continue
                fi
                if [[ "$_auto" == true ]]; then
                    local _tf_vs_auth; _tf_vs_auth=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
                    local _tf_vs_new;  _tf_vs_new=$(mktemp "$TMP_DIR/.sd_new_XXXXXX")
                    cp "$(_enc_authkey_path)" "$_tf_vs_auth"
                    printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_vs_new"
                    sudo -n cryptsetup luksAddKey --batch-mode \
                        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
                        --key-slot "$_free_vs" --key-file "$_tf_vs_auth" \
                        "$IMG_PATH" "$_tf_vs_new" &>/dev/null
                    local _vsrc=$?; rm -f "$_tf_vs_auth" "$_tf_vs_new"; clear
                    if [[ $_vsrc -eq 0 ]]; then
                        _enc_vs_write "$_vid" "$_free_vs"
                        pause "$(printf 'Verified: %s (slot %s, auto-unlock active).' "$(cat /etc/hostname 2>/dev/null | tr -d "[:space:]" || printf "unknown")" "$_free_vs")"
                    else
                        pause "Failed to add key slot."
                    fi
                else
                    _enc_vs_write "$_vid" ""
                    pause "$(printf 'Cached: %s (Auto-Unlock disabled — enable to activate).' "$(cat /etc/hostname 2>/dev/null | tr -d "[:space:]" || printf "unknown")")"
                fi ;;

            *"[vs:"*)
                local _sel_vsid; _sel_vsid=$(printf '%s' "$sc" | grep -o '\[vs:[a-f0-9]*\]' | sed 's/\[vs://;s/\]//')
                [[ -z "$_sel_vsid" ]] && continue
                local _sel_vshost; _sel_vshost=$(_enc_vs_hostname "$_sel_vsid")
                local _sel_vslot; _sel_vslot=$(_enc_vs_slot "$_sel_vsid")
                local _vs_action
                _vs_action=$(printf 'Unauthorize\nCancel\n' \
                    | fzf "${FZF_BASE[@]}" \
                      --header="$(printf "${BLD}── %s (%s) ──${NC}" "$_sel_vshost" "$_sel_vsid")" \
                      2>/dev/null | _trim_s)
                case "$_vs_action" in
                    Unauthorize)
                        if [[ "$_sel_vsid" == "$_vid" && "$_auto" == true && "$_has_passkeys" == false ]]; then
                            local _remaining_vs=0
                            for _chk_id in "${_vs_ids[@]}"; do
                                [[ "$_chk_id" == "$_sel_vsid" ]] && continue
                                local _chk_slot; _chk_slot=$(_enc_vs_slot "$_chk_id")
                                [[ -n "$_chk_slot" && "$_chk_slot" != "0" ]] && (( _remaining_vs++ ))
                            done
                            if [[ $_remaining_vs -eq 0 ]]; then
                                pause "$(printf 'Cannot unauthorize — this is the only unlock method.\nAdd a passkey first.')"
                                continue
                            fi
                        fi
                        confirm "$(printf 'Unauthorize %s?' "$_sel_vshost")" || continue
                        clear
                        printf '\n  \033[1m── Unauthorize ──\033[0m\n'
                        printf '  \033[2mRemoving...\033[0m\n\n'
                        local _unauth_ok=true
                        if [[ -n "$_sel_vslot" && "$_sel_vslot" != "0" ]]; then
                            local _tf_unauth; _tf_unauth=$(mktemp "$TMP_DIR/.sd_unauth_XXXXXX")
                            _enc_authkey_valid \
                                && cp "$(_enc_authkey_path)" "$_tf_unauth" \
                                || printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_unauth"
                            sudo -n cryptsetup luksKillSlot --batch-mode \
                                --key-file "$_tf_unauth" "$IMG_PATH" "$_sel_vslot" &>/dev/null \
                                || _unauth_ok=false
                            rm -f "$_tf_unauth"
                        fi
                        rm -f "$_vdir/$_sel_vsid"; clear
                        "$_unauth_ok" && pause "Unauthorize complete." || pause "Failed to remove slot (cache removed)." ;;
                esac ;;

            *"[s:"*)
                local _sn; _sn=$(printf '%s' "$sc" | grep -o '\[s:[0-9]*\]' | sed 's/\[s://;s/\]//')
                [[ -z "$_sn" ]] && continue
                local _cur_name; _cur_name=$(jq -r --arg s "$_sn" '.[$s] // empty' "$_nf" 2>/dev/null)
                [[ -z "$_cur_name" ]] && _cur_name="Key $_sn"
                local action
                action=$(printf 'Rename\nRemove\nCancel\n' \
                    | fzf "${FZF_BASE[@]}" \
                      --header="$(printf "${BLD}── %s ──${NC}" "$_cur_name")" \
                      2>/dev/null | _trim_s)
                case "$action" in
                    Rename)
                        finput "$(printf 'New name for "%s":' "$_cur_name")" || continue
                        local _nn="${FINPUT_RESULT}"; [[ -z "$_nn" ]] && continue
                        local _cur2; _cur2=$(cat "$_nf" 2>/dev/null || printf '{}')
                        local _tmp2; _tmp2=$(mktemp "$TMP_DIR/.sd_kn_XXXXXX")
                        printf '%s' "$_cur2" | jq --arg s "$_sn" --arg n "$_nn" '.[$s] = $n' \
                            > "$_tmp2" 2>/dev/null && mv "$_tmp2" "$_nf" || rm -f "$_tmp2"
                        pause "Renamed to \"$_nn\"." ;;
                    Remove)
                        local _pk_count=${#_key_slots[@]}
                        local _vs_active_count=0
                        for _vsid2 in "${_vs_ids[@]}"; do
                            local _vs2slot; _vs2slot=$(_enc_vs_slot "$_vsid2")
                            [[ -n "$_vs2slot" && "$_vs2slot" != "0" ]] && (( _vs_active_count++ ))
                        done
                        if [[ "$_auto" == false && "$_pk_count" -le 1 ]]; then
                            pause "$(printf 'Cannot remove — Auto-Unlock is disabled.\nKeep at least one passkey\nor re-enable Auto-Unlock first.')"
                            continue
                        fi
                        if [[ "$_auto" == true && "$_pk_count" -le 1 && "$_vs_active_count" -eq 0 ]]; then
                            pause "$(printf 'Cannot remove — this is the only non-auto-unlock key.\nVerify a system or keep this key.')"
                            continue
                        fi
                        confirm "$(printf 'Remove key "%s"?' "$_cur_name")" || continue
                        clear
                        printf '\n  \033[1m── Remove Key ──\033[0m\n'
                        printf '  \033[2mRemoving key, please wait...\033[0m\n\n'
                        local _tf_rm; _tf_rm=$(mktemp "$TMP_DIR/.sd_rm_XXXXXX")
                        if _enc_authkey_valid; then
                            cp "$(_enc_authkey_path)" "$_tf_rm"
                        else
                            clear
                            printf '\n  \033[1m── Remove Key ──\033[0m\n\n'
                            printf '  \033[1mPassphrase for "%s":\033[0m ' "$_cur_name"
                            local _rp; IFS= read -rs _rp; printf '\n\n'
                            printf '%s' "$_rp" > "$_tf_rm"
                            clear; printf '\n  \033[1m── Remove Key ──\033[0m\n'
                            printf '  \033[2mRemoving key, please wait...\033[0m\n\n'
                        fi
                        sudo -n cryptsetup luksKillSlot \
                            --batch-mode --key-file "$_tf_rm" "$IMG_PATH" "$_sn" &>/dev/null
                        local _rmrc=$?; rm -f "$_tf_rm"; clear
                        if [[ $_rmrc -eq 0 ]]; then
                            local _kn_del; _kn_del=$(mktemp "$TMP_DIR/.sd_kn_del_XXXXXX")
                            jq --arg s "$_sn" 'del(.[$s])' "$_nf" > "$_kn_del" \
                                && mv "$_kn_del" "$_nf" 2>/dev/null || rm -f "$_kn_del"
                            pause "Key removed."
                        else
                            pause "Failed."
                        fi ;;
                esac ;;

            *"Add Key"*)
                local _free_k; _free_k=$(_enc_free_slot)
                if [[ -z "$_free_k" ]]; then
                    pause "$(printf 'No free slots (slots %s-%s full).' "$SD_LUKS_KEY_SLOT_MIN" "$SD_LUKS_KEY_SLOT_MAX")"
                    continue
                fi
                local _rname; _rname=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
                local _kname="$_rname"
                local _pbkdf="argon2id" _ram="262144" _threads="4" _iter="1000"
                local _cipher="aes-xts-plain64" _keybits="512" _hash="sha256" _sector="512"
                local _param_done=false
                while [[ "$_param_done" == false ]]; do
                    local _param_lines=(
                        "$(printf "${BLD}  ── Parameters ──────────────────────${NC}")"
                        "$(printf "  %-10s${CYN}%s${NC}" "name"     "$_kname")"
                        "$(printf "  %-10s${CYN}%s${NC}" "pbkdf"    "$_pbkdf")"
                        "$(printf "  %-10s${CYN}%s KiB${NC}" "ram"  "$_ram")"
                        "$(printf "  %-10s${CYN}%s${NC}" "threads"  "$_threads")"
                        "$(printf "  %-10s${CYN}%s${NC}" "iter-ms"  "$_iter")"
                        "$(printf "  %-10s${CYN}%s${NC}" "cipher"   "$_cipher")"
                        "$(printf "  %-10s${CYN}%s${NC}" "key-bits" "$_keybits")"
                        "$(printf "  %-10s${CYN}%s${NC}" "hash"     "$_hash")"
                        "$(printf "  %-10s${CYN}%s${NC}" "sector"   "$_sector")"
                        "$(printf "${BLD}  ── Navigation ──────────────────────${NC}")"
                        "$(printf "${GRN}▷  Continue${NC}")"
                        "$(printf "${RED}×  Cancel${NC}")"
                    )
                    local _po; _po=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
                    printf '%s\n' "${_param_lines[@]}" | fzf "${FZF_BASE[@]}" \
                        --header="$(printf "${BLD}── Encryption parameters ──${NC}\n${DIM}  Select a param to change it.${NC}")" \
                        >"$_po" 2>/dev/null &
                    local _ppid=$!; printf '%s' "$_ppid" > "$TMP_DIR/.sd_active_fzf_pid"
                    wait "$_ppid" 2>/dev/null; local _pfrc=$?
                    local _psel; _psel=$(cat "$_po" 2>/dev/null | _trim_s | _strip_ansi | sed 's/^[[:space:]]*//')
                    rm -f "$_po"
                    _sig_rc $_pfrc && { stty sane 2>/dev/null; continue; }
                    [[ $_pfrc -ne 0 || -z "$_psel" ]] && break
                    case "$_psel" in
                        *"Continue"*) _param_done=true ;;
                        *"Cancel"*)   break ;;
                        *"name"*)
                            finput "$(printf 'Key name (blank = %s):' "$_rname")" || continue
                            _kname="${FINPUT_RESULT:-$_rname}" ;;
                        *"pbkdf"*)
                            local _pv; _pv=$(printf 'argon2id\nargon2i\npbkdf2\n' \
                                | fzf "${FZF_BASE[@]}" --header="pbkdf" 2>/dev/null | _trim_s)
                            [[ -n "$_pv" ]] && _pbkdf="$_pv" ;;
                        *"ram"*)
                            finput "RAM in KiB (e.g. 262144 = 256MB):" || continue
                            [[ "$FINPUT_RESULT" =~ ^[0-9]+$ ]] && _ram="$FINPUT_RESULT" ;;
                        *"threads"*)
                            finput "Threads (e.g. 4):" || continue
                            [[ "$FINPUT_RESULT" =~ ^[0-9]+$ ]] && _threads="$FINPUT_RESULT" ;;
                        *"iter-ms"*)
                            finput "Iteration time in ms (e.g. 1000):" || continue
                            [[ "$FINPUT_RESULT" =~ ^[0-9]+$ ]] && _iter="$FINPUT_RESULT" ;;
                        *"cipher"*)
                            local _cv; _cv=$(printf 'aes-xts-plain64\nchacha20-poly1305\n' \
                                | fzf "${FZF_BASE[@]}" --header="cipher" 2>/dev/null | _trim_s)
                            [[ -n "$_cv" ]] && _cipher="$_cv" ;;
                        *"key-bits"*)
                            local _kv; _kv=$(printf '256\n512\n' \
                                | fzf "${FZF_BASE[@]}" --header="key-bits" 2>/dev/null | _trim_s)
                            [[ -n "$_kv" ]] && _keybits="$_kv" ;;
                        *"hash"*)
                            local _hv; _hv=$(printf 'sha256\nsha512\nsha1\n' \
                                | fzf "${FZF_BASE[@]}" --header="hash" 2>/dev/null | _trim_s)
                            [[ -n "$_hv" ]] && _hash="$_hv" ;;
                        *"sector"*)
                            local _sv2; _sv2=$(printf '512\n1024\n2048\n4096\n' \
                                | fzf "${FZF_BASE[@]}" --header="sector size" 2>/dev/null | _trim_s)
                            [[ -n "$_sv2" ]] && _sector="$_sv2" ;;
                    esac
                done
                [[ "$_param_done" == false ]] && continue
                clear
                printf '\n  \033[1m── Add Key: %s ──\033[0m\n\n' "$_kname"
                printf '  \033[1mNew passphrase:\033[0m '
                local _np1; IFS= read -rs _np1; printf '\n'
                printf '  \033[1mConfirm:\033[0m      '
                local _np2; IFS= read -rs _np2; printf '\n\n'
                [[ "$_np1" != "$_np2" || -z "$_np1" ]] && { clear; pause "Mismatch or empty."; continue; }
                local _tf_auth; _tf_auth=$(mktemp "$TMP_DIR/.sd_auth_XXXXXX")
                local _tf_new;  _tf_new=$(mktemp "$TMP_DIR/.sd_new_XXXXXX")
                _enc_authkey_valid && cp "$(_enc_authkey_path)" "$_tf_auth" || printf '%s' "$SD_VERIFICATION_CIPHER" > "$_tf_auth"
                printf '%s' "$_np1" > "$_tf_new"
                clear
                printf '\n  \033[1m── Add Key: %s ──\033[0m\n' "$_kname"
                printf '  \033[2mAdding key, this might take a few seconds...\033[0m\n\n'
                sudo -n cryptsetup luksAddKey \
                    --batch-mode \
                    --pbkdf "$_pbkdf" --pbkdf-memory "$_ram" --pbkdf-parallel "$_threads" --iter-time "$_iter" \
                    --key-slot "$_free_k" --key-file "$_tf_auth" \
                    "$IMG_PATH" "$_tf_new" &>/dev/null
                local _rc=$?; rm -f "$_tf_auth" "$_tf_new"; clear
                [[ $_rc -ne 0 ]] && { pause "Failed to add key."; continue; }
                local _cur; _cur=$(cat "$_nf" 2>/dev/null || printf '{}')
                local _tmp; _tmp=$(mktemp "$TMP_DIR/.sd_kn_XXXXXX")
                printf '%s' "$_cur" | jq --arg s "$_free_k" --arg n "$_kname" '.[$s] = $n' \
                    > "$_tmp" 2>/dev/null && mv "$_tmp" "$_nf" 2>/dev/null || rm -f "$_tmp"
                pause "$(printf 'Key "%s" added (slot %s).' "$_kname" "$_free_k")" ;;
        esac
    done
}
