#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$ROOT"
mkdir -p "$ROOT/.runtime/tmp"
T=$(mktemp -d "$ROOT/.runtime/tmp/local-serving.XXXXXXXX")
trap 'rm -rf -- "$T"' EXIT
for file in setup.sh scripts/local-env.sh scripts/run.sh.in; do bash -n "$file"; done
CC=${CC:-cc}
"$CC" -std=c99 -Wall -Wextra -Werror -I. tests/model_info_test.c \
    src/server/server_model_info.c -o "$T/model-info"
"$T/model-info"
[[ $("$T/model-info" --served-model-name big) == big ]]
[[ $("$T/model-info" --served-model-name=org/coder) == org/coder ]]
expect_failure() {
    local expected=$1 actual=0; shift
    "$@" >"$T/rejected.out" 2>&1 || actual=$?
    [[ "$actual" == "$expected" ]] || { cat "$T/rejected.out" >&2; echo "Expected exit $expected, got $actual" >&2; exit 1; }
}
expect_failure 2 "$T/model-info" --served-model-name
expect_failure 2 "$T/model-info" --served-model-name ''
expect_failure 2 "$T/model-info" '--served-model-name=not a model'
expect_failure 2 "$T/model-info" --served-model-name "$(printf '%0201d' 0)"
printf 'PASS: invalid and missing model names\n'
# Compile the actual model serialization functions, without loading the engine.
awk '/^static void append_model_json_full\(/ {copy=1} /^static void client_done\(/ {copy=0} copy' \
    src/server/server_httpd.c >"$T/model_json.inc"
"$CC" -std=c99 -Wall -Wextra -Werror -I. -I"$T" tests/model_json_test.c \
    src/server/server_model_info.c -o "$T/model-json"
"$T/model-json" >"$T/models.jsonl"
node - "$T/models.jsonl" <<'JS'
const fs = require('node:fs'), assert = require('node:assert/strict');
const [list, one, limited, defaultLimited] = fs.readFileSync(process.argv[2], 'utf8').trim().split('\n').map(JSON.parse);
assert.equal(list.object, 'list'); assert.equal(list.data.length, 1);
assert.deepEqual(list.data[0], one);
assert.equal(one.id, 'big'); assert.equal(one.object, 'model');
assert.equal(typeof one.owned_by, 'string'); assert(Number.isInteger(one.created) && one.created > 0);
assert.equal(one.shutdown_date, null); assert.equal(one.parent, null);
assert.equal(one.name, 'GGUF "model"'); assert.equal(one.root, 'model_info_test.c');
assert.equal(one.context_length, 4096); assert.equal(one.max_model_len, 4096);
assert.equal(one.max_completion_tokens, 4096); assert.equal(one.default_max_tokens, 128);
assert.equal(limited.data[0].max_completion_tokens, 512);
assert.equal(limited.data[0].top_provider.max_completion_tokens, 512);
assert.equal(defaultLimited.data[0].default_max_tokens, 512);
assert(one.supported_parameters.includes('tools') && one.supported_parameters.includes('stream'));
console.log('PASS: production model JSON, singleton listing, escaping and real token caps');
JS
F="$T/source checkout"
mkdir -p "$F/scripts" "$T/tools"
cp setup.sh "$F/"
cp scripts/local-env.sh scripts/run.sh.in "$F/scripts/"
cat >"$T/tools/nvcc" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$T/tools/make" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >make.args
cat >ds4-server <<'SERVER'
#!/usr/bin/env bash
printf 'HOME=%s\nCUDA_CACHE_PATH=%s\n' "$HOME" "$CUDA_CACHE_PATH"
printf '<%s>\n' "$@"
SERVER
chmod +x ds4-server
STUB
chmod +x "$T/tools/"*
PATH="$T/tools:$PATH" NVCC="$T/tools/nvcc" bash "$F/setup.sh" >"$T/setup.out"
[[ -x "$F/bin/ds4-server" && -x "$F/run.sh" && ! -e "$F/ds4-server" ]]
grep -qx ds4-server "$F/make.args"
grep -qx CUDA_ARCH=native "$F/make.args"
"$F/run.sh" --dry-run >"$T/preview"
grep -q -- '--port 8000 --served-model-name big' "$T/preview"
printf 'PASS: source build invocation, local binary and generated defaults\n'
printf '\n# user customization\n' >>"$F/run.sh"
cp "$F/run.sh" "$T/edited"
bash "$F/setup.sh" --skip-build > /dev/null
cmp "$F/run.sh" "$T/edited"
[[ -x "$F/run.sh.new" ]]
bash "$F/setup.sh" --skip-build --force-run-script > /dev/null
cmp "$F/run.sh" "$F/scripts/run.sh.in"
compgen -G "$F/logs/run.sh.backup.*" >/dev/null
printf 'PASS: rerun preserves edits; explicit replacement makes a local backup\n'
M="$T/relocated checkout"
mv "$F" "$M"
"$M/run.sh" --dry-run >"$T/preview"
! grep -Fq 'source\\ checkout' "$T/preview"
printf x >"$M/weights/DeepSeek-V4.1-Flash-vq8sh14-q4k-mtpnative.gguf"
for n in 47 48; do printf x >"$M/engram/model-000${n}-of-00048.safetensors"; done
ZCHAIN_DIR='' PORT=8002 SERVED_MODEL_NAME=coder BATCH=2 "$M/run.sh" >"$T/args"
grep -Fxq "HOME=$M/.runtime/home" "$T/args"
grep -Fxq "CUDA_CACHE_PATH=$M/.runtime/cache/cuda" "$T/args"
grep -Fxq '<coder>' "$T/args"; grep -Fxq '<8002>' "$T/args"
expect_failure 2 env PORT=65536 "$M/run.sh" --dry-run
expect_failure 2 env BATCH=9 "$M/run.sh" --dry-run
expect_failure 2 env SERVED_MODEL_NAME='bad name' "$M/run.sh" --dry-run
expect_failure 1 env MODEL_FILE="$T/external.gguf" "$M/run.sh" --dry-run
mv "$M/weights" "$T/external-weights"
ln -s "$T/external-weights" "$M/weights"
expect_failure 1 "$M/run.sh" --dry-run
printf 'PASS: relocation, environment overrides, local caches and path/argument validation\n'
printf 'All local-serving tests passed. No real GPU or model was used.\n'
