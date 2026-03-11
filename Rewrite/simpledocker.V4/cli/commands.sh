#!/usr/bin/env bash
# cli/commands.sh — command-line interface dispatcher
# All commands call the same lib/ functions as the TUI.

cli_dispatch() {
    local cmd="${1:-}"; shift 2>/dev/null || true
    case "$cmd" in
        start)       _start_container "$(_ct_id_by_name "$1")" ;;
        stop)        _stop_container  "$(_ct_id_by_name "$1")" ;;
        restart)     _stop_container  "$(_ct_id_by_name "$1")"; _start_container "$(_ct_id_by_name "$1")" ;;
        install)     _guard_install   "$(_ct_id_by_name "$1")" ;;
        uninstall)   _do_umount       "$(_ct_id_by_name "$1")" ;;
        list)        _load_containers false
                     for i in "${!CT_IDS[@]}"; do
                         local cid="${CT_IDS[$i]}" n="${CT_NAMES[$i]}"
                         local running="stopped"
                         tmux_up "$(tsess "$cid")" && running="running"
                         printf '%s\t%s\t%s\n' "$cid" "$n" "$running"
                     done ;;
        status)      local cid; cid=$(_ct_id_by_name "$1")
                     local running="stopped"; tmux_up "$(tsess "$cid")" && running="running"
                     printf 'id=%s name=%s status=%s installed=%s\n' "$cid" "$(_cname "$cid")" "$running" "$(_st "$cid" installed)" ;;
        logs)        local cid; cid=$(_ct_id_by_name "$1")
                     tail -n "${2:-50}" "$(_log_path "$cid" start)" 2>/dev/null ;;
        backup)      local cid; cid=$(_ct_id_by_name "$1"); _create_manual_backup "$cid" "${2:-}" ;;
        update)      local cid; cid=$(_ct_id_by_name "$1"); _do_blueprint_update "$cid" ;;
        group-start) _start_group "$1" ;;
        group-stop)  _stop_group  "$1"  ;;
        *)           printf 'Usage: %s {start|stop|restart|install|list|status|logs|backup|update|group-start|group-stop} [name]\n' "$(basename "$0")" >&2; exit 1 ;;
    esac
}
