# lib/ui.sh — fzf/UI primitives: _fzf(), confirm(), pause(), finput(), _menu()
# Sourced by main.sh — do NOT run directly

# ── fzf / UI primitives ───────────────────────────────────────────
FZF_BASE=(
    --ansi --no-sort --header-first
    --prompt="  ❯ " --pointer="▶"
    --height=80% --min-height=18
    --reverse --border=rounded --margin=1,2
    --no-info --bind=esc:abort
    "--bind=${KB[detach]}:execute-silent(tmux set-environment -g SD_DETACH 1 && tmux detach-client >/dev/null 2>&1)+abort"
)

_fzf() {
    local _out; _out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    fzf "$@" >"$_out" 2>/dev/null &
    local _pid=$!
    printf '%s' "$_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_pid" 2>/dev/null
    local _rc=$?
    if [[ $_rc -eq 143 || $_rc -eq 137 ]]; then rm -f "$_out"; return 2; fi
    cat "$_out" 2>/dev/null; rm -f "$_out"
    return $_rc
}

confirm() {
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "$(printf "${GRN}%s${NC}" "${L[yes]}")" "$(printf "${RED}%s${NC}" "${L[no]}")" \
        | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}%s${NC}" "$1")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local ans; ans=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; return 1; }
    [[ $_frc -ne 0 ]] && return 1
    printf '%s' "$ans" | grep -qi "${L[yes]}"
}

pause() {
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "$(printf "${GRN}[ OK ]${NC}  ${DIM}%s${NC}" "${1:-Done.}")" \
        | fzf "${FZF_BASE[@]}" --header="$(printf "${DIM}%s${NC}" "${L[ok_press]}")" --no-multi >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; return 0; }
    return 0
}

FINPUT_RESULT=""
finput() {
    FINPUT_RESULT=""
    local _tmp; _tmp=$(mktemp "$TMP_DIR/.sd_finput_XXXXXX")
    : | fzf "${FZF_BASE[@]}" --print-query \
        --header="$(printf "${BLD}%s${NC}\n${DIM}  %s${NC}" "$1" "${L[type_enter]}")" \
        2>/dev/null > "$_tmp"
    local _rc=$?
    if [[ $_rc -eq 0 || $_rc -eq 1 ]]; then
        FINPUT_RESULT=$(head -1 "$_tmp" 2>/dev/null || true)
        rm -f "$_tmp"; return 0
    else
        rm -f "$_tmp"; return 1
    fi
}

_menu() {
    local header="$1"; shift
    local lines=()
    for x in "$@"; do
        if printf '%s' "$x" | grep -q $'\033'; then
            lines+=("$x")
        else
            lines+=("$(printf "${DIM} %s${NC}" "$x")")
        fi
    done
    local _SEP_NAV; _SEP_NAV="$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"
    lines+=("$_SEP_NAV" "$(printf "${DIM} %s${NC}" "${L[back]}")")
    local _out _pid _rc
    while true; do
        while IFS= read -r -t 0 -n 1 _ 2>/dev/null; do :; done
        _out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── %s ──${NC}" "$header")" >"$_out" 2>/dev/null &
        _pid=$!; printf '%s' "$_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_pid" 2>/dev/null; _rc=$?
        REPLY=$(cat "$_out" 2>/dev/null | _trim_s); rm -f "$_out"
        _sig_rc $_rc && { stty sane 2>/dev/null; if [[ "$_SD_USR1_FIRED" == "1" ]]; then _SD_USR1_FIRED=0; return 2; fi; continue; }
        [[ $_rc -ne 0 || -z "$REPLY" || "$REPLY" == "${L[back]}" ]] && return 1
        return 0
    done
}

