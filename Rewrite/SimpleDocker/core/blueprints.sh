#!/usr/bin/env bash
# core/blueprints.sh — blueprint compilation, DSL helpers, autodetect,
#                      persistent/imported blueprints, service.json compilation

_bp_compile_to_json() {
    local file="$1" cid="$2"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    declare -A BP_META; declare -A BP_ENV
    BP_META=() BP_ENV=() BP_STORAGE="" BP_DEPS="" BP_DIRS="" BP_PIP=""
    BP_GITHUB="" BP_NPM="" BP_BUILD="" BP_INSTALL="" BP_UPDATE="" BP_START=""
    BP_ACTIONS_NAMES=() BP_ACTIONS_SCRIPTS=() BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()
    BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()
    _bp_parse "$file" || return 1

    local ct_name; ct_name=$(_cname "$cid")
    [[ -n "$ct_name" ]] && BP_META["name"]="$ct_name"

    # Validate — reject before writing any JSON
    if ! _bp_validate; then
        local errmsg; errmsg=$(printf '%s\n' "${BP_ERRORS[@]}")
        pause "$(printf '⚠  Blueprint validation failed:\n\n%s\n\n  Fix the blueprint and try again.' "$errmsg")"
        return 1
    fi

    # Build JSON
    local meta_json="{}"
    for k in "${!BP_META[@]}"; do
        meta_json=$(printf '%s' "$meta_json" | jq --arg k "$k" --arg v "${BP_META[$k]}" '.[$k]=$v')
    done

    local env_json="{}"
    for k in "${!BP_ENV[@]}"; do
        env_json=$(printf '%s' "$env_json" | jq --arg k "$k" --arg v "${BP_ENV[$k]}" '.[$k]=$v')
    done

    # Storage: parse comma/newline separated paths
    local storage_json="[]"
    if [[ -n "$BP_STORAGE" ]]; then
        local sp; sp=$(printf '%s' "$BP_STORAGE" | tr ',' '\n' | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
        storage_json=$(printf '%s\n' $sp | jq -R -s 'split("\n") | map(select(length>0))')
    fi

    # Actions — store label + dsl (raw pipe string from [actions] or legacy script from block sections)
    local acts_json="[]"
    for i in "${!BP_ACTIONS_NAMES[@]}"; do
        local lbl="${BP_ACTIONS_NAMES[$i]}" dsl="${BP_ACTIONS_SCRIPTS[$i]}"
        acts_json=$(printf '%s' "$acts_json" | jq \
            --arg l "$lbl" --arg d "$dsl" '. + [{"label":$l,"dsl":$d}]')
    done

    # Crons — store name + interval + cmd
    local crons_json="[]"
    for i in "${!BP_CRON_NAMES[@]}"; do
        local cn="${BP_CRON_NAMES[$i]}" ci="${BP_CRON_INTERVALS[$i]}" cc="${BP_CRON_CMDS[$i]}" cf="${BP_CRON_FLAGS[$i]:-}"
        crons_json=$(printf '%s' "$crons_json" | jq \
            --arg n "$cn" --arg iv "$ci" --arg c "$cc" --arg f "$cf" '. + [{"name":$n,"interval":$iv,"cmd":$c,"flags":$f}]')
    done

    jq -n \
        --argjson meta "$meta_json" \
        --argjson env "$env_json" \
        --argjson storage "$storage_json" \
        --arg deps "$BP_DEPS" \
        --arg dirs "$BP_DIRS" \
        --arg pip "$BP_PIP" \
        --arg npm "$BP_NPM" \
        --arg git "$BP_GITHUB" \
        --arg build "$BP_BUILD" \
        --arg install "$BP_INSTALL" \
        --arg update "$BP_UPDATE" \
        --arg start "$BP_START" \
        --argjson actions "$acts_json" \
        --argjson crons "$crons_json" \
        '{meta:$meta, environment:$env, storage:$storage,
          deps:$deps, dirs:$dirs, pip:$pip, npm:$npm, git:$git, build:$build,
          install:$install, update:$update, start:$start,
          actions:$actions, crons:$crons}' > "$sj" 2>/dev/null || return 1
}

# For backward compat: detect if a file is old JSON format
_bp_is_json() {
    jq '.' "$1" >/dev/null 2>&1
}

# Read a field from service.json (handles both new and old formats)

# ── $CONTAINER_ROOT auto-prefix ───────────────────────────────────
# Any value that looks like a relative path (no $, no ://, not starting
# with / or ~) gets $CONTAINER_ROOT/ prepended.
# Used at inject-time for [env] values.
_cr_prefix() {
    local v="$1"
    # pass-through: already absolute, already has $, or is a URL
    if [[ "$v" == /* || "$v" == ~* || "$v" == *'$'* || "$v" == *'://'* ]]; then
        printf '%s' "$v"; return
    fi
    # pass-through: empty, numeric, plain word with no path chars that looks like a flag/value
    [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return; }
    # pass-through: contains a colon (special directive like generate:hex32, or host:port)
    [[ "$v" == *':'* ]] && { printf '%s' "$v"; return; }
    # pass-through: looks like an IP address or hostname (dots, digits, no slashes)
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$v"; return; }
    # treat as relative path
    printf '$CONTAINER_ROOT/%s' "$v"
}

# ── [dirs] section processor ──────────────────────────────────────
# Parses:  bin, models, logs, lib(ollama)
# or multiline / deeply nested:  data(db(snapshots, wal), uploads)
# Creates all directories under $root.

# ── Persistent blueprint parser (new DSL format inside heredoc) ───
_SELF_PATH="$(realpath "$0" 2>/dev/null || printf '%s' "$0")"

# ── Blueprint settings config (.sd/bp_settings.json in image) ────
_bp_cfg()           { printf '%s/.sd/bp_settings.json' "$MNT_DIR"; }
_bp_cfg_get()       { jq -r ".$1 // empty" "$(_bp_cfg)" 2>/dev/null; }
_bp_cfg_set() {
    local key="$1" val="$2" tmp
    mkdir -p "$(dirname "$(_bp_cfg)")" 2>/dev/null
    [[ ! -f "$(_bp_cfg)" ]] && printf '{}' > "$(_bp_cfg)"
    tmp=$(mktemp "$TMP_DIR/.sd_bpcfg_XXXXXX")
    jq --arg k "$key" --arg v "$val" '.[$k]=$v' "$(_bp_cfg)" > "$tmp" && mv "$tmp" "$(_bp_cfg)" || rm -f "$tmp"
}
# persistent_blueprints: "true" (default) | "false"
_bp_persistent_enabled() { [[ "$(_bp_cfg_get persistent_blueprints)" != "false" ]]; }
# autodetect_blueprints: "Home" (default) | "Root" | "Everywhere" | "Custom" | "Disabled"
_bp_autodetect_mode()    { local m; m=$(_bp_cfg_get autodetect_blueprints); printf '%s' "${m:-Home}"; }

# Custom scan paths stored as JSON array in bp_settings.json under key "custom_paths"
_bp_custom_paths_get() {
    jq -r '.custom_paths[]? // empty' "$(_bp_cfg)" 2>/dev/null
}
_bp_custom_paths_add() {
    local p="$1"
    mkdir -p "$(dirname "$(_bp_cfg)")" 2>/dev/null
    [[ ! -f "$(_bp_cfg)" ]] && printf '{}' > "$(_bp_cfg)"
    local tmp; tmp=$(mktemp "$TMP_DIR/.sd_bpcfg_XXXXXX")
    jq --arg p "$p" '.custom_paths = ((.custom_paths // []) + [$p] | unique)' "$(_bp_cfg)" > "$tmp" \
        && mv "$tmp" "$(_bp_cfg)" || rm -f "$tmp"
}
_bp_custom_paths_remove() {
    local p="$1"
    local tmp; tmp=$(mktemp "$TMP_DIR/.sd_bpcfg_XXXXXX")
    jq --arg p "$p" '.custom_paths = [.custom_paths[]? | select(. != $p)]' "$(_bp_cfg)" > "$tmp" \
        && mv "$tmp" "$(_bp_cfg)" || rm -f "$tmp"
}

# ── Autodetect: scan for .container files ────────────────────────
_bp_autodetect_dirs() {
    local mode; mode=$(_bp_autodetect_mode)
    # Only match clean single-stem names: myapp.container, not foo.zig.container
    # Home mode prunes hidden dirs to exclude ~/.config, ~/.cache, ~/.local etc.
    case "$mode" in
        Home)
            find "$HOME" -maxdepth 6 \
                \( -path "$HOME/.*" -o -path '*/node_modules' -o -path '*/__pycache__' -o -path '*/.git' -o -path '*/vendor' \) \
                -prune -o -name '*.container' -type f -print 2>/dev/null \
                | grep -E '/[^./]+\.container$' ;;
        Root)
            find / -maxdepth 8 \
                \( -path '*/node_modules' -o -path '*/__pycache__' -o -path '*/.git' -o -path '*/vendor' \) \
                -prune -o -name '*.container' -type f -print 2>/dev/null \
                | grep -E '/[^./]+\.container$' ;;
        Everywhere)
            find / -maxdepth 12 \
                \( -path '*/node_modules' -o -path '*/__pycache__' -o -path '*/.git' -o -path '*/vendor' \) \
                -prune -o -name '*.container' -type f -print 2>/dev/null \
                | grep -E '/[^./]+\.container$' ;;
        Custom)
            while IFS= read -r _cpath; do
                [[ -d "$_cpath" ]] || continue
                find "$_cpath" \
                    \( -path '*/node_modules' -o -path '*/__pycache__' -o -path '*/.git' -o -path '*/vendor' \) \
                    -prune -o -name '*.container' -type f -print 2>/dev/null \
                    | grep -E '/[^./]+\.container$'
            done < <(_bp_custom_paths_get) ;;
        Disabled|*) return ;;
    esac
}

_list_imported_names() {
    [[ "$(_bp_autodetect_mode)" == "Disabled" ]] && return
    while IFS= read -r f; do
        [[ -f "$f" ]] && basename "${f%.container}"
    done < <(_bp_autodetect_dirs) | sort -u
}

_get_imported_bp_path() {
    local name="$1"
    [[ "$(_bp_autodetect_mode)" == "Disabled" ]] && return
    while IFS= read -r f; do
        [[ "$(basename "${f%.container}")" == "$name" ]] && printf '%s' "$f" && return
    done < <(_bp_autodetect_dirs)
}

_list_persistent_names() {
    _bp_persistent_enabled || return 0
    awk '
        /SD_PERSISTENT_END/ && !opened  { in_block=1; opened=1; next }
        /^SD_PERSISTENT_END$/ && opened { in_block=0; exit }
        in_block && /^# \[/ { s=$0; sub(/^# \[/,"",s); sub(/\].*/,"",s); print s }
    ' "$_SELF_PATH" 2>/dev/null
}

_get_persistent_bp() {
    awk -v name="$1" '
        /SD_PERSISTENT_END/ && !opened  { in_block=1; opened=1; next }
        /^SD_PERSISTENT_END$/ && opened { exit }
        !in_block { next }
        !found && $0 == "# [" name "]" { found=1; next }
        found && /^# \[/ { exit }
        found { sub(/^# /, ""); print }
    ' "$_SELF_PATH" 2>/dev/null
}

_view_persistent_bp() {
    local content; content=$(_get_persistent_bp "$1")
    [[ -z "$content" ]] && { pause "Could not read blueprint '$1'."; return; }
    printf '%s\n' "$content" \
        | _fzf "${FZF_BASE[@]}" \
              --header="$(printf "${BLD}── [Persistent] %s  ${DIM}(read only)${NC} ──${NC}" "$1")" \
              --no-multi --disabled 2>/dev/null || true
}

# Determine blueprint file extension (.toml = new, .json = old)
_bp_path() {
    local name="$1"
    [[ -f "$BLUEPRINTS_DIR/$name.toml" ]] && printf '%s/%s.toml' "$BLUEPRINTS_DIR" "$name" && return
    [[ -f "$BLUEPRINTS_DIR/$name.json" ]] && printf '%s/%s.json' "$BLUEPRINTS_DIR" "$name" && return
    printf '%s/%s.toml' "$BLUEPRINTS_DIR" "$name"  # default for new
}

_list_blueprint_names() {
    for f in "$BLUEPRINTS_DIR"/*.toml "$BLUEPRINTS_DIR"/*.json; do
        [[ -f "$f" ]] && basename "${f%.*}"
    done | sort -u
}

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

