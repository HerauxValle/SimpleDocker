#!/usr/bin/env bash

_proxy_menu() {
    [[ ! -f "$(_proxy_cfg)" ]] && printf '{"autostart":false,"routes":[]}' > "$(_proxy_cfg)"
    local _SEP_INST _SEP_STARTUP _SEP_ROUTES _SEP_NAV
    _SEP_INST="$(   printf "${BLD}  ── Installation ─────────────────────${NC}")"
    _SEP_STARTUP="$(printf "${BLD}  ── Startup ──────────────────────────${NC}")"
    _SEP_ROUTES="$( printf "${BLD}  ── Rerouting ────────────────────────${NC}")"
    _SEP_NAV="$(    printf "${BLD}  ── Navigation ───────────────────────${NC}")"

    while true; do
        local autostart; autostart=$(_proxy_get autostart); autostart="${autostart:-false}"
        local at_s; [[ "$autostart" == "true" ]] && at_s="${GRN}on${NC}" || at_s="${DIM}off${NC}"
        local caddy_ok=false; [[ -x "$(_proxy_caddy_bin)" ]] && caddy_ok=true
        local inst_s; $caddy_ok && inst_s="${GRN}installed${NC}" || inst_s="${RED}not installed${NC}"
        local run_s;  _proxy_running && run_s="${GRN}running${NC}" || run_s="${RED}stopped${NC}"
        local local_count=0
        while IFS= read -r _ru; do [[ "$_ru" == *.local ]] && (( local_count++ )) || true
        done < <(jq -r '.routes[]?.url // empty' "$(_proxy_cfg)" 2>/dev/null)
        local lines=("$_SEP_INST"
            "$(printf " ${DIM}◈${NC}  Caddy + mDNS — %b" "$inst_s")"
            "$_SEP_STARTUP"
            "$(printf " ${DIM}◈${NC}  Running — %b" "$run_s")"
            "$(printf " ${DIM}◈${NC}  Autostart — %b  ${DIM}(starts with img mount)${NC}" "$at_s")"
            "$_SEP_ROUTES")

        local route_urls=(); local route_lines=()
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            local rurl rcid rhttps proto rname
            rurl=$( printf '%s' "$r" | jq -r '.url');  rcid=$(printf '%s' "$r" | jq -r '.cid')
            rhttps=$(printf '%s' "$r" | jq -r '.https // "false"')
            rname=$(_cname "$rcid" 2>/dev/null || printf '%s' "$rcid")
            [[ "$rhttps" == "true" ]] && proto="https" || proto="http"
            local rmdns; rmdns=$(_avahi_mdns_name "$rurl")
            route_lines+=("$(printf " ${CYN}◈${NC}  ${CYN}%s${NC}  →  %s  ${DIM}(%s  mDNS: %s)${NC}" "$rurl" "$rname" "$proto" "$rmdns")")
            route_urls+=("$rurl")
        done < <(jq -c '.routes[]?' "$(_proxy_cfg)" 2>/dev/null)
        for rl in "${route_lines[@]}"; do lines+=("$rl"); done
        lines+=("$(printf "${GRN} +${NC}  Add URL")")

        # ── Port exposure per container ────────────────────────────
        local _SEP_EXP; _SEP_EXP="$(printf "${BLD}  ── Port exposure ────────────────────${NC}")"
        lines+=("$_SEP_EXP")
        local exp_cids=() exp_names=()
        _load_containers false
        for i in "${!CT_IDS[@]}"; do
            local ecid="${CT_IDS[$i]}"
            [[ "$(_st "$ecid" installed)" != "true" ]] && continue
            local eport; eport=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$ecid/service.json" 2>/dev/null)
            local eep; eep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$ecid/service.json" 2>/dev/null)
            [[ -n "$eep" ]] && eport="$eep"
            [[ -z "$eport" || "$eport" == "0" ]] && continue
            local ename="${CT_NAMES[$i]}"
            local ect_ip; ect_ip=$(_netns_ct_ip "$ecid" "$MNT_DIR")
            lines+=("$(printf " %b  %s  ${DIM}%s:%s  %s.local${NC}" "$(_exposure_label "$(_exposure_get "$ecid")")" "$ename" "$ect_ip" "$eport" "$ecid")")
            exp_cids+=("$ecid"); exp_names+=("$ename")
        done
        [[ ${#exp_cids[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no installed containers with ports)${NC}")")

        lines+=("$_SEP_NAV" "$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Reverse proxy ──${NC}  ${DIM}ns: 10.88.%d.0/24${NC}" "$(_netns_idx "$MNT_DIR")")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "$sel" ]] && return
        local sc; sc=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*//')

        case "$sc" in
            *"${L[back]}"*) return ;;
            *"Caddy + mDNS"*)
                if $caddy_ok; then
                    _menu "Caddy + mDNS" "Reinstall / update" "Uninstall" "View log" "View Caddyfile" "Reset proxy config" || continue
                    case "$REPLY" in
                        "Reinstall / update")
                            _proxy_install_caddy "reinstall"
                            _hostpkg_mark "avahi-utils" ;;
                        "Uninstall")
                            _proxy_stop 2>/dev/null; _avahi_stop 2>/dev/null || true
                            rm -f "$(_proxy_caddy_bin)" "$(_proxy_caddy_runner)" 2>/dev/null
                            sudo -n rm -f "$(_proxy_sudoers_path)" 2>/dev/null || true
                            _hostpkg_ensure_apt_sudoers
                            local _sc; _sc=$(mktemp "$TMP_DIR/.sd_avahi_XXXXXX.sh")
                            printf '#!/usr/bin/env bash\nsudo -n apt-get remove -y avahi-utils 2>&1\n' > "$_sc"; chmod +x "$_sc"
                            _tmux_launch "sdAvahiUninst" "Uninstall mDNS (avahi-utils)" "$_sc"; rm -f "$_sc"
                            _hostpkg_unmark "avahi-utils" ;;
                        "View log") pause "$(cat "$(_proxy_caddy_log)" 2>/dev/null | tail -50 || echo "(no log)")" ;;
                        "View Caddyfile") pause "$(cat "$(_proxy_caddyfile)" 2>/dev/null || echo "(no Caddyfile)")" ;;
                        "Reset proxy config")
                            confirm "$(printf '⚠  This will:\n  - Remove all custom rerouting URLs\n  - Reset all containers to default exposure (localhost)\n\nThe Caddyfile will be regenerated from scratch.\nContinue?')" || continue
                            _proxy_stop 2>/dev/null || true
                            # Wipe proxy.json — removes all custom routes
                            printf '{"autostart":false,"routes":[]}' > "$(_proxy_cfg)"
                            # Reset all container exposure files to default (localhost)
                            _load_containers false 2>/dev/null || true
                            for _rcid in "${CT_IDS[@]}"; do
                                [[ -f "$(_exposure_file "$_rcid")" ]] && rm -f "$(_exposure_file "$_rcid")"
                            done
                            # Regenerate Caddyfile and restart
                            _proxy_write
                            _proxy_update_hosts add
                            _proxy_start
                            pause "Proxy config reset and restarted." ;;
                    esac
                else
                    _proxy_install_caddy
                    _hostpkg_mark "avahi-utils"
                    while tmux_up "sdCaddyMdnsInst_$$" 2>/dev/null; do sleep 0.3; done
                fi
                continue ;;
            *"Autostart"*)
                [[ "$autostart" == "true" ]] \
                    && local _ptmp; _ptmp=$(mktemp "$TMP_DIR/.sd_px_XXXXXX") && jq '.autostart=false' "$(_proxy_cfg)" > "$_ptmp" && mv "$_ptmp" "$(_proxy_cfg)" || rm -f "$_ptmp" \
                    || local _ptmp; _ptmp=$(mktemp "$TMP_DIR/.sd_px_XXXXXX") && jq '.autostart=true' "$(_proxy_cfg)" > "$_ptmp" && mv "$_ptmp" "$(_proxy_cfg)" || rm -f "$_ptmp" ;;
            *"Running"*)
                if _proxy_running; then
                    _proxy_stop; _avahi_stop 2>/dev/null || true; pause "Proxy stopped."
                else
                    if _proxy_start; then
                        _hostpkg_installed "avahi-utils" && _avahi_start
                        pause "Proxy started."
                    else
                        local _caddy_log_tail; _caddy_log_tail=$(tail -30 "$(_proxy_caddy_log)" 2>/dev/null || echo "(no log yet)")
                        local _extra=""
                        # Detect port conflict: "ambiguous site definition: http://localhost:PORT"
                        local _conflict_port; _conflict_port=$(printf '%s' "$_caddy_log_tail" \
                            | grep -oP 'ambiguous site definition: https?://[^:]+:\K[0-9]+' | head -1)
                        if [[ -n "$_conflict_port" ]]; then
                            local _conflicting=()
                            _load_containers false 2>/dev/null || true
                            for _cc in "${CT_IDS[@]}"; do
                                [[ "$(_st "$_cc" installed)" != "true" ]] && continue
                                local _cp; _cp=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$_cc/service.json" 2>/dev/null)
                                local _cep; _cep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$_cc/service.json" 2>/dev/null)
                                [[ -n "$_cep" ]] && _cp="$_cep"
                                [[ "$_cp" == "$_conflict_port" ]] && _conflicting+=("$(_cname "$_cc")")
                            done
                            if [[ ${#_conflicting[@]} -gt 1 ]]; then
                                local _clist; _clist=$(printf '  - %s\n' "${_conflicting[@]}")
                                _extra=$(printf '\n\n  Port conflict on :%s — containers sharing this port:\n%s\n  Fix: change one container port or set one to isolated.' \
                                    "$_conflict_port" "$_clist")
                            fi
                        fi
                        pause "$(printf '⚠  Caddy failed to start.%s\n\nLog:\n%s' "$_extra" "$_caddy_log_tail")"
                    fi
                fi ;;
            *"Add URL"*)
                _load_containers false
                [[ ${#CT_IDS[@]} -eq 0 ]] && { pause "No containers found."; continue; }
                local copts2=()
                for ci in "${CT_IDS[@]}"; do copts2+=("$(_cname "$ci")"); done
                local _fzf_out _fzf_pid _frc
                _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
                printf '%s\n' "${copts2[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Add route ──${NC}  ${DIM}Select container${NC}")" >"$_fzf_out" 2>/dev/null &
                _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
                wait "$_fzf_pid" 2>/dev/null; _frc=$?
                local csel; csel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
                _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
                [[ $_frc -ne 0 || -z "$csel" ]] && continue
                local ncid=""; for ci in "${CT_IDS[@]}"; do [[ "$(_cname "$ci")" == "$csel" ]] && ncid="$ci"; done
                local nport; nport=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$ncid/service.json" 2>/dev/null)
                local nep; nep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$ncid/service.json" 2>/dev/null)
                [[ -n "$nep" ]] && nport="$nep"
                [[ -z "$nport" || "$nport" == "0" ]] && { pause "$(printf "⚠  %s has no port defined.\n  Add 'port = XXXX' under [meta] in its blueprint." "$csel")"; continue; }
                finput "$(printf "Enter URL  (e.g. comfyui.local, myapp.local)\n\n  Use .local for zero-config LAN access on all devices (mDNS).\n  Other TLDs (e.g. .sd) only work on this machine unless you configure DNS.")" || continue
                local nurl="${FINPUT_RESULT}"; nurl="${nurl#http://}"; nurl="${nurl#https://}"; nurl="${nurl%%/*}"
                [[ -z "$nurl" ]] && continue
                local nhttps="false"
                _menu "Protocol for $nurl" "http  (no cert needed)" "https  (tls internal, CA trusted automatically)" || continue
                [[ "$REPLY" == "https"* ]] && nhttps="true"
                jq --arg u "$nurl" --arg c "$ncid" --argjson h "$nhttps" \
                    '.routes += [{"url":$u,"cid":$c,"https":$h}]' \
                    "$(_proxy_cfg)" > "$TMP_DIR/.sd_px_tmp.$$.tmp" && mv "$TMP_DIR/.sd_px_tmp.$$.tmp" "$(_proxy_cfg)" || rm -f "$TMP_DIR/.sd_px_tmp.$$.tmp"
                # Ensure Caddy CA is trusted when HTTPS selected
                [[ "$nhttps" == "true" && -x "$(_proxy_caddy_bin)" ]] \
                    && CADDY_STORAGE_DIR="$(_proxy_caddy_storage)" "$(_proxy_caddy_bin)" trust &>/dev/null &
                if _proxy_running; then
                    _proxy_stop; _proxy_start
                elif [[ "$(_proxy_get autostart)" == "true" ]]; then
                    _proxy_start --background
                fi
                pause "$(printf '✓ Added: %s → %s (port %s)\n\n  Visit: %s://%s' "$nurl" "$csel" "$nport" "$( [ "$nhttps" = "true" ] && echo "https" || echo "http" )" "$nurl")" ;;
            *)
                local _exp_hit=false
                for i in "${!exp_names[@]}"; do
                    [[ "$sc" != *"${exp_names[$i]}"* ]] && continue
                    local ecid2="${exp_cids[$i]}"
                    local _enew; _enew=$(_exposure_next "$ecid2")
                    _exposure_set "$ecid2" "$_enew"
                    tmux_up "$(tsess "$ecid2")" && _exposure_apply "$ecid2"
                    pause "$(printf "Port exposure set to: %b\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network" \
                        "$(_exposure_label "$_enew")")"
                    _exp_hit=true; break
                done
                [[ "$_exp_hit" == true ]] && continue
                # Otherwise it's a route URL — edit it
                local matched=""; local i
                for i in "${!route_lines[@]}"; do
                    [[ "$(printf '%s' "${route_lines[$i]}" | _strip_ansi | sed 's/^[[:space:]]*//')" == "$sc" ]] \
                        && matched="${route_urls[$i]}" && break
                done
                [[ -z "$matched" ]] && continue
                local rr; rr=$(jq -c --arg u "$matched" '.routes[] | select(.url==$u)' "$(_proxy_cfg)" 2>/dev/null)
                local rcid2; rcid2=$(printf '%s' "$rr" | jq -r '.cid')
                local rh2; rh2=$(printf '%s' "$rr" | jq -r '.https // "false"')
                _menu "$(printf 'Edit: %s' "$matched")" \
                    "Change URL" "Change container" "Toggle HTTPS (currently: $rh2)" "Remove" || continue
                case "$REPLY" in

                    "Change URL")
                        finput "New URL:" || continue
                        local nu="${FINPUT_RESULT}"; nu="${nu#http://}"; nu="${nu#https://}"; nu="${nu%%/*}"
                        [[ -z "$nu" ]] && continue
                        jq --arg o "$matched" --arg n "$nu" '(.routes[] | select(.url==$o)).url=$n' \
                            "$(_proxy_cfg)" > "$TMP_DIR/.sd_px_tmp.$$.tmp" && mv "$TMP_DIR/.sd_px_tmp.$$.tmp" "$(_proxy_cfg)" || rm -f "$TMP_DIR/.sd_px_tmp.$$.tmp"
                        _proxy_running && { _proxy_stop; _proxy_start; } ;;
                    "Change container")
                        _load_containers false
                        local copts3=(); for ci in "${CT_IDS[@]}"; do copts3+=("$(_cname "$ci")"); done
                        local _fzf_out _fzf_pid _frc
                        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
                        printf '%s\n' "${copts3[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Route: new container ──${NC}")" >"$_fzf_out" 2>/dev/null &
                        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
                        wait "$_fzf_pid" 2>/dev/null; _frc=$?
                        local cs3; cs3=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
                        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
                        [[ $_frc -ne 0 || -z "$cs3" ]] && continue
                        local nc3=""; for ci in "${CT_IDS[@]}"; do [[ "$(_cname "$ci")" == "$cs3" ]] && nc3="$ci"; done
                        jq --arg u "$matched" --arg c "$nc3" '(.routes[] | select(.url==$u)).cid=$c' \
                            "$(_proxy_cfg)" > "$TMP_DIR/.sd_px_tmp.$$.tmp" && mv "$TMP_DIR/.sd_px_tmp.$$.tmp" "$(_proxy_cfg)" || rm -f "$TMP_DIR/.sd_px_tmp.$$.tmp"
                        _proxy_running && { _proxy_stop; _proxy_start; } ;;
                    *"Toggle HTTPS"*)
                        local newh; [[ "$rh2" == "true" ]] && newh=false || newh=true
                        jq --arg u "$matched" --argjson h "$newh" '(.routes[] | select(.url==$u)).https=$h' \
                            "$(_proxy_cfg)" > "$TMP_DIR/.sd_px_tmp.$$.tmp" && mv "$TMP_DIR/.sd_px_tmp.$$.tmp" "$(_proxy_cfg)" || rm -f "$TMP_DIR/.sd_px_tmp.$$.tmp"
                        _proxy_running && { _proxy_stop; _proxy_start; } ;;
                    "Remove")
                        confirm "Remove $matched?" || continue
                        jq --arg u "$matched" '.routes=[.routes[] | select(.url!=$u)]' \
                            "$(_proxy_cfg)" > "$TMP_DIR/.sd_px_tmp.$$.tmp" && mv "$TMP_DIR/.sd_px_tmp.$$.tmp" "$(_proxy_cfg)" || rm -f "$TMP_DIR/.sd_px_tmp.$$.tmp"
                        _proxy_running && { _proxy_stop; _proxy_start; } ;;
                esac ;;
        esac
    done
}
