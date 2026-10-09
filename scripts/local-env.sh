#!/usr/bin/env bash
# Sourced by setup.sh and the generated run.sh; no shell profile is modified.
youngai_local_path() {
    local resolved
    resolved=$(realpath -m -- "$1") || return
    case "$resolved" in
        "$ROOT"/*) printf '%s\n' "$resolved" ;;
        *) printf 'Path must stay under %s: %s\n' "$ROOT" "$1" >&2; return 1 ;;
    esac
}

youngai_local_env() {
    local rel path
    for rel in bin weights engram logs .runtime .runtime/home .runtime/tmp \
               .runtime/cache .runtime/config .runtime/data .runtime/state \
               .runtime/cache/cuda .runtime/cache/ccache .runtime/cache/huggingface; do
        path=$(youngai_local_path "$ROOT/$rel") || return
        mkdir -p -- "$path" || return
    done
    export HOME="$ROOT/.runtime/home"
    export XDG_CACHE_HOME="$ROOT/.runtime/cache" XDG_CONFIG_HOME="$ROOT/.runtime/config"
    export XDG_DATA_HOME="$ROOT/.runtime/data" XDG_STATE_HOME="$ROOT/.runtime/state"
    export TMPDIR="$ROOT/.runtime/tmp" TMP="$ROOT/.runtime/tmp" TEMP="$ROOT/.runtime/tmp"
    export CUDA_CACHE_PATH="$ROOT/.runtime/cache/cuda" CCACHE_DIR="$ROOT/.runtime/cache/ccache"
    export HF_HOME="$ROOT/.runtime/cache/huggingface"
    export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub" HF_HUB_CACHE="$HF_HOME/hub"
}
