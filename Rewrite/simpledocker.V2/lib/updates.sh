#!/usr/bin/env bash

_collect_bps_by_type() {
    local stype="$1"
    _UPD_FILES=(); _UPD_NAMES=(); _UPD_VERS=(); _UPD_SRCS=(); _UPD_ISTMP=()
    for f in "$BLUEPRINTS_DIR"/*.toml "$BLUEPRINTS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        local t; t=$(_get_bp_storage_type "$f"); [[ "$t" != "$stype" ]] && continue
        local v; v=$(_get_bp_version "$f")
        _UPD_FILES+=("$f"); _UPD_NAMES+=("$(basename "${f%.*}")"); _UPD_VERS+=("$v"); _UPD_SRCS+=("Blueprint"); _UPD_ISTMP+=(false)
    done
    local pname
    while IFS= read -r pname; do
        local raw; raw=$(_get_persistent_bp "$pname"); [[ -z "$raw" ]] && continue
        local tmp; tmp=$(mktemp "$TMP_DIR/.sd_upd_XXXXXX.toml")
        printf '%s\n' "$raw" > "$tmp"
        local t; t=$(_get_bp_storage_type "$tmp")
        if [[ "$t" != "$stype" ]]; then rm -f "$tmp"; continue; fi
        local v; v=$(_get_bp_version "$tmp")
        _UPD_FILES+=("$tmp"); _UPD_NAMES+=("$pname"); _UPD_VERS+=("$v"); _UPD_SRCS+=("Persistent"); _UPD_ISTMP+=(true)
    done < <(_list_persistent_names)
}

_cleanup_upd_tmps() {
    for i in "${!_UPD_ISTMP[@]}"; do
        [[ "${_UPD_ISTMP[$i]}" == true && -f "${_UPD_FILES[$i]}" ]] && rm -f "${_UPD_FILES[$i]}"
    done
    _UPD_FILES=(); _UPD_NAMES=(); _UPD_VERS=(); _UPD_SRCS=(); _UPD_ISTMP=()
}

_write_pkg_manifest() {
    local cid="$1" sj="$CONTAINERS_DIR/$cid/service.json" mf="$CONTAINERS_DIR/$cid/pkg_manifest.json"
    local deps pip gh dep_arr="[]" pip_arr="[]" gh_arr="[]"
    deps=$(jq -r '.deps // empty' "$sj" 2>/dev/null)
    pip=$(jq -r '.pip // empty' "$sj" 2>/dev/null)
    gh=$(jq -r '.git // empty' "$sj" 2>/dev/null)
    if [[ -n "$deps" ]]; then
        _deps_parse_split "$deps"
        dep_arr=$(printf '%s\n' $SD_APK_PKGS | jq -R . | jq -s . 2>/dev/null || echo "[]")
    fi
    [[ -n "$pip" ]] && pip_arr=$(printf '%s' "$pip" | tr ',' '\n' | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo "[]")
    if [[ -n "$gh" ]]; then
        gh_arr=$(while IFS= read -r l; do
            l=$(printf '%s' "$l" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$l" ]] && continue
            [[ "$l" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*=[[:space:]]*(.*) ]] && l="${BASH_REMATCH[1]}"
            printf '%s\n' "$(printf '%s' "$l" | awk '{print $1}')"
        done <<< "$gh" | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo "[]")
    fi
    local npm npm_arr="[]"
    npm=$(jq -r '.npm // empty' "$sj" 2>/dev/null)
    [[ -n "$npm" ]] && npm_arr=$(printf '%s' "$npm" | tr ',' '
' | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo "[]")
    jq -n --argjson d "$dep_arr" --argjson p "$pip_arr" --argjson n "$npm_arr" --argjson g "$gh_arr" \
        --arg ts "$(date '+%Y-%m-%d %H:%M')" '{deps:$d,pip:$p,npm:$n,git:$g,updated:$ts}' > "$mf" 2>/dev/null || true
}

_build_pkg_update_item() {
    local cid="$1" mf="$CONTAINERS_DIR/$cid/pkg_manifest.json"
    [[ ! -f "$mf" ]] && return
    local n; n=$(jq -r '(.deps|length)+(.pip|length)+(.npm|length)+(.git|length)' "$mf" 2>/dev/null)
    [[ "${n:-0}" -eq 0 ]] && return
    local ts; ts=$(jq -r '.updated // empty' "$mf" 2>/dev/null)
    # github update check (cached 1h)
    local has_upd=0
    local cache="$CACHE_DIR/gh_tag/$cid" inst="$CACHE_DIR/gh_tag/$cid.inst"
    local age=9999
    [[ -f "$cache" ]] && age=$(( $(date +%s) - $(date -r "$cache" +%s 2>/dev/null || echo 0) ))
    if [[ $age -gt 3600 ]]; then
        local _gh_out; _gh_out=$(jq -r '.git[]' "$mf" 2>/dev/null | while IFS= read -r repo; do
            curl -fsSL --max-time 6 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
                | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4
        done)
        [[ -n "$_gh_out" ]] && printf '%s\n' "$_gh_out" > "$cache"
    fi
    if [[ -f "$cache" && -f "$inst" ]]; then
        [[ "$(cat "$cache")" != "$(cat "$inst")" ]] && has_upd=1
    elif [[ -f "$cache" && -s "$cache" ]]; then
        has_upd=1
    fi
    local entry
    if [[ $has_upd -eq 1 ]]; then
        entry="$(printf "${DIM}[P]${NC} Packages ${DIM}— %s${NC} — ${YLW}Update available${NC}" "${ts:-never}")"
    else
        entry="$(printf "${DIM}[P]${NC} Packages ${DIM}— ✓ %s${NC}" "${ts:-never}")"
    fi
    _UPD_ITEMS=("$entry" "${_UPD_ITEMS[@]}")
    _UPD_IDX=("__pkgs__" "${_UPD_IDX[@]}")
}

_do_pkg_update() {
    local cid="$1" mf="$CONTAINERS_DIR/$cid/pkg_manifest.json"
    local install_path; install_path=$(_cpath "$cid")
    [[ ! -f "$mf" ]] && { pause "No manifest. Reinstall first."; return; }
    local dep_pkgs pip_pkgs npm_pkgs gh_repos
    dep_pkgs=$(jq -r '.deps|join(" ")' "$mf" 2>/dev/null)
    pip_pkgs=$(jq -r '.pip|join(" ")' "$mf" 2>/dev/null)
    npm_pkgs=$(jq -r '.npm|join(" ")' "$mf" 2>/dev/null)
    gh_repos=$(jq -r '.git[]' "$mf" 2>/dev/null)
    [[ -z "$dep_pkgs" && -z "$pip_pkgs" && -z "$npm_pkgs" && -z "$gh_repos" ]] && { pause "Nothing to update."; return; }
    local _um=""; [[ -n "$dep_pkgs" ]] && _um+="$(printf "  apt: %s\n" "$dep_pkgs")"
    [[ -n "$pip_pkgs" ]] && _um+="$(printf "  pip: %s\n" "$pip_pkgs")"
    [[ -n "$npm_pkgs" ]] && _um+="$(printf "  npm: %s\n" "$npm_pkgs")"
    [[ -n "$gh_repos" ]] && _um+="  git: $(printf '%s' "$gh_repos" | tr '\n' ' ')"
    confirm "$(printf "Update packages for '%s'?\n\n%s" "$(_cname "$cid")" "$_um")" || return
    local ok="$CONTAINERS_DIR/$cid/.install_ok" fail="$CONTAINERS_DIR/$cid/.install_fail"
    rm -f "$ok" "$fail"
    local scr; scr=$(mktemp "$TMP_DIR/.sd_pkgupd_XXXXXX.sh")
    local arch; [[ "$(uname -m)" == "aarch64" ]] && arch=arm64 || arch=amd64
    local _sd_cfn='_chroot_bash() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }'
    local ok_q fail_q; ok_q=$(printf '%q' "$ok"); fail_q=$(printf '%q' "$fail")
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$_sd_cfn"
        printf '_finish() { local c=$?; [[ $c -eq 0 ]] && touch %s || touch %s; }\n' "$ok_q" "$fail_q"
        printf 'trap _finish EXIT\n'
        printf 'trap '"'"'touch %s; exit 130'"'"' INT TERM\n\n' "$fail_q"
        printf '_mnt_ubuntu() { sudo -n mount --bind /proc %q/proc; sudo -n mount --bind /sys %q/sys; sudo -n mount --bind /dev %q/dev; }\n' \
            "$UBUNTU_DIR" "$UBUNTU_DIR" "$UBUNTU_DIR"
        printf '_umnt_ubuntu() { sudo -n umount -lf %q/dev %q/sys %q/proc 2>/dev/null||true; }\n' \
            "$UBUNTU_DIR" "$UBUNTU_DIR" "$UBUNTU_DIR"

        # ════════════════════════════════════════════════════════
        # ── Package update handlers (apt, pip, npm, git)       ──
        # ════════════════════════════════════════════════════════

        # ── apt: upgrade only already-installed packages ──────────
        if [[ -n "$dep_pkgs" && -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
            printf 'printf "\033[1m[apt] Upgrading: %s\033[0m\n"\n' "$dep_pkgs"
            printf '_mnt_ubuntu\n'
            printf '_sd_apt_upd=$(mktemp %q/../.sd_aptupd_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_aptupd_%s.sh)\n' "$UBUNTU_DIR" "$$"
            printf 'printf '"'"'#!/bin/sh\nset -e\napt-get update -qq\nDEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade %s 2>&1\n'"'"' > "$_sd_apt_upd"\n' "$dep_pkgs"
            printf 'chmod +x "$_sd_apt_upd"\n'
            printf 'sudo -n mount --bind "$_sd_apt_upd" %q/tmp/.sd_aptupd_run.sh 2>/dev/null || cp "$_sd_apt_upd" %q/tmp/.sd_aptupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
            printf '_chroot_bash %q /tmp/.sd_aptupd_run.sh\n' "$UBUNTU_DIR"
            printf 'sudo -n umount -lf %q/tmp/.sd_aptupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf 'rm -f "$_sd_apt_upd" %q/tmp/.sd_aptupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf '_umnt_ubuntu\n\n'
        fi

        # ── pip: upgrade named packages inside venv ──────────────
        if [[ -n "$pip_pkgs" && -f "$install_path/venv/bin/pip" ]]; then
            printf 'printf "\033[1m[pip] Upgrading: %s\033[0m\n"\n' "$pip_pkgs"
            printf '_mnt_ubuntu\n'
            printf 'sudo -n mount --bind %q %q/mnt\n' "$install_path" "$UBUNTU_DIR"
            printf '_sd_pip_upd=$(mktemp %q/../.sd_pipupd_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_pipupd_%s.sh)\n' "$UBUNTU_DIR" "$$"
            printf 'printf '"'"'#!/bin/sh\nset -e\n/mnt/venv/bin/pip install --upgrade %s 2>&1\n'"'"' > "$_sd_pip_upd"\n' "$pip_pkgs"
            printf 'chmod +x "$_sd_pip_upd"\n'
            printf 'sudo -n mount --bind "$_sd_pip_upd" %q/tmp/.sd_pipupd_run.sh 2>/dev/null || cp "$_sd_pip_upd" %q/tmp/.sd_pipupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
            printf '_chroot_bash %q /tmp/.sd_pipupd_run.sh\n' "$UBUNTU_DIR"
            printf 'sudo -n umount -lf %q/tmp/.sd_pipupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf 'sudo -n umount -lf %q/mnt 2>/dev/null||true\n' "$UBUNTU_DIR"
            printf 'rm -f "$_sd_pip_upd" %q/tmp/.sd_pipupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf '_umnt_ubuntu\n\n'
        fi

        # ── npm: upgrade named packages ──────────────────────────
        if [[ -n "$npm_pkgs" && -d "$install_path/node_modules" ]]; then
            printf 'printf "\033[1m[npm] Upgrading: %s\033[0m\n"\n' "$npm_pkgs"
            printf '_mnt_ubuntu\n'
            printf 'sudo -n mount --bind %q %q/mnt\n' "$install_path" "$UBUNTU_DIR"
            printf '_sd_npm_upd=$(mktemp %q/../.sd_npmupd_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_npmupd_%s.sh)\n' "$UBUNTU_DIR" "$$"
            printf 'printf '"'"'#!/bin/sh\nset -e\ncd /mnt && npm update %s 2>&1\n'"'"' > "$_sd_npm_upd"\n' "$npm_pkgs"
            printf 'chmod +x "$_sd_npm_upd"\n'
            printf 'sudo -n mount --bind "$_sd_npm_upd" %q/tmp/.sd_npmupd_run.sh 2>/dev/null || cp "$_sd_npm_upd" %q/tmp/.sd_npmupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR" "$UBUNTU_DIR"
            printf '_chroot_bash %q /tmp/.sd_npmupd_run.sh\n' "$UBUNTU_DIR"
            printf 'sudo -n umount -lf %q/tmp/.sd_npmupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf 'sudo -n umount -lf %q/mnt 2>/dev/null||true\n' "$UBUNTU_DIR"
            printf 'rm -f "$_sd_npm_upd" %q/tmp/.sd_npmupd_run.sh 2>/dev/null || true\n' "$UBUNTU_DIR"
            printf 'sudo -n chown -R %q %q/node_modules 2>/dev/null || true\n' "${_me2}:" "$install_path"
            printf '_umnt_ubuntu\n\n'
        fi

        # ── git: check tag, only re-download if newer ───────────
        if [[ -n "$gh_repos" ]]; then
            printf 'printf "\033[1m[git] Checking releases\xe2\x80\xa6\033[0m\n"\n'
            printf '_SD_ARCH=%q\n_SD_INSTALL=%q\n' "$arch" "$install_path"
            local inst_f; inst_f=$(printf '%q' "$CACHE_DIR/gh_tag/$cid.inst")
            printf '_new_tags=""\n'
            # Embed helpers
            cat <<'HELPERS'
_sd_ltag(){ curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4; }
_sd_burl(){ local r=$1 a=$2 rel urls u
    rel=$(curl -fsSL "https://api.github.com/repos/$r/releases/latest" 2>/dev/null)
    urls=$(printf '%s' "$rel" | grep -o '"browser_download_url":"[^"]*"' \
        | grep -ivE 'sha256|\.sig|\.txt|\.json|rocm' | grep -o 'https://[^"]*')
    u=$(printf '%s\n' "$urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$' \
        | grep -iE "linux.*$a|$a.*linux" | head -1)
    [[ -z "$u" ]] && u=$(printf '%s\n' "$urls" | grep -iE "$a" | head -1)
    printf '%s' "$u"; }
_sd_xauto(){ local u=$1 d=$2; mkdir -p "$d"
    local t; t=$(mktemp "$d/.dl_X")
    curl -fL --progress-bar --retry 3 -C - "$u" -o "$t" || { rm -f "$t"; return 1; }
    if   [[ "$u" =~ \.(tar\.(gz|bz2|xz|zst)|tgz)$ ]]; then
        tar -xa -C "$d" --strip-components=1 -f "$t" 2>/dev/null \
            || tar -xa -C "$d" -f "$t" 2>/dev/null
    elif [[ "$u" =~ \.zip$ ]]; then unzip -o -d "$d" "$t" 2>/dev/null
    else mkdir -p "$d/bin"
        mv "$t" "$d/bin/$(basename "$u" | sed 's/[?#].*//')"; chmod +x "$d/bin/"*; return
    fi; rm -f "$t"; }
HELPERS
            while IFS= read -r repo; do
                [[ -z "$repo" ]] && continue
                local _inst_tag_q; _inst_tag_q=$(printf '%q' "$CACHE_DIR/gh_tag/$cid.inst")
                printf 'printf "  checking %s\\n" %q\n' "$repo" "$repo"
                printf '_latest=$(_sd_ltag %q)\n' "$repo"
                # Read installed tag for this specific repo from the inst file (one tag per line, same order as manifest)
                printf '_inst=$(grep -x %q %s 2>/dev/null | head -1 || true)\n' "$repo" "$_inst_tag_q"
                printf 'if [[ -z "$_latest" ]]; then printf "  [!] could not fetch tag for %s, skipping\n"; \n' "$repo"
                printf 'elif [[ "$_latest" == "$_inst" ]]; then\n'
                printf '    printf "  \033[2m✓ %s already at %%s\033[0m\n" "$_latest"\n' "$repo"
                printf 'else\n'
                printf '    printf "  \033[1m%s: %%s → %%s\033[0m\n" "${_inst:-(unknown)}" "$_latest"\n' "$repo"
                printf '    _url=$(_sd_burl %q "$_SD_ARCH")\n' "$repo"
                printf '    if [[ -n "$_url" ]]; then\n'
                printf '        _sd_xauto "$_url" "$_SD_INSTALL" && printf "  \033[0;32m✓ updated %%s\033[0m\n" "$_latest"\n'
                printf '    else printf "  [!] no release asset found for %s\n"; fi\n' "$repo"
                printf 'fi\n'
                # Track new tag
                printf '_new_tags="${_new_tags}${_latest}\n"\n'
            done <<< "$gh_repos"
            # Write inst file with updated tags (one per line, same order)
            printf 'printf "%%s" "$_new_tags" > %s\n' "$inst_f"
        fi

        printf 'jq --arg t "$(date '"'"'+%%Y-%%m-%%d %%H:%%M'"'"')" '"'"'.updated=$t'"'"' %q > %q.tmp && mv %q.tmp %q\n' \
            "$mf" "$mf" "$mf" "$mf"
        printf 'printf "\n\033[0;32m══ Package update complete ══\033[0m\n"\n'
    } > "$scr"
    chmod +x "$scr"
    _tmux_set SD_INSTALLING "$cid"
    local _pu_sess; _pu_sess=$(_inst_sess "$cid")
    tmux kill-session -t "$_pu_sess" 2>/dev/null || true
    _tmux_launch "$_pu_sess" "Pkg update: $(_cname "$cid")" "$scr"
    [[ $? -eq 1 ]] && { rm -f "$scr"; _tmux_set SD_INSTALLING ""; return; }
    rm -f "$CACHE_DIR/gh_tag/$cid"
}

_ct_ubuntu_stamp() { cat "${1}/.sd_ubuntu_stamp" 2>/dev/null; }

_ct_ubuntu_ver() {
    local p="$1"
    grep -m1 '^VERSION_ID=' "${p}/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"'
}

_build_ubuntu_update_item() {
    local cid="$1"
    local install_path; install_path=$(_cpath "$cid")
    [[ -z "$install_path" || ! -d "$install_path" ]] && return

    local entry
    if [[ ! -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
        entry="$(printf "${DIM}[U]${NC} Ubuntu base ${DIM}—${NC} ${YLW}Not installed${NC}")"
    else
        local ct_stamp;   ct_stamp=$(_ct_ubuntu_stamp "$install_path")
        local base_stamp; base_stamp=$(_ct_ubuntu_stamp "$UBUNTU_DIR")
        local ct_ver;     ct_ver=$(_ct_ubuntu_ver "$UBUNTU_DIR")
        [[ -z "$ct_ver" ]] && ct_ver="unknown"
        if [[ -z "$base_stamp" || ( -n "$ct_stamp" && "$ct_stamp" == "$base_stamp" ) ]]; then
            entry="$(printf "${DIM}[U]${NC} Ubuntu base ${DIM}— ✓ %s${NC}" "$ct_ver")"
        else
            entry="$(printf "${DIM}[U]${NC} Ubuntu base — ${YLW}%s — Update available${NC}" "$ct_ver")"
        fi
    fi
    _UPD_ITEMS+=("$entry")
    _UPD_IDX+=("__ubuntu__")
}

_do_ubuntu_update() {
    local cid="$1" name; name=$(_cname "$cid")
    local base_ver; base_ver=$(_ct_ubuntu_ver "$UBUNTU_DIR")

    # Step 1: confirm
    confirm "$(printf "Update Ubuntu base for '%s'?\n\n  Base : %s" "$name" "$base_ver")" || return

    # Step 2: backup
    local snap_label="Update-${base_ver//[ .]/-}"
    if confirm "$(printf "Create a backup first?\n\n  Will appear in Backups as '%s'." "$snap_label")"; then
        local sdir; sdir=$(_snap_dir "$cid")
        local install_path; install_path=$(_cpath "$cid")
        mkdir -p "$sdir" 2>/dev/null
        local snap_id="$snap_label" n=1
        while [[ -d "$sdir/$snap_id" ]]; do snap_id="${snap_label}-$n"; (( n++ )); done
        if btrfs subvolume snapshot -r "$install_path" "$sdir/$snap_id" &>/dev/null \
            || cp -a "$install_path" "$sdir/$snap_id" 2>/dev/null; then
            _snap_meta_set "$sdir" "$snap_id" "type=manual" "ts=$(date '+%Y-%m-%d %H:%M')"
            pause "$(printf "✓ Backup '%s' created." "$snap_id")"
        else
            confirm "⚠  Backup failed. Continue anyway?" || return
        fi
    fi

    # Step 3: attach or background — runs apt upgrade in the shared Ubuntu base
    local apt_cmd="apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y 2>&1"
    _ubuntu_pkg_tmux "sdUbuntuCtUpd" "Ubuntu update — $name" "$apt_cmd"
    # Stamp both the base and the container install path
    date '+%Y-%m-%d' > "$UBUNTU_DIR/.sd_ubuntu_stamp" 2>/dev/null || true
    local _up; _up=$(_cpath "$cid")
    [[ -n "$_up" ]] && cp "$UBUNTU_DIR/.sd_ubuntu_stamp" "$_up/.sd_ubuntu_stamp" 2>/dev/null || true
}

_build_update_items() {
    local cid="$1"; _UPD_ITEMS=(); _UPD_IDX=()
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local stype; stype=$(jq -r '.meta.storage_type // empty' "$sj" 2>/dev/null)
    local cur_ver; cur_ver=$(jq -r '.meta.version // empty' "$sj" 2>/dev/null)
    local cur_src="$CONTAINERS_DIR/$cid/service.src"
    [[ -z "$stype" ]] && return
    _collect_bps_by_type "$stype"; [[ ${#_UPD_FILES[@]} -eq 0 ]] && return
    for i in "${!_UPD_FILES[@]}"; do
        local nv="${_UPD_VERS[$i]}" src="${_UPD_SRCS[$i]}" bn="${_UPD_NAMES[$i]}"
        local stag; [[ "$src" == Persistent ]] && stag="${BLU}[P]${NC}" || stag="${DIM}[B]${NC}"
        local entry
        if [[ "$cur_ver" == "$nv" ]]; then
            # Same version — check for config drift
            local has_diff=0
            [[ -f "$cur_src" && -f "${_UPD_FILES[$i]}" ]] &&                 diff -q "$cur_src" "${_UPD_FILES[$i]}" >/dev/null 2>&1 || has_diff=1
            if [[ $has_diff -eq 1 && -f "$cur_src" && -f "${_UPD_FILES[$i]}" ]]; then
                local _vs=""; [[ -n "$cur_ver" ]] && _vs="  ${DIM}v${cur_ver}${NC}"
                entry="$(printf "%b %s ${DIM}%s${NC} — ${YLW}Changes detected${NC}%b" "$stag" "$bn" "$src" "$_vs")"
            else
                local _vs2=""; [[ -n "$cur_ver" ]] && _vs2=" ${cur_ver}"
                entry="$(printf "%b %s ${DIM}%s — ✓%s${NC}" "$stag" "$bn" "$src" "$_vs2")"
            fi
        else
            local _cv=""; [[ -n "$cur_ver" ]] && _cv="$cur_ver" || _cv="?"
            entry="$(printf "%b %s ${DIM}%s${NC} — ${YLW}%s${NC} → ${GRN}%s${NC}" "$stag" "$bn" "$src" "$_cv" "${nv:-?}")"
        fi
        _UPD_ITEMS+=("$entry"); _UPD_IDX+=("$i")
    done
}

_do_blueprint_update() {
    local cid="$1" idx="$2"
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local cur_ver; cur_ver=$(jq -r '.meta.version // empty' "$sj" 2>/dev/null)
    local bp_file="${_UPD_FILES[$idx]}" new_ver="${_UPD_VERS[$idx]}" bname="${_UPD_NAMES[$idx]}" src="${_UPD_SRCS[$idx]}"
    local cur_src="$CONTAINERS_DIR/$cid/service.src"
    if [[ "$cur_ver" == "$new_ver" ]]; then
        # Same version — check if blueprint config differs from installed src
        local has_diff=0
        if [[ -f "$cur_src" && -f "$bp_file" ]]; then
            diff -q "$cur_src" "$bp_file" >/dev/null 2>&1 || has_diff=1
        fi
        if [[ $has_diff -eq 0 ]]; then
            pause "$(printf "Nothing to do — '%s' is already up to date\n  (version %s, configuration unchanged)." "$bname" "${cur_ver:-?}")"
            return
        fi
        # Config differs even though version is the same
        confirm "$(printf "Changes detected in '%s' (version %s unchanged).\n\n  Blueprint : %s\n  Apply configuration changes?"             "$(_cname "$cid")" "${cur_ver:-?}" "$bname")" || return
        cp "$bp_file" "$cur_src"
        if _compile_service "$cid"; then
            [[ "$(jq -r '.meta.installed // false' "$sj" 2>/dev/null)" == "true" ]] && _build_start_script "$cid" 2>/dev/null || true
            pause "$(printf "Configuration updated for '%s' (version %s)." "$(_cname "$cid")" "${cur_ver:-?}")"
        else
            pause "⚠  Update applied but compile had errors. Check Edit configuration."
        fi
        return
    fi
    confirm "$(printf "Update '%s' from %s?\n\n  Blueprint : %s\n  Version   : %s → %s" \
        "$(_cname "$cid")" "$src" "$bname" "${cur_ver:-?}" "${new_ver:-?}")" || return
    cp "$bp_file" "$CONTAINERS_DIR/$cid/service.src"
    if _compile_service "$cid"; then
        [[ "$(jq -r '.meta.installed // false' "$sj" 2>/dev/null)" == "true" ]] && _build_start_script "$cid" 2>/dev/null || true
        pause "$(printf "'%s' updated to %s." "$(_cname "$cid")" "${new_ver:-?}")"
    else
        pause "⚠  Update applied but compile had errors. Check Edit configuration."
    fi
}
