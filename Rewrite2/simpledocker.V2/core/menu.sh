#!/usr/bin/env bash
# core/menu.sh — JSON-driven fzf menu renderer
# Reads menu.json and renders menus via fzf.
# All static menus are declared in menu.json.
# Dynamic entries (container list, etc.) are injected via hook functions.
#
# Public API:
#   sd_menu <menu_id> [ctx_arg]   — render a menu, handle selection, loop until back/ESC
#   SD_MENU_CTX                   — current context arg (e.g. cid for container_item)

SD_MENU_JSON="${SD_ROOT}/menu.json"

# ── Color resolver ────────────────────────────────────────────────
_mc() {
    case "$1" in
        GRN) printf '%s' "$GRN" ;; RED) printf '%s' "$RED" ;;
        YLW) printf '%s' "$YLW" ;; BLU) printf '%s' "$BLU" ;;
        CYN) printf '%s' "$CYN" ;; BLD) printf '%s' "$BLD" ;;
        DIM) printf '%s' "$DIM" ;; *)   printf '%s' "$NC"  ;;
    esac
}

# ── Condition evaluator ───────────────────────────────────────────
# Returns 0 (show entry) or 1 (hide entry)
_menu_cond() {
    local cond="$1" cid="${SD_MENU_CTX:-}"
    [[ -z "$cond" ]] && return 0
    case "$cond" in
        running)       tmux_up "$(tsess "$cid")"  && return 0 || return 1 ;;
        not_running)   tmux_up "$(tsess "$cid")"  && return 1 || return 0 ;;
        installed)     [[ "$(_st "$cid" installed)" == "true" ]] && return 0 || return 1 ;;
        not_installed) [[ "$(_st "$cid" installed)" == "true" ]] && return 1 || return 0 ;;
        installing)    _is_installing "$cid"  && return 0 || return 1 ;;
        *)             return 0 ;;
    esac
}

# ── Entry renderer ────────────────────────────────────────────────
# Prints one display line for a static entry, or nothing if cond fails
_menu_render_entry() {
    local entry_json="$1"
    local type;   type=$(printf '%s'   "$entry_json" | jq -r '.type   // "item"')
    local cond;   cond=$(printf '%s'   "$entry_json" | jq -r '.cond   // empty')

    case "$type" in
        sep)
            printf "${BLD}  ─────────────────────────────────────${NC}\n"
            return ;;
        sep_label)
            local lbl; lbl=$(printf '%s' "$entry_json" | jq -r '.label')
            printf "${BLD}  ── %s ${NC}\n" "$lbl"
            return ;;
        dynamic) return ;;  # handled separately
    esac

    _menu_cond "$cond" || return 0

    local label icon color label_key status_fn
    label_key=$(printf '%s' "$entry_json" | jq -r '.label_key // empty')
    label=$(printf '%s' "$entry_json" | jq -r '.label     // empty')
    icon=$(printf '%s'  "$entry_json" | jq -r '.icon      // empty')
    color=$(printf '%s' "$entry_json" | jq -r '.color     // empty')
    status_fn=$(printf '%s' "$entry_json" | jq -r '.status_fn // empty')

    # label_key overrides label
    [[ -n "$label_key" ]] && label="${L[$label_key]:-$label_key}"

    local col; col=$(_mc "$color")
    local status_str=""
    [[ -n "$status_fn" ]] && status_str="  $(${status_fn} 2>/dev/null)"

    if [[ -n "$icon" ]]; then
        printf "${col} %s  %s${NC}%s\n" "$icon" "$label" "$status_str"
    else
        printf "${DIM} %s${NC}%s\n" "$label" "$status_str"
    fi
}

# ── Hook runner ───────────────────────────────────────────────────
# Calls the hook bash function, collects its stdout as display lines
# Hook functions print lines to stdout: "DISPLAY\tACTION\tARG"
_menu_run_hook() {
    local hook_name="$1"
    local hook_fn; hook_fn=$(jq -r --arg h "$hook_name" '.hooks[$h].fn // empty' "$SD_MENU_JSON")
    [[ -z "$hook_fn" ]] && return
    "$hook_fn" "${SD_MENU_CTX:-}" 2>/dev/null
}

# ── Main renderer ─────────────────────────────────────────────────
# Renders menu_id, returns action string via SD_MENU_ACTION
# Format of action: "menu:X", "fn:X", "back", or "fn:X\targ"
SD_MENU_ACTION=""

_menu_render() {
    local menu_id="$1"
    local menu_json; menu_json=$(jq -c --arg m "$menu_id" '.menus[$m]' "$SD_MENU_JSON")
    [[ -z "$menu_json" || "$menu_json" == "null" ]] && { pause "Unknown menu: $menu_id"; return 1; }

    local header; header=$(printf '%s' "$menu_json" | jq -r '.header // ""')
    local header_fn; header_fn=$(printf '%s' "$menu_json" | jq -r '.header_fn // empty')
    [[ -n "$header_fn" ]] && header=$("$header_fn" "${SD_MENU_CTX:-}" 2>/dev/null)

    local entries; entries=$(printf '%s' "$menu_json" | jq -c '.entries[]')
    local display_lines=()
    local action_map=()  # parallel array: action for each non-sep line

    while IFS= read -r entry; do
        local type; type=$(printf '%s' "$entry" | jq -r '.type // "item"')

        if [[ "$type" == "dynamic" ]]; then
            local hook; hook=$(printf '%s' "$entry" | jq -r '.hook')
            # Hook prints: DISPLAY\tACTION[\tARG]
            while IFS=$'\t' read -r disp act arg; do
                [[ -z "$disp" ]] && continue
                display_lines+=("$disp")
                action_map+=("${act}${arg:+	$arg}")
            done < <(_menu_run_hook "$hook")
            continue
        fi

        if [[ "$type" == "sep" || "$type" == "sep_label" ]]; then
            local sep_line; sep_line=$(_menu_render_entry "$entry")
            display_lines+=("$sep_line")
            action_map+=("__sep__")
            continue
        fi

        local cond; cond=$(printf '%s' "$entry" | jq -r '.cond // empty')
        _menu_cond "$cond" || continue

        local line; line=$(_menu_render_entry "$entry")
        local action; action=$(printf '%s' "$entry" | jq -r '.action // "back"')
        display_lines+=("$line")
        action_map+=("$action")
    done <<< "$entries"

    # fzf pick
    local _out; _out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%04d\t%s\n' $(seq 0 $((${#display_lines[@]}-1))) | \
        paste - <(printf '%s\n' "${display_lines[@]}") | \
        cut -f2- | \
        printf '%s\n' "${display_lines[@]}" | \
        fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}── %s ──${NC}" "$header")" \
            --with-nth=1.. \
            >"$_out" 2>/dev/null &
    local _pid=$!
    printf '%s' "$_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_pid" 2>/dev/null; local _rc=$?
    local sel; sel=$(cat "$_out" 2>/dev/null | _trim_s); rm -f "$_out"

    _sig_rc $_rc && { stty sane 2>/dev/null; SD_MENU_ACTION="__sig__"; return 0; }
    [[ $_rc -ne 0 || -z "$sel" ]] && { SD_MENU_ACTION="back"; return 0; }

    # Match selection back to action
    for i in "${!display_lines[@]}"; do
        local clean; clean=$(printf '%s' "${display_lines[$i]}" | _trim_s)
        if [[ "$clean" == "$sel" ]]; then
            SD_MENU_ACTION="${action_map[$i]}"
            return 0
        fi
    done

    SD_MENU_ACTION="back"
}

# ── Public entry point ────────────────────────────────────────────
# sd_menu <menu_id> [ctx_arg]
# Loops until user goes back or ESCs.
sd_menu() {
    local menu_id="$1"
    SD_MENU_CTX="${2:-}"
    while true; do
        _menu_render "$menu_id" || return
        local action="$SD_MENU_ACTION"
        [[ "$action" == "back" || -z "$action" ]] && return
        [[ "$action" == "__sep__" || "$action" == "__sig__" ]] && continue
        case "$action" in
            menu:*)
                local sub="${action#menu:}"
                sd_menu "$sub" "$SD_MENU_CTX" ;;
            fn:*)
                local fn_part="${action#fn:}"
                local fn_name="${fn_part%%	*}"
                local fn_arg=""
                [[ "$fn_part" == *$'\t'* ]] && fn_arg="${fn_part#*	}"
                if [[ -n "$fn_arg" ]]; then
                    "$fn_name" "$fn_arg"
                else
                    "$fn_name" "${SD_MENU_CTX:-}"
                fi ;;
            back) return ;;
        esac
    done
}
