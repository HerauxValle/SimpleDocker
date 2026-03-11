#!/usr/bin/env bash

_qrencode_menu() {
    while true; do
        if [[ ! -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
            sd_msg "$(printf "QRencode runs inside the Ubuntu base layer.\n\n  Install Ubuntu base first (Other → Ubuntu base).")"; return
        fi

        # ── If an operation is already running, show blocking in-progress menu ──
        local _qr_sess=""
        tmux_up "sdQrInst"   && _qr_sess="sdQrInst"
        tmux_up "sdQrUninst" && _qr_sess="sdQrUninst"
        if [[ -n "$_qr_sess" ]]; then
            local _upkg_ok="$UBUNTU_DIR/.upkg_ok" _upkg_fail="$UBUNTU_DIR/.upkg_fail"
            _pkg_op_wait "$_qr_sess" "$_upkg_ok" "$_upkg_fail" "QRencode operation" && continue || return
        fi

        local _qr_installed=false
        _chroot_bash "$UBUNTU_DIR" -c 'command -v qrencode' >/dev/null 2>&1 && _qr_installed=true

        local _upkg_ok="$UBUNTU_DIR/.upkg_ok" _upkg_fail="$UBUNTU_DIR/.upkg_fail"
        rm -f "$_upkg_ok" "$_upkg_fail"

        # Drain any pending USR1 from _tmux_launch's background watcher before showing menu
        sleep 0.15; _SD_USR1_FIRED=0

        if [[ "$_qr_installed" == "true" ]]; then
            _menu "QRencode" "$(printf "${CYN}↑${NC}  Update")" "$(printf "${RED}×${NC}  Uninstall")"
            local _mrc=$?
            [[ $_mrc -eq 2 ]] && { _SD_USR1_FIRED=0; continue; }
            [[ $_mrc -ne 0 ]] && return
            case "$REPLY" in
                *"Update"*)
                    _ubuntu_pkg_tmux "sdQrInst" "Update QRencode" \
                        "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode 2>&1"
                    continue ;;
                *"Uninstall"*)
                    sd_confirm "Uninstall QRencode from Ubuntu?" || continue
                    _ubuntu_pkg_tmux "sdQrUninst" "Uninstall QRencode" \
                        "DEBIAN_FRONTEND=noninteractive apt-get remove -y qrencode 2>&1"
                    continue ;;
            esac
        else
            _menu "QRencode" "$(printf "${GRN}↓${NC}  Install")"
            local _mrc=$?
            [[ $_mrc -eq 2 ]] && { _SD_USR1_FIRED=0; continue; }
            [[ $_mrc -ne 0 ]] && return
            case "$REPLY" in
                *"Install"*)
                    _ubuntu_pkg_tmux "sdQrInst" "Install QRencode" \
                        "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode 2>&1"
                    continue ;;
            esac
        fi
    done
}
