#!/usr/bin/env bash
# tui/menus.sh — fzf UI primitives, all menu functions

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

FINPUT_RESULT=""
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

# ── Resize image ──────────────────────────────────────────────────

_blueprint_template() {
    printf '%s\n' "$SD_BLUEPRINT_PRESET"
}

_list_blueprint_names() {
    for f in "$BLUEPRINTS_DIR"/*.toml "$BLUEPRINTS_DIR"/*.json; do
        [[ -f "$f" ]] && basename "${f%.*}"
    done | sort -u
}

_blueprint_submenu() {
    local bname="$1" bfile; bfile=$(_bp_path "$bname")
    while true; do
        _menu "Blueprint: $bname" "${L[bp_edit]}" "${L[bp_rename]}" "${L[bp_delete]}"
        case $? in 2) continue ;; 0) ;; *) return ;; esac
        case "$REPLY" in
            "${L[bp_edit]}")
                _guard_space || continue
                ${EDITOR:-vi} "$bfile" ;;
            "${L[bp_rename]}")
                while true; do
                    finput "New name for blueprint '$bname':" || break
                    local new_bname; new_bname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"
                    [[ -z "$new_bname" ]] && { pause "Name cannot be empty."; continue; }
                    local ext="${bfile##*.}"
                    local new_bfile="$BLUEPRINTS_DIR/$new_bname.$ext"
                    [[ -f "$new_bfile" ]] && { pause "Blueprint '$new_bname' already exists."; continue; }
                    mv "$bfile" "$new_bfile" 2>/dev/null || { pause "Could not rename."; break; }
                    pause "Blueprint renamed to '$new_bname'."; return
                done ;;
            "${L[bp_delete]}")
                confirm "$(printf "Delete blueprint '%s'?\nThis cannot be undone." "$bname")" || continue
                rm -f "$bfile" 2>/dev/null || { pause "Could not delete."; continue; }
                pause "Blueprint '$bname' deleted."; return ;;
        esac
    done
}

# ── Update helpers ────────────────────────────────────────────────
_UPD_FILES=(); _UPD_NAMES=(); _UPD_VERS=(); _UPD_SRCS=(); _UPD_ISTMP=()
_UPD_ITEMS=(); _UPD_IDX=()

_get_bp_storage_type() {
    local file="$1"
    if _bp_is_json "$file"; then
        jq -r '.meta.storage_type // empty' "$file" 2>/dev/null
    else
        grep -m1 '^storage_type[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//'
    fi
}
_get_bp_version() {
    local file="$1"
    if _bp_is_json "$file"; then
        jq -r '.meta.version // empty' "$file" 2>/dev/null
    else
        grep -m1 '^version[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//'
    fi
}

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


# ── Package manifest & updates ────────────────────────────────────
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

# ── Ubuntu base update for installed containers ───────────────────
# Returns stamp date (for update comparison)
_ct_ubuntu_stamp() { cat "${1}/.sd_ubuntu_stamp" 2>/dev/null; }

# Returns human-readable Ubuntu version from chroot os-release
_ct_ubuntu_ver() {
    local p="$1"
    grep -m1 '^VERSION_ID=' "${p}/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"'
}

# Adds Ubuntu update entry to _UPD_ITEMS for any installed container when Ubuntu base is ready
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

# ── Install completion watcher ────────────────────────────────────
_installing_menu() {
    local cid="$1" header="$2"; shift 2
    local ok_file="$CONTAINERS_DIR/$cid/.install_ok"
    local fail_file="$CONTAINERS_DIR/$cid/.install_fail"
    local lines=()
    for x in "$@"; do
        printf '%s' "$x" | grep -q $'\033' && lines+=("$x") || lines+=("$(printf "${DIM} %s${NC}" "$x")")
    done
    local _nav; _nav="$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"
    lines+=("$_nav" "$(printf "${DIM} %s${NC}" "${L[back]}")")
    local _fzf_out; _fzf_out=$(mktemp "$TMP_DIR/.sd_fzfout_XXXXXX")
    local _wflag;   _wflag=$(mktemp -u "$TMP_DIR/.sd_wflag_XXXXXX")
    local _wpid=""
    printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$header" >"$_fzf_out" 2>/dev/null &
    local _fzf_pid=$!
    if [[ ! -f "$ok_file" && ! -f "$fail_file" ]]; then
        { while [[ ! -f "$ok_file" && ! -f "$fail_file" ]]; do sleep 0.3; done
          touch "$_wflag"; kill "$_fzf_pid" 2>/dev/null
        } &
        _wpid=$!
    fi
    wait "$_fzf_pid" 2>/dev/null
    [[ -n "$_wpid" ]] && { kill "$_wpid" 2>/dev/null; wait "$_wpid" 2>/dev/null; }
    if [[ -f "$_wflag" ]]; then
        rm -f "$_wflag" "$_fzf_out"
        stty sane 2>/dev/null
        return 2
    fi
    REPLY=$(cat "$_fzf_out" 2>/dev/null | _trim_s)
    rm -f "$_fzf_out"
    [[ -z "$REPLY" || "$REPLY" == "${L[back]}" ]] && return 1
    return 0
}

_process_install_finish() {
    local cid="$1" name; name=$(_cname "$cid")
    local ok_file="$CONTAINERS_DIR/$cid/.install_ok"
    local fail_file="$CONTAINERS_DIR/$cid/.install_fail"
    tmux kill-session -t "$(_inst_sess "$cid")" 2>/dev/null || true; _tmux_set SD_INSTALLING ""
    if [[ -f "$ok_file" ]]; then
        # Stale if ok_file is older than 10 minutes and tmux session is gone
        local _ok_age; _ok_age=$(( $(date +%s) - $(date -r "$ok_file" +%s 2>/dev/null || echo 0) ))
        if [[ "$_ok_age" -gt 600 ]] && ! tmux_up "$(_inst_sess "$cid")"; then
            rm -f "$ok_file"; pause "⚠  Installation result is stale. Please reinstall."; return
        fi
        rm -f "$ok_file"
        # Pkg update: container already installed — just update manifest + show done
        if [[ "$(_st "$cid" installed)" == "true" ]]; then
            _write_pkg_manifest "$cid"
            pause "$(printf "'%s' packages updated." "$name")"
            return
        fi
        # Fresh install
        _set_st "$cid" installed true
        _write_pkg_manifest "$cid"
        local _ipath; _ipath=$(_cpath "$cid")
        [[ -n "$_ipath" && -f "$UBUNTU_DIR/.sd_ubuntu_stamp" ]] && cp "$UBUNTU_DIR/.sd_ubuntu_stamp" "$_ipath/.sd_ubuntu_stamp" 2>/dev/null || true
        if confirm "$(printf "'%s' ${L[msg_install_ok]}\n\nCreate a Post-Install backup?\n  (Instant revert to clean install)" "$name")"; then
            local _pi_sdir; _pi_sdir=$(_snap_dir "$cid"); mkdir -p "$_pi_sdir" 2>/dev/null
            local _pi_id="Post-Installation" _pi_path; _pi_path=$(_cpath "$cid")
            local _pi_ts; _pi_ts=$(date '+%Y-%m-%d %H:%M')
            [[ -d "$_pi_sdir/$_pi_id" ]] && _delete_backup "$_pi_sdir" "$_pi_id"
            if btrfs subvolume snapshot -r "$_pi_path" "$_pi_sdir/$_pi_id" &>/dev/null; then
                _snap_meta_set "$_pi_sdir" "$_pi_id" "type=manual" "ts=$_pi_ts"
                pause "$(printf "Backup 'Post-Installation' created for '%s'." "$name")"
            else
                cp -a "$_pi_path" "$_pi_sdir/$_pi_id" 2>/dev/null \
                    && _snap_meta_set "$_pi_sdir" "$_pi_id" "type=manual" "ts=$_pi_ts" \
                    && pause "$(printf "Backup 'Post-Installation' created for '%s'." "$name")" \
                    || pause "$(printf "Backup failed for '%s' — disk full?" "$name")"
            fi
        else
            pause "'$name' ${L[msg_install_ok]}"
        fi
    elif [[ -f "$fail_file" ]]; then
        rm -f "$fail_file"; pause "${L[msg_install_fail]}"
    fi
    _update_size_cache "$cid"
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

# ── Open in submenu ───────────────────────────────────────────────
_open_in_submenu() {
    local cid="$1"; local name; name=$(_cname "$cid")
    local is_running=false; tmux_up "$(tsess "$cid")" && is_running=true
    local sj="$CONTAINERS_DIR/$cid/service.json"
    local svc_port; svc_port=$(jq -r '.meta.port // 0' "$sj" 2>/dev/null); svc_port="${svc_port:-0}"
    local env_port; env_port=$(jq -r '.environment.PORT // empty' "$sj" 2>/dev/null)
    [[ -n "$env_port" ]] && svc_port="$env_port"
    local install_path; install_path=$(_cpath "$cid")

    # Prefer proxy URL over localhost:port if a route exists for this container
    _open_in_best_url() {
        local _cid="$1" _port="$2"
        local _route_url _https
        _route_url=$(jq -r --arg c "$_cid" '.routes[] | select(.cid==$c) | .url' "$(_proxy_cfg)" 2>/dev/null | head -1)
        if [[ -n "$_route_url" ]]; then
            _https=$(jq -r --arg c "$_cid" '.routes[] | select(.cid==$c) | (.https // "false")' "$(_proxy_cfg)" 2>/dev/null | head -1)
            [[ "$_https" == "true" ]] && printf 'https://%s' "$_route_url" || printf 'http://%s' "$_route_url"
        else
            printf 'http://localhost:%s' "$_port"
        fi
    }

    while true; do
        local opts=()
        [[ "$svc_port" != "0" && -n "$svc_port" ]] && opts+=("⊕  Browser")
        [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && _chroot_bash "$UBUNTU_DIR" -c 'command -v qrencode' >/dev/null 2>&1 \
            && [[ "$svc_port" != "0" && -n "$svc_port" ]] && opts+=("⊞  Show QR code")
        opts+=("◧  File manager" "◉  Terminal")
        _menu "$(printf "Open in — %s" "$name")" "${opts[@]}"
        case $? in 2) continue ;; 0) ;; *) return ;; esac
        case "$REPLY" in
            *"Browser"*)
                [[ "$is_running" == "false" ]] && { pause "Please start the container first."; continue; }
                _sd_open_url "$(_open_in_best_url "$cid" "$svc_port")" >/dev/null 2>&1
                return ;;
            *"QR code"*)
                [[ "$is_running" == "false" ]] && { pause "Please start the container first."; continue; }
                local _qr_exp; _qr_exp=$(_exposure_get "$cid")
                if [[ "$_qr_exp" != "public" ]]; then
                    pause "$(printf "Exposure is %b — QR code requires public.\n\n  Set this container to public in Reverse Proxy → Port exposure." "$(_exposure_label "$_qr_exp")")"
                    continue
                fi
                local _qr_url="http://${cid}.local"
                local _qr_render; _qr_render=$(_chroot_bash "$UBUNTU_DIR" -c "qrencode -t UTF8 -o - '$_qr_url'" 2>/dev/null)
                printf '%s

  %s
' "$_qr_render" "$_qr_url"                     | _fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── QR Code ──${NC}
${DIM}  Scan to open on any LAN device (mDNS)${NC}")"                           --no-multi --disabled >/dev/null 2>&1 || true ;;
                        *"File manager"*)
                local open_path="${install_path:-$INSTALLATIONS_DIR}"
                [[ -z "$open_path" ]] && { pause "No install path found."; continue; }
                xdg-open "$open_path" 2>/dev/null & disown 2>/dev/null || true ;;
            *"Terminal"*)
                local tsess_term="sdTerm_${cid}"
                local tip; tip=$(_cpath "$cid"); [[ -z "$tip" ]] && tip="$HOME"
                if ! tmux has-session -t "$tsess_term" 2>/dev/null; then
                    tmux new-session -d -s "$tsess_term" "cd $(printf '%q' "$tip") && exec bash" 2>/dev/null
                    tmux set-option -t "$tsess_term" detach-on-destroy off 2>/dev/null || true
                fi
                pause "$(printf "Opening terminal for '%s'\n\n  %s\n  Press %s to detach." "$name" "$tip" "${KB[tmux_detach]}")"
                tmux switch-client -t "$tsess_term" 2>/dev/null || true ;;
        esac
    done
}

# ── Create container ──────────────────────────────────────────────
_create_container() {
    local bname="$1" bfile="${2:-}"
    [[ -z "$bfile" ]] && bfile=$(_bp_path "$bname")
    local is_tmpfile=false
    if [[ -z "$bfile" || ! -f "$bfile" ]]; then
        local raw; raw=$(_get_persistent_bp "$bname"); [[ -z "$raw" ]] && { pause "Could not read blueprint '$bname'."; return 1; }
        bfile=$(mktemp "$TMP_DIR/.sd_pbp_XXXXXX.toml")
        printf '%s\n' "$raw" > "$bfile"; is_tmpfile=true
    fi
    _guard_space || { [[ "$is_tmpfile" == true ]] && rm -f "$bfile"; return 1; }

    # Pre-validate before asking for a name — fail fast on bad blueprints
    if ! _bp_is_json "$bfile"; then
        declare -A _vc_META=(); declare -A _vc_ENV=()
        local _vc_saved_meta _vc_saved_env
        # Save/restore globals around a parse-only run
        BP_META=() BP_ENV=() BP_STORAGE="" BP_DEPS="" BP_DIRS=""
        BP_GITHUB="" BP_NPM="" BP_BUILD="" BP_INSTALL="" BP_UPDATE="" BP_START=""
        BP_ACTIONS_NAMES=() BP_ACTIONS_SCRIPTS=() BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()
        if _bp_parse "$bfile"; then
            if ! _bp_validate; then
                local _errmsg; _errmsg=$(printf '%s\n' "${BP_ERRORS[@]}")
                [[ "$is_tmpfile" == true ]] && rm -f "$bfile"
                pause "$(printf '⚠  Blueprint validation failed:\n\n%s\n\n  Edit the blueprint and try again.' "$_errmsg")"
                return 1
            fi
        fi
    fi

    local suggested
    if _bp_is_json "$bfile"; then
        suggested=$(jq -r '.meta.name // empty' "$bfile" 2>/dev/null)
    else
        suggested=$(grep -m1 '^name[[:space:]]*=' "$bfile" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//')
    fi
    [[ -z "$suggested" ]] && suggested="$bname"

    local ct_name
    while true; do
        if ! finput "Container name (default: $suggested):"; then
            [[ "$is_tmpfile" == true ]] && rm -f "$bfile"; return 1
        fi
        ct_name="${FINPUT_RESULT//[^a-zA-Z0-9_\-]/}"
        [[ -z "$ct_name" ]] && ct_name="${suggested//[^a-zA-Z0-9_\-]/}"

        local dup=false
        for d in "$CONTAINERS_DIR"/*/; do
            [[ -f "$d/state.json" ]] || continue
            [[ "$(jq -r '.name // empty' "$d/state.json" 2>/dev/null)" == "$ct_name" ]] && dup=true && break
        done
        if [[ "$dup" == "true" ]]; then [[ "$is_tmpfile" == true ]] && rm -f "$bfile"; pause "A container named '$ct_name' already exists."; return 1; fi

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n%s\n' "$(printf "${GRN}▶  Continue${NC}")" "$(printf "${DIM}   Change name${NC}")" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Container name ──${NC}")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local name_choice; name_choice=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 ]] && return
        local name_choice_clean; name_choice_clean=$(printf '%s' "$name_choice" | _trim_s)
        [[ "$name_choice_clean" == *"Change name"* ]] && continue
        break
    done

    local cid; cid=$(_rand_id)
    mkdir -p "$CONTAINERS_DIR/$cid" 2>/dev/null
    jq -n --arg id "$cid" --arg n "$ct_name" --arg ip "$ct_name" \
        '{id:$id,name:$n,install_path:$ip,installed:false,hidden:false,trash:false}' \
        > "$CONTAINERS_DIR/$cid/state.json"
    cp "$bfile" "$CONTAINERS_DIR/$cid/service.src"
    [[ "$is_tmpfile" == true ]] && rm -f "$bfile"
    _compile_service "$cid" || { pause "Failed to compile blueprint."; return 1; }
    pause "Container '$ct_name' created. Select it to install."
}


# ── Shared container edit/rename helpers ─────────────────────────
_edit_container_bp() {
    local cid="$1"
    local src="$CONTAINERS_DIR/$cid/service.src"
    local _erun=false _einst=false
    tmux_up "$(tsess "$cid")" && _erun=true
    _is_installing "$cid"    && _einst=true
    [[ "$_erun" == "true" || "$_einst" == "true" ]] && { pause "⚠  Stop the container before editing."; return 1; }
    _guard_space || return 1; _ensure_src "$cid"
    ${EDITOR:-vi} "$src"
    if ! _bp_is_json "$src"; then
        BP_META=() BP_ENV=() BP_STORAGE="" BP_DEPS="" BP_DIRS=""
        BP_GITHUB="" BP_NPM="" BP_BUILD="" BP_INSTALL="" BP_UPDATE="" BP_START=""
        BP_ACTIONS_NAMES=() BP_ACTIONS_SCRIPTS=() BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()
        _bp_parse "$src" 2>/dev/null
        if ! _bp_validate; then
            local _ee; _ee=$(printf '%s\n' "${BP_ERRORS[@]}")
            pause "$(printf '⚠  Blueprint has errors (not saved):\n\n%s\n\n  Re-open editor to fix.' "$_ee")"
            return 1
        fi
    fi
    _compile_service "$cid" && [[ "$(_st "$cid" installed)" == "true" ]] && _build_start_script "$cid" 2>/dev/null || true
}

_rename_container() {
    local cid="$1" name; name=$(_cname "$cid")
    [[ "$(_st "$cid" installed)" == "true" ]] && { pause "Rename is only available for uninstalled containers."; return 1; }
    while true; do
        finput "New name for '$name':" || return 1
        local new_ct_name; new_ct_name="${FINPUT_RESULT//[^a-zA-Z0-9_\-]/}"
        [[ -z "$new_ct_name" ]] && { pause "Name cannot be empty."; continue; }
        local dup_found=false
        for dd in "$CONTAINERS_DIR"/*/; do
            [[ -f "$dd/state.json" ]] || continue
            local en; en=$(jq -r '.name // empty' "$dd/state.json" 2>/dev/null)
            [[ "$en" == "$new_ct_name" && "$(basename "$dd")" != "$cid" ]] && dup_found=true && break
        done
        [[ "$dup_found" == "true" ]] && { pause "A container named '$new_ct_name' already exists."; continue; }
        jq --arg n "$new_ct_name" '.name=$n' "$CONTAINERS_DIR/$cid/state.json" \
            > "$CONTAINERS_DIR/$cid/state.json.tmp" \
            && mv "$CONTAINERS_DIR/$cid/state.json.tmp" "$CONTAINERS_DIR/$cid/state.json" 2>/dev/null
        pause "Container renamed to '$new_ct_name'."; return 0
    done
}

# ── Container submenu ─────────────────────────────────────────────
_container_submenu() {
    local cid="$1"
    while true; do
        clear; _cleanup_stale_lock
        local name; name=$(_cname "$cid"); [[ -z "$name" ]] && name="(unnamed-$cid)"
        local installed; installed=$(_st "$cid" installed)
        local is_running=false; tmux_up "$(tsess "$cid")" && is_running=true
        local is_installing=false; _is_installing "$cid" && is_installing=true
        local ok_file="$CONTAINERS_DIR/$cid/.install_ok"
        local fail_file="$CONTAINERS_DIR/$cid/.install_fail"
        local install_done=false; [[ -f "$ok_file" || -f "$fail_file" ]] && install_done=true

        local svc_port; svc_port=$(jq -r '.meta.port // 0' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null); svc_port="${svc_port:-0}"
        local env_port; env_port=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        [[ -n "$env_port" ]] && svc_port="$env_port"

        local action_labels=() action_dsls=()
        local cron_names=() cron_intervals=() cron_idxs=()
        if [[ "$installed" == "true" && "$is_installing" == "false" ]]; then
            local sj="$CONTAINERS_DIR/$cid/service.json"
            local act_count; act_count=$(jq -r '.actions | length' "$sj" 2>/dev/null)
            if [[ -n "$act_count" && "$act_count" -gt 0 ]]; then
                for (( ai=0; ai<act_count; ai++ )); do
                    local lbl; lbl=$(jq -r --argjson i "$ai" '.actions[$i].label // empty' "$sj" 2>/dev/null)
                    # Support both new .dsl and legacy .script field
                    local dsl; dsl=$(jq -r --argjson i "$ai" '.actions[$i].dsl // .actions[$i].script // empty' "$sj" 2>/dev/null)
                    [[ -z "$lbl" ]] && continue
                    # Skip "Open browser" — user opens via Open in → Browser
                    [[ "${lbl,,}" == "open browser" ]] && continue
                    # Auto-prepend a run icon if the label doesn't already start with a non-ASCII symbol
                    local _first_char; _first_char=$(printf '%s' "$lbl" | cut -c1)
                    if [[ "$_first_char" =~ ^[a-zA-Z0-9]$ ]]; then
                        lbl="⊙  $lbl"
                    fi
                    action_labels+=("$lbl"); action_dsls+=("$dsl")
                done
            fi
            local cron_count; cron_count=$(jq -r '.crons | length' "$sj" 2>/dev/null)
            if [[ -n "$cron_count" && "$cron_count" -gt 0 ]]; then
                for (( ci=0; ci<cron_count; ci++ )); do
                    local cn; cn=$(jq -r --argjson i "$ci" '.crons[$i].name // empty' "$sj" 2>/dev/null)
                    local civ; civ=$(jq -r --argjson i "$ci" '.crons[$i].interval // empty' "$sj" 2>/dev/null)
                    [[ -z "$cn" ]] && continue
                    cron_names+=("$cn"); cron_intervals+=("$civ"); cron_idxs+=("$ci")
                done
            fi
        fi

        local SEP_GEN SEP_ACT SEP_CRON SEP_MGT
        SEP_GEN="$(printf "${BLD}  ── General ──────────────────────────${NC}")"
        SEP_ACT="$(printf "${BLD}  ── Actions ──────────────────────────${NC}")"
        SEP_CRON="$(printf "${BLD}  ── Cron ─────────────────────────────${NC}")"
        SEP_MGT="$(printf "${BLD}  ── Management ───────────────────────${NC}")"
        local items=("$SEP_GEN")

        local _UPD_FILES=() _UPD_NAMES=() _UPD_VERS=() _UPD_SRCS=() _UPD_ISTMP=()
        local _UPD_ITEMS=() _UPD_IDX=()
        [[ "$is_installing" == "false" && "$is_running" == "false" ]] && {
            _build_update_items "$cid"
            [[ "$installed" == "true" ]] && _build_ubuntu_update_item "$cid"
            [[ "$installed" == "true" ]] && _build_pkg_update_item "$cid"
        }

        if [[ "$is_installing" == "true" || "$install_done" == "true" ]]; then
            if [[ "$install_done" == "true" ]]; then
                local _fin_lbl="${L[ct_finish_inst]}"
                [[ "$installed" == "true" ]] && _fin_lbl="✓  Finish update"
                items+=("$_fin_lbl")
            else
                items+=("${L[ct_attach_inst]}")
            fi
        elif [[ "$is_running" == "true" ]]; then
            items+=("${L[ct_stop]}" "${L[ct_restart]}" "${L[ct_attach]}" "${L[ct_open_in]}" "${L[ct_log]}")
            [[ "${#action_labels[@]}" -gt 0 ]] && items+=("$SEP_ACT" "${action_labels[@]}")
            # Cron section — show static interval from blueprint declaration
            if [[ "${#cron_names[@]}" -gt 0 ]]; then
                items+=("$SEP_CRON")
                for ci in "${!cron_names[@]}"; do
                    local _cidx="${cron_idxs[$ci]}"
                    local _csess; _csess=$(_cron_sess "$cid" "$_cidx")
                    if tmux_up "$_csess"; then
                        items+=("$(printf " ${CYN}⏱${NC}  ${DIM}%s  ${CYN}[%s]${NC}" "${cron_names[$ci]}" "${cron_intervals[$ci]}")")
                    else
                        items+=("$(printf " ${DIM}⏱  %s  [stopped]${NC}" "${cron_names[$ci]}")")
                    fi
                done
            fi
        elif [[ "$installed" == "true" ]]; then
            local SEP_STO SEP_DNG
            SEP_STO="$(printf "${BLD}  ── Storage ───────────────────────────${NC}")"
            SEP_DNG="$(printf "${BLD}  ── Caution ───────────────────────────${NC}")"
            items+=("${L[ct_start]}" "${L[ct_open_in]}")
            items+=("$SEP_STO" "${L[ct_backups]}" "${L[ct_profiles]}")
            items+=("${L[ct_edit]}")
            # Count actually pending updates
            local _pending_upd=0
            for _ui_e in "${_UPD_ITEMS[@]}"; do
                printf '%s' "$_ui_e" | _strip_ansi | grep -qE 'Changes detected|→' && (( _pending_upd++ )) || true
            done
            local _upd_lbl=""
            if [[ "${#_UPD_ITEMS[@]}" -gt 0 ]]; then
                if [[ "$_pending_upd" -gt 0 ]]; then
                    _upd_lbl="$(printf " ${YLW}⬆  Updates${NC}")"
                else
                    _upd_lbl="⬆  Updates"
                fi
            fi
            items+=("$SEP_DNG")
            [[ -n "$_upd_lbl" ]] && items+=("$_upd_lbl")
            items+=("${L[ct_uninstall]}")
        else
            local SEP_DNG2; SEP_DNG2="$(printf "${BLD}  ── Caution ───────────────────────────${NC}")"
            items+=("${L[ct_install]}" "${L[ct_edit]}" "${L[ct_rename]}")
            items+=("$SEP_DNG2" "${L[ct_remove]}")
        fi

        local hdr_dot
        if   [[ "$is_installing" == "true" || "$install_done" == "true" ]]; then hdr_dot="${YLW}◈${NC}"
        elif [[ "$is_running" == "true" ]]; then
            if _health_check "$cid"; then hdr_dot="${GRN}◈${NC}"
            else hdr_dot="${YLW}◈${NC}"; fi
        elif [[ "$installed" == "true" ]]; then hdr_dot="${RED}◈${NC}"
        else hdr_dot="${DIM}◈${NC}"; fi
        local _ct_dlg; _ct_dlg=$(jq -r '.meta.dialogue // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local _hdr
        if [[ -n "$_ct_dlg" ]]; then
            _hdr="$(printf "%b  %s  ${DIM}— %s${NC}" "$hdr_dot" "$name" "$_ct_dlg")"
        else
            _hdr="$(printf "%b  %s" "$hdr_dot" "$name")"
        fi
        if [[ "$svc_port" != "0" && -n "$svc_port" ]]; then
            local _hdr_ip; _hdr_ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
            _hdr+="$(printf "  ${DIM}%s:%s${NC}" "$_hdr_ip" "$svc_port")"
        fi

        if [[ "$is_installing" == "true" || "$install_done" == "true" ]]; then
            _installing_menu "$cid" "$_hdr" "${items[@]}"
            case $? in 1) _cleanup_upd_tmps; return ;; 2) continue ;; esac
        else
            _menu "$_hdr" "${items[@]}"
            local _mrc=$?
            case $_mrc in 2) continue ;; 0) ;; *) _cleanup_upd_tmps; return ;; esac
        fi

        case "$REPLY" in
            "${L[ct_attach_inst]}") _tmux_attach_hint "installation" "$(_inst_sess "$cid")"; _cleanup_stale_lock ;;
            "${L[ct_finish_inst]}"|"✓  Finish update") _process_install_finish "$cid" ;;
            "${L[ct_install]}")
                _guard_install || continue
                _run_job install "$cid"; _cleanup_upd_tmps ;;
            "${L[ct_start]}")       _start_container "$cid"; _cleanup_upd_tmps ;;
            "${L[ct_attach]}")      _tmux_attach_hint "$name" "$(tsess "$cid")" ;;
            "${L[ct_stop]}")        confirm "Stop '$name'?" || continue; _stop_container "$cid" ;;
            "${L[ct_restart]}")     _stop_container "$cid"; sleep 0.3; _start_container "$cid" ;;
            "${L[ct_open_in]}")     _open_in_submenu "$cid" ;;
            *"⏱"*)
                # Cron entry clicked — match by name and attach to its session
                local _cron_clicked; _cron_clicked=$(printf '%s' "$REPLY" | _strip_ansi | sed 's/^[[:space:]]*//' | grep -oP '(?<=⏱  )[^\[]+' | sed 's/[[:space:]]*$//')
                local _ci
                for _ci in "${!cron_names[@]}"; do
                    if [[ "${cron_names[$_ci]}" == "$_cron_clicked" ]]; then
                        local _csess; _csess=$(_cron_sess "$cid" "${cron_idxs[$_ci]}")
                        if tmux_up "$_csess"; then
                            _tmux_attach_hint "cron: ${cron_names[$_ci]}" "$_csess"
                        else
                            pause "Cron '${cron_names[$_ci]}' is not running."
                        fi
                        break
                    fi
                done ;;
            *"⬤  Exposure"*)
                local _new_mode; _new_mode=$(_exposure_next "$cid")
                _exposure_set "$cid" "$_new_mode"
                _exposure_apply "$cid"
                pause "$(printf "Port exposure set to: %b" "$(_exposure_label "$_new_mode")")" ;;
            "${L[ct_log]}")
                local _meta_log; _meta_log=$(jq -r '.meta.log // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
                local _lf
                if [[ -n "$_meta_log" ]]; then
                    _lf="$(_cpath "$cid")/$_meta_log"
                else
                    _lf=$(_log_path "$cid" "start")
                fi
                if [[ -f "$_lf" ]]; then
                    pause "$(tail -100 "$_lf" 2>/dev/null | cat)"
                else
                    pause "No log yet for '$name'."
                fi ;;
            "${L[ct_edit]}")  _edit_container_bp "$cid" || continue ;;
            "${L[ct_rename]}")  _rename_container "$cid" ;;
            "${L[ct_backups]}")  _container_backups_menu "$cid" ;;
            "${L[ct_profiles]}") _stor_ctx_cid="$cid"; _persistent_storage_menu "$cid"; _stor_ctx_cid="" ;;
            *"Clone container"*) _clone_container "$cid" ;;
            "⚙  Management"*) ;; # no-op, replaced by inline section
            "◦  Edit blueprint"|"${L[ct_edit]}"*)  _edit_container_bp "$cid" || continue ;;
            *"Installation"*) ;; # no-op, flattened
            "${L[ct_uninstall]}")
                local ip; ip=$(_cpath "$cid")
                confirm "$(printf "Uninstall '%s'?\n\n  ✕  Installation subvolume: %s\n  ✕  Snapshots\n\n  Persistent storage is kept.\n  Container entry stays — select Install to reinstall." "$name" "$ip")" || continue
                [[ -d "$ip" ]] && { sudo -n btrfs subvolume delete "$ip" &>/dev/null || btrfs subvolume delete "$ip" &>/dev/null || sudo -n rm -rf "$ip" 2>/dev/null || rm -rf "$ip" 2>/dev/null || true; }
                local sdir2; sdir2=$(_snap_dir "$cid")
                if [[ -d "$sdir2" ]]; then
                    for _sf in "$sdir2"/*/; do [[ -d "$_sf" ]] && _delete_snap "$_sf" || true; done
                    rm -rf "$sdir2" 2>/dev/null || true
                fi
                _set_st "$cid" installed false
                pause "'$name' uninstalled. Persistent storage kept." ;;
            "${L[ct_update]}")   _guard_install || continue; _run_job update "$cid" ;;
            "${L[ct_exposure]}"*)
                local _new_exp; _new_exp=$(_exposure_next "$cid")
                _exposure_set "$cid" "$_new_exp"
                tmux_up "$(tsess "$cid")" && _exposure_apply "$cid"
                pause "$(printf "Port exposure set to: %b\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network" "$(_exposure_label "$_new_exp")")" ;;
            "${L[ct_remove]}")
                confirm "$(printf "Remove container entry '%s'?\n\n  No installation or storage files deleted." "$name")" || continue
                rm -f "$CACHE_DIR/sd_size/$cid" "$CACHE_DIR/gh_tag/$cid" "$CACHE_DIR/gh_tag/$cid.inst" 2>/dev/null || true
                rm -rf "$CONTAINERS_DIR/$cid" 2>/dev/null
                _cleanup_upd_tmps; pause "'$name' removed."; return ;;
            *"⬆  Updates"*)
                [[ "${#_UPD_ITEMS[@]}" -eq 0 ]] && continue
                # Build submenu with the update items
                local _upd_menu_items=()
                for _umi in "${_UPD_ITEMS[@]}"; do _upd_menu_items+=("$_umi"); done
                _menu "Update — $name" "${_upd_menu_items[@]}" || continue
                local _upd_reply_clean; _upd_reply_clean=$(printf '%s' "$REPLY" | _trim_s)
                for ui in "${!_UPD_ITEMS[@]}"; do
                    local _ic; _ic=$(printf '%s' "${_UPD_ITEMS[$ui]}" | _trim_s)
                    if [[ "$_upd_reply_clean" == "$_ic" ]]; then
                        if [[ "${_UPD_IDX[$ui]}" == "__ubuntu__" ]]; then
                            _do_ubuntu_update "$cid"; continue 2
                        elif [[ "${_UPD_IDX[$ui]}" == "__pkgs__" ]]; then
                            _do_pkg_update "$cid"; continue 2
                        else
                            _do_blueprint_update "$cid" "${_UPD_IDX[$ui]}"; continue 2
                        fi
                    fi
                done ;;
            *)
                local _reply_clean; _reply_clean=$(printf '%s' "$REPLY" | _trim_s)
                for ui in "${!_UPD_ITEMS[@]}"; do
                    local _ic; _ic=$(printf '%s' "${_UPD_ITEMS[$ui]}" | _trim_s)
                    if [[ "$_reply_clean" == "$_ic" ]]; then
                        if [[ "${_UPD_IDX[$ui]}" == "__ubuntu__" ]]; then
                            _do_ubuntu_update "$cid"; continue 2
                        elif [[ "${_UPD_IDX[$ui]}" == "__pkgs__" ]]; then
                            _do_pkg_update "$cid"; continue 2
                        else
                            _do_blueprint_update "$cid" "${_UPD_IDX[$ui]}"; continue 2
                        fi
                    fi
                done
                printf '%s' "$REPLY" | grep -q '^──' && continue
                for ai in "${!action_labels[@]}"; do
                    [[ "$REPLY" != "${action_labels[$ai]}" ]] && continue
                    local ip; ip=$(_cpath "$cid")
                    local dsl="${action_dsls[$ai]}"
                    local arunner; arunner=$(mktemp "$TMP_DIR/.sd_action_XXXXXX.sh")
                    local sname="sdAction_${cid}_${ai}"
                    {
                        printf '#!/usr/bin/env bash\n'
                        _env_exports "$cid" "$ip"
                        printf 'cd "$CONTAINER_ROOT"\n'

                        # Determine if this is new DSL (contains |) or legacy bash block
                        if printf '%s' "$dsl" | grep -q '|'; then
                            # ── DSL action: parse pipe-separated segments ──
                            # Segments:
                            #   prompt: "text"          → read input, bind to {input}
                            #   select: cmd [--col N] [--skip-header]  → fzf pick, bind to {selection}
                            #   bare cmd [with {input} or {selection}] → execute
                            local _input_var="" _select_var=""
                            local seg_idx=0
                            # Split on | — use printf trick to avoid subshell
                            local IFS_BAK="$IFS"; IFS='|'
                            local segs=()
                            while IFS= read -r seg; do
                                seg=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                                [[ -n "$seg" ]] && segs+=("$seg")
                            done <<< "$(printf '%s' "$dsl" | tr '|' '\n')"
                            IFS="$IFS_BAK"

                            for seg in "${segs[@]}"; do
                                if [[ "$seg" == prompt:* ]]; then
                                    # prompt: "text"
                                    local ptxt; ptxt=$(printf '%s' "$seg" | sed 's/^prompt:[[:space:]]*//' | tr -d '"'"'")
                                    printf 'printf "%s\\n> "; read -r _sd_input\n' "$ptxt"
                                    printf '[[ -z "$_sd_input" ]] && exit 0\n'

                                elif [[ "$seg" == select:* ]]; then
                                    # select: cmd [--skip-header] [--col N]
                                    local scmd; scmd=$(printf '%s' "$seg" | sed 's/^select:[[:space:]]*//')
                                    local skip_hdr=0 col_n=1
                                    [[ "$scmd" == *"--skip-header"* ]] && skip_hdr=1
                                    if [[ "$scmd" =~ --col[[:space:]]+([0-9]+) ]]; then col_n="${BASH_REMATCH[1]}"; fi
                                    scmd=$(printf '%s' "$scmd" | sed 's/--skip-header//g;s/--col[[:space:]]*[0-9]*//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                                    # Auto-prefix relative command path
                                    local scmd_bin="${scmd%% *}" scmd_rest="${scmd#* }"
                                    [[ "$scmd_rest" == "$scmd_bin" ]] && scmd_rest=""
                                    local scmd_bin_p; scmd_bin_p=$(_cr_prefix "$scmd_bin")
                                    local full_scmd="${scmd_bin_p}${scmd_rest:+ $scmd_rest}"
                                    printf '_sd_list=$(%s 2>/dev/null)\n' "$full_scmd"
                                    printf '[[ -z "$_sd_list" ]] && { printf "Nothing found.\\n"; exit 0; }\n'
                                    if [[ $skip_hdr -eq 1 ]]; then
                                        printf '_sd_list=$(printf "%%s" "$_sd_list" | tail -n +2)\n'
                                    fi
                                    printf '_sd_selection=$(printf "%%s\\n" "$_sd_list" | awk '"'"'{print $%d}'"'"' | fzf --ansi --no-sort --prompt="  ❯ " --pointer="▶" --height=40%% --reverse --border=rounded --margin=1,2 --no-info 2>/dev/null) || exit 0\n' "$col_n"
                                    printf '[[ -z "$_sd_selection" ]] && exit 0\n'

                                else
                                    # Bare command — substitute {input} and {selection}
                                    local cmd_out; cmd_out="$seg"
                                    # Auto-prefix relative command
                                    local cmd_bin="${cmd_out%% *}" cmd_rest="${cmd_out#* }"
                                    [[ "$cmd_rest" == "$cmd_bin" ]] && cmd_rest=""
                                    local cmd_bin_p; cmd_bin_p=$(_cr_prefix "$cmd_bin")
                                    cmd_out="${cmd_bin_p}${cmd_rest:+ $cmd_rest}"
                                    # Substitute placeholders
                                    cmd_out=$(printf '%s' "$cmd_out" | sed 's/{input}/$_sd_input/g; s/{selection}/$_sd_selection/g')
                                    printf '%s\n' "$cmd_out"
                                fi
                            done
                        else
                            # ── Legacy bash block ──
                            printf '%s\n' "$dsl"
                        fi
                    } > "$arunner"; chmod +x "$arunner"
                    if tmux has-session -t "$sname" 2>/dev/null; then
                        pause "$(printf "Action '%s' is still running.\n\n  Press %s to detach." "${action_labels[$ai]}" "${KB[tmux_detach]}")"
                        tmux switch-client -t "$sname" 2>/dev/null || true
                    else
                        tmux new-session -d -s "$sname" \
                            "bash $(printf '%q' "$arunner"); rm -f $(printf '%q' "$arunner"); printf '\n\033[0;32m══ Done ══\033[0m\n'; printf 'Press Enter to return...\n'; read -rs _; tmux switch-client -t simpleDocker 2>/dev/null || true; tmux kill-session -t \"$sname\" 2>/dev/null || true" 2>/dev/null
                        tmux set-option -t "$sname" detach-on-destroy off 2>/dev/null || true
                        pause "$(printf "Starting '%s'...\n\n  Press %s to detach." "${action_labels[$ai]}" "${KB[tmux_detach]}")"
                        tmux switch-client -t "$sname" 2>/dev/null || true
                    fi
                    break
                done ;;
        esac
    done
}

# ── Quit ──────────────────────────────────────────────────────────
_quit_all() {
    confirm "Stop all containers and quit?" || return
    _load_containers true
    for cid in "${CT_IDS[@]}"; do
        local sess; sess="$(tsess "$cid")"
        tmux_up "$sess" && { tmux send-keys -t "$sess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$sess" 2>/dev/null || true; }
        # Mark any in-progress install as failed before killing its session
        if _is_installing "$cid" && [[ ! -f "$CONTAINERS_DIR/$cid/.install_ok" && ! -f "$CONTAINERS_DIR/$cid/.install_fail" ]]; then
            touch "$CONTAINERS_DIR/$cid/.install_fail" 2>/dev/null || true
        fi
    done
    tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true; _tmux_set SD_INSTALLING ""
    _unmount_img; clear
    tmux kill-session -t "simpleDocker" 2>/dev/null || true; exit 0
}

_quit_menu() {
    _menu "${L[quit]}" "${L[detach]}" "${L[quit_stop_all]}" || return
    case "$REPLY" in
        "${L[detach]}")        _tmux_set SD_DETACH 1; tmux detach-client 2>/dev/null || true ;;
        "${L[quit_stop_all]}") _quit_all ;;
    esac
}

# ── Active processes ──────────────────────────────────────────────
_active_processes_menu() {
    while true; do
        local gpu_hdr=""
        if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null 2>&1; then
            gpu_hdr=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
                --format=csv,noheader,nounits 2>/dev/null \
                | awk -F, 'NR==1{gsub(/ /,"",$1);gsub(/ /,"",$2);gsub(/ /,"",$3)
                             printf "  ·  GPU:%s%%  VRAM:%s/%s MiB",$1,$2,$3}')
        fi

        mapfile -t _sd_sessions < <(tmux list-sessions -F "#{session_name}" 2>/dev/null \
            | grep -E "^sd_[a-z0-9]{8}$|^sdInst_|^sdResize$|^sdTerm_|^sdAction_|^simpleDocker$")

        local display_lines=() display_sess=()
        local sess
        for sess in "${_sd_sessions[@]}"; do
            local label="" cid="" pid="" cpu="-" mem="-"
            pid=$(tmux list-panes -t "$sess" -F "#{pane_pid}" 2>/dev/null | head -1)
            if [[ -n "$pid" ]]; then
                local _rss=""; read -r cpu _rss _ < <(ps -p "$pid" -o pcpu=,rss=,comm= --no-headers 2>/dev/null)
                while read -r cc cr; do
                    [[ -n "$cc" ]] && cpu=$(awk "BEGIN{printf \"%.1f\",$cpu+$cc}")
                    [[ -n "$cr" ]] && _rss=$(( ${_rss:-0} + cr ))
                done < <(ps --ppid "$pid" -o pcpu=,rss= --no-headers 2>/dev/null)
                [[ -n "$_rss" ]] && mem="$(( _rss / 1024 ))M"
                [[ -n "$cpu"  ]] && cpu="${cpu}%"
            fi
            local stats; stats=$(printf "${DIM}CPU:%-6s RAM:%-6s${NC}" "$cpu" "$mem")
            case "$sess" in
                simpleDocker)   label="simpleDocker  (UI)" ;;
                sdInst_*)       local icid; icid=$(_installing_id)
                                local iname; [[ -n "$icid" ]] && iname=$(_cname "$icid") || iname="unknown"
                                label="Install › $iname" ;;
                sdResize)       label="Resize operation" ;;
                sdTerm_*)       cid="${sess#sdTerm_}"
                                label="Terminal › $(_cname "$cid" 2>/dev/null || printf '%s' "$cid")" ;;
                sdAction_*)     cid=$(printf '%s' "$sess" | sed 's/sdAction_\([a-z0-9]*\)_.*/\1/')
                                local aidx="${sess##*_}"
                                local albl; albl=$(jq -r --argjson i "$aidx" '.actions[$i].label // empty' \
                                    "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
                                label="Action › ${albl:-$aidx}  ($(_cname "$cid" 2>/dev/null || printf '%s' "$cid"))" ;;
                sd_*)           cid="${sess#sd_}"
                                label="$(_cname "$cid" 2>/dev/null || printf '%s' "$cid")" ;;
                *)              label="$sess" ;;
            esac
            display_lines+=("$(printf '  %-36s %s  PID:%-7s\t%s' "$label" "$stats" "${pid:--}" "$sess")"); display_sess+=("$sess")
        done

        [[ ${#display_lines[@]} -eq 0 ]] && { pause "No active processes."; return; }
        local _proc_entries=("${display_lines[@]}") _proc_sess=("${display_sess[@]}")
        display_lines=()
        display_sess=()
        display_lines+=("$(printf "${BLD}  ── Processes ────────────────────────${NC}\t__sep__")"); display_sess+=("__sep__")
        for i in "${!_proc_entries[@]}"; do
            display_lines+=("${_proc_entries[$i]}"); display_sess+=("${_proc_sess[$i]}")
        done
        display_lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}\t__sep__")"); display_sess+=("__sep__")
        display_lines+=("$(printf "${DIM} %s${NC}\t__back__" "${L[back]}")"); display_sess+=("__back__")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${display_lines[@]}" | fzf "${FZF_BASE[@]}" --with-nth=1 --delimiter=$'\t' --header="$(printf "${BLD}── Processes ──${NC}  ${DIM}[%d active]${NC}%s" "${#_proc_entries[@]}" "$gpu_hdr")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel_clean; sel_clean=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel_clean}" ]] && return
        local target_sess
        target_sess=$(printf '%s' "$sel_clean" | awk -F'\t' '{print $2}' | tr -d '[:space:]')
        [[ "$target_sess" == "__back__" || -z "$target_sess" ]] && return

        confirm "Kill '$target_sess'?" || continue
        tmux send-keys -t "$target_sess" C-c "" 2>/dev/null; sleep 0.3
        tmux kill-session -t "$target_sess" 2>/dev/null || true
        pause "Killed."
    done
}


#  ISOLATION — Resources (cgroups) + Reverse proxy (Caddy) + Port exposure

_port_exposure_menu() {
    while true; do
        _load_containers false
        local lines=()
        local SEP_CT; SEP_CT="$(printf "${BLD}  ── Containers ───────────────────────${NC}")"
        lines+=("$SEP_CT")

        local cids=() cnames=()
        for i in "${!CT_IDS[@]}"; do
            local cid="${CT_IDS[$i]}"
            [[ "$(_st "$cid" installed)" != "true" ]] && continue
            local port; port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local ep; ep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            [[ -n "$ep" ]] && port="$ep"
            [[ -z "$port" || "$port" == "0" ]] && continue
            local mode; mode=$(_exposure_get "$cid")
            local name; name="${CT_NAMES[$i]}"
            lines+=("$(printf " %b  %s ${DIM}(%s)${NC}" "$(_exposure_label "$mode")" "$name" "$port")")
            cids+=("$cid"); cnames+=("$name")
        done

        [[ ${#cids[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no installed containers with ports)${NC}")")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local sel; sel=$(printf '%s
' "${lines[@]}"             | _fzf "${FZF_BASE[@]}"                   --header="$(printf "${BLD}── Port Exposure ──${NC}
${DIM}  Enter to cycle: isolated → localhost → public${NC}")"                   2>/dev/null) || return
        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" ]] && return

        for i in "${!cnames[@]}"; do
            [[ "$clean" != *"${cnames[$i]}"* ]] && continue
            local cid="${cids[$i]}"
            local _new; _new=$(_exposure_next "$cid")
            _exposure_set "$cid" "$_new"
            tmux_up "$(tsess "$cid")" && _exposure_apply "$cid"
            pause "$(printf "Port exposure set to: %b\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network" \
                "$(_exposure_label "$_new")")"
            break
        done
    done
}

# ── Resources (cgroups via systemd-run --user --scope) ────────────
_resources_cfg() { printf '%s/resources.json' "$CONTAINERS_DIR/$1"; }
_res_get() { jq -r ".$2 // empty" "$(_resources_cfg "$1")" 2>/dev/null; }
_res_set() {
    local f; f=$(_resources_cfg "$1")
    [[ ! -f "$f" ]] && printf '{}' > "$f"
    local tmp; tmp=$(mktemp); jq --arg k "$2" --arg v "$3" '.[$k]=$v' "$f" > "$tmp" && mv "$tmp" "$f"
}
_res_del() {
    local f; f=$(_resources_cfg "$1"); [[ ! -f "$f" ]] && return
    local tmp; tmp=$(mktemp); jq --arg k "$2" 'del(.[$k])' "$f" > "$tmp" && mv "$tmp" "$f"
}

_resources_menu() {
    _load_containers false
    [[ ${#CT_IDS[@]} -eq 0 ]] && { pause "No containers found."; return; }
    local copts=()
    copts+=("$(printf "${BLD}  ── Containers ───────────────────────${NC}")")
    for ci in "${CT_IDS[@]}"; do
        local rs; rs=""
        [[ "$(jq -r '.enabled // false' "$(_resources_cfg "$ci")" 2>/dev/null)" == "true" ]] \
            && rs="$(printf "  ${GRN}[cgroups on]${NC}")"
        copts+=("$(printf " ${DIM}◈${NC}  %s%b" "$(_cname "$ci")" "$rs")")
    done
    copts+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
    copts+=("$(printf "${DIM} %s${NC}" "${L[back]}")")
    local _fzf_out _fzf_pid _frc
    _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
    printf '%s\n' "${copts[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Resource limits ──${NC}  ${DIM}[%d containers]${NC}" "${#CT_IDS[@]}")" >"$_fzf_out" 2>/dev/null &
    _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
    wait "$_fzf_pid" 2>/dev/null; _frc=$?
    local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
    _sig_rc $_frc && { stty sane 2>/dev/null; return; }
    [[ $_frc -ne 0 || -z "$sel" ]] && return
    local sel_clean; sel_clean=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*//')
    [[ "$sel_clean" == "${L[back]}" || "$sel_clean" == ──* || "$sel_clean" == "── "* ]] && return
    local cid=""; local ci
    local sel_name; sel_name=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*◈[[:space:]]*//' | awk '{print $1}')
    for ci in "${CT_IDS[@]}"; do [[ "$(_cname "$ci")" == "$sel_name" ]] && cid="$ci" && break; done
    [[ -z "$cid" ]] && return
    [[ ! -f "$(_resources_cfg "$cid")" ]] && printf '{"enabled":false}' > "$(_resources_cfg "$cid")"

    while true; do
        local enabled;    enabled=$(   _res_get "$cid" enabled);    enabled="${enabled:-false}"
        local cpu_quota;  cpu_quota=$( _res_get "$cid" cpu_quota);  cpu_quota="${cpu_quota:-(unlimited)}"
        local mem_max;    mem_max=$(   _res_get "$cid" mem_max);     mem_max="${mem_max:-(unlimited)}"
        local mem_swap;   mem_swap=$(  _res_get "$cid" mem_swap);    mem_swap="${mem_swap:-(unlimited)}"
        local cpu_weight; cpu_weight=$(jq -r '.cpu_weight // empty' "$(_resources_cfg "$cid")" 2>/dev/null); cpu_weight="${cpu_weight:-(default 100)}"
        local tog; [[ "$enabled" == "true" ]] && tog="${GRN}● Enabled${NC}" || tog="${RED}○ Disabled${NC}"
        local lines=(
            "$(printf "${BLD}  ── Configuration ────────────────────${NC}")"
            "$(printf ' %b  — toggle cgroups on/off (applies on next start)' "$tog")"
            "$(printf '  CPU quota    %b%s%b  — e.g. 200%% = 2 cores' "$CYN" "$cpu_quota" "$NC")"
            "$(printf '  Memory max   %b%s%b  — e.g. 8G, 512M' "$CYN" "$mem_max" "$NC")"
            "$(printf '  Memory+swap  %b%s%b  — e.g. 10G' "$CYN" "$mem_swap" "$NC")"
            "$(printf '  CPU weight   %b%s%b  — 1-10000, default=100 (relative priority)' "$CYN" "$cpu_weight" "$NC")"
            "$(printf "${BLD}  ── Info ──────────────────────────────${NC}")"
            "$(printf '  %bGPU/VRAM%b     not configurable via cgroups (planned separately)' "$DIM" "$NC")"
            "$(printf '  %bNetwork%b      not configurable via cgroups (planned separately)' "$DIM" "$NC")"
            "$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"
            "$(printf "${DIM} %s${NC}" "${L[back]}")"
        )
        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}── Resources: %s ──${NC}\n${DIM}  Limits apply on container restart via systemd cgroups.${NC}" "$(_cname "$cid")")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel2; sel2=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "$sel2" ]] && return
        local sc; sc=$(printf '%s' "$sel2" | _strip_ansi | sed 's/^[[:space:]]*//')
        case "$sc" in
            *"${L[back]}"*|"") return ;;
            *"toggle"*)
                [[ "$enabled" == "true" ]] && _res_set "$cid" enabled false || _res_set "$cid" enabled true ;;
            *"CPU quota"*)
                finput "CPU quota (e.g. 200% = 2 cores, blank = remove limit):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" cpu_quota || _res_set "$cid" cpu_quota "$FINPUT_RESULT" ;;
            *"Memory max"*)
                finput "Memory max (e.g. 8G, 512M, blank = remove limit):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" mem_max || _res_set "$cid" mem_max "$FINPUT_RESULT" ;;
            *"Memory+swap"*)
                finput "Memory+swap max (e.g. 10G, blank = remove limit):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" mem_swap || _res_set "$cid" mem_swap "$FINPUT_RESULT" ;;
            *"CPU weight"*)
                finput "CPU weight (1-10000, blank = default 100):" || continue
                [[ -z "$FINPUT_RESULT" ]] && _res_del "$cid" cpu_weight || _res_set "$cid" cpu_weight "$FINPUT_RESULT" ;;
        esac
    done
}

# ── Reverse proxy (Caddy) ─────────────────────────────────────────
_proxy_cfg()       { printf '%s/.sd/proxy.json'    "$MNT_DIR"; }
_proxy_caddyfile() { printf '%s/.sd/Caddyfile'     "$MNT_DIR"; }
_proxy_pidfile()   { printf '%s/.sd/.caddy.pid'    "$MNT_DIR"; }
_proxy_caddy_bin()     { printf '%s/.sd/caddy/caddy'       "$MNT_DIR"; }
_proxy_caddy_storage() { printf '%s/.sd/caddy/data'        "$MNT_DIR"; }
_proxy_caddy_runner()  { printf '%s/.sd/caddy/run.sh'      "$MNT_DIR"; }
_proxy_caddy_log()     { printf '%s/.sd/caddy/caddy.log'   "$MNT_DIR"; }
_proxy_get()       { jq -r ".$1 // empty" "$(_proxy_cfg)" 2>/dev/null; }
_proxy_running()   { local p; p=$(cat "$(_proxy_pidfile)" 2>/dev/null); [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }
_proxy_dns_pidfile() { printf '%s/.sd/caddy/dnsmasq.pid'  "$MNT_DIR"; }
_proxy_dns_conf()    { printf '%s/.sd/caddy/dnsmasq.conf' "$MNT_DIR"; }
_proxy_dns_log()     { printf '%s/.sd/caddy/dnsmasq.log'  "$MNT_DIR"; }
_proxy_dns_running() { local p; p=$(cat "$(_proxy_dns_pidfile)" 2>/dev/null); [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

# ── Host-package install tracking (image-scoped flags) ───────────
# Flag files live inside .sd/ so they're tied to the image, not the host.
_hostpkg_flagfile() { printf '%s/.sd/.sd_hostpkg_%s' "$MNT_DIR" "$1"; }
_hostpkg_installed() { [[ -f "$(_hostpkg_flagfile "$1")" ]]; }
_hostpkg_mark()      { touch "$(_hostpkg_flagfile "$1")" 2>/dev/null; }
_hostpkg_unmark()    { rm -f "$(_hostpkg_flagfile "$1")" 2>/dev/null; }

# ── Host apt-get sudoers — write once, passwordless forever ──────
# Grants NOPASSWD for apt-get to the current user so plugin installs
# work in background (no sudo password prompt in the tmux session).
# Called BEFORE _tmux_launch; if the sudoers file isn't present yet
# we run a blocking `sudo` in the terminal here (one-time password entry).
_hostpkg_apt_sudoers_path() { printf '/etc/sudoers.d/simpledocker_apt_%s' "$(id -un)"; }
_hostpkg_ensure_apt_sudoers() { return 0;  # covered by main sudoers written at startup
    _hostpkg_ensure_apt_sudoers_unused() {
    local sudoers_path; sudoers_path="$(_hostpkg_apt_sudoers_path)"
    # Already written — nothing to do
    [[ -f "$sudoers_path" ]] && return 0
    local apt_bin; apt_bin=$(command -v apt-get 2>/dev/null || printf '/usr/bin/apt-get')
    local me; me=$(id -un)
    local sudoers_line; sudoers_line="${me} ALL=(ALL) NOPASSWD: ${apt_bin}"
    # Try passwordless first (e.g. already have broad NOPASSWD)
    if printf '%s\n' "$sudoers_line" | sudo -n tee "$sudoers_path" >/dev/null 2>&1; then
        chmod 0440 "$sudoers_path" 2>/dev/null || sudo -n chmod 0440 "$sudoers_path" 2>/dev/null || true
        return 0
    fi
    # Need password — ask once in the terminal, then write sudoers
    printf '\n\033[1m[simpleDocker] One-time sudo setup for plugin installs.\033[0m\n'
    printf '  This grants passwordless apt-get for your user.\n'
    printf '  You will not be asked again.\n\n'
    if printf '%s\n' "$sudoers_line" | sudo tee "$sudoers_path" >/dev/null 2>&1; then
        sudo chmod 0440 "$sudoers_path" 2>/dev/null || true
        printf '\033[0;32m✓ Done — plugins will now install silently in background.\033[0m\n\n'
        return 0
    fi
    printf '\033[0;33m⚠  Could not write sudoers — plugin installs will prompt for password.\033[0m\n\n'
    return 1   # non-fatal: scripts fall back to plain sudo (works when attached)
    }  # end _hostpkg_ensure_apt_sudoers_unused
}

_avahi_piddir()  { printf '%s/.sd/caddy/avahi' "$MNT_DIR"; }
_avahi_pidfile() { printf '%s/%s.pid' "$(_avahi_piddir)" "$(printf '%s' "$1" | tr './' '__')"; }

_avahi_mdns_name() {
    # Append .local to any URL: comfyui.com → comfyui.com.local, comfyui.sd → comfyui.sd.local
    # Already ends in .local? return as-is
    local url="$1"
    [[ "$url" == *.local ]] && printf '%s' "$url" || printf '%s.local' "$url"
}

_avahi_start() {
    command -v avahi-publish >/dev/null 2>&1 || return 0
    _avahi_stop
    mkdir -p "$(_avahi_piddir)" 2>/dev/null
    local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$lan_ip" ]] && return 0
    local _seen="|"
    # Publish cid.local for every installed container — always, regardless of exposure mode.
    # mDNS is just name resolution; port access is controlled by iptables separately.
    _load_containers false 2>/dev/null || true
    for _acid in "${CT_IDS[@]}"; do
        [[ "$(_st "$_acid" installed)" != "true" ]] && continue
        local _aport; _aport=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$_acid/service.json" 2>/dev/null)
        local _aep; _aep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$_acid/service.json" 2>/dev/null)
        [[ -n "$_aep" ]] && _aport="$_aep"
        [[ -z "$_aport" || "$_aport" == "0" ]] && continue
        local _cid_mdns="${_acid}.local"
        [[ "$_seen" == *"|${_cid_mdns}|"* ]] && continue
        _seen+="|${_cid_mdns}|"
        setsid avahi-publish --address -R "$_cid_mdns" "$lan_ip"             </dev/null >>"$(_proxy_dns_log)" 2>&1 &
        printf '%d' "$!" > "$(_avahi_pidfile "$_cid_mdns")"
    done
    # Also publish route .local aliases for public-exposure routes
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        local url cid
        url=$(printf '%s' "$r" | jq -r '.url')
        cid=$(printf '%s' "$r" | jq -r '.cid')
        [[ "$(_exposure_get "$cid")" != "public" ]] && continue
        local mdns; mdns=$(_avahi_mdns_name "$url")
        [[ "$_seen" == *"|${mdns}|"* ]] && continue
        _seen+="|${mdns}|"
        setsid avahi-publish --address -R "$mdns" "$lan_ip"             </dev/null >>"$(_proxy_dns_log)" 2>&1 &
        printf '%d' "$!" > "$(_avahi_pidfile "$mdns")"
    done < <(jq -c '.routes[]?' "$(_proxy_cfg)" 2>/dev/null)
}

_avahi_stop() {
    local piddir; piddir=$(_avahi_piddir)
    [[ ! -d "$piddir" ]] && return 0
    for pf in "$piddir"/*.pid; do
        [[ -f "$pf" ]] || continue
        local pid; pid=$(cat "$pf" 2>/dev/null)
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        rm -f "$pf"
    done
    pkill -f "avahi-publish.*--address" 2>/dev/null || true
}

_avahi_running() {
    # Consider avahi "running" if avahi-daemon is active (it handles mDNS resolution)
    # The avahi-publish processes only appear for public routes
    command -v avahi-publish >/dev/null 2>&1 || return 1
    systemctl is-active --quiet avahi-daemon 2>/dev/null && return 0
    # Fallback: check for live publish processes
    local piddir; piddir=$(_avahi_piddir)
    [[ ! -d "$piddir" ]] && return 1
    for pf in "$piddir"/*.pid; do
        [[ -f "$pf" ]] || continue
        local pid; pid=$(cat "$pf" 2>/dev/null)
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}


_proxy_dns_write() {
    # Build a dnsmasq config that resolves all proxy hostnames to the LAN IP.
    # Other devices use this host as DNS (set in router DHCP or per-device settings).
    local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$lan_ip" ]] && return 1
    local conf; conf=$(_proxy_dns_conf)
    mkdir -p "$(dirname "$conf")" 2>/dev/null
    # Forward unknown queries upstream; bind only on LAN IP to avoid conflict with systemd-resolved
    local upstream; upstream=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
    [[ -z "$upstream" || "$upstream" == "$lan_ip" || "$upstream" == "127.0.0.53" ]] && upstream="1.1.1.1"
    {
        printf 'listen-address=%s
' "$lan_ip"
        printf 'bind-interfaces
'
        printf 'port=53
'
        printf 'log-facility=%s
' "$(_proxy_dns_log)"
        printf 'server=%s
' "$upstream"
        # One address record per proxy route pointing to this host's LAN IP
        jq -r '.routes[]?.url // empty' "$(_proxy_cfg)" 2>/dev/null | while read -r url; do
            [[ -z "$url" ]] && continue
            printf 'address=/%s/%s
' "$url" "$lan_ip"
        done
    } > "$conf"
}

_proxy_dns_start() {
    command -v dnsmasq >/dev/null 2>&1 || return 0   # dnsmasq not installed — skip silently
    _proxy_dns_write || return 0
    local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$lan_ip" ]] && return 0
    # Stop any old instance
    _proxy_dns_stop
    # dnsmasq needs root to bind port 53; sudoers written by _proxy_ensure_sudoers before this
    setsid sudo -n dnsmasq --conf-file="$(_proxy_dns_conf)" \
        --pid-file="$(_proxy_dns_pidfile)" </dev/null >>"$(_proxy_dns_log)" 2>&1 &
}

_proxy_dns_stop() {
    local pid; pid=$(cat "$(_proxy_dns_pidfile)" 2>/dev/null)
    if [[ -n "$pid" ]]; then
        sudo -n kill "$pid" 2>/dev/null || true
    else
        # Kill any dnsmasq listening on our LAN IP
        local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
        [[ -n "$lan_ip" ]] && sudo -n pkill -f "dnsmasq.*${lan_ip}" 2>/dev/null || true
    fi
    rm -f "$(_proxy_dns_pidfile)" 2>/dev/null || true
}

_proxy_write() {
    # Generate Caddyfile respecting exposure modes:
    #   isolated  — no Caddy stanza (completely blocked)
    #   localhost — stanza bound to 127.0.0.1 only (host browser only)
    #   public    — stanza on all interfaces + LAN_IP:port direct access
    local cf; cf=$(_proxy_caddyfile)
    printf '{\n  admin off\n  local_certs\n}\n\n' > "$cf"
    local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    # Write one Caddy stanza, binding based on exposure mode
    _pw_stanza() {
        local _exp="$1" _scheme="$2" _host="$3" _ct="$4" _p="$5"
        case "$_exp" in
            isolated) return ;;
            localhost|public)
                [[ "$_scheme" == "https" ]]                     && printf 'https://%s {
  tls internal
  reverse_proxy %s:%s
}

' "$_host" "$_ct" "$_p"                     || printf 'http://%s {
  reverse_proxy %s:%s
}

' "$_host" "$_ct" "$_p" ;;
        esac
    }

    local _seen_lan_ports="|"
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        local url cid https port
        url=$(printf '%s' "$r" | jq -r '.url')
        cid=$(printf '%s' "$r" | jq -r '.cid')
        https=$(printf '%s' "$r" | jq -r '.https // "false"')
        port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        local ep; ep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
        [[ -n "$ep" ]] && port="$ep"
        [[ -z "$port" || "$port" == "0" ]] && continue
        local ct_ip; ct_ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
        local exp_mode; exp_mode=$(_exposure_get "$cid")
        local scheme; [[ "$https" == "true" ]] && scheme="https" || scheme="http"
        # Named-URL stanza + its .local alias
        _pw_stanza "$exp_mode" "$scheme" "$url" "$ct_ip" "$port" >> "$cf"
        local mdns_url; mdns_url=$(_avahi_mdns_name "$url")
        [[ "$mdns_url" != "$url" ]] && _pw_stanza "$exp_mode" "$scheme" "$mdns_url" "$ct_ip" "$port" >> "$cf"

    done < <(jq -c '.routes[]?' "$(_proxy_cfg)" 2>/dev/null)

    # Per-container stanzas: cid.local (exposure-aware) + 127.0.0.1:port (localhost browser access)
    local _seen_cid="|"
    _load_containers false 2>/dev/null || true
    for _wcid in "${CT_IDS[@]}"; do
        [[ "$(_st "$_wcid" installed)" != "true" ]] && continue
        local _wport; _wport=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$_wcid/service.json" 2>/dev/null)
        local _wep; _wep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$_wcid/service.json" 2>/dev/null)
        [[ -n "$_wep" ]] && _wport="$_wep"
        [[ -z "$_wport" || "$_wport" == "0" ]] && continue
        [[ "$_seen_cid" == *"|${_wcid}|"* ]] && continue
        _seen_cid+="|${_wcid}|"
        local _wct_ip; _wct_ip=$(_netns_ct_ip "$_wcid" "$MNT_DIR")
        local _wexp; _wexp=$(_exposure_get "$_wcid")
        # cid.local — mDNS hostname routing (exposure-aware)
        _pw_stanza "$_wexp" "http" "${_wcid}.local" "$_wct_ip" "$_wport" >> "$cf"
    done
}

_proxy_update_hosts() {
    # Rewrite /etc/hosts: strip our old entries, re-add current routes if action=add
    local action="${1:-add}"
    local tmp; tmp=$(mktemp)
    grep -v '# simpleDocker' /etc/hosts > "$tmp" 2>/dev/null || cp /etc/hosts "$tmp"
    if [[ "$action" == "add" ]]; then
        # Get LAN IP once for public-exposure routes
        local lan_ip; lan_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
        [[ -z "$lan_ip" ]] && lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        jq -c '.routes[]?' "$(_proxy_cfg)" 2>/dev/null \
            | while IFS= read -r r; do
                [[ -z "$r" ]] && continue
                local url; url=$(printf '%s' "$r" | jq -r '.url')
                local cid; cid=$(printf '%s' "$r" | jq -r '.cid')
                [[ -z "$url" ]] && continue
                local exp_mode; exp_mode=$(_exposure_get "$cid")
                # Use LAN IP for public routes so other devices can reach the URL too
                local host_ip="127.0.0.1"
                [[ "$exp_mode" == "public" && -n "$lan_ip" ]] && host_ip="$lan_ip"
                printf '%s %s  # simpleDocker\n' "$host_ip" "$url"
                # Also add .local alias so the local machine can resolve comfyui.com.local
                local _mdns; _mdns=$(_avahi_mdns_name "$url")
                [[ "$_mdns" != "$url" ]] && printf '%s %s  # simpleDocker\n' "$host_ip" "$_mdns"
                # Also add cid.local so the local machine resolves it (Caddy stanza handles routing)
                printf '127.0.0.1 %s.local  # simpleDocker\n' "$cid"
              done >> "$tmp"
        # Also add hostnames for port-exposure containers (not in routes, but have a .local in Caddyfile)
        _load_containers false 2>/dev/null || true
        for _hcid in "${CT_IDS[@]}"; do
            [[ "$(_st "$_hcid" installed)" != "true" ]] && continue
            local _hport; _hport=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$_hcid/service.json" 2>/dev/null)
            [[ -z "$_hport" || "$_hport" == "0" ]] && continue
            local _hexp; _hexp=$(_exposure_get "$_hcid")
            [[ "$_hexp" == "isolated" ]] && continue
            local _hurl; _hurl="${_hcid}.local"
            local _hip="127.0.0.1"
            [[ "$_hexp" == "public" && -n "$lan_ip" ]] && _hip="$lan_ip"
            printf '%s %s  # simpleDocker\n' "$_hip" "$_hurl"
        done >> "$tmp"
    fi
    sudo -n tee /etc/hosts < "$tmp" >/dev/null 2>/dev/null || true
    rm -f "$tmp"
}

_proxy_sudoers_path() { printf '/etc/sudoers.d/simpledocker_caddy_%s' "$(id -un)"; }

_proxy_ensure_sudoers() {
    # Write a tiny wrapper script that sets CADDY_STORAGE_DIR and execs caddy.
    # We grant sudo to the wrapper — avoids "sudo -n env ..." which sudo rejects
    # because it sees "env" as the target command, not "caddy".
    local bin; bin="$(_proxy_caddy_bin)"
    local dnsmasq_bin; dnsmasq_bin=$(command -v dnsmasq 2>/dev/null || true)
    # Need at least one of caddy or dnsmasq to write sudoers
    [[ ! -x "$bin" && -z "$dnsmasq_bin" ]] && return 1
    local nopasswd_line=""
    if [[ -x "$bin" ]]; then
        local runner; runner="$(_proxy_caddy_runner)"
        local storage; storage="$(_proxy_caddy_storage)"
        printf '#!/bin/bash\nexport CADDY_STORAGE_DIR=%q\nexec %q "$@"\n' "$storage" "$bin" > "$runner"
        chmod +x "$runner"
        nopasswd_line="${runner}, /usr/sbin/update-ca-certificates, /usr/bin/update-ca-certificates"
    fi
    if [[ -n "$dnsmasq_bin" ]]; then
        local pkill_bin; pkill_bin=$(command -v pkill 2>/dev/null || printf '/usr/bin/pkill')
        [[ -n "$nopasswd_line" ]] && nopasswd_line+=", "
        nopasswd_line+="${dnsmasq_bin}, ${pkill_bin}"
    fi
    # Allow starting avahi-daemon without password
    local systemctl_bin; systemctl_bin=$(command -v systemctl 2>/dev/null || true)
    if [[ -n "$systemctl_bin" ]]; then
        [[ -n "$nopasswd_line" ]] && nopasswd_line+=", "
        nopasswd_line+="${systemctl_bin} start avahi-daemon, ${systemctl_bin} enable avahi-daemon"
    fi
    printf '%s ALL=(ALL) NOPASSWD: %s\n' "$(id -un)" "$nopasswd_line" \
        | sudo -n tee "$(_proxy_sudoers_path)" >/dev/null 2>/dev/null || true
}

_proxy_start() {
    # Optional flag: --background = fire and forget (no wait, no trust step blocking caller)
    local _bg=false; [[ "${1:-}" == "--background" ]] && _bg=true

    [[ ! -x "$(_proxy_caddy_bin)" ]] && { printf '[sd] caddy not installed\n' >>"$(_proxy_caddy_log)"; return 1; }
    [[ ! -f "$(_proxy_cfg)" ]] && return 0
    _proxy_write
    _proxy_update_hosts add
    _proxy_ensure_sudoers
    _proxy_dns_start
    # Ensure avahi-daemon is running (needed for mDNS resolution on LAN devices)
    systemctl is-active --quiet avahi-daemon 2>/dev/null \
        || sudo -n systemctl start avahi-daemon 2>/dev/null || true
    _avahi_start
    setsid sudo -n "$(_proxy_caddy_runner)" run --config "$(_proxy_caddyfile)" </dev/null >>"$(_proxy_caddy_log)" 2>&1 &
    printf '%d' "$!" > "$(_proxy_pidfile)"

    if [[ "$_bg" == "true" ]]; then
        # Non-blocking: do trust step async so menu appears instantly
        {
            local _w=0
            while ! _proxy_running && [[ $_w -lt 20 ]]; do sleep 0.3; (( _w++ )); done
            _proxy_trust_ca
        } &>/dev/null &
        return 0
    fi

    sleep 1.2
    if ! _proxy_running; then
        printf '[sd] Caddy failed to start — check "$(_proxy_caddy_log)"\n' >>"$(_proxy_caddy_log)"
        return 1
    fi
    _proxy_trust_ca
}

_proxy_trust_ca() {
    sudo -n chown -R "$(id -u):$(id -g)" "$(_proxy_caddy_storage)" 2>/dev/null || true
    local ca_crt; ca_crt="$(_proxy_caddy_storage)/pki/authorities/local/root.crt"
    local _waited=0
    while [[ ! -f "$ca_crt" && $_waited -lt 10 ]]; do sleep 0.5; (( _waited++ )); done
    sudo -n chown -R "$(id -u):$(id -g)" "$(_proxy_caddy_storage)" 2>/dev/null || true
    [[ ! -f "$ca_crt" ]] && { printf '[sd] Caddy CA cert never appeared\n' >>"$(_proxy_caddy_log)"; return 0; }

    # Install into system CA store — browser-agnostic, works for all browsers
    sudo -n cp "$ca_crt" /usr/local/share/ca-certificates/simpleDocker-caddy.crt 2>/dev/null \
        && sudo -n update-ca-certificates 2>/dev/null \
        && printf '[sd] CA trusted via system store\n' >>"$(_proxy_caddy_log)" \
        || printf '[sd] system CA trust failed (update-ca-certificates not available?)\n' >>"$(_proxy_caddy_log)"

    # Copy CA cert inside the img for reference/portability
    cp "$ca_crt" "$MNT_DIR/.sd/caddy/ca.crt" 2>/dev/null || true
}

_proxy_stop() {
    local pid; pid=$(cat "$(_proxy_pidfile)" 2>/dev/null)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$(_proxy_pidfile)" 2>/dev/null
    _proxy_dns_stop
    _avahi_stop
    [[ -f "$(_proxy_cfg)" ]] && _proxy_update_hosts remove || true
}

_qrencode_menu() {
    while true; do
        if [[ ! -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
            pause "$(printf "QRencode runs inside the Ubuntu base layer.\n\n  Install Ubuntu base first (Other → Ubuntu base).")"; return
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
                    confirm "Uninstall QRencode from Ubuntu?" || continue
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

_proxy_install_caddy() {
    # $1 = "reinstall" for reinstall/update mode, default = fresh install
    local _mode="${1:-install}"
    mkdir -p "$MNT_DIR/.sd/caddy" 2>/dev/null
    local caddy_dest; caddy_dest="$(_proxy_caddy_bin)"

    local log_file="$TMP_DIR/.sd_caddy_log_$$"

    # Ensure passwordless apt-get before launching (asks password once if needed)
    _hostpkg_ensure_apt_sudoers

    local script; script=$(mktemp "$TMP_DIR/.sd_caddy_inst_XXXXXX.sh")
    {
        printf '#!/usr/bin/env bash\n'
        printf 'exec > >(tee -a %q) 2>&1\n' "$log_file"
        printf 'set -uo pipefail\n'
        printf 'die() { printf "\\033[0;31mFAIL: %%s\\033[0m\\n" "$*"; exit 1; }\n'

        # ── Part 1: Caddy binary from GitHub ──────────────────────────
        printf 'printf "\\033[1m── Installing Caddy ──────────────────────────\\033[0m\\n"\n'
        printf 'mkdir -p %q\n' "$MNT_DIR/.sd/caddy"
        printf 'case "$(uname -m)" in\n'
        printf '    x86_64)        ARCH=amd64 ;;\n'
        printf '    aarch64|arm64) ARCH=arm64 ;;\n'
        printf '    armv7l)        ARCH=armv7 ;;\n'
        printf '    *)             ARCH=amd64 ;;\n'
        printf 'esac\n'
        printf 'VER=""\n'
        printf 'printf "Fetching latest Caddy version...\\n"\n'
        printf 'API_RESP=$(curl -fsSL --max-time 15 "https://api.github.com/repos/caddyserver/caddy/releases/latest" 2>&1) && {\n'
        printf '    VER=$(printf "%%s" "$API_RESP" | tr -d "\\n" | grep -o '"'"'"tag_name":"[^"]*"'"'"' | cut -d: -f2 | tr -d '"'"'"v '"'"')\n'
        printf '} || printf "GitHub API unreachable: %%s\\n" "$API_RESP"\n'
        printf '[[ -z "$VER" ]] && {\n'
        printf '    VER=$(curl -fsSL --max-time 15 -o /dev/null -w "%%{url_effective}" \\\n'
        printf '         "https://github.com/caddyserver/caddy/releases/latest" 2>&1 | grep -o "[0-9]*\\.[0-9]*\\.[0-9]*" | head -1)\n'
        printf '}\n'
        printf '[[ -z "$VER" ]] && { printf "Using fallback version 2.9.1\\n"; VER="2.9.1"; }\n'
        printf 'printf "Version: %%s\\n" "$VER"\n'
        printf 'TMPD=$(mktemp -d)\n'
        printf 'URL="https://github.com/caddyserver/caddy/releases/download/v${VER}/caddy_${VER}_linux_${ARCH}.tar.gz"\n'
        printf 'printf "Downloading: %%s\\n" "$URL"\n'
        printf 'curl -fsSL --max-time 120 "$URL" -o "$TMPD/caddy.tar.gz" || die "Download failed"\n'
        printf 'tar -xzf "$TMPD/caddy.tar.gz" -C "$TMPD" caddy   || die "Extraction failed"\n'
        printf '[[ -f "$TMPD/caddy" ]] || die "caddy binary not found after extraction"\n'
        printf 'mv "$TMPD/caddy" %q\n' "$caddy_dest"
        printf 'chmod +x %q\n' "$caddy_dest"
        printf 'rm -rf "$TMPD"\n'
        printf 'printf "\\033[0;32m✓ Caddy binary ready\\033[0m\\n"\n'

        # ── Part 2: Write caddy sudoers (can use sudo -n now that apt sudoers is set) ──
        printf 'printf "%%s ALL=(ALL) NOPASSWD: %%s\\n" "$(id -un)" %q \\\n' "$caddy_dest"
        printf '    | sudo -n tee %q >/dev/null 2>/dev/null || true\n' "$(_proxy_sudoers_path)"

        # ── Part 3: avahi-utils via apt ────────────────────────────────
        printf 'printf "\\033[1m── Installing mDNS (avahi-utils) ─────────────\\033[0m\\n"\n'
        if [[ "$_mode" == "reinstall" ]]; then
            printf 'sudo -n apt-get install --reinstall -y avahi-utils 2>&1\n'
        else
            printf 'sudo -n apt-get install -y avahi-utils 2>&1\n'
        fi
        printf 'printf "\\033[0;32m✓ mDNS ready\\033[0m\\n"\n'

        printf 'printf "\\033[1;32m✓ Caddy + mDNS installed.\\033[0m\\n"\n'
    } > "$script"
    chmod +x "$script"

    local sess="sdCaddyMdnsInst_$$"
    local _tl_rc
    _tmux_launch "$sess" "Install Caddy + mDNS" "$script"
    _tl_rc=$?
    [[ $_tl_rc -eq 1 ]] && { rm -f "$script"; return 1; }
    return 0
}

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

# ── Ubuntu base management menu ───────────────────────────────────
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
        "×  Kill")   confirm "Kill the running operation?" || return 1
                     tmux kill-session -t "sdUbuntuPkg" 2>/dev/null || true; return 0 ;;
        *) return 1 ;;
    esac
}

# _pkg_op_wait sess ok_file fail_file title
# Shows a blocking "in progress" fzf with attach/back options while sess is running.
# Watcher kills fzf when ok/fail file appears or session ends.
# Returns: 0 = operation finished (caller should continue/refresh)
#          1 = user pressed Back/ESC
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
            confirm "Ubuntu base not installed. Download and install now?" || return
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
                        pause "Already up to date."; continue
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
            confirm "$(printf "${YLW}⚠  Uninstall Ubuntu base?${NC}\n\nThis will wipe the Ubuntu chroot.\nAll installed packages will be lost.\nContainers that depend on it will stop working.")" || continue
            rm -rf "$UBUNTU_DIR" 2>/dev/null
            mkdir -p "$UBUNTU_DIR" 2>/dev/null
            pause "✓ Ubuntu base removed."
            return
        fi

        # ── Add package ──
        if [[ "$clean" == *"Add package"* ]]; then
            local pkg_name
            finput "Package name (e.g. ffmpeg, nodejs):" || continue
            pkg_name="${FINPUT_RESULT// /}"
            [[ -z "$pkg_name" ]] && continue
            local pkg_ver
            finput "$(printf "Version (leave blank for latest):")" || continue
            pkg_ver="${FINPUT_RESULT// /}"
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
            pause "$(printf "Protected package\n\n'%s' is a default Ubuntu package.\nUnable to modify this package." "$cpkg")"
            continue
        fi
        for i in "${!sys_lines[@]}"; do
            local lc; lc=$(printf '%s' "${sys_lines[$i]}" | _trim_s)
            if [[ "$lc" == "$clean" ]]; then chosen_key="${sys_keys[$i]}"; break; fi
        done
        if [[ -n "$chosen_key" ]]; then
            local cpkg="${chosen_key%%|*}"
            pause "$(printf "System package\n\n'%s' is an Ubuntu system package.\nRemoving it would break the system.\nUnable to modify this package." "$cpkg")"
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
        confirm "$(printf "Remove '${BLD}%s${NC}' from Ubuntu base?\n\n${DIM}%s${NC}" "$cpkg" "$cver")" || continue
        local rm_cmd="DEBIAN_FRONTEND=noninteractive apt-get remove -y ${cpkg} 2>&1"
        _ubuntu_pkg_tmux "sdUbuntuPkg" "Removing ${cpkg}" "$rm_cmd"
    done
}


# ── Other / help menu ────────────────────────────────────────────
_logs_browser() {
    while true; do
        [[ -z "$LOGS_DIR" || ! -d "$LOGS_DIR" ]] && { pause "No Logs folder found."; return; }
        local _files=()
        while IFS= read -r f; do
            _files+=("$(printf "${DIM}%s${NC}" "${f#$LOGS_DIR/}")")
        done < <(find "$LOGS_DIR" -type f -name "*.log" | sort -r)
        [[ ${#_files[@]} -eq 0 ]] && { pause "No log files yet."; return; }
        _files+=("$(printf "${DIM}%s${NC}" "${L[back]}")")
        local sel; sel=$(printf '%s\n' "${_files[@]}" \
            | _fzf "${FZF_BASE[@]}" \
                --header="$(printf "${BLD}── Logs ──${NC}")" 2>/dev/null) || return
        local sel_clean; sel_clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$sel_clean" == "${L[back]}" ]] && return
        local _path="$LOGS_DIR/$sel_clean"
        [[ ! -f "$_path" ]] && continue
        cat "$_path" \
            | _fzf "${FZF_BASE[@]}" \
                --header="$(printf "${BLD}── %s  ${DIM}(read only)${NC} ──${NC}" "$sel_clean")" \
                --no-multi --disabled >/dev/null 2>&1 || true
    done
}

_help_menu() {
    local _SEP_STORAGE _SEP_PLUGINS _SEP_ISOLATION _SEP_TOOLS _SEP_DANGER _SEP_NAV
    _SEP_STORAGE="$(  printf "${BLD}  ── Storage ───────────────────────────${NC}")"
    _SEP_PLUGINS="$(  printf "${BLD}  ── Plugins ───────────────────────────${NC}")"
    _SEP_TOOLS="$(    printf "${BLD}  ── Tools ─────────────────────────────${NC}")"
    _SEP_HELP="$(     printf "${BLD}  ── Help ──────────────────────────────${NC}")"
    _SEP_DANGER="$(   printf "${BLD}  ── Caution ───────────────────────────${NC}")"
    _SEP_NAV="$(      printf "${BLD}  ── Navigation ────────────────────────${NC}")"
    while true; do
        local ubuntu_status proxy_status ubuntu_upd_tag=""
        _sd_ub_cache_read
        if [[ -f "$UBUNTU_DIR/.ubuntu_ready" ]]; then
            ubuntu_status="$(printf "${GRN}ready${NC}  ${CYN}[P]${NC}")"
            if [[ "$_SD_UB_PKG_DRIFT" == true || "$_SD_UB_HAS_UPDATES" == true ]]; then
                ubuntu_upd_tag="  $(printf "${YLW}Updates available${NC}")"
            fi
        else
            ubuntu_status="$(printf "${YLW}not installed${NC}")"
        fi
        _proxy_running                        && proxy_status="$(printf "${GRN}running${NC}")"  || proxy_status="$(printf "${DIM}stopped${NC}")"
        local lines=(
            "$_SEP_STORAGE"
            "$(printf "${DIM} ◈  Profiles & data${NC}")"
            "$(printf "${DIM} ◈  Backups${NC}")"
            "$(printf "${DIM} ◈  Blueprints${NC}")"
            "$_SEP_PLUGINS"
            "$(printf " ${CYN}◈${NC}${DIM}  Ubuntu base — %b%s${NC}" "$ubuntu_status" "$ubuntu_upd_tag")"
            "$(printf " ${CYN}◈${NC}${DIM}  Caddy — %b${NC}" "$proxy_status")"
            "$(printf " ${CYN}◈${NC}${DIM}  QRencode — %b${NC}" "$([[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && _chroot_bash "$UBUNTU_DIR" -c 'command -v qrencode' >/dev/null 2>&1 && printf "${GRN}installed${NC}" || printf "${DIM}not installed${NC}")")"

            "$_SEP_TOOLS"
            "$(printf "${DIM} ◈  Active processes${NC}")"
            "$(printf "${DIM} ◈  Resource limits${NC}")"
            "$(printf "${DIM} ≡  Blueprint preset${NC}")"

            "$_SEP_DANGER"
            "$(printf "${DIM} ≡  View logs${NC}")"
            "$(printf "${DIM} ⊘  Clear cache${NC}")"
            "$(printf "${DIM} ▷  Resize image${NC}")"
            "$(printf "${DIM} ◈  Manage Encryption${NC}")"
            "$(printf " ${RED}×${NC}${DIM}  Delete image file${NC}")"
            "$_SEP_NAV"
            "$(printf "${DIM} %s${NC}" "${L[back]}")"
        )
        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── %s ──${NC}  ${DIM}Ubuntu:${NC}%b  ${DIM}Proxy:${NC}%b" "${L[help]}" "$ubuntu_status" "$proxy_status")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        if _sig_rc $_frc; then stty sane 2>/dev/null; continue; fi
        [[ $_frc -ne 0 ]] && return
        local sel_clean; sel_clean=$(printf '%s' "$sel" | _trim_s)
        case "$sel_clean" in
            *"${L[back]}"*)         return ;;
            *"Clear cache"*)
                confirm "Clear all cached data?" || continue
                rm -rf "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null || true
                mkdir -p "$CACHE_DIR/sd_size" "$CACHE_DIR/gh_tag" 2>/dev/null
                pause "Cache cleared." ;;
            *"Resize image"*)       _resize_image ;;
            *"Manage Encryption"*)  _enc_menu ;;
            *"Profiles & data"*) _persistent_storage_menu; continue ;;
            *"Backups"*)            _manage_backups_menu ;;
            *"Blueprints"*)         _blueprints_settings_menu; continue ;;
            *"Active processes"*)   _active_processes_menu ;;
            *"Resource limits"*)  _resources_menu ;;
            *"Caddy"*)               _proxy_menu; continue ;;
            *"QRencode"*)
                _qrencode_menu; continue ;;
            *"Ubuntu base"*)
                _ubuntu_menu; continue ;;
            *"Blueprint preset"*)
                _blueprint_template \
                    | _fzf "${FZF_BASE[@]}" \
                          --header="$(printf "${BLD}── Blueprint preset  ${DIM}(read only)${NC} ──${NC}")" \
                          --no-multi --disabled >/dev/null 2>&1 || true ;;
            *"Blueprint example"*) ;;
            *"View logs"*|*"Logs"*)
                _logs_browser ;;
            *"Delete image file"*)
                [[ -z "$IMG_PATH" ]] && { pause "No image currently loaded."; continue; }
                local img_name; img_name=$(basename "$IMG_PATH")
                local img_path_save="$IMG_PATH"
                confirm "$(printf "PERMANENTLY DELETE IMAGE?\n\n  File: %s\n  Path: %s\n\n  THIS CANNOT BE UNDONE!" "$img_name" "$img_path_save")" || continue
                _load_containers true
                local dcid dsess
                for dcid in "${CT_IDS[@]}"; do
                    dsess="$(tsess "$dcid")"
                    tmux_up "$dsess" && { tmux send-keys -t "$dsess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$dsess" 2>/dev/null || true; }
                done
                tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^sdInst_" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true; _tmux_set SD_INSTALLING ""
                _unmount_img; rm -f "$img_path_save" 2>/dev/null
                IMG_PATH="" BLUEPRINTS_DIR="" CONTAINERS_DIR="" INSTALLATIONS_DIR="" BACKUP_DIR="" STORAGE_DIR=""
                pause "$(printf "✓ Image deleted: %s\n\n  Select or create a new image." "$img_name")"
                _setup_image; return ;;
        esac
    done
}

#  MAIN MENU  —  Containers / Groups / Blueprints as submenus
_SEP="$(printf     "${BLD}  ─────────────────────────────────────${NC}")"

main_menu() {
    while true; do
        clear; _cleanup_stale_lock; _validate_containers; _load_containers false
        local inst_id; inst_id=$(_installing_id)

        # Count summaries
        local n_running=0 n_groups=0 n_bps=0
        for cid in "${CT_IDS[@]}"; do tmux_up "$(tsess "$cid")" && (( n_running++ )) || true; done
        local grp_ids=(); mapfile -t grp_ids < <(_list_groups)
        n_groups=${#grp_ids[@]}
        local bp_names=(); mapfile -t bp_names < <(_list_blueprint_names)
        local pbp_names=(); mapfile -t pbp_names < <(_list_persistent_names)
        local ibp_names=(); mapfile -t ibp_names < <(_list_imported_names)
        n_bps=$(( ${#bp_names[@]} + ${#pbp_names[@]} + ${#ibp_names[@]} ))

        # Status indicators for submenu items
        local ct_status="${DIM}${#CT_IDS[@]}${NC}"
        [[ $n_running -gt 0 ]] && ct_status="$(printf "${GRN}%d running${NC}${DIM}/%d${NC}" "$n_running" "${#CT_IDS[@]}")"

        local grp_n_active=0
        for gid in "${grp_ids[@]}"; do
            local grunning=0
            while IFS= read -r cname; do
                local gcid; gcid=$(_ct_id_by_name "$cname")
                [[ -n "$gcid" ]] && tmux_up "$(tsess "$gcid")" && (( grunning++ )) || true
            done < <(_grp_containers "$gid")
            [[ $grunning -gt 0 ]] && (( grp_n_active++ )) || true
        done
        local grp_status="${DIM}${n_groups}${NC}"
        [[ $grp_n_active -gt 0 ]] && grp_status="$(printf "${GRN}%d active${NC}${DIM}/%d${NC}" "$grp_n_active" "$n_groups")"

        local lines=(
            "$(printf " ${GRN}◈${NC}  %-28s %b" "Containers" "$ct_status")"
            "$(printf " ${CYN}▶${NC}  %-28s %b" "Groups" "$grp_status")"
            "$(printf " ${BLU}◈${NC}  %-28s ${DIM}%d${NC}" "Blueprints" "$n_bps")"
            "$_SEP"
            "$(printf "${DIM} ?  %s${NC}" "${L[help]}")"
            "$(printf "${RED} ×  %s${NC}" "${L[quit]}")"
        )

        local img_label=""
        if [[ -n "$IMG_PATH" ]] && mountpoint -q "$MNT_DIR" 2>/dev/null; then
            local used_kb total_bytes
            used_kb=$(df -k "$MNT_DIR" 2>/dev/null | awk 'NR==2{print $3}')
            total_bytes=$(stat -c%s "$IMG_PATH" 2>/dev/null)
            local used_gb total_gb
            used_gb=$(awk "BEGIN{printf \"%.1f\",${used_kb:-0}/1048576}")
            total_gb=$(awk "BEGIN{printf \"%.1f\",${total_bytes:-0}/1073741824}")
            img_label="$(printf "${DIM}  %s  [%s/%s GB]${NC}" "$(basename "$IMG_PATH")" "$used_gb" "$total_gb")"
        elif [[ -n "$IMG_PATH" ]]; then
            img_label="$(printf "${DIM}  %s${NC}" "$(basename "$IMG_PATH")")"
        fi

        local _fzf_sel_out; _fzf_sel_out=$(mktemp "$TMP_DIR/.sd_fzf_sel_XXXXXX")
        printf '%s\n' "${lines[@]}" \
            | fzf "${FZF_BASE[@]}" \
                  --header="$(printf "${BLD}── %s ──${NC}%s" "${L[title]}" "$img_label")" \
                  "--bind=${KB[quit]}:execute-silent(tmux set-environment -g SD_QUIT 1)+abort" \
                  >"$_fzf_sel_out" 2>/dev/null &
        local _fzf_sel_pid=$!
        printf '%s' "$_fzf_sel_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_sel_pid" 2>/dev/null
        local _fzf_rc=$?
        if [[ $_fzf_rc -eq 143 || $_fzf_rc -eq 138 || $_fzf_rc -eq 137 ]]; then
            rm -f "$_fzf_sel_out"; stty sane 2>/dev/null; continue
        fi
        local sel; sel=$(cat "$_fzf_sel_out" 2>/dev/null); rm -f "$_fzf_sel_out"
        if [[ -z "$sel" ]]; then
            if [[ "$(_tmux_get SD_QUIT)" == "1" ]]; then
                _tmux_set SD_QUIT 0; _quit_menu; continue
            fi
            _quit_all
        fi

        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ -z "$clean" ]] && continue

        case "$clean" in
            *"${L[quit]}"*) _quit_menu ;;
            *"${L[help]}"*) _help_menu ;;

            *"Containers"*) _containers_submenu ;;
            *"Groups"*)     _groups_menu ;;
            *"Blueprints"*) _blueprints_submenu ;;
        esac
    done
}

# ── Containers submenu ────────────────────────────────────────────
_containers_submenu() {
    while true; do
        clear
        # drain any buffered terminal input so it doesn't leak into fzf's query
        stty sane 2>/dev/null
        while IFS= read -r -t 0.1 -n 256 _ 2>/dev/null; do :; done
        _load_containers false
        local inst_id; inst_id=$(_installing_id)
        local lines=() n_running_ct=0
        lines+=("$(printf "${BLD}  ── Containers ──────────────────────${NC}")")

        for i in "${!CT_IDS[@]}"; do
            local cid="${CT_IDS[$i]}" n="${CT_NAMES[$i]}"
            local dialogue; dialogue=$(jq -r '.meta.dialogue // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local dot
            local _cok="$CONTAINERS_DIR/$cid/.install_ok" _cfail="$CONTAINERS_DIR/$cid/.install_fail"
            if   _is_installing "$cid" || [[ -f "$_cok" || -f "$_cfail" ]]; then dot="${YLW}◈${NC}"
            elif tmux_up "$(tsess "$cid")"; then
                (( n_running_ct++ )) || true
                if _health_check "$cid"; then dot="${GRN}◈${NC}"
                else dot="${YLW}◈${NC}"; fi
            elif [[ "$(_st "$cid" installed)" == "true" ]]; then dot="${RED}◈${NC}"
            else dot="${DIM}◈${NC}"; fi
            local disp_name
            [[ -n "$dialogue" ]] \
                && disp_name="$(printf "%s  \033[2m— %s\033[0m" "$n" "$dialogue")" \
                || disp_name="$n"
            local _sz_lbl=""
            local _ipath; _ipath=$(_cpath "$cid")
            if [[ -d "$_ipath" ]]; then
                local _sz_cache="$CACHE_DIR/sd_size/$cid"
                # Show cached value instantly, refresh in background
                if [[ -f "$_sz_cache" ]]; then
                    _sz_lbl="$(printf "${DIM}[%sgb]${NC}" "$(cat "$_sz_cache" 2>/dev/null)")"
                fi
                # Refresh cache in background if missing or older than 60s
                local _sz_age=999
                [[ -f "$_sz_cache" ]] && _sz_age=$(( $(date +%s) - $(date -r "$_sz_cache" +%s 2>/dev/null || echo 0) ))
                if [[ $_sz_age -gt 60 ]]; then
                    { mkdir -p "${_sz_cache%/*}" 2>/dev/null; du -sb "$_ipath" 2>/dev/null | awk '{printf "%.2f",$1/1073741824}' > "$_sz_cache.tmp" && mv "$_sz_cache.tmp" "$_sz_cache"; } 2>/dev/null &
                    disown 2>/dev/null || true
                fi
            fi
            local _list_port; _list_port=$(jq -r '.meta.port // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            local _list_ep; _list_ep=$(jq -r '.environment.PORT // empty' "$CONTAINERS_DIR/$cid/service.json" 2>/dev/null)
            [[ -n "$_list_ep" ]] && _list_port="$_list_ep"
            local _list_ip_lbl=""
            if [[ -n "$_list_port" && "$_list_port" != "0" && "$(_st "$cid" installed)" == "true" ]]; then
                local _list_ip; _list_ip=$(_netns_ct_ip "$cid" "$MNT_DIR")
                _list_ip_lbl="$(printf "\033[2m[%s:%s]\033[0m " "$_list_ip" "$_list_port")"
            fi
            lines+=("$(printf " %b  %b\033[0m\033[2m %b %s[%s]\033[0m" "$dot" "$disp_name" "$_sz_lbl" "$_list_ip_lbl" "$cid")")
        done

        local bps=(); mapfile -t bps < <(_list_blueprint_names)
        local pbps=(); mapfile -t pbps < <(_list_persistent_names)
        local all_bps=("${bps[@]}" "${pbps[@]}")

        [[ ${#CT_IDS[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no containers yet)${NC}")")
        lines+=("$(printf "${GRN} +  %s${NC}" "${L[new_container]}")")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        local _ct_hdr_extra; _ct_hdr_extra=$(printf "  ${DIM}[%d · ${GRN}%d ▶${NC}${DIM}]${NC}" "${#CT_IDS[@]}" "$n_running_ct")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" --header="$(printf "${BLD}── Containers ──${NC}%s" "$_ct_hdr_extra")" >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel}" ]] && return

        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" ]] && return
        [[ -z "$clean" ]] && continue

        if [[ "$clean" == *"${L[new_container]}"* ]]; then
            _install_method_menu; continue
        fi

        local cid_tag
        cid_tag=$(printf '%s' "$clean" | grep -oP '(?<=\[)[a-z0-9]{8}(?=\]$)' || true)
        [[ -n "$cid_tag" && -d "$CONTAINERS_DIR/$cid_tag" ]] && _container_submenu "$cid_tag"
    done
}

# ── Blueprint settings menu ───────────────────────────────────────
_blueprints_settings_menu() {
    local _SEP_GEN _SEP_PATHS _SEP_NAV
    _SEP_GEN="$(printf "${BLD}  ── General ───────────────────────────${NC}")"
    _SEP_PATHS="$(printf "${BLD}  ── Scanned paths ─────────────────────${NC}")"
    _SEP_NAV="$(printf "${BLD}  ── Navigation ───────────────────────${NC}")"
    while true; do
        local pers_enabled; _bp_persistent_enabled && pers_enabled=true || pers_enabled=false
        local pers_tog
        [[ "$pers_enabled" == "true" ]] \
            && pers_tog="$(printf "${GRN}[Enabled]${NC}")" \
            || pers_tog="$(printf "${RED}[Disabled]${NC}")"

        local ad_mode; ad_mode=$(_bp_autodetect_mode)
        local ad_lbl
        case "$ad_mode" in
            Home)       ad_lbl="$(printf "${GRN}[Home]${NC}")" ;;
            Root)       ad_lbl="$(printf "${YLW}[Root]${NC}")" ;;
            Everywhere) ad_lbl="$(printf "${CYN}[Everywhere]${NC}")" ;;
            Custom)     ad_lbl="$(printf "${BLU}[Custom]${NC}")" ;;
            Disabled)   ad_lbl="$(printf "${DIM}[Disabled]${NC}")" ;;
        esac

        local lines=(
            "$_SEP_GEN"
            "$(printf " ${DIM}◈${NC}  Persistent blueprints  %b  ${DIM}— toggle built-in visibility${NC}" "$pers_tog")"
            "$(printf " ${DIM}◈${NC}  Autodetect blueprints  %b  ${DIM}— scan for .container files${NC}" "$ad_lbl")"
        )

        # Scanned paths section only visible in Custom mode
        if [[ "$ad_mode" == "Custom" ]]; then
            lines+=("$_SEP_PATHS")
            local _cpaths=(); mapfile -t _cpaths < <(_bp_custom_paths_get)
            if [[ ${#_cpaths[@]} -eq 0 ]]; then
                lines+=("$(printf "${DIM}  (no paths configured)${NC}")")
            else
                for _cp in "${_cpaths[@]}"; do
                    if [[ -d "$_cp" ]]; then
                        lines+=("$(printf " ${DIM}◈${NC}  ${DIM}%s${NC}" "$_cp")")
                    else
                        lines+=("$(printf " ${DIM}◈${NC}  ${DIM}%s${NC}  ${RED}[corrupted]${NC}" "$_cp")")
                    fi
                done
            fi
            lines+=("$(printf "${GRN} +  Add path${NC}")")
        fi

        lines+=("$_SEP_NAV")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" \
            | fzf "${FZF_BASE[@]}" \
                  --header="$(printf "${BLD}── Blueprints — Settings ──${NC}")" \
                  >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "$sel" ]] && return
        local sc; sc=$(printf '%s' "$sel" | _strip_ansi | sed 's/^[[:space:]]*//')
        case "$sc" in
            *"${L[back]}"*|"") return ;;
            *"Persistent blueprints"*)
                [[ "$pers_enabled" == "true" ]] \
                    && _bp_cfg_set persistent_blueprints false \
                    || _bp_cfg_set persistent_blueprints true ;;
            *"Autodetect blueprints"*)
                # Cycle: Home → Root → Everywhere → Custom → Disabled → Home
                case "$ad_mode" in
                    Home)       _bp_cfg_set autodetect_blueprints Root ;;
                    Root)       _bp_cfg_set autodetect_blueprints Everywhere ;;
                    Everywhere) _bp_cfg_set autodetect_blueprints Custom ;;
                    Custom)     _bp_cfg_set autodetect_blueprints Disabled ;;
                    Disabled)   _bp_cfg_set autodetect_blueprints Home ;;
                esac ;;
            *"Add path"*)
                # Pick folder via yazi
                if ! command -v yazi >/dev/null 2>&1; then
                    pause "yazi is not installed on this system."; continue
                fi
                local _chosen_dir; _chosen_dir=$(mktemp -u "$TMP_DIR/.sd_yazi_XXXXXX")
                yazi --chooser-file="$_chosen_dir" 2>/dev/null
                local _picked; _picked=$(cat "$_chosen_dir" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//'); rm -f "$_chosen_dir"
                [[ -z "$_picked" ]] && continue
                [[ ! -d "$_picked" ]] && { pause "$(printf "Not a directory:\n  %s" "$_picked")"; continue; }
                _bp_custom_paths_add "$_picked"
                ;;
            *)
                # Check if sc matches one of the custom paths (path removal)
                local _cp
                while IFS= read -r _cp; do
                    if [[ "$sc" == *"$_cp"* ]]; then
                        confirm "$(printf "Remove path from scan list?\n\n  %s" "$_cp")" || break
                        _bp_custom_paths_remove "$_cp"
                        break
                    fi
                done < <(_bp_custom_paths_get)
                ;;
        esac
    done
}

# ── Blueprints submenu ────────────────────────────────────────────
_blueprints_submenu() {
    while true; do
        clear
        while IFS= read -r -t 0 -n 1 _ 2>/dev/null; do :; done
        local bps=(); mapfile -t bps < <(_list_blueprint_names)
        local pbps=(); mapfile -t pbps < <(_list_persistent_names)
        local ibps=(); mapfile -t ibps < <(_list_imported_names)
        local lines=()

        lines+=("$(printf "${BLD}  ── Blueprints ───────────────────────${NC}")")
        for n in "${bps[@]}";  do lines+=("$(printf "${DIM} ◈${NC}  %s" "$n")"); done
        for n in "${pbps[@]}"; do lines+=("$(printf "${BLU} ◈${NC}  %s  ${DIM}[Persistent]${NC}" "$n")"); done
        for n in "${ibps[@]}"; do lines+=("$(printf "${CYN} ◈${NC}  %s  ${DIM}[Imported]${NC}" "$n")"); done

        [[ ${#bps[@]} -eq 0 && ${#pbps[@]} -eq 0 && ${#ibps[@]} -eq 0 ]] && lines+=("$(printf "${DIM}  (no blueprints yet)${NC}")")
        lines+=("$(printf "${GRN} +  %s${NC}" "${L[bp_new]}")")
        lines+=("$(printf "${BLD}  ── Navigation ───────────────────────${NC}")")
        lines+=("$(printf "${DIM} %s${NC}" "${L[back]}")")

        local _fzf_out _fzf_pid _frc
        _fzf_out=$(mktemp "$TMP_DIR/.sd_fzf_out_XXXXXX")
        printf '%s\n' "${lines[@]}" | fzf "${FZF_BASE[@]}" \
            --header="$(printf "${BLD}── Blueprints ──${NC}  ${DIM}[%d file · %d built-in · %d imported]${NC}" "${#bps[@]}" "${#pbps[@]}" "${#ibps[@]}")" \
            >"$_fzf_out" 2>/dev/null &
        _fzf_pid=$!; printf '%s' "$_fzf_pid" > "$TMP_DIR/.sd_active_fzf_pid"
        wait "$_fzf_pid" 2>/dev/null; _frc=$?
        local sel; sel=$(cat "$_fzf_out" 2>/dev/null | _trim_s); rm -f "$_fzf_out"
        _sig_rc $_frc && { stty sane 2>/dev/null; continue; }
        [[ $_frc -ne 0 || -z "${sel}" ]] && return
        local clean; clean=$(printf '%s' "$sel" | _trim_s)
        [[ "$clean" == "${L[back]}" ]] && return

        local sc; sc=$(printf '%s' "$clean" | _strip_ansi | sed 's/^[[:space:]]*//')

        if [[ "$clean" == *"${L[bp_new]}"* ]]; then
            _guard_space || continue
            finput "Blueprint name:" || continue
            local bname; bname="${FINPUT_RESULT//[^a-zA-Z0-9_\- ]/}"
            [[ -z "$bname" ]] && continue
            local bfile; bfile="$BLUEPRINTS_DIR/$bname.toml"
            [[ -f "$bfile" ]] && { pause "Blueprint '$bname' already exists."; continue; }
            _blueprint_template > "$bfile"
            pause "Blueprint '$bname' created. Select it to edit."
            continue
        fi

        if [[ "$clean" == *"[Persistent]"* ]]; then
            local pname; pname=$(printf '%s' "$clean" | sed 's/^[[:space:]]*◈[[:space:]]*//;s/[[:space:]]*\[Persistent\].*//')
            [[ -n "$pname" ]] && _view_persistent_bp "$pname"
            continue
        fi

        if [[ "$clean" == *"[Imported]"* ]]; then
            local iname; iname=$(printf '%s' "$clean" | sed 's/^[[:space:]]*◈[[:space:]]*//;s/[[:space:]]*\[Imported\].*//')
            local ipath; ipath=$(_get_imported_bp_path "$iname")
            if [[ -n "$ipath" && -f "$ipath" ]]; then
                cat "$ipath" \
                    | _fzf "${FZF_BASE[@]}" \
                          --header="$(printf "${BLD}── [Imported] %s  ${DIM}(%s)${NC} ──${NC}" "$iname" "$ipath")" \
                          --no-multi --disabled 2>/dev/null || true
            else
                pause "Could not locate imported blueprint '$iname'."
            fi
            continue
        fi

        for n in "${bps[@]}"; do
            if [[ "$clean" == *"$n"* ]]; then _blueprint_submenu "$n"; break; fi
        done
    done
}

