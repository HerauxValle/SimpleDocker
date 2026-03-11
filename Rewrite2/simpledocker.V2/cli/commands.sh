#!/usr/bin/env bash
# CLI layer — calls lib/ functions directly, no fzf/TUI
# Usage: main.sh <command> [args...]
#
# Available commands mirror TUI functionality 1:1.
# All call the same lib/ functions as the TUI wrappers.

cli_dispatch() {
    case "$1" in
        start)       cli_start      "${@:2}" ;;
        stop)        cli_stop       "${@:2}" ;;
        restart)     cli_restart    "${@:2}" ;;
        install)     cli_install    "${@:2}" ;;
        uninstall)   cli_uninstall  "${@:2}" ;;
        remove)      cli_remove     "${@:2}" ;;
        list)        cli_list       "${@:2}" ;;
        status)      cli_status     "${@:2}" ;;
        logs)        cli_logs       "${@:2}" ;;
        group)       cli_group      "${@:2}" ;;
        storage)     cli_storage    "${@:2}" ;;
        backup)      cli_backup     "${@:2}" ;;
        update)      cli_update     "${@:2}" ;;
        help|--help|-h) cli_help   ;;
        *) printf 'unknown command: %s\nRun: %s help\n' "$1" "$(basename "$0")" >&2; exit 1 ;;
    esac
}

# ── Helpers ───────────────────────────────────────────────────────
_cli_resolve() {
    # Resolve container name → cid; print cid or exit 1
    local name="$1"
    [[ -z "$name" ]] && { printf 'error: container name required\n' >&2; exit 1; }
    _setup_image_headless 2>/dev/null || true
    _load_containers true
    local cid; cid=$(_ct_id_by_name "$name")
    [[ -z "$cid" ]] && { printf 'error: no container named "%s"\n' "$name" >&2; exit 1; }
    printf '%s' "$cid"
}

_setup_image_headless() {
    # Mount the default image without prompting (requires DEFAULT_IMG set)
    [[ -z "$DEFAULT_IMG" || ! -f "$DEFAULT_IMG" ]] && {
        printf 'error: DEFAULT_IMG not set or not found — set it in core/globals.sh\n' >&2
        exit 1
    }
    _mount_img "$DEFAULT_IMG" 2>/dev/null
}

# ── Commands ──────────────────────────────────────────────────────
cli_start() {
    local cid; cid=$(_cli_resolve "$1")
    _start_container "$cid"
}

cli_stop() {
    local cid; cid=$(_cli_resolve "$1")
    _stop_container "$cid"
}

cli_restart() {
    local cid; cid=$(_cli_resolve "$1")
    _stop_container "$cid"
    sleep 0.5
    _start_container "$cid"
}

cli_install() {
    local cid; cid=$(_cli_resolve "$1")
    _guard_install || exit 1
    _run_job install "$cid"
}

cli_uninstall() {
    local cid; cid=$(_cli_resolve "$1")
    _stop_container "$cid" 2>/dev/null || true
    # uninstall removes installation dir but keeps config
    local ip; ip=$(_cpath "$cid")
    [[ -n "$ip" && -d "$ip" ]] && btrfs subvolume delete "$ip" 2>/dev/null || rm -rf "$ip" 2>/dev/null || true
    _set_st "$cid" installed false
    printf 'uninstalled: %s\n' "$(_cname "$cid")"
}

cli_remove() {
    local cid; cid=$(_cli_resolve "$1")
    _stop_container "$cid" 2>/dev/null || true
    local ip; ip=$(_cpath "$cid")
    [[ -n "$ip" && -d "$ip" ]] && { btrfs subvolume delete "$ip" 2>/dev/null || rm -rf "$ip" 2>/dev/null || true; }
    rm -rf "$CONTAINERS_DIR/$cid" 2>/dev/null || true
    printf 'removed: %s\n' "$1"
}

cli_list() {
    _setup_image_headless 2>/dev/null || true
    _load_containers false
    for i in "${!CT_IDS[@]}"; do
        local cid="${CT_IDS[$i]}"
        local running="stopped"
        tmux_up "$(tsess "$cid")" && running="running"
        local installed; installed=$(_st "$cid" installed)
        printf '%-20s  %-8s  installed=%-5s  [%s]\n' \
            "${CT_NAMES[$i]}" "$running" "$installed" "$cid"
    done
}

cli_status() {
    local cid; cid=$(_cli_resolve "$1")
    local name; name=$(_cname "$cid")
    local installed; installed=$(_st "$cid" installed)
    local running="false"; tmux_up "$(tsess "$cid")" && running="true"
    local installing="false"; _is_installing "$cid" && installing="true"
    printf 'name:       %s\n' "$name"
    printf 'id:         %s\n' "$cid"
    printf 'installed:  %s\n' "$installed"
    printf 'running:    %s\n' "$running"
    printf 'installing: %s\n' "$installing"
}

cli_logs() {
    local cid; cid=$(_cli_resolve "$1")
    local mode="${2:-start}"
    local logfile; logfile=$(_log_path "$cid" "$mode")
    [[ -f "$logfile" ]] && cat "$logfile" || printf 'no log file: %s\n' "$logfile" >&2
}

cli_group() {
    local sub="$1"; shift
    case "$sub" in
        start) local gid="$1"; _start_group "$gid" ;;
        stop)  local gid="$1"; _stop_group  "$gid" ;;
        list)
            _setup_image_headless 2>/dev/null || true
            while IFS= read -r gid; do
                printf '%s\n' "$gid"
            done < <(_list_groups) ;;
        *) printf 'usage: group <start|stop|list> [group-id]\n' >&2; exit 1 ;;
    esac
}

cli_storage() {
    local sub="$1" scid="$2"
    case "$sub" in
        list)
            _setup_image_headless 2>/dev/null || true
            for sdir in "$STORAGE_DIR"/*/; do
                [[ -d "$sdir" ]] || continue
                local id; id=$(basename "$sdir")
                printf '%-10s  %s\n' "$id" "$(_stor_read_name "$id")"
            done ;;
        *) printf 'usage: storage <list>\n' >&2; exit 1 ;;
    esac
}

cli_backup() {
    local sub="$1" name="$2"
    case "$sub" in
        create)
            local cid; cid=$(_cli_resolve "$name")
            _create_manual_backup "$cid" "cli-backup-$(date +%Y%m%d-%H%M%S)" ;;
        list)
            local cid; cid=$(_cli_resolve "$name")
            local sdir; sdir=$(_snap_dir "$cid")
            for f in "$sdir"/*.meta; do
                [[ -f "$f" ]] || continue
                printf '%s\n' "$(basename "${f%.meta}")"
            done ;;
        *) printf 'usage: backup <create|list> <container>\n' >&2; exit 1 ;;
    esac
}

cli_update() {
    local cid; cid=$(_cli_resolve "$1")
    _do_blueprint_update "$cid" 0
}

cli_help() {
    printf 'simpleDocker CLI\n\n'
    printf 'Usage: %s <command> [args]\n\n' "$(basename "$0")"
    printf 'Commands:\n'
    printf '  list                        list all containers\n'
    printf '  status   <name>             show container status\n'
    printf '  start    <name>             start container\n'
    printf '  stop     <name>             stop container\n'
    printf '  restart  <name>             restart container\n'
    printf '  install  <name>             install container\n'
    printf '  uninstall <name>            uninstall (keep config)\n'
    printf '  remove   <name>             remove container + config\n'
    printf '  logs     <name> [mode]      view logs (mode: start|install|update)\n'
    printf '  update   <name>             run blueprint update\n'
    printf '  group    list               list groups\n'
    printf '  group    start <id>         start group\n'
    printf '  group    stop  <id>         stop group\n'
    printf '  storage  list               list storage profiles\n'
    printf '  backup   create <name>      create manual backup\n'
    printf '  backup   list   <name>      list backups for container\n'
}
