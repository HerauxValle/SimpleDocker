#!/usr/bin/env bash

_sudo_keepalive() {
    ( while true; do sudo -n true 2>/dev/null; sleep 55; done ) &
    disown "$!" 2>/dev/null || true
}

_require_sudo() {
    # Sudoers is written in the outer shell (before tmux) where a real tty exists.
    # Inside tmux we just need the keepalive — sudo -n commands work because the rule is already written.
    _sudo_keepalive
}
