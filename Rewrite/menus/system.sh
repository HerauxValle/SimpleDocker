# menus/system.sh — _res_set/_res_del, _resources_menu (cgroup/systemd-run resource limits)
# Sourced by main.sh — do NOT run directly

_res_get() { jq -r ".$2 // empty" "$(_resources_cfg "$1")" 2>/dev/null; }
_res_set() {
    local f; f=$(_resources_cfg "$1")
    [[ ! -f "$f" ]] && printf '{}' > "$f"
    local tmp; tmp=$(mktemp); jq --arg k "$2" --arg v "$3" '.[$k]=$v' "$f" > "$tmp" && mv "$tmp" "$f"
}
_res_del() {
    local f; f=$(_resources_cfg "$1"); [[ ! -f "$f" ]] && return
    local tmp; tmp=$(mktemp); jq --arg k "$2" 'del(.[$k])' "$f" > "$tmp" && mv "$tmp" "$f"
}

_resources_menu() {
    _load_containers false
    [[ ${#CT_IDS[@]} -eq 0 ]] && { pause "No containers found."; return; }
    local copts=()
    copts+=("$(printf "${BLD}  ── Containers ───────────────────────${NC}")")
    for ci in "${CT_IDS[@]}"; do
        local rs; rs=""
        [[ "$(jq -r '.enabled // false' "$(_resources_cfg "$ci")" 2>/dev/null)" == "true" ]] \
            && rs="$(printf "  ${GRN}[cgroups on]${NC}")"
        copts+=("$(printf " ${DIM}◈${NC}  %s%b" "$(_cname "$ci")" "$rs")")
    done
    copts+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
    copts+=("$(printf "${DIM} %s${NC}" "${L[back]}")")
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${copts[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Resource limits ──${NC}  ${DIM}[%d containers]${NC}" "${#CT_IDS[@]}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; return; }
    [[ $_frc -ne 0 || -z "$sel" ]] && return
    local sel_clean; sel_clean=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*//')
    [[ "$sel_clean" == "${L[back]}" || "$sel_clean" == ──* || "$sel_clean" == "── "* ]] && return
    local cid=""; local ci
    local sel_name; sel_name=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*◈[[:space:]]*//' | awk '{print $1}')
    for ci in "${CT_IDS[@]}"; do [[ "$(_cname "$ci")" == "$sel_name" ]] && cid="$ci" && break; done
    [[ -z "$cid" ]] && return
    [[ ! -f "$(_resources_cfg "$cid")" ]] && printf '{"enabled":false}' > "$(_resources_cfg "$cid")"

    while true; do
        local enabled;    enabled=$(   _res_get "$cid" enabled);    enabled="${enabled:-false}"
        local cpu_quota;  cpu_quota=$( _res_get "$cid" cpu_quota);  cpu_quota="${cpu_quota:-(unlimited)}"
        local mem_max;    mem_max=$(   _res_get "$cid" mem_max);     mem_max="${mem_max:-(unlimited)}"
        local mem_swap;   mem_swap=$(  _res_get "$cid" mem_swap);    mem_swap="${mem_swap:-(unlimited)}"
        local cpu_weight; cpu_weight=$(jq -r '.cpu_weight // empty' "$(_resources_cfg "$cid")" 2>/dev/null); cpu_weight="${cpu_weight:-(default 100)}"
        local tog; [[ "$enabled" == "true" ]] && tog="${GRN}● Enabled${NC}" || tog="${RED}○ Disabled${NC}"
        local lines=(
            "$(printf "${BLD}  ── Configuration ────────────────────${NC}")"
            "$(printf ' %b  — toggle cgroups on/off (applies on next start)' "$tog")"
            "$(printf '  CPU quota    %b%s%b  — e.g. 200%% = 2 cores' "$CYN" "$cpu_quota" "$NC")"
            "$(printf '  Memory max   %b%s%b  — e.g. 8G, 512M' "$CYN" "$mem_max" "$NC")"
            "$(printf '  Memory+swap  %b%s%b  — e.g. 10G' "$CYN" "$mem_swap" "$NC")"
            "$(printf '  CPU weight   %b%s%b  — 1-10000, default=100 (relative priority)' "$CYN" "$cpu_weight" "$NC")"
            "$(printf "${BLD}  ── Info ──────────────────────────────${NC}")"
            "$(printf '  %bGPU/VRAM%b     not configurable via cgroups (planned separately)' "$DIM" "$NC")"
            "$(printf '  %bNetwork%b      not configurable via cgroups (planned separately)' "$DIM" "$NC")"
            "$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"
            "$(printf "${DIM} %s${NC}" "${L[back]}")"
        )
        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}── Resources: %s ──${NC}\n${DIM}  Limits apply on container restart via systemd cgroups.${NC}" "$(_cname "$cid")")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel2; sel2=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "$sel2" ]] && return
        local sc; sc=$(printf '%s' "$sel2" | _strip_ansi | sed 's/^[[:space:]]*//')
        case "$sc" in
            *"${L[back]}"*|"") return ;;
            *"toggle"*)
                [[ "$enabled" == "true" ]] && _res_set "$cid" enabled false || _res_set "$cid" enabled true ;;
            *"CPU quota"*)
                finput "CPU quota (e.g. 200% = 2 cores, blank = remove limit):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" cpu_quota || _res_set "$cid" cpu_quota "$FINPUT_RESULT" ;;
            *"Memory max"*)
                finput "Memory max (e.g. 8G, 512M, blank = remove limit):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" mem_max || _res_set "$cid" mem_max "$FINPUT_RESULT" ;;
            *"Memory+swap"*)
                finput "Memory+swap max (e.g. 10G, blank = remove limit):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" mem_swap || _res_set "$cid" mem_swap "$FINPUT_RESULT" ;;
            *"CPU weight"*)
                finput "CPU weight (1-10000, blank = default 100):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" cpu_weight || _res_set "$cid" cpu_weight "$FINPUT_RESULT" ;;
        esac
    done
}

