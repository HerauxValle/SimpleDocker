# lib/blueprint.sh — Container list/validation, install lock, blueprint DSL parser,
#                     validator, compiler, settings, autodetect, path helpers
# Sourced by main.sh — do NOT run directly

_load_containers() {
    CT_IDS=(); CT_NAMES=()
    local show_hidden="${1:-false}"
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        local hidden n
        { read -r hidden; IFS= read -r n; } < <(jq -r '.hidden // false, .name // empty' "$d/state.json" 2>/dev/null)
        [[ "$show_hidden" == "false" && "$hidden" == "true" ]] && continue
        [[ -z "$n" ]] && n="(unnamed-$cid)"
        CT_IDS+=("$cid"); CT_NAMES+=("$n")
    done
}

_validate_containers() {
    [[ -z "$CONTAINERS_DIR" ]] && return
    for d in "$CONTAINERS_DIR"/*/; do
        [[ -f "$d/state.json" ]] || continue
        local cid; cid=$(basename "$d")
        [[ "$(_st "$cid" installed)" != "true" ]] && continue
        local ip; ip=$(_cpath "$cid")
        [[ -n "$ip" && -d "$ip" ]] || _set_st "$cid" installed false
    done
}

# ── Install lock ──────────────────────────────────────────────────
_installing_id()      { _tmux_get SD_INSTALLING; }
_inst_sess()          { printf 'sdInst_%s' "$1"; }
_is_installing()      { local cid="$1"; tmux_up "$(_inst_sess "$cid")"; }
_cleanup_stale_lock() {
    local cur; cur=$(_installing_id)
    [[ -z "$cur" ]] && return 0
    tmux_up "$(_inst_sess "$cur")" && return 0
    _tmux_set SD_INSTALLING ""
}

#  NEW BLUEPRINT PARSER  (DSL format)

# Parse a blueprint file/string and emit fields to stdout as:
#   SECTION<RS>VALUE<RS>...
# Returns parsed data into associative arrays via _bp_parse().

# Global associative arrays — declare -A at global scope so string keys work
# correctly when called outside _bp_compile_to_json (which shadows with a local declare -A).
declare -A BP_META=()
declare -A BP_ENV=()

# _bp_parse FILE
# Sets globals: BP_META[], BP_ENV[], BP_STORAGE, BP_DEPS, BP_DIRS, BP_PIP,
#               BP_GITHUB, BP_BUILD, BP_INSTALL, BP_UPDATE, BP_START,
#               BP_ACTIONS_NAMES[], BP_ACTIONS_SCRIPTS[], BP_CRON_NAMES[], BP_CRON_INTERVALS[], BP_CRON_CMDS[]
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

# ── Blueprint validator ───────────────────────────────────────────
# Call after _bp_parse. Populates BP_ERRORS[] with human-readable messages.
# Returns 1 if any errors found, 0 if clean.
BP_ERRORS=()
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

# Convert parsed blueprint to service.json (internal runtime format)
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

