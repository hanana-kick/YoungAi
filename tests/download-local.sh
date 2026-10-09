#!/usr/bin/env bash
# Offline integration exercise of the downloader, with a tiny local HF fixture.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
for script in download.sh setup.sh scripts/local-env.sh; do bash -n "$ROOT/$script"; done
T=$(mktemp -d)
cleanup() {
    if [[ -n ${server_pid:-} ]]; then kill "$server_pid" 2>/dev/null || :; wait "$server_pid" 2>/dev/null || :; fi
    rm -rf -- "$T"
}
trap cleanup EXIT
C="$T/a movable checkout"
mkdir -p "$C/scripts"
cp "$ROOT/download.sh" "$C/download.sh"
cp "$ROOT/scripts/local-env.sh" "$C/scripts/local-env.sh"
cat >"$T/mock.js" <<'JS'
const http = require('node:http');
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const root = process.argv[2], portfile = process.argv[3];
const A = 'a'.repeat(40), B = 'b'.repeat(40);
const MODEL = 'DeepSeek-V4.1-Flash-vq8sh14-q4k-mtpnative.gguf';
const SIDE = 'DeepSeek-V4.1-Flash-vq8sh14-q4k-mtpnative-grrb-code_fit_n15360-engine';
const REPO = 'wenzhouwu/YoungAi-DeepSeek-V4.1-Flash';
const DREPO = 'deepseek-ai/DeepSeek-V4.1-Flash';
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const files = new Map();
const parts = [];
for(let i=1; i<=40; i++) {
    const name = MODEL + '.part' + String(i).padStart(2,'0') + '-of-40';
    const b = Buffer.from(('mock-base-' + i + '!').repeat(i % 4 + 1));
    parts.push(b);
    files.set(REPO + '/' + name, b);
}
const model = Buffer.concat(parts);
const sums = [sha(model) + '  ' + MODEL];
for (let i=1; i<=40; i++) {
    const name = MODEL + '.part' + String(i).padStart(2,'0') + '-of-40';
    sums.push(sha(parts[i-1]) + '  ' + name);
}
files.set(REPO + '/SHA256SUMS', Buffer.from(sums.join('\n')+'\n'));
const side = new Map([
    ['manifest.txt', 'mock domain sidecar\n'],
    ['gr_L01.bin', 'gr test data'],
    ['rb_L01.bin', 'rb test data'],
]);
for (const [name, value] of side) files.set(REPO + '/' + SIDE + '/' + name, Buffer.from(value));
const shards = ['model-00047-of-00048.safetensors','model-00048-of-00048.safetensors'];
for (const [i, name] of shards.entries()) {
    files.set(DREPO + '/' + name, Buffer.from(('Engram-' + (47+i)).repeat(257)));
}
const sideIndex = [...side.keys()].map(name => {
    const p = SIDE + '/' + name, b = files.get(REPO + '/' + p);
    return {path:p,type:'file',size:b.length,lfs:{sha256:sha(b)}};
});
const shardIndex = shards.map(name => {
    const b = files.get(DREPO + '/' + name);
    return {path:name,type:'file',size:b.length,lfs:{sha256:sha(b)}};
});
function send(res,code,body,headers={}) {
    const b = Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body));
    res.writeHead(code, {'Content-Length':b.length,...headers}); res.end(b);
}
const server = http.createServer((req,res) => {
    const u = new URL(req.url,'http://localhost'), p = decodeURIComponent(u.pathname);
    if (p === '/api/models/' + REPO) return send(res,200,{sha:A});
    if (p === '/api/models/' + DREPO) return send(res,200,{sha:B});
    if (p.startsWith('/api/models/' + REPO + '/tree/' + A + '/' + SIDE))
        return send(res,200,sideIndex);
    if (p.startsWith('/api/models/' + DREPO + '/tree/' + B))
        return send(res,200,shardIndex);
    const mark = '/resolve/';
    const mi = p.indexOf(mark);
    if (mi >= 0) {
        const repo = p.substring(1,mi);
        const tail = p.slice(mi+mark.length);
        const slash = tail.indexOf('/');
        const rev = tail.slice(0,slash), file = tail.slice(slash+1);
        if ((repo === REPO && rev !== A) || (repo === DREPO && rev !== B))
            return send(res,404,'wrong revision');
        const b = files.get(repo + '/' + file);
        if (!b) return send(res,404,'not found');
        const range = req.headers.range;
        if (range) {
            const m = /^bytes=(\d+)-$/.exec(range);
            if (!m || +m[1] >= b.length) {
                res.writeHead(416, {'Content-Range':'bytes */'+b.length}); res.end(); return;
            }
            return send(res,206,b.subarray(+m[1]),{
                'Content-Range': 'bytes '+m[1]+'-'+(b.length-1)+'/'+b.length,
                'Accept-Ranges':'bytes'
            });
        }
        return send(res,200,b,{'Accept-Ranges':'bytes'});
    }
    send(res,404,{error:'not found',p});
});
server.listen(0,'127.0.0.1',()=>fs.writeFileSync(portfile,String(server.address().port)));
JS
node "$T/mock.js" "$T" "$T/port" >"$T/server.out" 2>"$T/server.err" &
server_pid=$!
for i in {1..50}; do [[ -s "$T/port" ]] && break; sleep 0.1; done
[[ -s "$T/port" ]] || { cat "$T/server.err" >&2; exit 1; }
export HF_ENDPOINT="http://127.0.0.1:$(cat "$T/port")"
MODEL=DeepSeek-V4.1-Flash-vq8sh14-q4k-mtpnative.gguf
SIDE=DeepSeek-V4.1-Flash-vq8sh14-q4k-mtpnative-grrb-code_fit_n15360-engine
bash "$C/download.sh" all --skip-space-check >"$T/first.log" 2>&1 || { cat "$T/first.log" >&2; exit 1; }
[[ -s "$C/weights/$MODEL" ]]
[[ -s "$C/weights/$SIDE/manifest.txt" ]]
[[ -s "$C/engram/model-00047-of-00048.safetensors" ]]
[[ -s "$C/engram/model-00048-of-00048.safetensors" ]]
[[ $(ls "$C/weights" | grep -c '.part.*-of-40' || true) == 0 ]]
[[ $(cat "$C/.runtime/download/youngai.revision") == $(printf 'a%.0s' {1..40}) ]]
[[ $(cat "$C/.runtime/download/deepseek.revision") == $(printf 'b%.0s' {1..40}) ]]
bash "$C/download.sh" all --skip-space-check >"$T/second.log" 2>&1 || { cat "$T/second.log" >&2; exit 1; }
echo 'PASS: complete download, checksums, sidecar, Engram, and idempotent rerun'

# Reconstruct an interrupted append: truncate must discard the unfinished tail,
# resume from the recorded whole part, and produce the original checksum.
cp "$C/weights/$MODEL" "$T/original.gguf"
first=$(printf 'mock-base-1!%.0s' {1..2})
printf '%s' "$first" >"$C/weights/$MODEL.assembling"
len=$(stat -c %s "$C/weights/$MODEL.assembling")
printf 'TRUNCATE THIS TAIL' >>"$C/weights/$MODEL.assembling"
printf '1 %s\n' "$len" >"$C/.runtime/download/model-assembly.state"
rm -- "$C/weights/$MODEL"
bash "$C/download.sh" model --skip-space-check >"$T/resume.log" 2>&1 || { cat "$T/resume.log" >&2; exit 1; }
cmp "$C/weights/$MODEL" "$T/original.gguf"
echo 'PASS: interrupted GGUF append repaired at committed part boundary'

# Resume a partially downloaded shard using HTTP Range.
shard=model-00047-of-00048.safetensors
mv "$C/engram/$shard" "$T/original-shard"
head -c 15 "$T/original-shard" >"$C/engram/$shard.download"
bash "$C/download.sh" engram --skip-space-check >"$T/range.log" 2>&1 || { cat "$T/range.log" >&2; exit 1; }
cmp "$T/original-shard" "$C/engram/$shard"
echo 'PASS: interrupted Engram download resumed via HTTP Range'

# Same-sized content corruption is rejected by the published LFS SHA256.
printf X | dd of=\"$C/engram/$shard\" bs=1 seek=0 conv=notrunc status=none
if bash \"$C/download.sh\" engram --skip-space-check >\"$T/engram-corrupt.log\" 2>&1; then
    echo 'Expected Engram SHA256 verification failure' >&2; exit 1
fi
cp \"$T/original-shard\" \"$C/engram/$shard\"
echo 'PASS: Engram SHA256 rejects same-sized tampering'

# Refuse to overwrite an existing corrupted file.
printf BAD >>"$C/weights/$MODEL"
if bash "$C/download.sh" model --skip-space-check >"$T/corrupt.log" 2>&1; then
    echo 'Expected existing checksum failure' >&2; exit 1
fi
cp "$T/original.gguf" "$C/weights/$MODEL"
echo 'PASS: corrupted existing model refused'

# Refuse download destinations that resolve outside the checkout.
mv "$C/weights" "$T/outside-weights"
ln -s "$T/outside-weights" "$C/weights"
if bash "$C/download.sh" sidecar --skip-space-check >"$T/path.log" 2>&1; then
    echo 'Expected unsafe symlink rejection' >&2; exit 1
fi
echo 'PASS: external symlink rejected'
