#!/usr/bin/env bash

_ubuntu_pkg_list() {
    # Returns installed packages: name\tversion\tsys
    # sys=1 for Essential:yes or Priority:required/important packages (Ubuntu system core)
    _chroot_bash "$UBUNTU_DIR" -c \
        "dpkg-query -W -f='\${Package}\t\${Version}\t\${Status}\t\${Essential}\t\${Priority}\n' 2>/dev/null \
         | awk -F'\t' '\$3~/installed/{sys=(\$4==\"yes\"||\$5==\"required\"||\$5==\"important\")?1:0; print \$1\"\t\"\$2\"\t\"sys}'" 2>/dev/null
}

_ubuntu_pkg_updates() {
    # Returns package names that have upgrades available
    _chroot_bash "$UBUNTU_DIR" -c \
        "apt-get update -qq 2>/dev/null; apt-get --simulate upgrade 2>/dev/null \
         | awk '/^Inst /{print \$2}'" 2>/dev/null
}

_ubuntu_pkg_tmux() {
    local sess="$1" title="$2" cmd="$3" chroot_dir="${4:-$UBUNTU_DIR}"
    local ok_file="$UBUNTU_DIR/.upkg_ok" fail_file="$UBUNTU_DIR/.upkg_fail"
    rm -f "$ok_file" "$fail_file"
    local script; script=$(mktemp "$TMP_DIR/.sd_upkg_XXXXXX.sh")
    local _sd_cfn='_chroot_bash() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }'
    # Write the command to a separate script to avoid %q escaping && || {} metacharacters
    local inner_script; inner_script=$(mktemp "$TMP_DIR/.sd_upkg_inner_XXXXXX.sh")
    printf '#!/bin/sh\nset -e\n%s\n' "$cmd" > "$inner_script"
    chmod +x "$inner_script"
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$_sd_cfn"
        printf 'trap '\'''\'' INT\n'
        printf 'printf "\\033[1m── %s ──\\033[0m\\n\\n"\n' "$title"
        printf 'sudo -n mount --bind /proc %q/proc 2>/dev/null || true\n' "$chroot_dir"
        printf 'sudo -n mount --bind /sys  %q/sys  2>/dev/null || true\n' "$chroot_dir"
        printf 'sudo -n mount --bind /dev  %q/dev  2>/dev/null || true\n' "$chroot_dir"
        printf 'sudo -n mount --bind %q %q/tmp/.sd_upkg_inner.sh 2>/dev/null || cp %q %q/tmp/.sd_upkg_inner.sh 2>/dev/null || true\n' \
            "$inner_script" "$chroot_dir" "$inner_script" "$chroot_dir"
        printf 'if _chroot_bash %q /tmp/.sd_upkg_inner.sh; then\n' "$chroot_dir"
        printf '    touch %q\n' "$ok_file"
        printf '    printf "\\n\\033[0;32m✓ Done.\\033[0m\\n"\n'
        printf 'else\n'
        printf '    touch %q\n' "$fail_file"
        printf '    printf "\\n\\033[0;31m✗ Failed.\\033[0m\\n"\n'
        printf 'fi\n'
        printf 'sudo -n umount -lf %q/tmp/.sd_upkg_inner.sh 2>/dev/null || true\n' "$chroot_dir"
        printf 'sudo -n umount -lf %q/dev %q/sys %q/proc 2>/dev/null || true\n' "$chroot_dir" "$chroot_dir" "$chroot_dir"
        printf 'rm -f %q %q/tmp/.sd_upkg_inner.sh 2>/dev/null || true\n' "$inner_script" "$chroot_dir"
        printf 'sleep 1\n'
        printf 'tmux kill-session -t %q 2>/dev/null || true\n' "$sess"
    } > "$script"
    chmod +x "$script"

    local _tl_rc
    _tmux_launch "$sess" "$title" "$script"
    _tl_rc=$?
    [[ $_tl_rc -eq 1 ]] && { rm -f "$script"; return 1; }
    return 0
}

_guard_ubuntu_pkg() {
    tmux_up "sdUbuntuPkg" || return 0
    _menu "$(printf "${BLD}⚠  Ubuntu pkg operation in progress${NC}")" \
        "→  Attach" "×  Kill" || return 1
    case "$REPLY" in
        "→  Attach") _tmux_attach_hint "ubuntu pkg" "sdUbuntuPkg" || true; return 1 ;;
        "×  Kill")   sd_confirm "Kill the running operation?" || return 1
                     tmux kill-session -t "sdUbuntuPkg" 2>/dev/null || true; return 0 ;;
        *) return 1 ;;
    esac
}

_ubuntu_menu() {
    [[ -z "$UBUNTU_DIR" ]] && return
    while true; do
        # ── If setup or pkg session is running, show installing-style menu ──
        local _ub_ok="$UBUNTU_DIR/.ubuntu_ok_flag" _ub_fail="$UBUNTU_DIR/.ubuntu_fail_flag"
        local _upkg_ok="$UBUNTU_DIR/.upkg_ok" _upkg_fail="$UBUNTU_DIR/.upkg_fail"
        if tmux_up "sdUbuntuSetup" || tmux_up "sdUbuntuPkg"; then
            local _running_sess; _running_sess=$(tmux_up "sdUbuntuSetup" && echo "sdUbuntuSetup" || echo "sdUbuntuPkg")
            local _running_ok;   _running_ok=$(  [[ "$_running_sess" == "sdUbuntuSetup" ]] && echo "$_ub_ok"   || echo "$_upkg_ok")
            local _running_fail; _running_fail=$([[ "$_running_sess" == "sdUbuntuSetup" ]] && echo "$_ub_fail" || echo "$_upkg_fail")
            _pkg_op_wait "$_running_sess" "$_running_ok" "$_running_fail" "Ubuntu operation" && continue || return
        fi

        if [[ ! -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
            sd_confirm "Ubuntu base not installed. Download and install now?" || return
            _ensure_ubuntu
            continue
        fi

        # Read background cache results on first pass (blocks max 3s if still running)
        _sd_ub_cache_read

        # ── Gather info ──
        local ub_ver; ub_ver=$(grep PRETTY_NAME "$UBUNTU_DIR/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"')
        local ub_size; ub_size=$(du -sh "$UBUNTU_DIR" 2>/dev/null | cut -f1)

        # ── Determine default pkg set ──
        local cur_default_pkgs=()
        read -ra cur_default_pkgs <<< "$DEFAULT_UBUNTU_PKGS"

        # Build associative map of installed packages → version
        declare -A installed_map=()
        while IFS=$'\t' read -r pkg ver _is_sys; do
            [[ -n "$pkg" ]] && installed_map["$pkg"]="$ver"
        done < <(_ubuntu_pkg_list 2>/dev/null)

        # Is pkg in the current default list?
        _is_default_pkg() {
            local p="$1"
            for dp in "${cur_default_pkgs[@]+"${cur_default_pkgs[@]}"}"; do [[ "$dp" == "$p" ]] && return 0; done
            return 1
        }

        # ── Get installed packages — split into default / system / extra ──
        # Build as "line\tkey" pairs so sort keeps them in sync, then split
        local def_pairs=() sys_pairs=() pkg_pairs=()
        while IFS=$'\t' read -r pkg ver is_sys; do
            [[ -z "$pkg" ]] && continue
            installed_map["$pkg"]="$ver"
            local line; line=$(printf " ${CYN}◈${NC}  %-28s ${DIM}%s${NC}" "$pkg" "$ver")
            local key="$pkg|$ver"
            if _is_default_pkg "$pkg"; then
                def_pairs+=("${line}	${key}")
            elif [[ "$is_sys" == "1" ]]; then
                sys_pairs+=("${line}	${key}")
            else
                pkg_pairs+=("${line}	${key}")
            fi
        done < <(_ubuntu_pkg_list 2>/dev/null)
        IFS=$'\n' def_pairs=($(printf '%s\n' "${def_pairs[@]+"${def_pairs[@]}"}" | sort))
        IFS=$'\n' sys_pairs=($(printf '%s\n' "${sys_pairs[@]+"${sys_pairs[@]}"}" | sort))
        IFS=$'\n' pkg_pairs=($(printf '%s\n' "${pkg_pairs[@]+"${pkg_pairs[@]}"}" | sort))
        unset IFS

        local def_lines=() def_keys=()
        for pair in "${def_pairs[@]+"${def_pairs[@]}"}"; do
            def_lines+=("${pair%	*}"); def_keys+=("${pair##*	}")
        done
        local sys_lines=() sys_keys=()
        for pair in "${sys_pairs[@]+"${sys_pairs[@]}"}"; do
            sys_lines+=("${pair%	*}"); sys_keys+=("${pair##*	}")
        done
        local pkg_lines=() pkg_keys=()
        for pair in "${pkg_pairs[@]+"${pkg_pairs[@]}"}"; do
            pkg_lines+=("${pair%	*}"); pkg_keys+=("${pair##*	}")
        done

        # ── Build status tags from mount-time cache ──
        local _drift_tag _upd_tag
        if [[ "$_SD_UB_PKG_DRIFT" == true ]]; then
            _drift_tag="  $(printf "${YLW}[changes detected]${NC}")"
        else
            _drift_tag="  $(printf "${GRN}[up to date]${NC}")"
        fi
        if [[ "$_SD_UB_HAS_UPDATES" == true ]]; then
            _upd_tag="  $(printf "${YLW}[updates available]${NC}")"
        else
            _upd_tag="  $(printf "${GRN}[up to date]${NC}")"
        fi

        # ── Build fzf list ──
        local lines=()
        lines+=("$(printf "${BLD} ── Actions ─────────────────────────────${NC}")")
        lines+=("$(printf " ${CYN}◈${NC}  Updates")")
        lines+=("$(printf " ${CYN}◈${NC}  Uninstall Ubuntu base")")
        lines+=("$(printf "${BLD} ── Default packages ────────────────────${NC}")")
        for l in "${def_lines[@]+"${def_lines[@]}"}"; do lines+=("$l"); done
        if [[ ${#def_lines[@]} -eq 0 ]]; then
            lines+=("$(printf " ${DIM} (none installed yet)${NC}")")
        fi
        lines+=("$(printf "${BLD} ── System packages ─────────────────────${NC}")")
        for l in "${sys_lines[@]+"${sys_lines[@]}"}"; do lines+=("$l"); done
        if [[ ${#sys_lines[@]} -eq 0 ]]; then
            lines+=("$(printf " ${DIM} (none)${NC}")")
        fi
        lines+=("$(printf "${BLD} ── Packages ────────────────────────────${NC}")")
        for l in "${pkg_lines[@]+"${pkg_lines[@]}"}"; do lines+=("$l"); done
        if [[ ${#pkg_lines[@]} -eq 0 ]]; then
            lines+=("$(printf " ${DIM} (no extra packages)${NC}")")
        fi
        lines+=("$(printf " ${GRN}+${NC}  Add package")")
        lines+=("$(printf "${BLD} ── Navigation ──────────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local header_info
        header_info="$(printf "${BLD}── Ubuntu base ──${NC}  ${DIM}%s${NC}  ${DIM}Size:${NC} %s  ${CYN}[P]${NC}" \
            "${ub_ver:-Ubuntu 24.04}" "${ub_size:-?}")"

        local _fzf_sel_out; _fzf_sel_out=$(mktemp "$TMP_DIR/.sd_fzf_sel_XXXXXX")
        printf '%s\n' "${lines[@]}" \
            | fzf "${FZF_BASE[@]}" \
                  --header="$header_info" \
                  >"$_fzf_sel_out" 2>/dev/null &
        local _fzf_sel_pid=$!
        printf '%s' "$_fzf_sel_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_sel_pid" 2>/dev/null
        local _fzf_rc=$?
        _sig_rc $_fzf_rc && { rm -f "$_fzf_sel_out"; stty sane 2>/dev/null; continue; }
        local sel; sel=$(cat "$_fzf_sel_out" 2>/dev/null); rm -f "$_fzf_sel_out"
        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" || -z "$clean" ]] && return
        [[ "$clean" == ──* || "$clean" == "── "* ]] && continue

        # ── Updates submenu ──
        if [[ "$clean" == *"Updates"* ]]; then
            local _upd_lines=(
                "$(printf "${BLD} ── Updates ─────────────────────────────${NC}")"
                "$(printf " ${CYN}◈${NC}  Sync default pkgs%b" "$_drift_tag")"
                "$(printf " ${CYN}◈${NC}  Update all pkgs%b"   "$_upd_tag")"
                "$(printf "${BLD} ── Navigation ──────────────────────────${NC}")"
                "$(printf "${DIM} %s${NC}" "${L[back]}")"
            )
            local _upd_out; _upd_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
            printf '%s
' "${_upd_lines[@]}" | fzf "${FZF_BASE[@]}"                 --header="$(printf "${BLD}── Updates ──${NC}")"                 >"$_upd_out" 2>/dev/null &
            local _upd_pid=$!; printf '%s' "$_upd_pid" > "$TMP_DIR/.sd_active_fzf_pid"
            wait "$_upd_pid" 2>/dev/null; local _upd_frc=$?
            local _upd_sel; _upd_sel=$(cat "$_upd_out" 2>/dev/null | _trim_s); rm -f "$_upd_out"
            _sig_rc $_upd_frc && { stty sane 2>/dev/null; continue; }
            [[ $_upd_frc -ne 0 || -z "$_upd_sel" ]] && continue
            local _upd_clean; _upd_clean=$(printf '%s' "$_upd_sel" | _strip_ansi | sed 's/^[[:space:]]*//')
            case "$_upd_clean" in
                *"${L[back]}"*|"") continue ;;
                *"Sync default pkgs"*)
                    local _cur_missing=()
                    for dp in "${cur_default_pkgs[@]}"; do
                        [[ -z "${installed_map[$dp]+x}" ]] && _cur_missing+=("$dp")
                    done
                    if [[ ${#_cur_missing[@]} -eq 0 && "$_SD_UB_PKG_DRIFT" == false ]]; then
                        sd_msg "Already up to date."; continue
                    fi
                    local _sync_pkgs="${_cur_missing[*]:-$DEFAULT_UBUNTU_PKGS}"
                    local sync_cmd="apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${_sync_pkgs} 2>&1"
                    _ubuntu_pkg_tmux "sdUbuntuPkg" "Sync default pkgs" "$sync_cmd" || continue
                    _pkg_op_wait "sdUbuntuPkg" "$_upkg_ok" "$_upkg_fail" "Sync default pkgs" || { continue; }
                    # Update saved default pkgs file + reset drift cache
                    printf '%s
' "${cur_default_pkgs[@]}" > "$(_ubuntu_default_pkgs_file)" 2>/dev/null || true
                    _SD_UB_PKG_DRIFT=false; _SD_UB_CACHE_LOADED=true
                    continue ;;
                *"Update all pkgs"*)
                    local upd_cmd="apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1"
                    _ubuntu_pkg_tmux "sdUbuntuPkg" "Update all pkgs" "$upd_cmd" || continue
                    _pkg_op_wait "sdUbuntuPkg" "$_upkg_ok" "$_upkg_fail" "Update all pkgs" || { continue; }
                    _SD_UB_HAS_UPDATES=false; _SD_UB_CACHE_LOADED=true
                    continue ;;
            esac
            continue
        fi

        # ── Uninstall ──
        if [[ "$clean" == *"Uninstall Ubuntu base"* ]]; then
            sd_sd_confirm "$(printf "${YLW}⚠  Uninstall Ubuntu base?${NC}\n\nThis will wipe the Ubuntu chroot.\nAll installed packages will be lost.\nContainers that depend on it will stop working.")" || continue
            rm -rf "$UBUNTU_DIR" 2>/dev/null
            mkdir -p "$UBUNTU_DIR" 2>/dev/null
            sd_msg "✓ Ubuntu base removed."
            return
        fi

        # ── Add package ──
        if [[ "$clean" == *"Add package"* ]]; then
            local pkg_name
            sd_input "Package name (e.g. ffmpeg, nodejs):" || continue
            pkg_name="${SD_MSG// /}"
            [[ -z "$pkg_name" ]] && continue
            local pkg_ver
            sd_input "$(printf "Version (leave blank for latest):")" || continue
            pkg_ver="${SD_MSG// /}"
            local apt_target="$pkg_name"
            [[ -n "$pkg_ver" ]] && apt_target="${pkg_name}=${pkg_ver}"
            local apt_cmd="DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${apt_target} 2>&1 || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${apt_target}; }"
            _ubuntu_pkg_tmux "sdUbuntuPkg" "Installing ${apt_target}" "$apt_cmd"
            continue
        fi

        # ── Package selected — check default section first, then system, then extra ──
        local chosen_key=""
        for i in "${!def_lines[@]}"; do
            local lc; lc=$(printf '%s' "${def_lines[$i]}" | _trim_s)
            if [[ "$lc" == "$clean" ]]; then chosen_key="${def_keys[$i]}"; break; fi
        done
        if [[ -n "$chosen_key" ]]; then
            local cpkg="${chosen_key%%|*}"
            sd_msg "$(printf "Protected package\n\n'%s' is a default Ubuntu package.\nUnable to modify this package." "$cpkg")"
            continue
        fi
        for i in "${!sys_lines[@]}"; do
            local lc; lc=$(printf '%s' "${sys_lines[$i]}" | _trim_s)
            if [[ "$lc" == "$clean" ]]; then chosen_key="${sys_keys[$i]}"; break; fi
        done
        if [[ -n "$chosen_key" ]]; then
            local cpkg="${chosen_key%%|*}"
            sd_msg "$(printf "System package\n\n'%s' is an Ubuntu system package.\nRemoving it would break the system.\nUnable to modify this package." "$cpkg")"
            continue
        fi
        for i in "${!pkg_lines[@]}"; do
            local lc; lc=$(printf '%s' "${pkg_lines[$i]}" | _trim_s)
            if [[ "$lc" == "$clean" ]]; then chosen_key="${pkg_keys[$i]}"; break; fi
        done
        [[ -z "$chosen_key" ]] && continue

        local cpkg="${chosen_key%%|*}"
        local cver="${chosen_key#*|}"

        # Non-default: confirm remove only (no per-package update)
        sd_sd_confirm "$(printf "Remove '${BLD}%s${NC}' from Ubuntu base?\n\n${DIM}%s${NC}" "$cpkg" "$cver")" || continue
        local rm_cmd="DEBIAN_FRONTEND=noninteractive apt-get remove -y ${cpkg} 2>&1"
        _ubuntu_pkg_tmux "sdUbuntuPkg" "Removing ${cpkg}" "$rm_cmd"
    done
}
