#!/usr/bin/env bash

_stor_path()          { printf '%s/%s' "$STORAGE_DIR" "$1"; }

_stor_meta_path()     { printf '%s/.sd_meta.json' "$(_stor_path "$1")"; }

_stor_meta_set() {
    local scid="$1"; shift
    local mp; mp=$(_stor_meta_path "$scid"); local tmp; tmp=$(mktemp)
    [[ -f "$mp" ]] && cp "$mp" "$tmp" || printf '{}' > "$tmp"
    local key val
    while [[ $# -ge 2 ]]; do
        key="$1" val="$2"; shift 2
        jq --arg k "$key" --arg v "$val" '.[$k]=$v' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
    done
    mv "$tmp" "$mp"
}

_stor_read_field()     { jq -r ".$2 // empty" "$(_stor_meta_path "$1")" 2>/dev/null; }

_stor_read_name()      { _stor_read_field "$1" name; }

_stor_read_type()      { _stor_read_field "$1" storage_type; }

_stor_read_active()    { _stor_read_field "$1" active_container; }

_stor_set_active()     { _stor_meta_set "$1" active_container "$2"; }

_stor_clear_active()   { _stor_meta_set "$1" active_container ""; }

_stor_type_from_sj() {
    local cid="$1"
    jq -r '.meta.storage_type // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null
}

_stor_count() {
    local cid="$1"
    local st; st=$(_stor_type_from_sj "$cid")
    [[ -z "$st" ]] && printf '0' && return
    local sj; sj="$CONTAINERS_DIR/$cid/service.json"
    local n; n=$(jq -r '.storage | length' "$sj" 2>/dev/null)
    printf '%s' "${n:-0}"
}

_stor_paths() {
    local cid="$1"
    jq -r '.storage[]? // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null
}

_stor_unlink() {
    local cid="$1" install_path="$2"
    local rel
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        local link_path="$install_path/$rel"
        if [[ -L "$link_path" ]]; then rm -f "$link_path" 2>/dev/null; mkdir -p "$link_path" 2>/dev/null; fi
    done < <(_stor_paths "$cid")
}

_stor_link() {
    local cid="$1" install_path="$2" scid="$3"
    local sdir; sdir=$(_stor_path "$scid"); mkdir -p "$sdir" 2>/dev/null
    local -A active=()
    local rel
    while IFS= read -r rel; do [[ -z "$rel" ]] && continue; active["$rel"]=1; done < <(_stor_paths "$cid")

    local prev_paths=()
    mapfile -t prev_paths < <(jq -r '.storage_paths[]? // empty' "$CONTAINERS_DIR/$cid/state.json" 2>/dev/null)
    for prev in "${prev_paths[@]}"; do
        [[ -z "$prev" || -n "${active[$prev]:-}" ]] && continue
        local real_path="$sdir/$prev" link_path="$install_path/$prev"
        [[ ! -d "$real_path" ]] && continue
        [[ -L "$link_path" ]] && rm -f "$link_path" 2>/dev/null
        mkdir -p "$link_path" 2>/dev/null
        [[ -n "$(ls -A "$real_path" 2>/dev/null)" ]] && cp -a "$real_path/." "$link_path/" 2>/dev/null || true
        rm -rf "$real_path" 2>/dev/null
    done

    for rel in "${!active[@]}"; do
        local real_path="$sdir/$rel" link_path="$install_path/$rel"
        mkdir -p "$real_path" "$(dirname "$link_path")" 2>/dev/null
        [[ -L "$link_path" ]] && rm -f "$link_path" 2>/dev/null
        if [[ -d "$link_path" ]]; then
            [[ -n "$(ls -A "$link_path" 2>/dev/null)" ]] && cp -a "$link_path/." "$real_path/" 2>/dev/null || true
            rm -rf "$link_path" 2>/dev/null
        fi
        ln -sfn "$real_path" "$link_path" 2>/dev/null
    done

    local paths_json; paths_json=$(printf '%s\n' "${!active[@]}" | jq -R -s 'split("\n") | map(select(length>0))')
    jq --argjson p "$paths_json" --arg s "$scid" '.storage_paths=$p | .storage_id=$s' \
        "$CONTAINERS_DIR/$cid/state.json" > "$CONTAINERS_DIR/$cid/state.json.tmp" 2>/dev/null \
        && mv "$CONTAINERS_DIR/$cid/state.json.tmp" "$CONTAINERS_DIR/$cid/state.json" 2>/dev/null || true
    _stor_set_active "$scid" "$cid"
}

_auto_pick_storage_profile() {
    # Silently selects a storage profile for group-start (no interactive prompt).
    # Priority: 1) default_storage_id in state, 2) last used storage_id, 3) first available, 4) create Default
    local cid="$1"
    local stype; stype=$(_stor_type_from_sj "$cid")
    [[ "$(_stor_count "$cid")" -eq 0 ]] && return 0
    [[ -z "$STORAGE_DIR" || ! -d "$STORAGE_DIR" ]] && { _stor_create_profile_silent "$cid" "$stype"; return; }

    # 1) explicit default
    local def_scid; def_scid=$(_state_get "$cid" default_storage_id)
    if [[ -n "$def_scid" && -d "$(_stor_path "$def_scid")" ]]; then
        local ac; ac=$(_stor_read_active "$def_scid")
        if [[ -z "$ac" || "$ac" == "$cid" ]] || ! tmux_up "$(tsess "$ac")"; then
            [[ -n "$ac" && "$ac" != "$cid" ]] && _stor_clear_active "$def_scid"
            printf '%s' "$def_scid"; return
        fi
    fi

    # 2) last used
    local last_scid; last_scid=$(_state_get "$cid" storage_id)
    if [[ -n "$last_scid" && -d "$(_stor_path "$last_scid")" ]]; then
        local ac; ac=$(_stor_read_active "$last_scid")
        if [[ -z "$ac" || "$ac" == "$cid" ]] || ! tmux_up "$(tsess "$ac")"; then
            [[ -n "$ac" && "$ac" != "$cid" ]] && _stor_clear_active "$last_scid"
            printf '%s' "$last_scid"; return
        fi
    fi

    # 3) first free profile of matching type
    for sdir in "$STORAGE_DIR"/*/; do
        [[ -d "$sdir" ]] || continue
        local scid; scid=$(basename "$sdir")
        [[ "$(_stor_read_type "$scid")" != "$stype" ]] && continue
        local ac; ac=$(_stor_read_active "$scid")
        if [[ -z "$ac" || "$ac" == "$cid" ]] || ! tmux_up "$(tsess "$ac")"; then
            [[ -n "$ac" && "$ac" != "$cid" ]] && _stor_clear_active "$scid"
            printf '%s' "$scid"; return
        fi
    done

    # 4) none found — create a silent Default profile
    _stor_create_profile_silent "$cid" "$stype"
}

_stor_create_profile_silent() {
    # Creates a "Default" storage profile without any user prompts
    local cid="$1" stype="$2"
    local new_scid
    while true; do
        new_scid=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
        [[ ! -d "$(_stor_path "$new_scid")" ]] && break
    done
    mkdir -p "$(_stor_path "$new_scid")" 2>/dev/null
    _stor_meta_set "$new_scid" storage_type "$stype" name "Default" created "$(date +%Y-%m-%d)" active_container ""
    # Set as default for this container
    _set_st "$cid" default_storage_id "\"$new_scid\""
    printf '%s' "$new_scid"
}
