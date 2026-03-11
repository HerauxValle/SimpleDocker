#!/usr/bin/env bash

CT_IDS=(); CT_NAMES=()
declare -A BP_META=()
declare -A BP_ENV=()

_tmux_get()   { tmux show-environment -g "$1" 2>/dev/null | cut -d= -f2-; }

_tmux_set()   { tmux set-environment -g "$1" "$2" 2>/dev/null; }

_st()         { jq -r ".$2 // empty" "$CONTAINERS_DIR/$1/state.json" 2>/dev/null; }

_set_st()     { local f="$CONTAINERS_DIR/$1/state.json"
                jq ".$2 = $3" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null; }

_state_get()  { _st "$1" "$2"; }

_cname()      { _st "$1" name; }

_cpath()      { local r; r=$(_st "$1" install_path); [[ -n "$r" ]] && printf '%s/%s' "$INSTALLATIONS_DIR" "$r"; }

tsess()       { printf 'sd_%s' "$1"; }

tmux_up()     { tmux has-session -t "$1" 2>/dev/null; }

_load_containers() {
    CT_IDS=(); CT_NAMES=()
    local show_hidden="${1:-false}"
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        local hidden n
        { read -r hidden; IFS= read -r n; } < <(jq -r '.hidden // false, .name // empty' "$d/state.json" 2>/dev/null)
        [[ "$show_hidden" == "false" && "$hidden" == "true" ]] && continue
        [[ -z "$n" ]] && n="(unnamed-$cid)"
        CT_IDS+=("$cid"); CT_NAMES+=("$n")
    done
}

_validate_containers() {
    [[ -z "$CONTAINERS_DIR" ]] && return
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        [[ "$(_st "$cid" installed)" != "true" ]] && continue
        local ip; ip=$(_cpath "$cid")
        [[ -n "$ip" && -d "$ip" ]] || _set_st "$cid" installed false
    done
}

_installing_id()      { _tmux_get SD_INSTALLING; }

_inst_sess()          { printf 'sdInst_%s' "$1"; }

_is_installing()      { local cid="$1"; tmux_up "$(_inst_sess "$cid")"; }

_cleanup_stale_lock() {
    local cur; cur=$(_installing_id)
    [[ -z "$cur" ]] && return 0
    tmux_up "$(_inst_sess "$cur")" && return 0
    _tmux_set SD_INSTALLING ""
}
