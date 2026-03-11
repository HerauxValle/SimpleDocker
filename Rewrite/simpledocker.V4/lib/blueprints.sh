#!/usr/bin/env bash

_bp_parse() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1
    BP_META=() BP_ENV=() BP_STORAGE="" BP_DEPS="" BP_DIRS="" BP_PIP=""
    BP_GITHUB="" BP_NPM="" BP_BUILD="" BP_INSTALL="" BP_UPDATE="" BP_START=""
    BP_ACTIONS_NAMES=() BP_ACTIONS_SCRIPTS=() BP_ACTIONS=() BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=() BP_CRON_FLAGS=()
    BP_CRON_NAMES=() BP_CRON_INTERVALS=() BP_CRON_CMDS=() BP_CRON_FLAGS=()

    local cur_section="" cur_content="" in_container=0 action_name=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # strip inline comments only outside bash blocks
        local stripped; stripped=$(printf '%s' "$line" | sed 's/#.*//' | sed 's/[[:space:]]*$//')

        # detect section headers
        if [[ "$stripped" =~ ^\[([^/][^]]*)\]$ ]]; then
            local new_sec="${BASH_REMATCH[1]}"
            # flush previous section
            _bp_flush_section "$cur_section" "$cur_content"
            cur_section="$new_sec"
            cur_content=""

            if [[ "$new_sec" == "container" || "$new_sec" == "blueprint" ]]; then
                in_container=1; cur_section=""; continue
            fi
            continue
        fi

        # detect closing tag [/container] or [/blueprint] or [/end]
        if [[ "$stripped" =~ ^\[/(container|blueprint|end)\]$ ]]; then
            _bp_flush_section "$cur_section" "$cur_content"
            cur_section=""; cur_content=""; in_container=0
            continue
        fi

        # accumulate content
        [[ -n "$cur_section" ]] && cur_content+="$line"$'\n'
    done < "$file"

    # flush final
    _bp_flush_section "$cur_section" "$cur_content"
}

_bp_flush_section() {
    local sec="$1" content="$2"
    [[ -z "$sec" ]] && return
    # trim trailing newlines
    content=$(printf '%s' "$content" | sed 's/[[:space:]]*$//')

    case "${sec,,}" in
        meta)
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" ]] && continue
                local k="${l%%=*}" v="${l#*=}"
                k=$(printf '%s' "$k" | sed 's/[[:space:]]*$//')
                v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//')
                BP_META["$k"]="$v"
            done <<< "$content" ;;
        env)
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" ]] && continue
                local k="${l%%=*}" v="${l#*=}"
                k=$(printf '%s' "$k" | sed 's/[[:space:]]*$//')
                v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//')
                BP_ENV["$k"]="$v"
            done <<< "$content" ;;
        storage)     BP_STORAGE="$content" ;;
        dependencies|deps) BP_DEPS="$content" ;;
        dirs)        BP_DIRS="$content" ;;
        pip|pypi)    BP_PIP="$content" ;;
        git)          BP_GITHUB="$content" ;;
        npm)         BP_NPM="$content" ;;
        build)       BP_BUILD="$content" ;;
        install)     BP_INSTALL="$content" ;;
        update)      BP_UPDATE="$content" ;;
        start)       BP_START="$content" ;;
        actions)
            # New DSL actions: one per line  label | type: args | cmd
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" || "$l" == \#* ]] && continue
                # Split on first |  to get label
                local albl="${l%%|*}"; albl=$(printf '%s' "$albl" | sed 's/[[:space:]]*$//')
                local arest="${l#*|}"; arest=$(printf '%s' "$arest" | sed 's/^[[:space:]]*//')
                [[ -z "$albl" ]] && continue
                BP_ACTIONS_NAMES+=("$albl")
                BP_ACTIONS_SCRIPTS+=("$arest")
            done <<< "$content" ;;
        cron)
            # Format: interval [name] [--sudo] [--unjailed] | command
            # --sudo    : prefix command with sudo (skipped if cmd already has sudo)
            # --unjailed: run on the host outside the container namespace
            while IFS= read -r l; do
                l=$(printf '%s' "$l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$l" || "$l" == \#* ]] && continue
                # Split on first |
                local cinterval_name="${l%%|*}"; cinterval_name=$(printf '%s' "$cinterval_name" | sed 's/[[:space:]]*$//')
                local ccmd="${l#*|}"; ccmd=$(printf '%s' "$ccmd" | sed 's/^[[:space:]]*//')
                [[ -z "$ccmd" ]] && continue
                # Extract flags --sudo and --unjailed from the pre-pipe part
                local cflags=""
                printf '%s' "$cinterval_name" | grep -q -- '--sudo'    && cflags="$cflags --sudo"
                printf '%s' "$cinterval_name" | grep -q -- '--unjailed' && cflags="$cflags --unjailed"
                cflags=$(printf '%s' "$cflags" | sed 's/^[[:space:]]*//')
                # Strip flags before parsing interval/name
                cinterval_name=$(printf '%s' "$cinterval_name" | sed 's/--sudo//g;s/--unjailed//g' | sed 's/[[:space:]]*$//')
                # Extract interval (first token) and name (rest in brackets or remainder)
                local cinterval cname
                cinterval=$(printf '%s' "$cinterval_name" | awk '{print $1}')
                # Name: rest after interval, strip surrounding brackets if present
                cname=$(printf '%s' "$cinterval_name" | sed 's/^[^[:space:]]*//' | sed 's/^[[:space:]]*//' | sed 's/^\[//;s/\]$//')
                [[ -z "$cname" ]] && cname="$cinterval job"
                BP_CRON_NAMES+=("$cname")
                BP_CRON_INTERVALS+=("$cinterval")
                # Auto-prefix unquoted relative paths after >> with $CONTAINER_ROOT
                local ccmd_prefixed; ccmd_prefixed=$(printf '%s' "$ccmd" | \
                    sed 's#>>[[:space:]]*\([[:alpha:]_][^[:space:]]*\)#>> $CONTAINER_ROOT/\1#g')
                BP_CRON_CMDS+=("$ccmd_prefixed")
                BP_CRON_FLAGS+=("$cflags")
            done <<< "$content" ;;
        *)
            # Legacy freeform custom actions (block syntax)
            BP_ACTIONS_NAMES+=("$sec")
            BP_ACTIONS_SCRIPTS+=("$content") ;;
    esac
}

_bp_validate() {
    BP_ERRORS=()

    # ── [meta] name required ──────────────────────────────────────
    [[ -z "${BP_META[name]:-}" ]] && BP_ERRORS+=("  [meta]  'name' is required")

    # ── entrypoint or [start] required ───────────────────────────
    local has_entry=0
    [[ -n "${BP_META[entrypoint]:-}" ]] && has_entry=1
    [[ -n "$BP_START" ]] && has_entry=1
    [[ $has_entry -eq 0 ]] && BP_ERRORS+=("  [meta]  'entrypoint' or a [start] block is required")

    # ── port must be numeric if present ──────────────────────────
    local port; port=$(printf '%s' "${BP_META[port]:-}" | sed 's/[[:space:]]//g')
    [[ -n "$port" && ! "$port" =~ ^[0-9]+$ ]] && BP_ERRORS+=("  [meta]  'port' must be a number, got: $port")

    # ── storage_type required when [storage] is non-empty ────────
    if [[ -n "$BP_STORAGE" ]]; then
        local st; st=$(printf '%s' "$BP_STORAGE" | tr ',' '\n' | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | head -1)
        [[ -n "$st" && -z "${BP_META[storage_type]:-}" ]] && \
            BP_ERRORS+=("  [storage]  'storage_type' in [meta] is required when [storage] paths are declared")
    fi

    # ── [git] lines must look like org/repo ───────────────────
    if [[ -n "$BP_GITHUB" ]]; then
        local gln=0
        while IFS= read -r gl; do
            (( gln++ )) || true
            gl=$(printf '%s' "$gl" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$gl" ]] && continue
            # strip optional varname= prefix
            [[ "$gl" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*=[[:space:]]*(.*) ]] && gl="${BASH_REMATCH[1]}"
            local repo; repo=$(printf '%s' "$gl" | awk '{print $1}')
            [[ ! "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] && \
                BP_ERRORS+=("  [git]  line $gln: invalid repo format '$repo' (expected org/repo)")
        done <<< "$BP_GITHUB"
    fi

    # ── [dirs] parentheses must be balanced ──────────────────────
    if [[ -n "$BP_DIRS" ]]; then
        local open=0 close=0 ch di=0 dlen=${#BP_DIRS}
        while [[ $di -lt $dlen ]]; do
            ch="${BP_DIRS:$di:1}"
            [[ "$ch" == '(' ]] && (( open++ ))  || true
            [[ "$ch" == ')' ]] && (( close++ )) || true
            (( di++ )) || true
        done
        [[ $open -ne $close ]] && \
            BP_ERRORS+=("  [dirs]  unbalanced parentheses (${open} open, ${close} close)")
    fi

    # ── [actions] DSL consistency ─────────────────────────────────
    local ai=0
    for i in "${!BP_ACTIONS_NAMES[@]}"; do
        (( ai++ )) || true
        local lbl="${BP_ACTIONS_NAMES[$i]}" dsl="${BP_ACTIONS_SCRIPTS[$i]}"
        # Only validate new DSL-style (contains |)
        printf '%s' "$dsl" | grep -q '|' || continue
        local has_prompt=0 has_select=0
        local seg
        while IFS= read -r seg; do
            seg=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ "$seg" == prompt:* ]] && has_prompt=1
            [[ "$seg" == select:* ]] && has_select=1
        done <<< "$(printf '%s' "$dsl" | tr '|' '\n')"
        # {input} without prompt
        printf '%s' "$dsl" | grep -q '{input}' && [[ $has_prompt -eq 0 ]] && \
            BP_ERRORS+=("  [actions]  '$lbl': uses {input} but no 'prompt:' segment")
        # {selection} without select
        printf '%s' "$dsl" | grep -q '{selection}' && [[ $has_select -eq 0 ]] && \
            BP_ERRORS+=("  [actions]  '$lbl': uses {selection} but no 'select:' segment")
        # empty label
        [[ -z "$lbl" ]] && BP_ERRORS+=("  [actions]  action $ai has an empty label")
    done

    # ── [pip] requires python3 in deps ──
    if [[ -n "$BP_PIP" ]]; then
        local has_py=0
        if [[ -n "$BP_DEPS" ]]; then
            printf '%s' "$BP_DEPS" | tr ',' ' ' | grep -qE 'python3' && has_py=1
        fi
        [[ $has_py -eq 0 ]] && \
            BP_ERRORS+=("  [pip]  requires 'python3' in [deps]")
    fi

    # [npm] does NOT require nodejs in [deps] — Node is auto-installed by the npm handler

    [[ ${#BP_ERRORS[@]} -eq 0 ]] && return 0 || return 1
}

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

_bp_is_json() {
    jq '.' "$1" >/dev/null 2>&1
}

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

_bp_cfg_set() {
    local key="$1" val="$2" tmp
    mkdir -p "$(dirname "$(_bp_cfg)")" 2>/dev/null
    [[ ! -f "$(_bp_cfg)" ]] && printf '{}' > "$(_bp_cfg)"
    tmp=$(mktemp "$TMP_DIR/.sd_bpcfg_XXXXXX")
    jq --arg k "$key" --arg v "$val" '.[$k]=$v' "$(_bp_cfg)" > "$tmp" && mv "$tmp" "$(_bp_cfg)" || rm -f "$tmp"
}

_bp_persistent_enabled() { [[ "$(_bp_cfg_get persistent_blueprints)" != "false" ]]; }
# autodetect_blueprints: "Home" (default) | "Root" | "Everywhere" | "Custom" | "Disabled"

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

_bp_path() {
    local name="$1"
    [[ -f "$BLUEPRINTS_DIR/$name.toml" ]] && printf '%s/%s.toml' "$BLUEPRINTS_DIR" "$name" && return
    [[ -f "$BLUEPRINTS_DIR/$name.json" ]] && printf '%s/%s.json' "$BLUEPRINTS_DIR" "$name" && return
    printf '%s/%s.toml' "$BLUEPRINTS_DIR" "$name"  # default for new
}

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

_blueprint_template() {
    printf '%s\n' "$SD_BLUEPRINT_PRESET"
}

_list_blueprint_names() {
    for f in "$BLUEPRINTS_DIR"/*.toml "$BLUEPRINTS_DIR"/*.json; do
        [[ -f "$f" ]] && basename "${f%.*}"
    done | sort -u
}

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
