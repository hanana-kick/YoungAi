#!/usr/bin/env bash
# Download YoungAi V4.1 GGUF, the coding sidecar, and official Engram shards.
# No Python, HF CLI, global caches, symlinks outside this checkout, or service setup.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
MODE=all
SKIP_SPACE_CHECK=0

usage() {
    cat <<'HELP'
Usage: bash download.sh [all|model|sidecar|engram] [--skip-space-check]
Downloads into the checkout: weights/ (GGUF + coding sidecar), engram/ (two shards).
Default: all. Interrupted transfers/assembly can be resumed by running again.
--skip-space-check: bypass the conservative free-space preflight (use with care).
Environment: HF_ENDPOINT=https://huggingface.co (optional mirror).
Nothing is installed globally; no upstream install.sh or Python is executed.
HELP
}
for arg in "$@"; do
    case "$arg" in
        all|model|sidecar|engram) MODE=$arg ;;
        --skip-space-check) SKIP_SPACE_CHECK=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

for cmd in bash curl jq sha256sum awk stat truncate df flock realpath mkdir mv; do
    command -v "$cmd" >/dev/null || { printf 'Missing required command: %s\n' "$cmd" >&2; exit 1; }
done
source "$ROOT/scripts/local-env.sh"
youngai_local_env
mkdir -p "$ROOT/.runtime/download"
exec 9>"$ROOT/.runtime/download/download.lock"
flock -n 9 || { echo 'Another download.sh is active in this checkout.' >&2; exit 1; }

HF_ENDPOINT=${HF_ENDPOINT:-https://huggingface.co}
HF_ENDPOINT=${HF_ENDPOINT%/}
YOUNGAI_REPO=wenzhouwu/YoungAi-DeepSeek-V4.1-Flash
DEEPSEEK_REPO=deepseek-ai/DeepSeek-V4.1-Flash
MODEL=DeepSeek-V4.1-Flash-vq8sh14-q4k-mtpnative.gguf
SIDECAR=DeepSeek-V4.1-Flash-vq8sh14-q4k-mtpnative-grrb-code_fit_n15360-engine
WEIGHTS="$ROOT/weights"
ENGRAM="$ROOT/engram"
STATE="$ROOT/.runtime/download"
EXPECTED_MODEL_BYTES=113556639424
SHARDS=(model-00047-of-00048.safetensors model-00048-of-00048.safetensors)

die() { printf 'download.sh: %s\n' "$*" >&2; exit 1; }
safe_path() { youngai_local_path "$1"; }

# Metadata is small; never execute downloaded content.
fetch_json() {
    local url=$1 out=$2
    out=$(safe_path "$out") || return 1
    curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
        --connect-timeout 30 --output "$out" "$url" || return 1
    jq -e . "$out" >/dev/null || die "Invalid JSON from $url"
}
revision() {
    local repo=$1 label=$2 file rev tmp
    file=$(safe_path "$STATE/$label.revision") || return 1
    if [[ -s "$file" ]]; then
        rev=$(cat -- "$file")
    else
        tmp=$(safe_path "$STATE/$label.metadata.json") || return 1
        fetch_json "$HF_ENDPOINT/api/models/$repo" "$tmp"
        rev=$(jq -er '.sha | select(test("^[0-9a-f]{40}$"))' "$tmp") ||
            die "Could not resolve revision for $repo"
        printf '%s\n' "$rev" >"$file.new"
        mv -- "$file.new" "$file"
        rm -f -- "$tmp"
    fi
    [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || die "Invalid pinned revision: $file"
    printf '%s\n' "$rev"
}
resolve_url() {
    printf '%s/%s/resolve/%s/%s\n' "$HF_ENDPOINT" "$1" "$2" "$3"
}
valid_file() {
    local file=$1 expected_size=${2:-} expected_sha=${3:-} actual
    [[ -f "$file" && ! -L "$file" ]] || return 1
    if [[ -n "$expected_size" ]]; then
        [[ $(stat -c %s -- "$file") == "$expected_size" ]] || return 1
    fi
    if [[ -n "$expected_sha" ]]; then
        actual=$(sha256sum -- "$file")
        [[ "${actual%% *}" == "$expected_sha" ]] || return 1
    fi
}
# Files are downloaded to *.download and atomically published after verification.
# Failed network transfers keep their partial bytes for the next run.
download_file() {
    local url=$1 dest=$2 size=${3:-} sha=${4:-} tmp attempt
    dest=$(safe_path "$dest") || return 1
    tmp=$(safe_path "$dest.download") || return 1
    mkdir -p -- "$(dirname -- "$dest")"
    if [[ -e "$dest" || -L "$dest" ]]; then
        valid_file "$dest" "$size" "$sha" && return 0
        die "Existing file failed verification (not overwritten): $dest"
    fi
    for attempt in 1 2; do
        printf 'Downloading %s (attempt %s)\n' "${dest#"$ROOT"/}" "$attempt"
        curl --fail --location --retry 8 --retry-all-errors --retry-delay 3 \
            --connect-timeout 30 --progress-bar --continue-at - \
            --output "$tmp" "$url" ||
            die "Transfer interrupted; partial file preserved: $tmp"
        if valid_file "$tmp" "$size" "$sha"; then
            mv -- "$tmp" "$dest"
            return 0
        fi
        printf 'Verification failed for %s; retrying from zero.\n' "$dest" >&2
        rm -f -- "$tmp"
    done
    die "Repeated verification failure: $dest"
}
checksum_for() {
    local filename=$1 val
    val=$(awk -v name="$filename" '$2 == name || $2 == "*" name {print $1; exit}' "$WEIGHTS/SHA256SUMS")
    [[ "$val" =~ ^[0-9a-f]{64}$ ]] || die "Missing/invalid SHA256 for $filename in SHA256SUMS"
    printf '%s\n' "$val"
}
# The check uses actual repository sizes when available, otherwise the published
# model size, and includes extra space for one in-flight GGUF part and overhead.
available_bytes() {
    df -B1 --output=avail "$ROOT" | tail -n 1 | tr -d '[:space:]'
}
bytes_present() {
    local path=$1
    [[ -f "$path" && ! -L "$path" ]] && stat -c %s -- "$path" || printf '0\n'
}
preflight() {
    (( SKIP_SPACE_CHECK )) && return 0
    local needed=$1 available
    (( needed > 0 )) || return 0
    available=$(available_bytes)
    [[ "$available" =~ ^[0-9]+$ ]] || die "Cannot determine free disk space"
    if (( available < needed )); then
        printf 'Free disk: %s GB; estimated additional required: %s GB\n' \
            "$((available/1000000000))" "$((needed/1000000000))" >&2
        die "Insufficient free space. Choose a larger volume or use --skip-space-check."
    fi
}
model_remaining() {
    local current=0
    if [[ -f "$WEIGHTS/$MODEL" ]]; then
        current=$(bytes_present "$WEIGHTS/$MODEL")
    elif [[ -f "$WEIGHTS/$MODEL.assembling" ]]; then
        current=$(bytes_present "$WEIGHTS/$MODEL.assembling")
    fi
    (( current < EXPECTED_MODEL_BYTES )) && printf '%s\n' "$((EXPECTED_MODEL_BYTES-current))" || printf '0\n'
}
parse_index() {
    local file=$1 path=$2
    jq -er --arg path "$path" \
      '.[] | select(.type == "file" and .path == $path) | [.size, (.lfs.oid // "" | sub("^sha256:";""))] | @tsv' \
      "$file" | head -n 1
}
# Returns a pinned repo tree, not branch main; partial reruns never mix versions.
load_index() {
    local repo=$1 rev=$2 query=$3 out=$4
    fetch_json "$HF_ENDPOINT/api/models/$repo/tree/$rev$query" "$out"
    jq -e 'type == "array"' "$out" >/dev/null || die "Expected Hugging Face tree array"
}
MODEL_REV='' DEEPSEEK_REV='' ENGRAM_INDEX=''
if [[ "$MODE" == all || "$MODE" == model || "$MODE" == sidecar ]]; then
    MODEL_REV=$(revision "$YOUNGAI_REPO" youngai)
fi
if [[ "$MODE" == all || "$MODE" == engram ]]; then
    DEEPSEEK_REV=$(revision "$DEEPSEEK_REPO" deepseek)
    ENGRAM_INDEX=$(safe_path "$STATE/engram-index.json")
    load_index "$DEEPSEEK_REPO" "$DEEPSEEK_REV" '?recursive=false' "$ENGRAM_INDEX"
fi

# Determine exact Engram sizes from the official repository metadata.
ENGRAM_REMAINING=0
if [[ -n "$ENGRAM_INDEX" ]]; then
    for shard in "${SHARDS[@]}"; do
        row=$(parse_index "$ENGRAM_INDEX" "$shard") || die "Missing shard metadata: $shard"
        IFS=$'\t' read -r size sha <<<"$row"
        [[ "$size" =~ ^[1-9][0-9]*$ ]] || die "Invalid shard size for $shard"
        have=$(bytes_present "$ENGRAM/$shard")
        if (( have == 0 )); then have=$(bytes_present "$ENGRAM/$shard.download"); fi
        (( have < size )) && ENGRAM_REMAINING=$((ENGRAM_REMAINING+size-have))
    done
fi
MODEL_REMAINING=0
if [[ "$MODE" == all || "$MODE" == model ]]; then MODEL_REMAINING=$(model_remaining); fi
# Include margin only if something substantial remains to fetch.
if (( MODEL_REMAINING > 0 || ENGRAM_REMAINING > 0 )); then
    preflight "$((MODEL_REMAINING + ENGRAM_REMAINING + 9000000000))"
fi

download_model() {
    local sums final assembling progress n offset i part digest actual sz
    sums=$(safe_path "$WEIGHTS/SHA256SUMS")
    download_file "$(resolve_url "$YOUNGAI_REPO" "$MODEL_REV" SHA256SUMS)" "$sums"
    digest=$(checksum_for "$MODEL")
    final=$(safe_path "$WEIGHTS/$MODEL")
    assembling=$(safe_path "$WEIGHTS/$MODEL.assembling")
    progress=$(safe_path "$STATE/model-assembly.state")
    if [[ -e "$final" ]]; then
        valid_file "$final" "" "$digest" || die "Existing GGUF failed SHA256: $final"
        printf 'Verified complete model: %s\n' "$final"
        return 0
    fi

    n=0; offset=0
    if [[ -e "$progress" ]]; then
        read -r n offset <"$progress" || die "Invalid assembly progress"
        [[ "$n" =~ ^([0-9]|[1-3][0-9]|40)$ && "$offset" =~ ^[0-9]+$ ]] ||
            die "Corrupt assembly progress: $progress"
        [[ -f "$assembling" && ! -L "$assembling" ]] || die "Assembly progress exists without its data file"
        (( $(stat -c %s "$assembling") >= offset )) ||
            die "Assembly is shorter than its committed progress"
        truncate -s "$offset" "$assembling"  # discard any interrupted append
    else
        [[ ! -e "$assembling" ]] || die "Assembly data exists without progress file; inspect before retrying"
        : >"$assembling"
        printf '0 0\n' >"$progress"
    fi

    for ((i=n+1; i<=40; i++)); do
        printf -v part '%s.part%02d-of-40' "$MODEL" "$i"
        digest=$(checksum_for "$part")
        download_file "$(resolve_url "$YOUNGAI_REPO" "$MODEL_REV" "$part")" \
            "$WEIGHTS/$part" "" "$digest"
        sz=$(stat -c %s -- "$WEIGHTS/$part")
        cat -- "$WEIGHTS/$part" >>"$assembling"
        offset=$((offset+sz))
        (( $(stat -c %s "$assembling") == offset )) || die "Assembly size mismatch at part $i"
        printf '%s %s\n' "$i" "$offset" >"$progress.new"
        mv -- "$progress.new" "$progress"
        rm -- "$WEIGHTS/$part"  # keep only the assembled copy
        printf 'Assembled %02d/40\n' "$i"
    done
    digest=$(checksum_for "$MODEL")
    valid_file "$assembling" "" "$digest" || die "Assembled GGUF checksum mismatch (data preserved)"
    mv -- "$assembling" "$final"
    rm -f -- "$progress"
    printf 'Verified model: %s\n' "$final"
}

download_sidecar() {
    local index path size sha row count=0
    index=$(safe_path "$STATE/sidecar-index.json")
    load_index "$YOUNGAI_REPO" "$MODEL_REV" "/$SIDECAR?recursive=true" "$index"
    while IFS=$'\t' read -r path size sha; do
        [[ "$path" == "$SIDECAR/"* && "$path" != *'..'* ]] ||
            die "Unsafe path from model repository: $path"
        [[ "$size" =~ ^[0-9]+$ ]] || die "Invalid size in sidecar metadata: $path"
        [[ -z "$sha" || "$sha" =~ ^[0-9a-f]{64}$ ]] || die "Invalid sidecar SHA: $path"
        download_file "$(resolve_url "$YOUNGAI_REPO" "$MODEL_REV" "$path")" \
            "$WEIGHTS/$path" "$size" "$sha"
        count=$((count+1))
    done < <(jq -r --arg prefix "$SIDECAR/" \
        '.[] | select(.type == "file" and (.path | startswith($prefix))) |
         [.path, (.size | tostring), (.lfs.oid // "" | sub("^sha256:";""))] | @tsv' "$index")
    (( count > 0 )) || die "No coding sidecar files were returned by Hugging Face"
    [[ -s "$WEIGHTS/$SIDECAR/manifest.txt" ]] || die "Coding sidecar manifest.txt missing"
    printf 'Verified coding sidecar: %s (%s files)\n' "$WEIGHTS/$SIDECAR" "$count"
}
download_engram() {
    local shard row size sha
    for shard in "${SHARDS[@]}"; do
        row=$(parse_index "$ENGRAM_INDEX" "$shard") || die "Missing Engram index: $shard"
        IFS=$'\t' read -r size sha <<<"$row"
        [[ "$size" =~ ^[1-9][0-9]*$ ]] || die "Invalid shard size: $shard"
        [[ -z "$sha" || "$sha" =~ ^[0-9a-f]{64}$ ]] || die "Invalid shard SHA: $shard"
        download_file "$(resolve_url "$DEEPSEEK_REPO" "$DEEPSEEK_REV" "$shard")" \
            "$ENGRAM/$shard" "$size" "$sha"
        printf 'Verified Engram shard: %s\n' "$shard"
    done
}

case "$MODE" in
    all) download_model; download_sidecar; download_engram ;;
    model) download_model ;;
    sidecar) download_sidecar ;;
    engram) download_engram ;;
esac
printf 'Download complete. All managed data is under %s\n' "$ROOT"
