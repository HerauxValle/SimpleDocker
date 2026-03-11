#!/usr/bin/env bash

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

_create_group() {
    finput "Group name:" || return 1
    local gname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"
    [[ -z "$gname" ]] && { pause "Name cannot be empty."; return 1; }
    local gid; gid=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
    printf 'name = %s\ndesc =\ncontainers =\nstart = {  }\n' "$gname" > "$(_grp_path "$gid")"
    pause "Group '$gname' created."
}
