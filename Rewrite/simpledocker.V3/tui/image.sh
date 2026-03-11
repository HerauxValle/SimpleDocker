#!/usr/bin/env bash

_setup_image() {
    # Auto-enter if already mounted (resuming session), otherwise always show selection
    if mountpoint -q "$MNT_DIR" 2>/dev/null; then _set_img_dirs; return 0; fi
    if [[ -n "$DEFAULT_IMG" && -f "$DEFAULT_IMG" ]]; then _mount_img "$DEFAULT_IMG"; return 0; fi
    while true; do
        # Detect compatible SD images in $HOME live (no cache) — BTRFS .img files
        local detected_imgs=()
        while IFS= read -r -d '' _df; do
            { file "$_df" 2>/dev/null | grep -q 'BTRFS' || _img_is_luks "$_df"; } && detected_imgs+=("$_df")
        done < <(find "$HOME" -maxdepth 4 -name '*.img' -type f -print0 2>/dev/null)

        local lines=()
        lines+=("$(printf " ${CYN}◈${NC}  ${L[img_select]}")")
        lines+=("$(printf " ${CYN}◈${NC}  ${L[img_create]}")")

        if [[ ${#detected_imgs[@]} -gt 0 ]]; then
            lines+=("$(printf "${DIM}  ── Detected images ──────────────────${NC}")")
            for _di in "${detected_imgs[@]}"; do
                lines+=("$(printf " ${CYN}◈${NC}  %s  ${DIM}(%s)${NC}" "$(basename "$_di")" "$(dirname "$_di")")")
            done
        fi

        local choice
        choice=$(printf '%s\n' "${lines[@]}" \
            | fzf --ansi --no-sort --prompt="  ❯ " --pointer="▶" \
                  --height=40% --reverse --border=rounded --margin=1,2 --no-info \
                  --header="$(printf "${BLD}── simpleDocker ──${NC}")" 2>/dev/null) || { clear; exit 0; }
        local clean; clean=$(printf '%s' "$choice" | _strip_ansi | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$clean" in
            *"${L[img_select]}"*) local picked; picked=$(_pick_img) && { _mount_img "$picked" && return 0; } ;;
            *"${L[img_create]}"*) _create_img && return 0 ;;
            *)
                for _di in "${detected_imgs[@]}"; do
                    if [[ "$clean" == *"$(basename "$_di")"* ]]; then
                        _mount_img "$_di" && return 0
                        break
                    fi
                done ;;
        esac
    done
}
