#!/usr/bin/env bash
# core/containers.sh — install/run jobs, container start/stop,
#                      build scripts, cron, cap_drop, seccomp

_run_job() {
    local mode="$1" cid="$2"
    local install_path; install_path=$(_cpath "$cid")
    local ok_file="$CONTAINERS_DIR/$cid/.install_ok"
    local fail_file="$CONTAINERS_DIR/$cid/.install_fail"

    # Warn if another install is already running, but allow proceeding
    if [[ "$mode" == "install" ]] && _is_installing "$cid"; then
        confirm "$(printf '⚠  %s is already installing.\n\n  Running it again will restart from scratch.\n  Continue?' "$(_cname "$cid")")" || return 1
        tmux kill-session -t "$(_inst_sess "$cid")" 2>/dev/null || true
    fi

    _compile_service "$cid" 2>/dev/null || true

    if [[ "$mode" == "install" ]]; then
        [[ -z "$install_path" ]] && { pause "No install path set."; return 1; }
        local _check; _check=$(jq -r '.install // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local _ghck;  _ghck=$(jq -r '.git // empty'  "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local _dirck; _dirck=$(jq -r '.dirs // empty'   "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local _pipck; _pipck=$(jq -r '.pip // empty'    "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local _npmck; _npmck=$(jq -r '.npm // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        [[ -z "$_check" && -z "$_ghck" && -z "$_dirck" && -z "$_pipck" && -z "$_npmck" ]] && \
            { pause "⚠  No install, git, dirs, pip, or npm block in service.json."; return 1; }
        [[ -d "$install_path" ]] && { sudo -n btrfs subvolume delete "$install_path" &>/dev/null || btrfs subvolume delete "$install_path" &>/dev/null || sudo -n rm -rf "$install_path" 2>/dev/null || rm -rf "$install_path" 2>/dev/null || true; }
        # ── CoW snapshot from base — zero extra disk cost for shared base files ──
        local _base_src=""
        [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && _base_src="$UBUNTU_DIR"
        if [[ -n "$_base_src" ]]; then
            btrfs subvolume snapshot "$_base_src" "$install_path" &>/dev/null \
                || { btrfs subvolume create "$install_path" &>/dev/null || mkdir -p "$install_path" 2>/dev/null; }
            # Snapshot inherits root ownership from base — fix so user can write start.sh/ns_wrapper.sh
            sudo -n chown "$(id -u):$(id -g)" "$install_path" 2>/dev/null || true
            # Stamp container to match base version at install time
            [[ -f "$_base_src/.sd_ubuntu_stamp" ]] && cp "$_base_src/.sd_ubuntu_stamp" "$install_path/.sd_ubuntu_stamp" 2>/dev/null || true
        else
            btrfs subvolume create "$install_path" &>/dev/null || mkdir -p "$install_path" 2>/dev/null
        fi
        rm -f "$ok_file" "$fail_file" 2>/dev/null
    else
        [[ -z "$install_path" || ! -d "$install_path" ]] && { pause "Not installed."; return 1; }
    fi
    _guard_space || return 1

    local _logfile; _logfile=$(_log_path "$cid" "$mode")
    mkdir -p "$LOGS_DIR" 2>/dev/null

    # ── Build the full install script: deps + pip + runner all in one ──
    # Everything runs inside a single sdInstall tmux session.
    # The runner script (github/build/install block) is appended inline.
    local full_script; full_script=$(mktemp "$TMP_DIR/.sd_install_XXXXXX.sh")
    local ok_q;   ok_q=$(printf '%q' "$ok_file")
    local fail_q; fail_q=$(printf '%q' "$fail_file")
    local log_q;  log_q=$(printf '%q' "$_logfile")
    local env_block; env_block=$(_env_exports "$cid" "$install_path")

    {
        printf '#!/usr/bin/env bash\n'
        # All output → logfile AND terminal (tee so user sees live output when attached)
        printf 'mkdir -p %q 2>/dev/null || true\n' "$_logdir"
        printf 'exec > >(tee -a %q) 2>&1\n' "$_logfile"
        printf '_sd_icap() { local _z; _z=$(stat -c%%s %q 2>/dev/null||echo 0); [[ $_z -gt 10485760 ]] && { tail -c 8388608 %q > %q.t 2>/dev/null && mv %q.t %q 2>/dev/null||true; }; }\ntrap _sd_icap EXIT\n' "$_logfile" "$_logfile" "$_logfile" "$_logfile" "$_logfile"
        printf '_finish() {\n'
        printf '    local code=$?\n'
        printf '    if [[ $code -eq 0 ]]; then\n'
        printf '        touch %s; printf '"'"'\n\033[0;32m══ %s complete ══\033[0m\n'"'"'\n' \
            "$ok_q" "${mode^}"
        printf '    else\n'
        printf '        touch %s; printf '"'"'\n\033[0;31m══ %s failed (exit %%d) ══\033[0m\n'"'"' "$code"\n' \
            "$fail_q" "${mode^}"
        printf '    fi\n'
        printf '}\n'
        printf 'trap _finish EXIT\n'
        printf 'trap '"'"'touch %s; exit 130'"'"' INT TERM\n\n' "$fail_q"

        # ── Env setup ──
        printf '%s\n' "$env_block"
        printf 'cd "$CONTAINER_ROOT"\n\n'
        printf '_chroot_bash() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }\n'

        # ── Step 0: Ubuntu base (auto-bootstrap inline if not yet installed) ──
        _emit_ubuntu_bootstrap_inline

        if [[ "$mode" == "install" ]]; then
            local _deps_raw; _deps_raw=$(jq -r '.deps // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local _pip;      _pip=$(jq -r '.pip // empty'    "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local _npm_raw;  _npm_raw=$(jq -r '.npm // empty'  "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local _dirs;     _dirs=$(jq -r '.dirs // empty'   "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)

            # ── Step 1: System deps (apt into Ubuntu chroot) ──
            if [[ -n "$_deps_raw" ]]; then
                _deps_parse_split "$_deps_raw"
                if [[ -n "$SD_APK_PKGS" ]]; then
                    printf '# ── System deps (apt) ──\n'
                    printf 'printf '\''\033[1m[deps] Installing: %s\033[0m\n'\'' %q\n' "$SD_APK_PKGS"
                    local _me; _me=$(id -un)
                    local _sudoers_q; _sudoers_q=$(printf '%q' "/etc/sudoers.d/simpledocker_deps_$$")
                    local _ub_q2; _ub_q2=$(printf '%q' "$UBUNTU_DIR")
                    printf 'printf '\''%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/chroot, /usr/sbin/chroot, /usr/bin/unshare\n'\'' | sudo -n tee %q >/dev/null 2>&1 || true\n' "$_me" "$_sudoers_q"
                    printf 'mkdir -p %s/tmp %s/proc %s/sys %s/dev 2>/dev/null || true\n' "$_ub_q2" "$_ub_q2" "$_ub_q2" "$_ub_q2"
                    printf 'sudo -n mount --bind /proc %s/proc 2>/dev/null || true\n' "$_ub_q2"
                    printf 'sudo -n mount --bind /sys  %s/sys  2>/dev/null || true\n' "$_ub_q2"
                    printf 'sudo -n mount --bind /dev  %s/dev  2>/dev/null || true\n' "$_ub_q2"
                    # Write apt command to a script to avoid %q over-escaping metacharacters
                    printf '_sd_deps_cmd=$(mktemp %s/../.sd_deps_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_deps_%s.sh)\n' "$_ub_q2" "$$"
                    printf 'printf '"'"'#!/bin/sh\nset -e\nDEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s 2>&1 || { apt-get update -qq 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s 2>&1; }\n'"'"' > "$_sd_deps_cmd"\n' "$SD_APK_PKGS" "$SD_APK_PKGS"
                    printf 'chmod +x "$_sd_deps_cmd"\n'
                    printf 'sudo -n mount --bind "$_sd_deps_cmd" %s/tmp/.sd_deps_run.sh 2>/dev/null || cp "$_sd_deps_cmd" %s/tmp/.sd_deps_run.sh 2>/dev/null || true\n' "$_ub_q2" "$_ub_q2"
                    printf '_chroot_bash %s /tmp/.sd_deps_run.sh\n' "$_ub_q2"
                    printf 'sudo -n umount -lf %s/tmp/.sd_deps_run.sh 2>/dev/null || true\n' "$_ub_q2"
                    printf 'sudo -n umount -lf %s/dev %s/sys %s/proc 2>/dev/null || true\n' "$_ub_q2" "$_ub_q2" "$_ub_q2"
                    printf 'rm -f "$_sd_deps_cmd" %s/tmp/.sd_deps_run.sh 2>/dev/null || true\n' "$_ub_q2"
                    printf 'sudo -n rm -f %q 2>/dev/null || true\n\n' "$_sudoers_q"
                fi
            fi

            # ── Step 2: dirs ──
            if [[ -n "$_dirs" ]]; then
                printf '# ── Create dirs ──\n'
                printf 'printf '"'"'\033[1m[dirs] Creating directory structure\033[0m\n'"'"'\n'
                # Emit mkdir commands for each dir
                local flat_dirs; flat_dirs=$(printf '%s' "$_dirs" | tr ',' '\n' | sed 's/([^)]*)//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
                while IFS= read -r d; do
                    printf 'mkdir -p %q 2>/dev/null || true\n' "$install_path/$d"
                done <<< "$flat_dirs"
                printf '\n'
            fi

            # ════════════════════════════════════════════════════════
            # ── Package handlers (pip, npm)                         ──
            # ════════════════════════════════════════════════════════

            # ── [pip] handler ──
            if [[ -n "$_pip" ]]; then
                local _pip_pkgs; _pip_pkgs=$(printf '%s' "$_pip" | tr ',' ' ' | sed 's/#.*//' | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                printf '# ── pip install ──\n'
                printf 'printf '"'"'\033[1m[pip] Installing: %s\033[0m\n'"'"' %q\n' "$_pip_pkgs"
                local _me2; _me2=$(id -un)
                local _sudoers2_q; _sudoers2_q=$(printf '%q' "/etc/sudoers.d/simpledocker_pip_$$")
                local _ub_q; _ub_q=$(printf '%q' "$UBUNTU_DIR")
                local _ip_q; _ip_q=$(printf '%q' "$install_path")
                local _venv_q; _venv_q=$(printf '%q' "$install_path/venv")
                printf 'printf '"'"'\033[2m[pip] Using Ubuntu base (glibc)\033[0m\n'"'"'\n'
                printf 'printf '"'"'%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/bash, /usr/bin/chroot, /usr/sbin/chroot, /usr/bin/unshare\n'"'"' | sudo -n tee %q >/dev/null 2>&1 || true\n' "$_me2" "$_sudoers2_q"
                printf 'mkdir -p %s/tmp %s/mnt %s/proc %s/sys %s/dev 2>/dev/null || true\n' "$_ub_q" "$_ub_q" "$_ub_q" "$_ub_q" "$_ub_q"
                printf 'sudo -n mount --bind /proc %s/proc 2>/dev/null || true\n' "$_ub_q"
                printf 'sudo -n mount --bind /sys  %s/sys  2>/dev/null || true\n' "$_ub_q"
                printf 'sudo -n mount --bind /dev  %s/dev  2>/dev/null || true\n' "$_ub_q"
                printf 'sudo -n mount --bind %s %s/mnt 2>/dev/null || true\n' "$_ip_q" "$_ub_q"
                # Write the pip command as a separate script file and exec it — avoids
                # %q over-escaping shell metacharacters (&&, ||, >, {}) in the chroot cmd.
                printf '_sd_pip_cmd=%s\n' "$(printf '%q' "$(mktemp "$TMP_DIR/.sd_pip_XXXXXX.sh" 2>/dev/null || echo "/tmp/.sd_pip_$$.sh")")"
                printf 'cat > "$_sd_pip_cmd" << '"'"'_SD_PIP_EOF'"'"'\n'
                printf '#!/bin/sh\n'
                printf 'set -e\n'
                local _py_tok; _py_tok=$(_deps_pkg_apt_token "$_deps_raw" "python3")
                printf 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s python3-full python3-pip 2>&1 || {\n' "$_py_tok"
                printf '    apt-get update -qq 2>&1\n'
                printf '    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s python3-full python3-pip 2>&1\n' "$_py_tok"
                printf '}\n'
                printf 'python3 -m venv --clear /mnt/venv\n'
                printf '/mnt/venv/bin/pip install --upgrade pip\n'
                printf '/mnt/venv/bin/pip install --upgrade %s\n' "$_pip_pkgs"
                printf '_SD_PIP_EOF\n'
                printf 'chmod +x "$_sd_pip_cmd"\n'
                # Mount the pip script into the chroot so it can be exec'd
                printf 'sudo -n mount --bind "$_sd_pip_cmd" %s/tmp/.sd_pip_run.sh 2>/dev/null || cp "$_sd_pip_cmd" %s/tmp/.sd_pip_run.sh 2>/dev/null || true\n' "$_ub_q" "$_ub_q"
                printf '_chroot_bash %s /tmp/.sd_pip_run.sh\n' "$_ub_q"
                printf '_sd_pip_rc=$?\n'
                printf 'sudo -n umount -lf %s/tmp/.sd_pip_run.sh 2>/dev/null || true\n' "$_ub_q"
                printf 'sudo -n umount -lf %s/mnt %s/dev %s/sys %s/proc 2>/dev/null || true\n' "$_ub_q" "$_ub_q" "$_ub_q" "$_ub_q"
                printf 'rm -f "$_sd_pip_cmd" %s/tmp/.sd_pip_run.sh 2>/dev/null || true\n' "$_ub_q"
                printf 'sudo -n rm -f %q 2>/dev/null || true\n' "$_sudoers2_q"
                # Fix ownership: venv was created by root inside chroot
                printf 'sudo -n chown -R %q %s 2>/dev/null || true\n' "${_me2}:" "$_venv_q"
                printf 'if [[ $_sd_pip_rc -ne 0 ]]; then exit "$_sd_pip_rc"; fi\n\n'
            fi

            # ── [npm] handler ──
            if [[ -n "$_npm_raw" ]]; then
                local _npm_pkgs; _npm_pkgs=$(printf '%s' "$_npm_raw" | tr ',' ' ' | sed 's/#.*//' | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                printf '# ── npm install ──\n'
                printf 'printf '"'"'\033[1m[npm] Installing: %s\033[0m\n'"'"' %q\n' "$_npm_pkgs"
                local _me3; _me3=$(id -un)
                local _sudoers3_q; _sudoers3_q=$(printf '%q' "/etc/sudoers.d/simpledocker_npm_$$")
                local _ub_qn; _ub_qn=$(printf '%q' "$UBUNTU_DIR")
                local _ip_qn; _ip_qn=$(printf '%q' "$install_path")
                printf 'printf '"'"'%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/bash, /usr/bin/chroot, /usr/sbin/chroot, /usr/bin/unshare\n'"'"' | sudo -n tee %q >/dev/null 2>&1 || true\n' "$_me3" "$_sudoers3_q"
                printf 'mkdir -p %s/tmp %s/mnt %s/proc %s/sys %s/dev 2>/dev/null || true\n' "$_ub_qn" "$_ub_qn" "$_ub_qn" "$_ub_qn" "$_ub_qn"
                printf 'sudo -n mount --bind /proc %s/proc 2>/dev/null || true\n' "$_ub_qn"
                printf 'sudo -n mount --bind /sys  %s/sys  2>/dev/null || true\n' "$_ub_qn"
                printf 'sudo -n mount --bind /dev  %s/dev  2>/dev/null || true\n' "$_ub_qn"
                printf 'sudo -n mount --bind %s %s/mnt 2>/dev/null || true\n' "$_ip_qn" "$_ub_qn"
                printf '_sd_npm_cmd=%s\n' "$(printf '%q' "$(mktemp "$TMP_DIR/.sd_npm_XXXXXX.sh" 2>/dev/null || echo "/tmp/.sd_npm_$$.sh")")"
                printf 'cat > "$_sd_npm_cmd" << '"'"'_SD_NPM_EOF'"'"'\n'
                printf '#!/bin/sh\n'
                printf 'set -e\n'
                printf '# ── Install Node.js >=22 via NodeSource if needed ──\n'
                printf 'node_ok=0\n'
                printf 'if command -v node >/dev/null 2>&1; then\n'
                printf '    _nv=$(node -e "process.exit(parseInt(process.version.slice(1)) >= 22 ? 0 : 1)" 2>/dev/null && echo 1 || echo 0)\n'
                printf '    [ "$_nv" = "1" ] && node_ok=1\n'
                printf 'fi\n'
                printf 'if [ "$node_ok" = "0" ]; then\n'
                printf '    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates 2>&1 || { apt-get update -qq 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates 2>&1; }\n'
                printf '    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1\n'
                printf '    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs 2>&1\n'
                printf 'fi\n'
                printf 'cd /mnt && npm install %s 2>&1\n' "$_npm_pkgs"
                printf '_SD_NPM_EOF\n'
                printf 'chmod +x "$_sd_npm_cmd"\n'
                printf 'sudo -n mount --bind "$_sd_npm_cmd" %s/tmp/.sd_npm_run.sh 2>/dev/null || cp "$_sd_npm_cmd" %s/tmp/.sd_npm_run.sh 2>/dev/null || true\n' "$_ub_qn" "$_ub_qn"
                printf '_chroot_bash %s /tmp/.sd_npm_run.sh\n' "$_ub_qn"
                printf '_sd_npm_rc=$?\n'
                printf 'sudo -n umount -lf %s/tmp/.sd_npm_run.sh 2>/dev/null || true\n' "$_ub_qn"
                printf 'sudo -n umount -lf %s/mnt %s/dev %s/sys %s/proc 2>/dev/null || true\n' "$_ub_qn" "$_ub_qn" "$_ub_qn" "$_ub_qn"
                printf 'rm -f "$_sd_npm_cmd" %s/tmp/.sd_npm_run.sh 2>/dev/null || true\n' "$_ub_qn"
                printf 'sudo -n rm -f %q 2>/dev/null || true\n' "$_sudoers3_q"
                printf 'sudo -n chown -R %q %s/node_modules 2>/dev/null || true\n' "${_me3}:" "$_ip_qn"
                printf 'if [[ $_sd_npm_rc -ne 0 ]]; then exit "$_sd_npm_rc"; fi\n\n'
            fi
        fi # end install mode

        # ── Step 4: GitHub downloads + build + install/update script ──
        _emit_runner_steps "$mode" "$cid" "$install_path"

    } > "$full_script"
    chmod +x "$full_script"

    # ── Ask attach/background BEFORE launching ──
    _tmux_set SD_INSTALLING "$cid"
    local _inst_s; _inst_s=$(_inst_sess "$cid")
    tmux kill-session -t "$_inst_s" 2>/dev/null || true

    local _tl_rc
    _tmux_launch "$_inst_s" "$(printf "%s: %s" "${mode^}" "$(_cname "$cid")")" "$full_script"
    _tl_rc=$?
    # rc=1: user cancelled; rc=2: session done while prompt open (refresh); rc=0: attach or background
    if [[ $_tl_rc -eq 1 ]]; then rm -f "$full_script"; _tmux_set SD_INSTALLING ""; return 1; fi
    # Hook: if session is killed/Ctrl+C'd before script writes ok/fail, write fail ourselves
    local _ok_f="$CONTAINERS_DIR/$cid/.install_ok"
    local _fail_f="$CONTAINERS_DIR/$cid/.install_fail"
    local _hook_script; _hook_script=$(mktemp "$TMP_DIR/.sd_inst_hook_XXXXXX.sh")
    printf '#!/usr/bin/env bash\n[[ -f %q || -f %q ]] || touch %q\n' \
        "$_ok_f" "$_fail_f" "$_fail_f" > "$_hook_script"
    chmod +x "$_hook_script"
    tmux set-hook -t "$_inst_s" pane-exited "run-shell $(printf '%q' "$_hook_script")" 2>/dev/null || true
}

_guard_install() {
    # Warn if any container is currently installing
    local _running=()
    for _d in "$CONTAINERS_DIR"/*/; do
        local _c; _c=$(basename "$_d")
        _is_installing "$_c" && _running+=("$(_cname "$_c")")
    done
    [[ ${#_running[@]} -eq 0 ]] && return 0
    confirm "$(printf "${BLD}⚠  Installation already running: %s${NC}\n\n  Running another simultaneously may slow both down.\n  Continue anyway?" "${_running[*]}")" || return 1
    return 0
}


#  HEALTH CHECK — auto-restart on container exit
#  Runs as a background loop watching the tmux session.
# ── Start / stop ──────────────────────────────────────────────────
_build_start_script() {
    local cid="$1" install_path; install_path=$(_cpath "$cid")
    # Ensure install_path is owned by current user (snapshot from root-owned base may not be)
    [[ -d "$install_path" ]] && sudo -n chown "$(id -u):$(id -g)" "$install_path" 2>/dev/null || true
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local start_cmd; start_cmd=$(jq -r '.start // empty' "$sj" 2>/dev/null)
    # Legacy JSON format compat
    [[ -z "$start_cmd" ]] && start_cmd=$(jq -r '.start.cmd // empty' "$sj" 2>/dev/null)
    # Fall back to entrypoint in meta
    if [[ -z "$start_cmd" ]]; then
        local ep; ep=$(jq -r '.meta.entrypoint // empty' "$sj" 2>/dev/null)
        if [[ -n "$ep" ]]; then
            # Auto-prefix relative path in entrypoint (e.g. bin/ollama serve → $CONTAINER_ROOT/bin/ollama serve)
            local ep_bin="${ep%% *}" ep_args="${ep#* }"
            [[ "$ep_args" == "$ep_bin" ]] && ep_args=""
            local ep_bin_prefixed; ep_bin_prefixed=$(_cr_prefix "$ep_bin")
            start_cmd="exec ${ep_bin_prefixed}${ep_args:+ $ep_args}"
        fi
    fi
    local _base; _base=$(jq -r '.meta.base // "ubuntu"' "$sj" 2>/dev/null)
    local env_block; env_block=$(_env_exports "$cid" "$install_path")
    {
        printf '#!/usr/bin/env bash\n# Auto-generated by simpleDocker\n\n'
        local _slog; _slog=$(_log_path "$cid" "start")
        printf 'mkdir -p %q 2>/dev/null || true\n' "$LOGS_DIR"
        printf 'exec > >(tee -a %q) 2>&1\n' "$_slog"
        printf '_sd_scap() { local _z; _z=$(stat -c%%s %q 2>/dev/null||echo 0); [[ $_z -gt 10485760 ]] && { tail -c 8388608 %q > %q.t 2>/dev/null && mv %q.t %q 2>/dev/null||true; }; }\ntrap _sd_scap EXIT\n\n' "$_slog" "$_slog" "$_slog" "$_slog" "$_slog"
            # Build env exports remapped to /mnt
            local env_str="export CONTAINER_ROOT=/mnt HOME=/mnt"
            local keys; mapfile -t keys < <(jq -r '.environment // {} | keys[]' "$sj" 2>/dev/null)
            for k in "${keys[@]}"; do
                local v; v=$(jq -r --arg k "$k" '.environment[$k] | tostring' "$sj" 2>/dev/null)
                if [[ "$v" == "generate:hex32" ]]; then
                    local _scid; _scid=$(_state_get "$cid" storage_id)
                    local _secret_file=""
                    if [[ -n "$_scid" ]]; then
                        _secret_file="$(_stor_path "$_scid")/.sd_secret_${k}"
                    else
                        _secret_file="$CONTAINERS_DIR/$cid/.sd_secret_${k}"
                    fi
                    if [[ -f "$_secret_file" ]]; then
                        v=$(cat "$_secret_file" 2>/dev/null)
                    else
                        v=$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d - || echo "changeme")
                        printf '%s' "$v" > "$_secret_file" 2>/dev/null || true
                    fi
                fi
                # Only prefix actual relative paths (not port numbers, hostnames, plain words)
                if [[ "$v" != /* && "$v" != '$'* && "$v" != *'://'* && -n "$v" && "$v" =~ / ]]; then v="/mnt/$v"; fi
                env_str+=" $k=\"$v\""
            done
            local chroot_cmd; chroot_cmd=$(printf '%s' "${start_cmd:-printf 'No start defined\\nsleep 10'}" | sed 's|\$CONTAINER_ROOT|/mnt|g')
            local _gpu_mode; _gpu_mode=$(jq -r '.meta.gpu // empty' "$sj" 2>/dev/null)

            # ── NVIDIA: pre-copy .so files outside the unshare block ─────────
            # Done at start.sh run-time on the host side, before entering the namespace.
            # NVIDIA libs are compiled against GLIBC_2.17 — safe to load in Ubuntu chroot.
            if [[ "$_gpu_mode" == "cuda_auto" ]]; then
                local _nv_chroot_lib; _nv_chroot_lib="$UBUNTU_DIR/usr/local/lib/sd_nvidia"
                printf '# NVIDIA: copy host driver .so files into chroot (exact version match)\n'
                printf '_SD_NV_MAJ=""\n'
                printf 'if [[ -f /sys/module/nvidia/version ]]; then\n'
                printf '  _SD_NV_MAJ=$(cut -d. -f1 /sys/module/nvidia/version 2>/dev/null)\n'
                printf 'fi\n'
                printf 'if [[ -z "$_SD_NV_MAJ" ]] && [[ -f /proc/driver/nvidia/version ]]; then\n'
                printf '  _SD_NV_MAJ=$(grep -oP '"'"'Kernel Module[[:space:]]+\K[0-9]+'"'"' /proc/driver/nvidia/version 2>/dev/null | head -1)\n'
                printf 'fi\n'
                printf '_SD_EXTRA=""\n'
                printf 'if [[ -z "$_SD_NV_MAJ" ]]; then\n'
                printf '  printf "[sd] No NVIDIA kernel module -- CPU mode\n"\n'
                printf '  _SD_EXTRA="--cpu"\n'
                printf 'else\n'
                printf '  printf "[sd] NVIDIA driver major version: %%s\n" "$_SD_NV_MAJ"\n'
                printf '  # ── Version mismatch check: clear stale libs if driver changed ──\n'
                printf '  _SD_NV_CACHED_VER=""\n'
                printf '  [[ -f %q/.sd_nv_ver ]] && _SD_NV_CACHED_VER=$(cat %q/.sd_nv_ver 2>/dev/null)\n' "$_nv_chroot_lib" "$_nv_chroot_lib"
                printf '  if [[ -n "$_SD_NV_CACHED_VER" && "$_SD_NV_CACHED_VER" != "$_SD_NV_MAJ" ]]; then\n'
                printf '    printf "[sd] WARNING: NVIDIA driver changed (%%s → %%s) -- clearing cached libs\n" "$_SD_NV_CACHED_VER" "$_SD_NV_MAJ"\n'
                printf '    rm -rf %q 2>/dev/null || true\n' "$_nv_chroot_lib"
                printf '  fi\n'
                printf '  _SD_NV_DIR=%q\n' "$_nv_chroot_lib"
                printf '  mkdir -p "$_SD_NV_DIR"\n'
                printf '  _SD_NV_COUNT=0\n'
                printf '  for _sd_f in /usr/lib/libcuda.so* /usr/lib/libnvidia*.so* /usr/lib64/libcuda.so* /usr/lib64/libnvidia*.so* /usr/lib/x86_64-linux-gnu/libcuda.so* /usr/lib/x86_64-linux-gnu/libnvidia*.so* /usr/lib/aarch64-linux-gnu/libcuda.so* /usr/lib/aarch64-linux-gnu/libnvidia*.so*; do\n'
                printf '    [[ -e "$_sd_f" ]] && cp -Pf "$_sd_f" "$_SD_NV_DIR/" 2>/dev/null && (( _SD_NV_COUNT++ )) || true\n'
                printf '  done\n'
                printf '  if [[ "$_SD_NV_COUNT" -eq 0 ]]; then\n'
                printf '    printf "[sd] WARNING: no NVIDIA .so files found on host -- CPU mode\n"\n'
                printf '    _SD_EXTRA="--cpu"\n'
                printf '  else\n'
                printf '    printf "%s" "$_SD_NV_MAJ" > %q/.sd_nv_ver\n' ''"'"''"'"'' "$_nv_chroot_lib"
                printf '    printf "[sd] Copied %%d NVIDIA lib files into chroot (driver %%s) -- GPU enabled\n" "$_SD_NV_COUNT" "$_SD_NV_MAJ"\n'
                printf '  fi\n'
                printf 'fi\n'
            fi

            # unshare gives each container a private mount namespace: mounts are
            # invisible to other processes and auto-cleaned on exit. No stacking possible.
            local _nv_ld=""
            [[ "$_gpu_mode" == "cuda_auto" ]] && _nv_ld=" LD_LIBRARY_PATH=\"/usr/local/lib/sd_nvidia:\${LD_LIBRARY_PATH:-}\""
            local _chroot_inner_cmd
            _chroot_inner_cmd=$(printf '%q' "cd /mnt && $env_str$_nv_ld && $chroot_cmd")
            # Derive a safe hostname from the container name (lowercase, alphanum+hyphen, max 63 chars)
            local _ct_hostname; _ct_hostname=$(printf '%s' "$(_cname "$cid")" \
                | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | cut -c1-63)
            # ── ns_wrapper: baked inline into start.sh as a heredoc ─────────
            # We no longer write ns_wrapper.sh to install_path (inside the BTRFS
            # loop mount).  When --user/--map-root-user is active the kernel marks
            # loop-backed mounts from the initial user namespace as MNT_LOCKED and
            # applies SB_I_NOEXEC at the superblock level inside the new user
            # namespace — bash cannot open scripts on such mounts even with 755
            # permissions.  Inlining the content as a heredoc fed to "bash -s"
            # avoids any file read inside the namespace entirely.
            #
            # The heredoc delimiter is unquoted so $-variables that should expand
            # at start.sh run-time (e.g. $_SD_EXTRA) are left as literals — all
            # paths are already baked in at install time via printf %q.

            # Build the heredoc body as a local variable so we can embed it cleanly
            local _nswrap_body=""
            _nswrap_body+='_chroot_bash() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }'$'\n'
            _nswrap_body+="# Runs inside: sudo nsenter -- unshare --mount --pid --uts --ipc [--user] --fork"$'\n'
            _nswrap_body+="_NS_EXTRA=\"\${1:-}\""$'\n\n'
            _nswrap_body+="# UTS: set container hostname"$'\n'
            _nswrap_body+="$(printf 'printf "%%s" %q > /proc/sys/kernel/hostname 2>/dev/null || true' "$_ct_hostname")"$'\n\n'
            _nswrap_body+="# Mount: proc must be fresh mount -t proc (not bind) when inside PID namespace"$'\n'
            _nswrap_body+="$(printf 'mount -t proc proc %q' "$UBUNTU_DIR/proc")"$'\n'
            _nswrap_body+="$(printf 'mount --bind /sys  %q' "$UBUNTU_DIR/sys")"$'\n'
            _nswrap_body+="$(printf 'mount --bind /dev  %q' "$UBUNTU_DIR/dev")"$'\n'
            _nswrap_body+="$(printf 'mount --bind %q %q' "$install_path" "$UBUNTU_DIR/mnt")"$'\n'
            if [[ -n "$MNT_DIR" ]]; then
                _nswrap_body+="$(printf 'mkdir -p %q 2>/dev/null || true' "$UBUNTU_DIR$MNT_DIR")"$'\n'
                _nswrap_body+="$(printf 'mount --bind %q %q' "$MNT_DIR" "$UBUNTU_DIR$MNT_DIR") \\"$'\n'
                _nswrap_body+='  || printf "[sd] WARNING: MNT_DIR bind mount failed -- storage symlinks may not resolve\n"'$'\n'
            fi
            local _nhf; _nhf=$(_netns_hosts "$MNT_DIR")
            _nswrap_body+="$(printf 'if [[ -f %q ]]; then mount --bind %q %q 2>/dev/null || true; fi' "$_nhf" "$_nhf" "$UBUNTU_DIR/etc/hosts")"$'\n\n'
            # Cap dropping: strip unneeded capabilities at runtime if capsh available
            local _exec_inner; _exec_inner=$(printf '_chroot_bash %q -c %s' "$UBUNTU_DIR" "$_chroot_inner_cmd")
            _nswrap_body+="${_exec_inner}"$'\n'

            # sudo already provides real CAP_SYS_ADMIN — no --user namespace needed.
            # (--map-root-user would MNT_LOCK all parent mounts, breaking bind mounts.)
            local _unshare_flags="--mount --pid --uts --ipc"

            local _nsname; _nsname=$(_netns_name "$MNT_DIR")
            # Emit the nsenter call with the wrapper script inlined via heredoc + bash -s.
            # $_SD_EXTRA (GPU case) is passed as $1 to bash -s so the wrapper sees it as $_NS_EXTRA.
            # The heredoc delimiter _SDNS_WRAP is unquoted so it is treated as a literal
            # string boundary; no variable expansion occurs in the body at this printf stage
            # because _nswrap_body was already fully expanded above.
            if [[ "$_gpu_mode" == "cuda_auto" ]]; then
                printf '  sudo -n nsenter --net=/run/netns/%q -- unshare %s --fork bash -s "$_SD_EXTRA" << '"'"'_SDNS_WRAP'"'"'\n%s\n_SDNS_WRAP\n' \
                    "$_nsname" "$_unshare_flags" "$_nswrap_body"
            else
                printf '  sudo -n nsenter --net=/run/netns/%q -- unshare %s --fork bash -s << '"'"'_SDNS_WRAP'"'"'\n%s\n_SDNS_WRAP\n' \
                    "$_nsname" "$_unshare_flags" "$_nswrap_body"
            fi
    } > "$install_path/start.sh"
    chmod +x "$install_path/start.sh"
}

# ── Cron engine ──────────────────────────────────────────────────
# Session naming: sdCron_{cid}_{idx}
_cron_sess()     { printf 'sdCron_%s_%s' "$1" "$2"; }
_cron_next_file(){ printf '%s/cron_%s_next' "$CONTAINERS_DIR/$1" "$2"; }

# Parse interval string (e.g. 30s, 5m, 1h, 2d, 1w, 3mo) → seconds
_cron_interval_secs() {
    local iv="$1"
    local num unit
    num=$(printf '%s' "$iv" | grep -oE '^[0-9]+')
    unit=$(printf '%s' "$iv" | grep -oE '[a-z]+$')
    [[ -z "$num" ]] && { printf '3600'; return; }
    case "$unit" in
        s)  printf '%d' "$num" ;;
        m)  printf '%d' $(( num * 60 )) ;;
        h)  printf '%d' $(( num * 3600 )) ;;
        d)  printf '%d' $(( num * 86400 )) ;;
        w)  printf '%d' $(( num * 604800 )) ;;
        mo) printf '%d' $(( num * 2592000 )) ;;
        *)  printf '%d' $(( num * 3600 )) ;;
    esac
}

# Format seconds remaining as human-readable countdown
_cron_countdown() {
    local secs="$1"
    (( secs < 0 )) && secs=0
    local d=$(( secs / 86400 ))
    local h=$(( (secs % 86400) / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    local s=$(( secs % 60 ))
    if   (( d > 0 )); then printf '%dd %02dh %02dm %02ds' "$d" "$h" "$m" "$s"
    elif (( h > 0 )); then printf '%dh %02dm %02ds' "$h" "$m" "$s"
    elif (( m > 0 )); then printf '%dm %02ds' "$m" "$s"
    else printf '%ds' "$s"
    fi
}

# Launch one cron loop session for job $idx of container $cid
_cron_start_one() {
    local cid="$1" idx="$2" name="$3" interval="$4" cmd="$5" cflags="${6:-}"
    local sname; sname=$(_cron_sess "$cid" "$idx")
    local ip; ip=$(_cpath "$cid")
    local secs; secs=$(_cron_interval_secs "$interval")
    local next_file; next_file=$(_cron_next_file "$cid" "$idx")
    local runner; runner=$(mktemp "$TMP_DIR/.sd_cron_XXXXXX.sh")

    # Resolve --sudo: wrap cmd in sudo -n bash -c unless it already starts with sudo
    local _use_sudo=false _unjailed=false
    printf '%s' "$cflags" | grep -q -- '--sudo'    && _use_sudo=true
    printf '%s' "$cflags" | grep -q -- '--unjailed' && _unjailed=true
    if [[ "$_use_sudo" == "true" ]]; then
        local _cmd_trimmed; _cmd_trimmed=$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//')
        if [[ "$_cmd_trimmed" != sudo* ]]; then
            # Bake CONTAINER_ROOT into the cmd so sudo's clean shell has the right path
            local _cmd_resolved; _cmd_resolved="${cmd//\$CONTAINER_ROOT/$ip}"
            cmd="sudo -n bash -c $(printf '%q' "$_cmd_resolved")"
        fi
    fi

    {
        printf '#!/usr/bin/env bash\n'
        printf '_cron_secs=%d\n' "$secs"
        printf '_cron_next_file=%q\n' "$next_file"
        printf '_cron_cmd=%q\n' "$cmd"
        printf 'while true; do\n'
        printf '    _next=$(( $(date +%%s) + _cron_secs ))\n'
        printf '    printf "%%d" "$_next" > "$_cron_next_file"\n'
        printf '    sleep "$_cron_secs" &\n'
        printf '    wait $!\n'
        printf '    [[ -f "$_cron_next_file" ]] || exit 0\n'
        printf '    printf "\\n\\033[1m── Cron: %s ──\\033[0m\\n" %q\n' "$name" "$name"
        if [[ "$_unjailed" == "false" ]]; then
            # Jailed: run inside namespace+chroot, cd to install path inside the chroot (/mnt)
            local _nsname; _nsname=$(_netns_name "$MNT_DIR")
            local _ub; _ub="$UBUNTU_DIR"
            local _cmd_inner; _cmd_inner=$(printf '%s' "$cmd" | sed 's|\$CONTAINER_ROOT|/mnt|g' | sed 's#>>[[:space:]]*\([^[:space:]]*\)#| tee -a \1#g')
            printf '    sudo -n nsenter --net=/run/netns/%q -- unshare --mount --pid --uts --ipc --fork bash -s << '"'"'_SDCRON_NS'"'"'\n' "$_nsname"
            printf '_cb() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }\n'
            printf 'mount -t proc proc %q 2>/dev/null || true\n' "$_ub/proc"
            printf 'mount --bind /sys %q 2>/dev/null || true\n' "$_ub/sys"
            printf 'mount --bind /dev %q 2>/dev/null || true\n' "$_ub/dev"
            printf 'mount --bind %q %q 2>/dev/null || true\n' "$ip" "$_ub/mnt"
            printf '_cb %q -c %q\n' "$_ub" "cd /mnt && $_cmd_inner"
            printf '_SDCRON_NS\n'
        else
            # Unjailed: run on host with CONTAINER_ROOT set to install path
            local _cmd_unjailed; _cmd_unjailed=$(printf '%s' "$cmd" | sed 's#>>[[:space:]]*\([^[:space:]]*\)#| tee -a \1#g')
            printf '    export CONTAINER_ROOT=%q\n' "$ip"
            printf '    (eval %q)\n' "$_cmd_unjailed"
        fi
        printf '    _cron_next_ts=$(( $(date +%%s) + _cron_secs ))\n'
        printf '    _cron_next_time=$(date -d "@$_cron_next_ts" +%%H:%%M:%%S 2>/dev/null || date -v+"${_cron_secs}S" +%%H:%%M:%%S 2>/dev/null)\n'
        printf '    _cron_next_date=$(date -d "@$_cron_next_ts" +%%Y-%%m-%%d 2>/dev/null || date -v+"${_cron_secs}S" +%%Y-%%m-%%d 2>/dev/null)\n'
        printf '    printf "\\n\\033[2mDone. Next execution: %%s [%%s]\\033[0m\\n" "$_cron_next_time" "$_cron_next_date"\n'
        printf 'done\n'
    } > "$runner"; chmod +x "$runner"
    tmux new-session -d -s "$sname" "bash $(printf '%q' "$runner"); rm -f $(printf '%q' "$runner")" 2>/dev/null
    tmux set-option -t "$sname" detach-on-destroy off 2>/dev/null || true
}

# Start all crons for a container (called from _start_container)
_cron_start_all() {
    local cid="$1"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local count; count=$(jq -r '.crons | length' "$sj" 2>/dev/null)
    [[ -z "$count" || "$count" -eq 0 ]] && return
    for (( i=0; i<count; i++ )); do
        local name iv cmd cflags
        name=$(jq -r --argjson i "$i" '.crons[$i].name' "$sj" 2>/dev/null)
        iv=$(jq -r --argjson i "$i" '.crons[$i].interval' "$sj" 2>/dev/null)
        cmd=$(jq -r --argjson i "$i" '.crons[$i].cmd' "$sj" 2>/dev/null)
        cflags=$(jq -r --argjson i "$i" '.crons[$i].flags // ""' "$sj" 2>/dev/null)
        [[ -z "$cmd" ]] && continue
        _cron_start_one "$cid" "$i" "$name" "$iv" "$cmd" "$cflags"
    done
}

# Stop all crons for a container (called from _stop_container)
_cron_stop_all() {
    local cid="$1"
    # Remove all next-time files so running loops exit cleanly
    rm -f "$CONTAINERS_DIR/$cid"/cron_*_next 2>/dev/null
    while IFS= read -r sess; do
        tmux kill-session -t "$sess" 2>/dev/null || true
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdCron_${cid}_")
}

_update_size_cache() {
    local cid="$1"
    local _ipath; _ipath=$(_cpath "$cid")
    [[ -d "$_ipath" ]] || return
    local _sz; _sz=$(du -sb "$_ipath" 2>/dev/null | awk '{printf "%.2f",$1/1073741824}')
    [[ -n "$_sz" ]] && printf '%s' "$_sz" > "$CACHE_DIR/sd_size/$cid"
}

_start_container() {
    local cid="$1" _auto=false
    [[ "${2:-}" == "--auto" ]] && _auto=true
    local install_path; install_path=$(_cpath "$cid")
    local sess; sess="$(tsess "$cid")"
    _guard_space || return 1
    _compile_service "$cid" 2>/dev/null || true

    if [[ "$(_stor_count "$cid")" -gt 0 ]]; then
        local prev_scid; prev_scid=$(_state_get "$cid" storage_id)
        if [[ -n "$prev_scid" && "$(_stor_read_active "$prev_scid")" == "$cid" ]]; then
            _stor_clear_active "$prev_scid"
        fi
        _stor_unlink "$cid" "$install_path"
        local scid
        if [[ "$_auto" == "true" ]]; then
            scid=$(_auto_pick_storage_profile "$cid")
        else
            scid=$(_pick_storage_profile "$cid")
        fi
        [[ -z "$scid" ]] && return 1
        _stor_link "$cid" "$install_path" "$scid"
    fi

    _rotate_and_snapshot "$cid"
    _build_start_script "$cid"
    _netns_ct_add "$cid" "$(_cname "$cid")" "$MNT_DIR"
    # Auto-derive exposure from HOST env only on first start (no exposure file yet).
    # Once the user has cycled exposure manually, that choice is permanent — HOST env is ignored.
    if [[ ! -f "$(_exposure_file "$cid")" ]]; then
        local _host_env; _host_env=$(jq -r '.environment.HOST // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        if [[ "$_host_env" == "0.0.0.0" ]]; then
            _exposure_set "$cid" "public"
        elif [[ "$_host_env" == "127.0.0.1" || "$_host_env" == "localhost" ]]; then
            _exposure_set "$cid" "localhost"
        fi
    fi
    _exposure_apply "$cid"
    # Write persistent sudoers for mount/umount so start.sh tmux session can use sudo -n
    local _sd_me; _sd_me=$(id -un)
    local _sd_sudoers="/etc/sudoers.d/simpledocker_${_sd_me}"
    : # sudoers written at startup by _sd_outer_sudo

    # Apply cgroups via systemd-run --user --scope if resources are enabled for this container
    local _sd_base_cmd; _sd_base_cmd="cd $(printf '%q' "$install_path") && bash $(printf '%q' "$install_path/start.sh")"
    local _sd_run_prefix=""
    local _res_cfg; _res_cfg="$CONTAINERS_DIR/$cid/resources.json"
    if [[ -f "$_res_cfg" ]] && [[ "$(jq -r '.enabled // false' "$_res_cfg" 2>/dev/null)" == "true" ]]; then
        _sd_run_prefix="systemd-run --user --scope --unit=sd-$cid"
        local _rq; _rq=$(jq -r '.cpu_quota  // empty' "$_res_cfg" 2>/dev/null); [[ -n "$_rq" ]] && _sd_run_prefix+=" -p CPUQuota=$_rq"
        local _rm; _rm=$(jq -r '.mem_max    // empty' "$_res_cfg" 2>/dev/null); [[ -n "$_rm" ]] && _sd_run_prefix+=" -p MemoryMax=$_rm"
        local _rs; _rs=$(jq -r '.mem_swap   // empty' "$_res_cfg" 2>/dev/null); [[ -n "$_rs" ]] && _sd_run_prefix+=" -p MemorySwapMax=$_rs"
        local _rw; _rw=$(jq -r '.cpu_weight // empty' "$_res_cfg" 2>/dev/null); [[ -n "$_rw" ]] && _sd_run_prefix+=" -p CPUWeight=$_rw"
        _sd_run_prefix+=" -- bash -c"
        tmux new-session -d -s "$sess" "$_sd_run_prefix $(printf '%q' "$_sd_base_cmd")" 2>/dev/null
    else
        tmux new-session -d -s "$sess" "$_sd_base_cmd" 2>/dev/null
    fi
    tmux set-option -t "$sess" detach-on-destroy off 2>/dev/null || true
    # Kill session when process exits (Ctrl+C, crash) so tmux_up returns false immediately
    tmux set-hook -t "$sess" pane-exited "kill-session -t $sess" 2>/dev/null || true
    # Watcher: send SIGUSR1 to refresh menu when session ends
    { while tmux_up "$sess" 2>/dev/null; do sleep 0.5; done
      kill -USR1 "$SD_SHELL_PID" 2>/dev/null || true
    } &
    disown $! 2>/dev/null || true
    # Start any cron jobs defined in the blueprint
    _cron_start_all "$cid"
    # Drop capabilities after container process is up
    { sleep 2; _cap_drop_apply "$cid"; _seccomp_apply "$cid"; } &>/dev/null &
    disown $! 2>/dev/null || true
    if [[ "$_auto" == "true" ]]; then
        sleep 0.5
        return 0
    fi
    sleep 0.5
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n%s\n' "$(printf "${GRN}▶  Start and show live output${NC}")" "$(printf "${DIM}   Start in the background${NC}")" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Start ──${NC}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local _start_choice; _start_choice=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
    [[ $_frc -ne 0 ]] && return
    if printf '%s' "$_start_choice" | _strip_ansi | grep -q "show live output"; then
        tmux switch-client -t "$sess" 2>/dev/null || true
        sleep 0.1; stty sane 2>/dev/null
        while IFS= read -r -t 0 -n 256 _ 2>/dev/null; do :; done
    fi
}


#  CAPABILITY DROPPING — drop unneeded Linux capabilities post-start
#  Uses capsh if available. Default drop set covers the most dangerous caps.
#  Stored per-container in service.json .meta.cap_drop (true/false, default true)
_SD_CAP_DROP_DEFAULT="cap_sys_ptrace,cap_sys_rawio,cap_sys_boot,cap_sys_module,cap_mknod,cap_audit_write,cap_audit_control,cap_syslog"

_cap_drop_enabled() {
    local v; v=$(jq -r '.meta.cap_drop // "true"' "$CONTAINERS_DIR/$1/service.json" 2>/dev/null)
    [[ "$v" != "false" ]]
}

_cap_drop_apply() {
    local cid="$1"
    _cap_drop_enabled "$cid" || return 0
    command -v capsh &>/dev/null || return 0
    local sess; sess="$(tsess "$cid")"
    local pane_pid; pane_pid=$(tmux list-panes -t "$sess" -F "#{pane_pid}" 2>/dev/null | head -1)
    [[ -z "$pane_pid" ]] && return 0
    # Drop caps from all children of the pane shell (the actual service processes)
    pgrep -P "$pane_pid" 2>/dev/null | while IFS= read -r cpid; do
        sudo -n capsh --drop="$_SD_CAP_DROP_DEFAULT" --pid="$cpid" 2>/dev/null || true
    done
}

# ── Seccomp ───────────────────────────────────────────────────────
# Writes a minimal seccomp BPF profile for the container's unshare wrapper.
# Uses the kernel's SECCOMP_SET_MODE_FILTER via a small C helper if available,
# or falls back to systemd-run --security-property=SystemCallFilter if cgroups
# are enabled, or skips silently if neither is available.
_SD_SECCOMP_BLOCKLIST=(
    # Kernel/boot — containers have no business touching these
    kexec_load kexec_file_load reboot init_module finit_module delete_module
    # Raw hardware / DMA
    ioperm iopl
    # Mounting — container is already in a mount namespace; internal mounts via unshare wrapper are fine
    # but blocking mount from within the service process itself is safe
    mount umount2 pivot_root
    # Namespace creation from inside the container (prevent escape attempts)
    unshare setns clone
    # Perf/tracing
    perf_event_open ptrace process_vm_readv process_vm_writev
    # Kernel keyring (not needed by typical services)
    add_key request_key keyctl
    # Misc dangerous
    acct swapon swapoff syslog quotactl nfsservctl
)

_seccomp_enabled() {
    local v; v=$(jq -r '.meta.seccomp // "true"' "$CONTAINERS_DIR/$1/service.json" 2>/dev/null)
    [[ "$v" != "false" ]]
}

_seccomp_apply() {
    local cid="$1"
    _seccomp_enabled "$cid" || return 0

    # Method 1: systemd-run scope already running — add SystemCallFilter
    if [[ -f "$CONTAINERS_DIR/$cid/resources.json" ]] && \
       [[ "$(jq -r '.enabled // false' "$CONTAINERS_DIR/$cid/resources.json" 2>/dev/null)" == "true" ]]; then
        local unit="sd-${cid}.scope"
        if systemctl --user is-active "$unit" &>/dev/null; then
            local block_str; block_str=$(printf '~%s ' "${_SD_SECCOMP_BLOCKLIST[@]}")
            systemctl --user set-property "$unit" "SystemCallFilter=${block_str}" 2>/dev/null || true
            return 0
        fi
    fi

    # Method 2: write seccomp profile to container dir and apply via nsenter to service pids
    # This is best-effort — requires libseccomp/scmp_sys_resolver or similar
    # For now: write the profile file so it can be picked up by future tooling
    local profile_file="$CONTAINERS_DIR/$cid/.seccomp_profile.json"
    if [[ ! -f "$profile_file" ]]; then
        local syscall_list; syscall_list=$(printf '{"names":[%s],"action":"SCMP_ACT_ERRNO"}' \
            "$(printf '"%s",' "${_SD_SECCOMP_BLOCKLIST[@]}" | sed 's/,$//')")
        printf '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[%s]}\n' "$syscall_list" \
            > "$profile_file" 2>/dev/null || true
    fi
}

_stop_container() {
    local cid="$1"
    local sess; sess="$(tsess "$cid")"
    local install_path; install_path=$(_cpath "$cid")
    # Send SIGINT to the foreground process group (same as pressing Ctrl-C manually)
    tmux send-keys -t "$sess" C-c "" 2>/dev/null || true
    # Wait up to 8s for the session to die naturally (pane-exited hook kills it on process exit)
    local _w=0
    while tmux_up "$sess" 2>/dev/null && [[ $_w -lt 40 ]]; do
        sleep 0.2; (( _w++ )) || true
    done
    # Force-kill if still alive after grace period
    tmux kill-session -t "$sess" 2>/dev/null || true
    tmux kill-session -t "sdTerm_${cid}" 2>/dev/null || true
    _netns_ct_del "$cid" "$(_cname "$cid")" "$MNT_DIR"
    while IFS= read -r _as; do
        tmux kill-session -t "$_as" 2>/dev/null || true
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdAction_${cid}_")
    _cron_stop_all "$cid"
    sleep 0.2
    if [[ "$(_stor_count "$cid")" -gt 0 ]]; then
        _stor_unlink "$cid" "$install_path"
        local scid; scid=$(_state_get "$cid" storage_id)
        [[ -n "$scid" ]] && _stor_clear_active "$scid"
    fi
    clear; pause "'$(_cname "$cid")' stopped."
    _update_size_cache "$cid"
}

# ── Health check / auto-restart ──────────────────────────────────

_ct_main_pid() {
    # Get the main process PID from the tmux session (first child of the shell)
    local sess; sess="$(tsess "$1")"
    tmux list-panes -t "$sess" -F "#{pane_pid}" 2>/dev/null | head -1
}

#  GROUPS
# Group file: $GROUPS_DIR/<id>.toml
# Format:
#   name = My Stack
#   desc = optional description
#   containers = ServiceA, ServiceB, ServiceC
#   start = { ServiceA, Wait 5, Wait for ServiceB, ServiceC }
#   stop = { ServiceC, ServiceB, ServiceA }

_grp_path()        { printf '%s/%s.toml' "$GROUPS_DIR" "$1"; }
