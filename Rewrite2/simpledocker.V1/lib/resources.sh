#!/usr/bin/env bash

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
