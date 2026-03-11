#!/usr/bin/env bash
# core/io.sh — mode-aware IO adapter
#
# lib/ functions call ONLY these. Never call pause/confirm/finput/fzf directly.
# SD_MODE=tui  → delegates to tui/ui.sh functions (fzf-based)
# SD_MODE=cli  → prints to stdout/stderr, reads from args or stdin
#
# All functions return 0=ok 1=cancel/no/empty

SD_MODE="${SD_MODE:-tui}"

# SD_MSG — set by lib functions to pass a result/error string back to caller
SD_MSG=""

# ── sd_msg <text> ─────────────────────────────────────────────────
# Show a message and wait for acknowledgement (TUI) or just print (CLI)
sd_msg() {
    local msg="$1"
    if [[ "$SD_MODE" == "tui" ]]; then
        pause "$msg"
    else
        printf '%s\n' "$msg" >&2
    fi
}

# ── sd_confirm <question> ─────────────────────────────────────────
# Returns 0=yes 1=no/cancel
sd_confirm() {
    local q="$1"
    if [[ "$SD_MODE" == "tui" ]]; then
        confirm "$q"
    else
        # CLI: non-interactive, default yes (caller passes --force or just runs)
        # If SD_FORCE=1, skip prompt entirely
        [[ "${SD_FORCE:-0}" == "1" ]] && return 0
        printf '%s [y/N] ' "$q" >&2
        local ans; read -r ans
        [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
    fi
}

# ── sd_input <prompt> [default] ──────────────────────────────────
# Returns result via SD_MSG, 0=ok 1=cancel/empty
sd_input() {
    local prompt="$1" default="${2:-}"
    if [[ "$SD_MODE" == "tui" ]]; then
        finput "$prompt" || return 1
        SD_MSG="$FINPUT_RESULT"
    else
        # CLI: use SD_INPUT env var if set (for scripting), else read stdin
        if [[ -n "${SD_INPUT:-}" ]]; then
            SD_MSG="$SD_INPUT"; SD_INPUT=""
            [[ -z "$SD_MSG" ]] && SD_MSG="$default"
        else
            printf '%s' "$prompt " >&2
            [[ -n "$default" ]] && printf '[%s] ' "$default" >&2
            read -r SD_MSG
            [[ -z "$SD_MSG" ]] && SD_MSG="$default"
        fi
        [[ -z "$SD_MSG" ]] && return 1
    fi
    return 0
}

# ── sd_pick_dir ───────────────────────────────────────────────────
# Returns selected directory via SD_MSG
# CLI: uses SD_DIR env var or prompts
sd_pick_dir() {
    if [[ "$SD_MODE" == "tui" ]]; then
        SD_MSG=$(_pick_dir) || return 1
    else
        if [[ -n "${SD_DIR:-}" ]]; then
            SD_MSG="$SD_DIR"; SD_DIR=""
        else
            printf 'Directory path: ' >&2
            read -r SD_MSG
        fi
        [[ -z "$SD_MSG" || ! -d "$SD_MSG" ]] && { printf 'Invalid directory\n' >&2; return 1; }
    fi
}

# ── sd_attach <session> <label> ───────────────────────────────────
# Offer to attach to a tmux session (TUI) or just print the attach hint (CLI)
sd_attach() {
    local sess="$1" label="${2:-session}"
    if [[ "$SD_MODE" == "tui" ]]; then
        _tmux_attach_hint "$label" "$sess"
    else
        printf 'Attach: tmux attach -t %s\n' "$sess" >&2
    fi
}

# ── sd_start_prompt <sess> <name> ────────────────────────────────
# After container start: TUI shows attach-or-background picker, CLI just prints
sd_start_prompt() {
    local sess="$1" name="$2"
    if [[ "$SD_MODE" == "tui" ]]; then
        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n%s\n' \
            "$(printf "${GRN}▶  Show live output${NC}")" \
            "$(printf "${DIM}   Start in background${NC}")" \
            | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── %s started ──${NC}" "$name")" \
            >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local _choice; _choice=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; return 0; }
        if printf '%s' "$_choice" | _strip_ansi | grep -q "live output"; then
            tmux switch-client -t "$sess" 2>/dev/null || true
            sleep 0.1; stty sane 2>/dev/null
            while IFS= read -r -t 0 -n 256 _ 2>/dev/null; do :; done
        fi
    else
        printf '%s started. Attach: tmux attach -t %s\n' "$name" "$sess"
    fi
}
