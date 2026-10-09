#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JOBS=${JOBS:-4}
SKIP_BUILD=0
FORCE_RUN=0
usage() {
    cat <<'HELP'
Usage: bash setup.sh [--jobs N] [--skip-build] [--force-run-script]
Build the checked-out source into ./bin/ds4-server and generate ./run.sh.
Defaults: CUDA_ARCH=native, JOBS=4; run.sh uses port 8000 and model ID big.
--skip-build        Generate run.sh/directories without compiling (offline preview).
--force-run-script  Replace run.sh, backing up an existing script in ./logs/.
No sudo, package installation, model download, service registration or shell edits.
Run bash download.sh separately to fetch GGUF + coding sidecar + Engram.
Use bash download.sh to fetch weights and Engram into this checkout; see docs/LOCAL_SERVING.md.
HELP
}
while (($#)); do
    case "$1" in
        --jobs) [[ $# -ge 2 ]] || { echo '--jobs requires N' >&2; exit 2; }; JOBS=$2; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --force-run-script) FORCE_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be a positive integer' >&2; exit 2; }
[[ $(uname -s) == Linux ]] || { echo 'This setup script targets Linux / DGX Spark.' >&2; exit 1; }
for cmd in realpath mkdir cp mv chmod cmp flock; do
    command -v "$cmd" >/dev/null || { printf 'Required command missing: %s\n' "$cmd" >&2; exit 1; }
done
source "$ROOT/scripts/local-env.sh"
youngai_local_env
cd -- "$ROOT"
exec 9>"$ROOT/.runtime/setup.lock"
flock -n 9 || { echo 'Another setup is running in this checkout.' >&2; exit 1; }
if (( ! SKIP_BUILD )); then
    command -v make >/dev/null || { echo 'GNU make is required.' >&2; exit 1; }
    if [[ -n ${NVCC:-} ]]; then
        NVCC=$(command -v -- "$NVCC") || { echo 'NVCC is not executable.' >&2; exit 1; }
    elif command -v nvcc >/dev/null; then
        NVCC=$(command -v nvcc)
    else
        NVCC="${CUDA_HOME:-/usr/local/cuda}/bin/nvcc"
    fi
    [[ -x "$NVCC" ]] || { echo 'CUDA toolkit/nvcc is required; nothing was installed globally.' >&2; exit 1; }
    CUDA_HOME=${CUDA_HOME:-$(dirname -- "$(dirname -- "$(readlink -f -- "$NVCC")")")}
    printf 'Building checked-out source. Log: %s/logs/build.log\n' "$ROOT"
    # Force rebuild: the upstream Makefile does not track every added local header.
    # The current cuda-spark target uses these same native architecture flags.
    make -B -j "$JOBS" ds4-server CUDA_ARCH="${CUDA_ARCH:-native}" \
        CUDA_HOME="$CUDA_HOME" NVCC="$NVCC" 2>&1 | tee "$ROOT/logs/build.log"
    [[ -x "$ROOT/ds4-server" ]] || { echo 'Build did not produce ds4-server.' >&2; exit 1; }
    target=$(youngai_local_path "$ROOT/bin/ds4-server")
    cp -- "$ROOT/ds4-server" "$ROOT/bin/.ds4-server.new"
    chmod 755 "$ROOT/bin/.ds4-server.new"
    mv -f -- "$ROOT/bin/.ds4-server.new" "$target"
    rm -- "$ROOT/ds4-server"
fi
run=$(youngai_local_path "$ROOT/run.sh")
if [[ -e "$run" ]] && ! cmp -s "$ROOT/scripts/run.sh.in" "$run" && (( ! FORCE_RUN )); then
    pending=$(youngai_local_path "$ROOT/run.sh.new")
    cp -- "$ROOT/scripts/run.sh.in" "$pending"
    chmod 755 "$pending"
    printf 'Kept existing run.sh; review generated run.sh.new or use --force-run-script.\n'
else
    if [[ -e "$run" ]] && ! cmp -s "$ROOT/scripts/run.sh.in" "$run"; then
        cp -- "$run" "$ROOT/logs/run.sh.backup.$(date +%Y%m%dT%H%M%S)"
    fi
    cp -- "$ROOT/scripts/run.sh.in" "$run"
    chmod 755 "$run"
fi
printf 'Root: %s\nBinary: %s/bin/ds4-server\nLauncher: %s/run.sh\n' "$ROOT" "$ROOT" "$ROOT"
printf 'Defaults: HOST=127.0.0.1 PORT=8000 SERVED_MODEL_NAME=big\n'
printf 'Weights were NOT downloaded. Run bash download.sh to fetch them.\n'
printf 'Preview: ./run.sh --dry-run\nGuide: docs/LOCAL_SERVING.md\n'
