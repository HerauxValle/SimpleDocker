#!/usr/bin/env bash

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

_tmux_launch() {
    # Shared attach/background launcher
    # Usage: _tmux_launch [--no-prompt] [--post-launch ok_file fail_file] sess title script
    #   --no-prompt        : skip fzf ask, always attach immediately (e.g. sdResize)
    #   --post-launch f1 f2: launch first, sleep 0.25, check ok/fail, then ask (e.g. storage)
    # Returns 2 if session finished while prompt open (caller should 'continue' to refresh)
    # Returns 1 if user cancelled
    local _no_prompt=false _post_ok="" _post_fail=""
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --no-prompt)   _no_prompt=true; shift ;;
            --post-launch) _post_ok="$2" _post_fail="$3"; shift 3 ;;
            *) shift ;;
        esac
    done
    local sess="$1" title="$2" script="$3"
    local _logfile="" _logcmd=""
    if [[ -n "$LOGS_DIR" ]]; then
        _logfile="$LOGS_DIR/${sess}-$(date '+%Y%m%d_%H%M%S').log"
        mkdir -p "$LOGS_DIR" 2>/dev/null || true
        _logcmd=" 2>&1 | tee $(printf '%q' "$_logfile")"
    fi

    # ── No-prompt: start and attach immediately ──
    if [[ "$_no_prompt" == "true" ]]; then
        tmux kill-session -t "$sess" 2>/dev/null || true
        tmux new-session -d -s "$sess" "bash $(printf '%q' "$script")${_logcmd}; rm -f $(printf '%q' "$script")" 2>/dev/null
        tmux switch-client -t "$sess" 2>/dev/null || true
        sleep 0.1; stty sane 2>/dev/null
        while IFS= read -r -t 0 -n 256 _ 2>/dev/null; do :; done
        return 0
    fi

    # ── Ask first, then start ──
    local _fzf_out; _fzf_out=$(mktemp "$TMP_DIR/.sd_launch_fzf_XXXXXX")
    printf '%s\n%s\n' \
        "$(printf "${GRN}▶  Attach — follow live output${NC}")" \
        "$(printf "${DIM}   Background — run silently${NC}")" \
        | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}── %s ──${NC}\n${DIM}  Press %s to detach at any time without stopping.${NC}" \
                "$title" "${KB[tmux_detach]}")" \
            >"$_fzf_out" 2>/dev/null
    local _rc=$?
    local choice; choice=$(cat "$_fzf_out" 2>/dev/null | _trim_s)
    rm -f "$_fzf_out"
    [[ $_rc -ne 0 || -z "$choice" ]] && return 1

    # ── Now start the session ──
    tmux kill-session -t "$sess" 2>/dev/null || true
    tmux new-session -d -s "$sess" "bash $(printf '%q' "$script")${_logcmd}; rm -f $(printf '%q' "$script")" 2>/dev/null
    tmux set-option -t "$sess" detach-on-destroy off 2>/dev/null || true

    if printf '%s' "$choice" | grep -qi "attach"; then
        tmux switch-client -t "$sess" 2>/dev/null || true
        # Ctrl+C or detach can leave terminal in raw/doubled state — full restore
        sleep 0.2; stty sane 2>/dev/null
        while IFS= read -r -t 0.2 -n 256 _ 2>/dev/null; do :; done
        tput reset 2>/dev/null || clear
        # Attached: return naturally re-renders the menu — no USR1 needed
    else
        # Background: terminal stayed here but key presses made while fzf
        # was open may have buffered — drain them so they don't leak into
        # the next fzf invocation.
        sleep 0.1; stty sane 2>/dev/null
        while IFS= read -r -t 0.15 -n 256 _ 2>/dev/null; do :; done
        # Background: fire USR1 when done so the menu refreshes automatically
        { while tmux_up "$sess" 2>/dev/null; do sleep 0.3; done
          kill -USR1 "$SD_SHELL_PID" 2>/dev/null || true
        } &
        disown
    fi
    return 0
}

_tmux_attach_hint() {
    local label="$1" sess="$2"
    confirm "$(printf "Attach to '%s'\n\n  Press %s to detach without stopping." "$label" "${KB[tmux_detach]}")" || return 0
    tmux switch-client -t "$sess" 2>/dev/null || true
    sleep 0.1; stty sane 2>/dev/null
    while IFS= read -r -t 0 -n 256 _ 2>/dev/null; do :; done
}

_pkg_op_wait() {
    local _sess="$1" _ok="$2" _fail="$3" _title="$4"
    local _fzf_out; _fzf_out=$(mktemp "$TMP_DIR/.sd_fzfout_XXXXXX")
    local _wflag;   _wflag=$(mktemp -u "$TMP_DIR/.sd_wflag_XXXXXX")
    printf '%s\n%s\n%s\n' \
        "${L[ct_attach_inst]}" \
        "$(printf "${BLD}  ── Navigation ───────────────────────${NC}")" \
        "$(printf "${DIM} ${L[back]}${NC}")" \
        | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}${YLW}◈${NC}  %s in progress${NC}\n${DIM}  Press %s to detach without stopping.${NC}" "$_title" "${KB[tmux_detach]}")" \
            >"$_fzf_out" 2>/dev/null &
    local _fzf_pid=$!
    printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    { while [[ ! -f "$_ok" && ! -f "$_fail" ]] && tmux_up "$_sess"; do sleep 0.3; done
      kill "$_fzf_pid" 2>/dev/null; touch "$_wflag"
    } &
    local _wpid=$!
    wait "$_fzf_pid" 2>/dev/null; local _frc=$?
    kill "$_wpid" 2>/dev/null; wait "$_wpid" 2>/dev/null
    stty sane 2>/dev/null
    while IFS= read -r -t 0 -n 256 _ 2>/dev/null; do :; done
    local _sel; _sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s)
    rm -f "$_fzf_out"
    if [[ -f "$_wflag" ]] || _sig_rc $_frc; then
        rm -f "$_wflag"; _SD_USR1_FIRED=0; return 0
    fi
    [[ "$_sel" == "${L[ct_attach_inst]}" ]] && { _tmux_attach_hint "$_title" "$_sess" || true; return 0; }
    return 1
}
