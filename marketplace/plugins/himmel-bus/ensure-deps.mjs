import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

export const NPM_DEADLINE_MS = 20000;

export function deadlineFrom(env) {
  const raw = env.ENSURE_DEPS_NPM_TIMEOUT_MS;
  return /^[1-9]\d*$/.test(raw ?? '') ? Number(raw) : NPM_DEADLINE_MS;
}

const say = line => process.stderr.write(`ensure-deps: ${line}\n`);

function readVersion(file, fsImpl) {
  try { return JSON.parse(fsImpl.readFileSync(file, 'utf8')).version ?? null; } catch { return null; }
}

export function findDifference(dir, fsImpl = fs) {
  const lock = JSON.parse(fsImpl.readFileSync(path.join(dir, 'package-lock.json'), 'utf8'));
  for (const [key, entry] of Object.entries(lock.packages ?? {})) {
    if (key === '' || entry.dev === true) continue;
    const have = readVersion(path.join(dir, key, 'package.json'), fsImpl);
    if (have !== entry.version) return { name: key.replace(/^node_modules\//, ''), installed: have ?? 'missing', lock: entry.version };
  }
  return null;
}

function quietRm(fsImpl, target) {
  try { fsImpl.rmSync(target, { recursive: true, force: true }); } catch {}
}

export function swap(dir, stage, pid, fsImpl = fs) {
  const live = path.join(dir, 'node_modules');
  const old = path.join(dir, `.ensure-deps.old.${pid}`);
  const done = result => {
    quietRm(fsImpl, stage);
    if (result !== 'failed' && (result !== 'restored' || fsImpl.existsSync(live))) quietRm(fsImpl, old);
    return result;
  };
  if (findDifference(dir, fsImpl) === null) return done('skipped');
  try {
    fsImpl.renameSync(live, old);
  } catch (error) {
    if (error.code !== 'ENOENT') return done('failed');
  }
  try {
    fsImpl.renameSync(path.join(stage, 'node_modules'), live);
  } catch (error) {
    if (error.code === 'ENOTEMPTY' || error.code === 'EEXIST') return done('kept-other');
    if (!fsImpl.existsSync(live)) {
      try { fsImpl.renameSync(old, live); } catch {}
    }
    return done('restored');
  }
  return done('swapped');
}

export function sweep(dir, fsImpl = fs) {
  const live = path.join(dir, 'node_modules');
  for (const name of fsImpl.readdirSync(dir)) {
    const m = /^\.ensure-deps\.(?:stage|old)\.(\d+)$/.exec(name);
    if (!m) continue;
    const pid = Number(m[1]);
    let dead = pid === process.pid;
    if (!dead) {
      try { process.kill(pid, 0); } catch (error) { dead = error.code === 'ESRCH'; }
    }
    if (!dead) continue;
    const target = path.join(dir, name);
    if (name.startsWith('.ensure-deps.old.') && !fsImpl.existsSync(live)) {
      try { fsImpl.renameSync(target, live); } catch {}
      continue;
    }
    quietRm(fsImpl, target);
  }
}

function main(dir) {
  const first = findDifference(dir);
  if (first === null) return 0;
  say(`${first.name} installed ${first.installed}, lock ${first.lock}: installing`);
  try { sweep(dir); } catch {}
  const stage = path.join(dir, `.ensure-deps.stage.${process.pid}`);
  const fail = reason => { say(`install failed: ${reason}`); quietRm(fs, stage); return 1; };
  fs.mkdirSync(stage);
  for (const file of ['package.json', 'package-lock.json', '.npmrc']) {
    if (fs.existsSync(path.join(dir, file))) fs.copyFileSync(path.join(dir, file), path.join(stage, file));
  }
  const timeout = deadlineFrom(process.env);
  const run = spawnSync('npm', ['ci', '--prefix', stage, '--no-audit', '--no-fund', '--silent'], {
    cwd: stage,
    stdio: ['ignore', 2, 2],
    timeout,
    killSignal: 'SIGKILL',
  });
  if (run.error?.code === 'ETIMEDOUT') return fail(`npm did not finish within ${timeout} ms`);
  if (run.error) return fail(run.error.message);
  if (run.status !== 0) return fail(`npm exited ${run.status ?? run.signal}`);
  const staged = findDifference(stage);
  if (staged) return fail(`staged tree differs: ${staged.name} installed ${staged.installed}, lock ${staged.lock}`);
  const result = swap(dir, stage, process.pid);
  if (result === 'failed' || result === 'restored') return fail(`swap ${result}`);
  const after = findDifference(dir);
  if (after) return fail(`${after.name} installed ${after.installed}, lock ${after.lock} after swap`);
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let code = 1;
  try { code = main(path.dirname(fileURLToPath(import.meta.url))); } catch (error) { say(`install failed: ${error.message}`); }
  process.exit(code);
}
