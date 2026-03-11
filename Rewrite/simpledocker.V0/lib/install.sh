# lib/install.sh — Runner step emitter, source/git/extract handlers, service compile,
#                   env exports, ubuntu bootstrap, apt/pip/npm installer, _run_job,
#                   _guard_install
# Sourced by main.sh — do NOT run directly

# ── Runner step emitter ─────────────────────────────────────────
# ════════════════════════════════════════════════════════════════
# ── Source handlers ([git])                                     ──
# ════════════════════════════════════════════════════════════════
_emit_runner_steps() {
    local mode="$1" cid="$2" install_path="$3"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local script; script=$(jq -r ".$mode // empty" "$sj" 2>/dev/null)
    local label; [[ "$mode" == "install" ]] && label="Installation" || label="Update"
    local github_block; github_block=$(jq -r '.git // empty' "$sj" 2>/dev/null)
    local build_block;  build_block=$(jq -r '.build // empty' "$sj" 2>/dev/null)
    local _me; _me=$(id -un)

    if [[ -n "$github_block" && "$mode" == "install" ]]; then
        local go_arch; [[ "$(uname -m)" == "aarch64" ]] && go_arch="arm64" || go_arch="amd64"
        local gpu_flag; gpu_flag=$(jq -r '.meta.gpu // empty' "$sj" 2>/dev/null)
        printf '# ── GitHub downloads ──\n'
        printf '_SD_ARCH=%q\n_SD_INSTALL=%q\n\n' "$go_arch" "$install_path"
        if [[ "$gpu_flag" == "cuda_auto" || "$gpu_flag" == "auto" ]]; then
            cat <<'GPUDETECT'
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    _SD_GPU=cuda
else
    _SD_GPU=cpu
fi
GPUDETECT
        fi
        cat <<'SDHELPER'
_sd_extract_auto() {
    local url="$1" dest="$2"; mkdir -p "$dest"
    local _tmp; _tmp=$(mktemp "$dest/.sd_dl_XXXXXX")
    curl -fL --progress-bar --retry 5 --retry-delay 3 --retry-all-errors -C - "$url" -o "$_tmp" || { rm -f "$_tmp"; printf "[!] Download failed: %s\n" "$url"; return 1; }
    local strip=1
    if [[ "$url" =~ \.tar\.zst$ ]]; then
        local _tops; _tops=$(tar --use-compress-program=unzstd -t -f "$_tmp" 2>/dev/null | sed 's|/.*||' | sort -u | grep -v '^\.$' | wc -l) || true
        [[ "${_tops:-1}" -gt 1 ]] && strip=0
        tar --use-compress-program=unzstd -x -C "$dest" --strip-components="$strip" -f "$_tmp"
    elif [[ "$url" =~ \.tar\.(gz|bz2|xz)$|\.tgz$ ]]; then
        local _tops; _tops=$(tar -ta -f "$_tmp" 2>/dev/null | sed 's|/.*||' | sort -u | grep -v '^\.$' | wc -l) || true
        [[ "${_tops:-1}" -gt 1 ]] && strip=0
        tar -xa -C "$dest" --strip-components="$strip" -f "$_tmp"
    elif [[ "$url" =~ \.zip$ ]]; then unzip -o -d "$dest" "$_tmp" 2>/dev/null
    else
        local _bn; _bn=$(basename "$url" | sed 's/[?#].*//' | sed 's/[-_]linux[-_][^.]*$//' | sed 's/[-_]\(amd64\|arm64\|x86_64\|aarch64\)$//')
        [[ -z "$_bn" ]] && _bn=$(basename "$url" | sed 's/[?#].*//')
        mkdir -p "$dest/bin"
        mv "$_tmp" "$dest/bin/$_bn"; chmod +x "$dest/bin/$_bn"; return; fi
    rm -f "$_tmp"
}
_sd_latest_tag() {
    local repo="$1"
    local tag
    tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"') || true
    printf '%s' "$tag"
}
_sd_best_url() {
    local repo="$1" arch="$2" hint="${3:-}" atype="${4:-}"
    local rel; rel=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) || true
    local urls; urls=$(printf '%s' "$rel" | grep -o '"browser_download_url": *"[^"]*"' \
        | grep -ivE 'sha256|\.sig|\.txt|\.json|rocm|jetpack' | grep -o 'https://[^"]*') || true
    # Build a type filter based on [BIN], [ZIP], [TAR] — default to ZIP when no hint given
    local _arc_pat='\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$'
    local _zip_pat='\.zip$'
    local _tar_pat='\.(tar\.(gz|zst|xz|bz2)|tgz)$'
    local _bin_pat  # matches URLs that are NOT archives
    local type_urls="$urls"
    case "${atype^^}" in
        BIN)  type_urls=$(printf '%s' "$urls" | grep -ivE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$') ;;
        ZIP)  type_urls=$(printf '%s' "$urls" | grep -iE "$_zip_pat") ;;
        TAR)  type_urls=$(printf '%s' "$urls" | grep -iE "$_tar_pat") ;;
    esac
    # If no hint given and no explicit type, default auto-detection to prefer archives (ZIP/TAR)
    local url=""
    # If explicit asset hint given, match within type-filtered urls first
    if [[ -n "$hint" ]]; then
        url=$(printf '%s' "$type_urls" | grep -iF "$hint" | head -1) || true
        # If type filter gave no result, fall back to unfiltered hint match
        [[ -z "$url" ]] && url=$(printf '%s' "$urls" | grep -iF "$hint" | head -1) || true
    fi
    # If CUDA GPU detected, prefer cuda assets first
    if [[ -z "$url" && "${_SD_GPU:-cpu}" == "cuda" ]]; then
        url=$(printf '%s' "$type_urls" | grep -iE "cuda" | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true
        [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE "cuda" | grep -iE "$arch" | head -1) || true
    fi
    # Prefer archives — pick tarball/zip for arch first, fall back to raw binary
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$' | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$' | grep -iE "$arch" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE "$arch" | head -1) || true
    [[ -z "$url" && -n "$hint" ]] && url=$(printf '%s' "$urls" | grep -i "$hint" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$' | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$rel" | grep -o '"tarball_url": *"[^"]*"' | grep -o 'https://[^"]*' | head -1) || true
    printf '%s' "$url"
}
SDHELPER

        while IFS= read -r ghline; do
            ghline=$(printf '%s' "$ghline" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$ghline" ]] && continue
            [[ "$ghline" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*=[[:space:]]*(.*) ]] && ghline="${BASH_REMATCH[1]}"
            local repo; repo=$(printf '%s' "$ghline" | awk '{print $1}')
            local rest;  rest=$(printf '%s' "$ghline" | cut -d' ' -f2-)
            # Support explicit asset name: repo [asset-name][TYPE] → dest
            # TYPE optional: BIN, ZIP, TAR — filters which asset type is matched
            local asset_hint="" asset_type=""
            local _rest_scan="$rest"
            while [[ "$_rest_scan" =~ \[([^]]+)\] ]]; do
                local _bval="${BASH_REMATCH[1]}"
                _rest_scan="${_rest_scan#*\[${_bval}\]}"
                if [[ "${_bval^^}" =~ ^(BIN|ZIP|TAR)$ ]]; then
                    asset_type="${_bval^^}"
                elif [[ -z "$asset_hint" ]]; then
                    asset_hint="$_bval"
                fi
            done
            rest=$(printf '%s' "$rest" | sed 's/\[[^]]*\]//g')
            local dest_sub=""; [[ "$rest" =~ →[[:space:]]*([^[:space:]]+) ]] && dest_sub="${BASH_REMATCH[1]%/}"
            local dest_expr; [[ -n "$dest_sub" && "$dest_sub" != "." ]] && dest_expr="\$_SD_INSTALL/${dest_sub}" || dest_expr="\$_SD_INSTALL"
            local hint="$asset_hint"; [[ -z "$hint" && "$rest" =~ (binary|tarball):([^[:space:]→]+) ]] && hint="${BASH_REMATCH[2]}"
            if [[ "$rest" =~ ^source ]]; then
                cat <<GHBLOCK
printf 'Cloning ${repo}...\\n'
_sd_tag=\$(_sd_latest_tag "${repo}")
_sd_cdest="${dest_expr}"
_sd_ctmp=""
if [[ -d "\$_sd_cdest" && -n "\$(ls -A "\$_sd_cdest" 2>/dev/null)" ]]; then
    _sd_ctmp=\$(mktemp -d "\$_SD_INSTALL/.sd_clone_XXXXXX")
    _sd_cdest="\$_sd_ctmp"
fi
if [[ -n "\$_sd_tag" ]]; then
    git clone --depth=1 --branch "\$_sd_tag" "https://github.com/${repo}.git" "\$_sd_cdest" 2>&1
else
    git clone --depth=1 "https://github.com/${repo}.git" "\$_sd_cdest" 2>&1
fi
if [[ -n "\$_sd_ctmp" ]]; then
    mkdir -p "${dest_expr}"
    cp -rn "\$_sd_ctmp/." "${dest_expr}/" 2>/dev/null || true
    rm -rf "\$_sd_ctmp"
fi

GHBLOCK
            else
                cat <<GHBLOCK
printf 'Fetching ${repo} (%s)...\\n' "\$_SD_ARCH"
_sd_url=\$(_sd_best_url "${repo}" "\$_SD_ARCH" "${hint}" "${asset_type}")
[[ -z "\$_sd_url" ]] && { printf '[!] No asset found for ${repo}\\n'; exit 1; }
_sd_extract_auto "\$_sd_url" "${dest_expr}"
printf '✓ ${repo} → ${dest_expr}\\n'

GHBLOCK
            fi
        done <<< "$github_block"
    fi
    [[ -n "$build_block" && "$mode" == "install" ]] && printf '# ── Build ──\n%s\n\n' "$build_block"
    if [[ -n "$script" ]]; then
        local _base; _base=$(jq -r '.meta.base // "ubuntu"' "$sj" 2>/dev/null)
        printf '# ── %s script ──\n' "$label"
        local _ub_q3; _ub_q3=$(printf '%q' "$UBUNTU_DIR")
        local _ip_q3; _ip_q3=$(printf '%q' "$install_path")
        local _sudoers_q; _sudoers_q=$(printf '%q' "/etc/sudoers.d/simpledocker_script_$$")
        printf 'printf '\''%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/bash, /usr/bin/chroot, /usr/sbin/chroot, /usr/bin/unshare\\n'\'' | sudo -n tee %q >/dev/null 2>&1 || true\n' "$_me" "$_sudoers_q"
        printf 'mkdir -p %s/tmp %s/mnt %s/proc %s/sys %s/dev 2>/dev/null || true\n' "$_ub_q3" "$_ub_q3" "$_ub_q3" "$_ub_q3" "$_ub_q3"
        printf 'sudo -n mount --bind /proc %s/proc 2>/dev/null || true\n' "$_ub_q3"
        printf 'sudo -n mount --bind /sys  %s/sys  2>/dev/null || true\n' "$_ub_q3"
        printf 'sudo -n mount --bind /dev  %s/dev  2>/dev/null || true\n' "$_ub_q3"
        printf 'sudo -n mount --bind %s %s/mnt 2>/dev/null || true\n' "$_ip_q3" "$_ub_q3"
        # Write the script body into a file to avoid %q mangling shell metacharacters
        printf '_sd_run_cmd=$(mktemp %s/../.sd_run_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_run_%s.sh)\n' "$_ub_q3" "$$"
        printf 'cat > "$_sd_run_cmd" << '"'"'_SD_RUN_EOF'"'"'\n'
        printf '#!/bin/bash\nset -e\ncd /mnt\n'
        printf '%s\n' "$script"
        printf '_SD_RUN_EOF\n'
        printf 'chmod +x "$_sd_run_cmd"\n'
        printf 'sudo -n mount --bind "$_sd_run_cmd" %s/tmp/.sd_run.sh 2>/dev/null || cp "$_sd_run_cmd" %s/tmp/.sd_run.sh 2>/dev/null || true\n' "$_ub_q3" "$_ub_q3"
        printf '_chroot_bash %s /tmp/.sd_run.sh\n' "$_ub_q3"
        printf '_sd_run_rc=$?\n'
        printf 'sudo -n umount -lf %s/tmp/.sd_run.sh 2>/dev/null || true\n' "$_ub_q3"
        printf 'sudo -n umount -lf %s/mnt %s/dev %s/sys %s/proc 2>/dev/null || true\n' "$_ub_q3" "$_ub_q3" "$_ub_q3" "$_ub_q3"
        printf 'rm -f "$_sd_run_cmd" %s/tmp/.sd_run.sh 2>/dev/null || true\n' "$_ub_q3"
        printf 'sudo -n rm -f %q 2>/dev/null || true\n' "$_sudoers_q"
        printf 'if [[ $_sd_run_rc -ne 0 ]]; then exit "$_sd_run_rc"; fi\n'
    fi
}

# ── service.src → service.json compile ───────────────────────────
_compile_service() {
    local cid="$1"
    local src="$CONTAINERS_DIR/$cid/service.src"
    [[ ! -f "$src" ]] && return 1

    if _bp_is_json "$src"; then
        # Old JSON format — keep as-is with legacy handling
        local sj="$CONTAINERS_DIR/$cid/service.json"
        cp "$src" "$sj"
        sha256sum "$src" 2>/dev/null | cut -d" " -f1 > "$src.hash"
        return 0
    fi

    # New DSL format
    _bp_compile_to_json "$src" "$cid" || return 1
    sha256sum "$src" 2>/dev/null | cut -d" " -f1 > "$CONTAINERS_DIR/$cid/service.src.hash"
}

_bootstrap_src() {
    local cid="$1"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local src="$CONTAINERS_DIR/$cid/service.src"
    [[ ! -f "$sj" ]] && return 1
    cp "$sj" "$src"
    sha256sum "$src" 2>/dev/null | cut -d" " -f1 > "$src.hash"
}

_ensure_src() {
    local cid="$1"
    local src="$CONTAINERS_DIR/$cid/service.src"
    [[ -f "$src" ]] && return 0
    _bootstrap_src "$cid"
}

# ── Env exports ───────────────────────────────────────────────────
_env_exports() {
    local cid="$1" install_path="$2"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    printf 'export CONTAINER_ROOT=%q\n' "$install_path"
    cat <<'ENVBLOCK'
export HOME="$CONTAINER_ROOT"
export XDG_CACHE_HOME="$CONTAINER_ROOT/.cache"
export XDG_CONFIG_HOME="$CONTAINER_ROOT/.config"
export XDG_DATA_HOME="$CONTAINER_ROOT/.local/share"
export XDG_STATE_HOME="$CONTAINER_ROOT/.local/state"
export PATH="$CONTAINER_ROOT/venv/bin:$CONTAINER_ROOT/python/bin:$CONTAINER_ROOT/.local/bin:$CONTAINER_ROOT/bin:$PATH"
export PYTHONNOUSERSITE=1 PIP_USER=false VIRTUAL_ENV="$CONTAINER_ROOT/venv"
# Ensure venv site-packages are always on PYTHONPATH (survives stale pyvenv.cfg from chroot install)
_sd_sp=$(python3 -c "import sys; print(next((p for p in sys.path if 'site-packages' in p and '/usr' not in p), ''))" 2>/dev/null)
_sd_vsp=$(compgen -G "$CONTAINER_ROOT/venv/lib/python*/site-packages" 2>/dev/null | head -1) || true
[[ -n "$_sd_vsp" ]] && export PYTHONPATH="$_sd_vsp${PYTHONPATH:+:$PYTHONPATH}"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
         "$CONTAINER_ROOT/bin" "$CONTAINER_ROOT/.local/bin" 2>/dev/null
ENVBLOCK

    # GPU detection — triggered by gpu = cuda_auto (or legacy gpu = auto)
    local gpu_flag; gpu_flag=$(jq -r '.meta.gpu // empty' "$sj" 2>/dev/null)
    if [[ "$gpu_flag" == "cuda_auto" || "$gpu_flag" == "auto" ]]; then
        cat <<'GPUBLOCK'
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    export NVIDIA_GPU=1 CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
    printf '[gpu] CUDA mode\n'
else
    printf '[gpu] CPU mode\n'
fi
GPUBLOCK
    fi

    # Environment from [env] section — auto-prefix relative paths with $CONTAINER_ROOT
    local keys; mapfile -t keys < <(jq -r '.environment // {} | keys[]' "$sj" 2>/dev/null)
    for k in "${keys[@]}"; do
        local v; v=$(jq -r --arg k "$k" '.environment[$k] | tostring' "$sj" 2>/dev/null)
        # Apply $CONTAINER_ROOT auto-prefix for relative paths
        local pv; pv=$(_cr_prefix "$v")
        # Special handling: generate:hex32 → generate a random 32-byte hex secret at runtime
        if [[ "$v" == "generate:hex32" ]]; then
            pv='$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d - || echo "changeme_set_secret")'
        fi
        # Special handling for PATH-like vars: append to existing env var
        if [[ "$k" == "LD_LIBRARY_PATH" || "$k" == "LIBRARY_PATH" || "$k" == "PKG_CONFIG_PATH" ]]; then
            printf 'export %s="%s:${%s:-}"\n' "$k" "$pv" "$k"
        else
            printf 'export %s="%s"\n' "$k" "$pv"
        fi
    done
}

# ── Install / update runner ───────────────────────────────────────

# Emits Ubuntu base bootstrap code into the generated install script.
# All paths are baked in at generation time via %q; runtime vars are escaped.
# If Ubuntu is already set up (.ubuntu_ready exists) this block is a no-op.
_emit_ubuntu_bootstrap_inline() {
    local ub_q;      ub_q=$(printf '%q'      "$UBUNTU_DIR")
    local pkgs_q;    pkgs_q=$(printf '%q'    "$DEFAULT_UBUNTU_PKGS")
    local me_q;      me_q=$(printf '%q'      "$(id -un)")
    local sudoers_q; sudoers_q=$(printf '%q' "/etc/sudoers.d/simpledocker_ubsetup_$$")
    printf '# ── Ubuntu base (auto-install if missing) ──\n'
    printf 'if [[ ! -f %q/.ubuntu_ready ]]; then\n' "$UBUNTU_DIR"
    printf '    printf '"'"'\033[1m[ubuntu] Base not found — installing (this takes a few minutes)...\033[0m\n'"'"'\n'
    printf '    _sd_ub_arch=$(uname -m)\n'
    printf '    case "$_sd_ub_arch" in\n'
    printf '        x86_64)  _sd_ub_arch=amd64 ;;\n'
    printf '        aarch64) _sd_ub_arch=arm64  ;;\n'
    printf '        armv7l)  _sd_ub_arch=armhf  ;;\n'
    printf '        *)       _sd_ub_arch=amd64  ;;\n'
    printf '    esac\n'
    printf '    _sd_ub_index="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/"\n'
    printf '    _sd_ub_ver=$(curl -fsSL "$_sd_ub_index" 2>/dev/null | grep -oP "ubuntu-base-\\K[0-9]+\\.[0-9]+\\.[0-9]+-base-${_sd_ub_arch}" | head -1)\n'
    printf '    [[ -z "$_sd_ub_ver" ]] && _sd_ub_ver="24.04.3-base-${_sd_ub_arch}"\n'
    printf '    _sd_ub_url="${_sd_ub_index}ubuntu-base-${_sd_ub_ver}.tar.gz"\n'
    printf '    _sd_ub_tmp=$(mktemp %q/../.sd_ubuntu_dl_XXXXXX.tar.gz 2>/dev/null || mktemp /tmp/.sd_ubuntu_dl_XXXXXX.tar.gz)\n' "$UBUNTU_DIR"
    printf '    mkdir -p %q\n' "$UBUNTU_DIR"
    printf '    printf '"'"'[ubuntu] Downloading Ubuntu 24.04 LTS Noble (%%s)...\\n'"'"' "$_sd_ub_arch"\n'
    printf '    if curl -fsSL --progress-bar "$_sd_ub_url" -o "$_sd_ub_tmp"; then\n'
    printf '        printf '"'"'[ubuntu] Extracting...\\n'"'"'\n'
    printf '        tar -xzf "$_sd_ub_tmp" -C %q 2>&1 || true\n' "$UBUNTU_DIR"
    printf '        rm -f "$_sd_ub_tmp"\n'
    printf '        [[ ! -e %q/bin   ]] && ln -sf usr/bin   %q/bin   2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        [[ ! -e %q/lib   ]] && ln -sf usr/lib   %q/lib   2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        [[ ! -e %q/lib64 ]] && ln -sf usr/lib64 %q/lib64 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        printf '"'"'nameserver 8.8.8.8\\n'"'"' > %q/etc/resolv.conf 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        mkdir -p %q/etc/apt/apt.conf.d 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        printf '"'"'APT::Sandbox::User "root";\\n'"'"' > %q/etc/apt/apt.conf.d/99sandbox 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        printf '"'"'[ubuntu] Installing base packages...\\n'"'"'\n'
    printf '        printf '"'"'%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/chroot, /usr/sbin/chroot\\n'"'"' | sudo -n tee %q >/dev/null 2>&1 || true\n' "$me_q" "$sudoers_q"
    printf '        mkdir -p %q/tmp %q/proc %q/sys %q/dev 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR" "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        sudo -n mount --bind /proc %q/proc 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        sudo -n mount --bind /sys  %q/sys  2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        sudo -n mount --bind /dev  %q/dev  2>/dev/null || true\n' "$UBUNTU_DIR"
    # Write apt command to a temp file — avoids %q mangling && and || metacharacters
    printf '        _sd_ub_apt=$(mktemp %q/../.sd_ubinit_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_ubinit_%s.sh)\n' "$UBUNTU_DIR" "$$"
    printf '        printf '"'"'#!/bin/sh\nset -e\napt-get update -qq\nDEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s 2>&1\n'"'"' > "$_sd_ub_apt"\n' "$DEFAULT_UBUNTU_PKGS"
    printf '        chmod +x "$_sd_ub_apt"\n'
    printf '        sudo -n mount --bind "$_sd_ub_apt" %q/tmp/.sd_ubinit.sh 2>/dev/null || cp "$_sd_ub_apt" %q/tmp/.sd_ubinit.sh 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        _chroot_bash %q /tmp/.sd_ubinit.sh || true\n' "$UBUNTU_DIR"
    printf '        sudo -n umount -lf %q/tmp/.sd_ubinit.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        sudo -n umount -lf %q/dev %q/sys %q/proc 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR" "$UBUNTU_DIR"
    printf '        rm -f "$_sd_ub_apt" %q/tmp/.sd_ubinit.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
    printf '        sudo -n rm -f %q 2>/dev/null || true\n' "$sudoers_q"
    printf '        touch %q/.ubuntu_ready\n' "$UBUNTU_DIR"
    printf '        date '"'"'+%%Y-%%m-%%d'"'"' > %q/.sd_ubuntu_stamp\n' "$UBUNTU_DIR"
    printf '        printf '"'"'\033[0;32m[ubuntu] Ubuntu base ready.\033[0m\\n\\n'"'"'\n'
    printf '    else\n'
    printf '        rm -f "$_sd_ub_tmp"\n'
    printf '        printf '"'"'\033[0;31m[ubuntu] ERROR: Download failed — cannot proceed.\033[0m\\n'"'"'\n'
    printf '        exit 1\n'
    printf '    fi\n'
    printf 'fi\n\n'
}

# Parse [deps] block — collect all package tokens (@ prefix stripped).
# Sets: SD_APK_PKGS (space-sep)
SD_APK_PKGS=""
# Extract apt token for a specific package name from a deps block.
# Returns "pkg=ver" if version specified, else "pkg".
_deps_pkg_apt_token() {
    local block="$1" name="$2"
    local tok _pkg _ver
    while IFS= read -r l; do
        l=$(printf '%s' "$l" | tr -d '\r' | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        while IFS=',' read -r tok; do
            tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            tok="${tok//$'\r'/}"
            [[ "$tok" == @* ]] && tok="${tok#@}"
            _pkg="${tok%%:*}"
            [[ "$_pkg" != "$name" ]] && continue
            if [[ "$tok" == *:* ]]; then
                _ver="${tok#*:}"
                [[ "$_ver" == "latest" ]] && { printf '%s' "$name"; return; }
                _ver="${_ver//.x/.*}"
                printf '%s=%s' "$name" "$_ver"; return
            else
                printf '%s' "$name"; return
            fi
        done <<< "$l"
    done <<< "$block"
    printf '%s' "$name"
}

_deps_parse_split() {
    local block="$1"
    SD_APK_PKGS=""
    while IFS= read -r l; do
        l=$(printf '%s' "$l" | tr -d '\r' | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$l" ]] && continue
        while IFS=',' read -r tok; do
            tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            tok="${tok//$'\r'/}"
            [[ -z "$tok" ]] && continue
            # Strip legacy @ prefix
            [[ "$tok" == @* ]] && tok="${tok#@}"
            # :version → apt pkg=version syntax
            # :X.x wildcard → apt pkg=X.* (highest available for that major)
            if [[ "$tok" == *:* ]]; then
                local _pkg="${tok%%:*}" _ver="${tok#*:}"
                if [[ "$_ver" == "latest" ]]; then
                    tok="$_pkg"
                else
                    _ver="${_ver//.x/.*}"
                    tok="${_pkg}=${_ver}"
                fi
            fi
            [[ -n "$tok" ]] && SD_APK_PKGS+=" $tok"
        done
    done <<< "$block"
    SD_APK_PKGS="${SD_APK_PKGS# }"
}
# ── pip installer (runs into container venv) ──────────────────────
# Called synchronously before runner.
# Uses Ubuntu chroot (glibc) so prebuilt PyPI wheels work on the host.

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
