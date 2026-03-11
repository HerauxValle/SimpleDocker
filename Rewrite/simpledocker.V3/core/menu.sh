#!/usr/bin/env bash
# core/menu.sh — JSON-driven fzf menu renderer
#
# Every entry stored as: DISPLAY\tACTION
# fzf uses --with-nth=1 --delimiter=$'\t' — only DISPLAY shown, ACTION extracted after.
#
# Public:
#   sd_menu <menu_id> [ctx_arg]
#   SD_MENU_CTX  — current context (cid, gid, etc.)

SD_MENU_JSON="${SD_ROOT}/menu.json"

_mc() {
    case "$1" in
        GRN) printf '%s' "$GRN";; RED) printf '%s' "$RED";;
        YLW) printf '%s' "$YLW";; BLU) printf '%s' "$BLU";;
        CYN) printf '%s' "$CYN";; BLD) printf '%s' "$BLD";;
        DIM) printf '%s' "$DIM";; *)   printf '%s' "$NC" ;;
    esac
}

_menu_cond() {
    local cond="$1" cid="${SD_MENU_CTX:-}"
    [[ -z "$cond" || "$cond" == "null" ]] && return 0
    case "$cond" in
        running)               tmux_up "$(tsess "$cid")"  && return 0 || return 1;;
        not_running)           tmux_up "$(tsess "$cid")"  && return 1 || return 0;;
        installed)             [[ "$(_st "$cid" installed)" == "true" ]] && return 0 || return 1;;
        not_installed)         [[ "$(_st "$cid" installed)" == "true" ]] && return 1 || return 0;;
        installed_not_running) [[ "$(_st "$cid" installed)" == "true" ]] && ! tmux_up "$(tsess "$cid")" && return 0 || return 1;;
        not_running_installed) [[ "$(_st "$cid" installed)" == "true" ]] && ! tmux_up "$(tsess "$cid")" && return 0 || return 1;;
        installing)            _is_installing "$cid"       && return 0 || return 1;;
        install_done)          [[ -f "$CONTAINERS_DIR/$cid/.install_ok" || -f "$CONTAINERS_DIR/$cid/.install_fail" ]] && return 0 || return 1;;
        grp_running)           local _gr=0; while IFS= read -r _cn; do local _gc; _gc=$(_ct_id_by_name "$_cn"); [[ -n "$_gc" ]] && tmux_up "$(tsess "$_gc")" && _gr=1; done < <(_grp_containers "$cid"); [[ $_gr -eq 1 ]] && return 0 || return 1;;
        grp_not_running)       local _gr=0; while IFS= read -r _cn; do local _gc; _gc=$(_ct_id_by_name "$_cn"); [[ -n "$_gc" ]] && tmux_up "$(tsess "$_gc")" && _gr=1; done < <(_grp_containers "$cid"); [[ $_gr -eq 0 ]] && return 0 || return 1;;
        *)                     return 0;;
    esac
}

_SD_ENTRIES=()

_menu_build_entries() {
    local menu_id="$1"
    _SD_ENTRIES=()
    local raw; raw=$(jq -c --arg m "$menu_id" '.menus[$m].entries[]' "$SD_MENU_JSON" 2>/dev/null)
    [[ -z "$raw" ]] && return 1
    while IFS= read -r entry; do
        local type; type=$(printf '%s' "$entry" | jq -r '.type // "item"')
        local cond; cond=$(printf '%s' "$entry" | jq -r '.cond // empty')
        case "$type" in
            sep)
                _SD_ENTRIES+=("$(printf "${BLD}  ─────────────────────────────────────${NC}")"$'\t''__sep__')
                continue;;
            sep_label)
                local lbl; lbl=$(printf '%s' "$entry" | jq -r '.label')
                _SD_ENTRIES+=("$(printf "${BLD}  ── %s ${NC}" "$lbl")"$'\t''__sep__')
                continue;;
            dynamic)
                local hook; hook=$(printf '%s' "$entry" | jq -r '.hook')
                local hook_fn; hook_fn=$(jq -r --arg h "$hook" '.hooks[$h].fn // empty' "$SD_MENU_JSON")
                [[ -n "$hook_fn" && "$hook_fn" != "null" ]] && \
                while IFS= read -r hline; do
                    [[ -n "$hline" ]] && _SD_ENTRIES+=("$hline")
                done < <("$hook_fn" "${SD_MENU_CTX:-}" 2>/dev/null)
                continue;;
        esac
        _menu_cond "$cond" || continue
        local label icon color label_key status_fn action
        label_key=$(printf '%s' "$entry" | jq -r '.label_key // empty')
        label=$(printf '%s'     "$entry" | jq -r '.label     // empty')
        icon=$(printf '%s'      "$entry" | jq -r '.icon      // empty')
        color=$(printf '%s'     "$entry" | jq -r '.color     // empty')
        status_fn=$(printf '%s' "$entry" | jq -r '.status_fn // empty')
        action=$(printf '%s'    "$entry" | jq -r '.action    // "back"')
        [[ -n "$label_key" && "$label_key" != "null" ]] && label="${L[$label_key]:-$label_key}"
        local col; col=$(_mc "$color")
        local status_str=""
        [[ -n "$status_fn" && "$status_fn" != "null" ]] && status_str="  $("$status_fn" 2>/dev/null)"
        local display
        if [[ -n "$icon" && "$icon" != "null" ]]; then
            display="$(printf "${col} %s  %s${NC}%s" "$icon" "$label" "$status_str")"
        else
            display="$(printf "${DIM} %s${NC}%s" "$label" "$status_str")"
        fi
        _SD_ENTRIES+=("${display}"$'\t'"${action}")
    done <<< "$raw"
}

SD_MENU_ACTION=""

_menu_render() {
    local menu_id="$1"
    local menu_json; menu_json=$(jq -c --arg m "$menu_id" '.menus[$m]' "$SD_MENU_JSON" 2>/dev/null)
    [[ -z "$menu_json" || "$menu_json" == "null" ]] && { sd_msg "Unknown menu: $menu_id"; return 1; }
    local header; header=$(printf '%s' "$menu_json" | jq -r '.header // ""')
    local header_fn; header_fn=$(printf '%s' "$menu_json" | jq -r '.header_fn // empty')
    [[ -n "$header_fn" && "$header_fn" != "null" ]] && header=$("$header_fn" "${SD_MENU_CTX:-}" 2>/dev/null)
    _menu_build_entries "$menu_id" || { sd_msg "No entries for menu: $menu_id"; return 1; }
    local _out; _out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${_SD_ENTRIES[@]}" \
        | fzf "${FZF_BASE[@]}" \
              --with-nth=1 --delimiter=$'\t' \
              --header="$(printf "${BLD}── %s ──${NC}" "$header")" \
              >"$_out" 2>/dev/null &
    local _pid=$!; printf '%s' "$_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_pid" 2>/dev/null; local _rc=$?
    local sel; sel=$(cat "$_out" 2>/dev/null); rm -f "$_out"
    _sig_rc $_rc && { stty sane 2>/dev/null; SD_MENU_ACTION="__sig__"; return 0; }
    [[ $_rc -ne 0 || -z "$sel" ]] && { SD_MENU_ACTION="back"; return 0; }
    SD_MENU_ACTION=$(printf '%s' "$sel" | cut -d$'\t' -f2)
    [[ -z "$SD_MENU_ACTION" ]] && SD_MENU_ACTION="back"
}

_menu_dispatch() {
    local action="$1"
    case "$action" in
        back|"")         return 1;;
        __sep__|__sig__) return 0;;
        menu:*)
            sd_menu "${action#menu:}" "$SD_MENU_CTX"; return 0;;
        fn:*)
            local fp="${action#fn:}"
            local fn="${fp%%$'\t'*}"
            local arg="${fp#*$'\t'}"; [[ "$arg" == "$fp" ]] && arg=""
            if [[ -n "$arg" ]]; then "$fn" "$arg"
            else "$fn" "${SD_MENU_CTX:-}"; fi
            return 0;;
    esac
}

sd_menu() {
    local menu_id="$1"
    SD_MENU_CTX="${2:-}"
    while true; do
        _menu_render "$menu_id" || return 1
        local action="$SD_MENU_ACTION"
        [[ "$action" == "back" || -z "$action" ]] && return 0
        [[ "$action" == "__sig__" || "$action" == "__sep__" ]] && continue
        _menu_dispatch "$action" || return 0
    done
}
