#!/usr/bin/env node
// migrate-env-verify.mjs — the node half of migrate-env.sh's verify step.
//
//   node migrate-env-verify.mjs <scratch repo> <.env> <empty home> <home> <himmel root> KEY...
//
// Runs each node reader of the behaviour keys twice in the scratch checkout:
// once with the keys only in .env (a copy in the scratch repo, HOME empty),
// once with them only in their new place (HOME, an empty .env). Prints
// `MISMATCH <key> (<reader>)` for every difference and exits 1; then
// `readers: <names>`. Values are compared as digests and never printed.
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [repo, dotenv, emptyHome, home, root, ...keys] = process.argv.slice(2);

const digest = (read) => {
  let v;
  try { v = `ok:${read() ?? ''}`; } catch (e) { v = `throw:${e.message}`; }
  return createHash('sha256').update(v).digest('hex');
};
const load = async (path) => import(pathToFileURL(path).href);

const readers = [];
try {
  const jira = join(root, 'scripts/jira/dist');
  if (existsSync(join(jira, 'handover-root.js'))) {
    const { behaviourKey, handoverRoot } = await load(join(jira, 'handover-root.js'));
    readers.push(['jira config reader', (env) => keys.map((k) => [k, digest(() => behaviourKey(k, env))])]);
    if (keys.includes('HANDOVER_DIR')) {
      readers.push(['jira handover root', (env) => [['HANDOVER_DIR', digest(() => handoverRoot(env))]]]);
    }
    const slugKey = ['USER_SLUG', 'HANDOVER_DIR'].find((k) => keys.includes(k));
    if (slugKey && existsSync(join(jira, 'release/paths.js'))) {
      const { releaseRoot } = await load(join(jira, 'release/paths.js'));
      readers.push(['jira release state', (env) => [[slugKey, digest(() => releaseRoot(env))]]]);
    }
  }
  const lanes = join(root, 'scripts/lanes/resolve.mjs');
  if (existsSync(lanes)) {
    const { buildCtx } = await load(lanes);
    readers.push(['lanes resolve', (env) => {
      const ctx = buildCtx(repo, env);
      return keys.map((k) => [k, digest(() => ctx.env[k])]);
    }]);
  }
} catch (e) {
  console.log(`verify: a node reader failed to load (${e.code || e.name})`);
  process.exit(1);
}

const snapshot = (h) => {
  const out = new Map();
  for (const [name, read] of readers) {
    for (const [k, d] of read({ HOME: h, PATH: process.env.PATH })) out.set(`${k}\t${name}`, d);
  }
  return out;
};

process.chdir(repo);
copyFileSync(dotenv, join(repo, '.env'));
const before = snapshot(emptyHome);
writeFileSync(join(repo, '.env'), '');
const after = snapshot(home);

let failed = false;
for (const [id, d] of before) {
  if (after.get(id) === d) continue;
  const [k, name] = id.split('\t');
  console.log(`MISMATCH ${k} (${name})`);
  failed = true;
}
console.log(`readers: ${readers.map(([name]) => name).join(', ')}`);
process.exit(failed ? 1 : 0);
