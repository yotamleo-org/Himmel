#!/usr/bin/env bash
# Real fixture callers leave no owned directories,
# and the merge-on-green holder never forks after announcing readiness.
# Platform guard: bash + Node; the child-process observation is Linux-only.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
node - "$HERE/../.." <<'NODE'
const fs=require('fs'), path=require('path'), os=require('os'), cp=require('child_process'), assert=require('assert');
const repo=path.resolve(process.argv[2]), root=fs.mkdtempSync(path.join(fs.existsSync('/tmp')?'/tmp':os.tmpdir(),'fx-'));
let passed=0, failed=0;
function test(name, fn) { try { fn(); passed++; console.log('ok: '+name); } catch(e) { failed++; console.error('FAIL: '+name+' — '+e.message); } }
function dirs(dir) {
 const found=[];
 for(const entry of fs.readdirSync(dir,{withFileTypes:true}))if(entry.isDirectory()) {
  const p=path.join(dir,entry.name);found.push(p,...dirs(p));
 }
 return found;
}
function remove(dir) {
 fs.chmodSync(dir,0o700);
 for(const entry of fs.readdirSync(dir,{withFileTypes:true}))if(entry.isDirectory())remove(path.join(dir,entry.name));
 fs.rmSync(dir,{recursive:true,force:true});
}
// clean-sandbox's PATH is fixed, so a node installed elsewhere (macOS: Homebrew, the toolcache) would be
// invisible to the suite and the GO writer's ledger and disposition steps would die on it. Link the
// tools into root/bin and append that dir inside the sandbox, after the system dirs.
function sandbox(scratch,argv,opts,tools=[['node',process.execPath]]) {
 const bin=path.join(root,'bin');fs.mkdirSync(bin,{recursive:true});
 for(const [name,exe] of tools)if(!fs.existsSync(path.join(bin,name)))fs.symlinkSync(exe,path.join(bin,name));
 return cp.spawnSync('bash',[path.join(repo,'scripts/lib/clean-sandbox.sh'),'--scratch',scratch,'--','bash','-c','PATH="$PATH:$1"; shift; exec "$@"','_',bin,...argv],opts);
}
try {
 test('a sandboxed suite reaches a tool installed outside the sandbox PATH',()=>{
  const fake=path.join(root,'himmel-fx-tool');
  fs.writeFileSync(fake,'#!/bin/sh\necho fx-tool-ran\n',{mode:0o755});
  const r=sandbox(path.join(root,'tool'),['himmel-fx-tool'],{encoding:'utf8'},[['himmel-fx-tool',fake]]);
  assert.strictEqual(r.status,0,'tool exit '+r.status+'; '+r.stderr);
  assert(r.stdout.includes('fx-tool-ran'),'tool not run: '+r.stdout);
 });
 for(const [suite,prefix] of [
  ['scripts/lib/test-git-test-env.sh','himmel-git-empty-template.'],
  ['scripts/hooks/test-trigger-cr-on-pr-create.sh','himmel-git-empty-template.'],
  ['scripts/sync/test-repo-sync-cadence.sh','himmel-git-empty-template.'],
  ['scripts/handover/test-merge-on-green.sh','mog-'],
  ['scripts/test-lane-mirror-seed.sh','clean-sandbox.']
 ])test(suite+' EXIT removes every '+prefix+' fixture',()=>{
  // Keep Unix socket fixture paths below sockaddr_un's pathname limit: the root is under /tmp,
  // not os.tmpdir() (CI's TMPDIR is already /tmp/himmel-suite.XXXXXX deep).
  const scratch=path.join(root,String(passed+failed));
  const r=sandbox(scratch,['bash',path.join(repo,suite)],{cwd:repo,encoding:'utf8',timeout:300000,maxBuffer:16*1024*1024});
  assert.strictEqual(r.status,0,'suite exit '+r.status+'; '+(r.error||'')+'\n'+r.stdout+'\n'+r.stderr);
  const left=dirs(scratch).filter(p=>path.basename(p).startsWith(prefix));
  assert.strictEqual(left.length,0,'left '+left.length+' directories: '+left.slice(0,5).join(', '));
 });
 test('mog EXIT removes read-only subdirectories on an early failure',()=>{
  const source=fs.readFileSync(path.join(repo,'scripts/handover/test-merge-on-green.sh'),'utf8');
  const end=source.indexOf('MOG_HOME=$(mktemp -d');assert(end!==-1,'suite initialization boundary not found');
  const script=path.join(root,'mog-exit.sh'), scratch=path.join(root,'exit');
  fs.writeFileSync(script,source.slice(0,end)+`
mkdir -p "$TMPDIR/mog-run.readonly/locked"
printf fixture > "$TMPDIR/mog-run.readonly/locked/file"
chmod 500 "$TMPDIR/mog-run.readonly/locked"
exit 7
`);
  const r=sandbox(scratch,['bash',script],{encoding:'utf8'});
  assert.strictEqual(r.status,7,'cleanup must preserve the original failure status');
  assert.strictEqual(dirs(scratch).filter(p=>path.basename(p).startsWith('mog-')).length,0,'read-only mog fixture leaked');
 });
 if(process.platform==='linux')test('sleeper has no child after readiness and exits when marker disappears',()=>{
  const source=fs.readFileSync(path.join(repo,'scripts/handover/test-merge-on-green.sh'),'utf8');
  const body=source.match(/cat > "\$SUITE_HOLDER_DIR\/sleeper\.sh" <<'SHEOF'\n([\s\S]*?)\nSHEOF/);
  assert(body,'sleeper fixture not found');
  const script=path.join(root,'sleeper.sh'), ready=path.join(root,'ready');
  fs.writeFileSync(script,body[1]+'\n');
  const fifo=cp.spawnSync('mkfifo',[ready+'.idle']);assert.strictEqual(fifo.status,0,'idle FIFO setup');
  // The controller blocks only itself; the holder runs in a separate process.
  const controller=`
const fs=require('fs'),cp=require('child_process'),assert=require('assert');
const [script,ready,cwd]=process.argv.slice(1), child=cp.spawn('bash',[script,ready],{cwd,stdio:'ignore'});
const children='/proc/'+child.pid+'/task/'+child.pid+'/children';
function pause(){Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,5);}
try {
 const end=Date.now()+3000;while(!fs.existsSync(ready)&&Date.now()<end)pause();
 assert(fs.existsSync(ready),'holder did not announce readiness');
 for(let i=0;i<40;i++){assert.strictEqual(fs.readFileSync(children,'utf8').trim(),'','holder forked after readiness');pause();}
 fs.unlinkSync(ready);
 const stop=Date.now()+3000;
 while(fs.existsSync('/proc/'+child.pid+'/stat')&&Date.now()<stop){
  if(fs.readFileSync('/proc/'+child.pid+'/stat','utf8').split(') ')[1].startsWith('Z '))break;
  pause();
 }
 assert(!fs.existsSync('/proc/'+child.pid+'/stat')||fs.readFileSync('/proc/'+child.pid+'/stat','utf8').split(') ')[1].startsWith('Z '),'holder did not stop');
} finally {child.kill();}
`;
  const r=cp.spawnSync(process.execPath,['-e',controller,script,ready,root],{encoding:'utf8',timeout:10000});
  assert.strictEqual(r.status,0,r.stderr);
 });
} finally { remove(root); }
console.log(passed+' passed; '+failed+' failed');process.exit(failed?1:0);
NODE
