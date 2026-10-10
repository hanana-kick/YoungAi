#!/usr/bin/env node
// Audit translatable Chinese string literals in production code.
// Comments are excluded. Lint reports candidates; not every Han literal is a log
// (e.g. model prompts and multilingual query triggers must remain unchanged).
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const EXCLUDED = new Set(['.git','.runtime','node_modules','docs','tests','notes','reports','papers','.github','logs','weights','engram','bin','speed-bench','competition','misc']);
const EXTENSIONS = new Set(['.c','.h','.cu','.inc','.m','.metal','.cc','.cpp','.sh']);
const HAN = /[\u3400-\u9fff]/u;
const files=[];
function walk(dir) {
  for (const ent of fs.readdirSync(dir, {withFileTypes:true})) {
    if (ent.isSymbolicLink()) continue;
    const pathname=path.join(dir,ent.name);
    if (ent.isDirectory()) { if (!EXCLUDED.has(ent.name)) walk(pathname); }
    else if (ent.isFile() && EXTENSIONS.has(path.extname(ent.name)) && ent.name !== 'audit-runtime-language.js')
      files.push(pathname);
  }
}
walk(ROOT);

let found=0, total=0;
for (const filepath of files.sort()) {
  const text=fs.readFileSync(filepath,'utf8');
  const lines=text.split('\n');
  let line=1, i=0, state='code', start=0, lit='', delim='', escape=false;
  while (i<text.length) {
    const ch=text[i], next=text[i+1];
    if (state==='code') {
      if (ch==='/' && next==='/') { state='linecomment'; i+=2; continue; }
      if (ch==='/' && next==='*') { state='blockcomment'; i+=2; continue; }
      if (ch==='#' && path.extname(filepath)==='.sh' && (i===0 || text[i-1]==='\n' || /\s/.test(text[i-1]))) {
        state='linecomment'; ++i;continue;
      }
      if (ch==='"' || ch==="'") {
        if (ch==="'" && path.extname(filepath)!=='.sh') { state='char'; delim=ch; escape=false; ++i;continue; }
        state='string'; start=line;lit='';delim=ch;escape=false;++i;continue;
      }
    } else if (state==='string' || state==='char') {
      if (escape) {lit+=ch; escape=false;++i;continue;}
      if (ch==='\\') {lit+=ch;escape=true;++i;continue;}
      if (ch===delim) {
        if (state==='string' && HAN.test(lit)) {
          const context=lines[start-1].trim().slice(0,200).replace(/\s+/g,' ');
          process.stdout.write(path.relative(ROOT,filepath)+':'+start+'\t'+JSON.stringify(lit.slice(0,240))+'\t'+JSON.stringify(context)+'\n');
          ++found;
        }
        state='code'; ++i;continue;
      }
      lit+=ch;
    } else if (state==='linecomment') {
      if (ch==='\n') state='code';
    } else if (state==='blockcomment') {
      if (ch==='*'&&next==='/') {state='code';i+=2;continue;}
    }
    if (ch==='\n') ++line;
    ++i;
  }
  ++total;
}
process.stdout.write('AUDIT_END files='+total+' Chinese_literals='+found+'\n');
