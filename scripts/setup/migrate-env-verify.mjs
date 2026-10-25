#!/usr/bin/env node
// migrate-env-verify.mjs — the node half of migrate-env.sh's verify step.
//
//   node migrate-env-verify.mjs <scratch repo> <.env> <empty home> <home> <himmel root> KEY...
//
// Runs each node reader of the behaviour keys twice in the scratch checkout:
// once with the keys only in .env (a copy in the scratch repo, HOME empty),
// once with them only in their new place (HOME, an empty .env). Prints
// `MISMATCH <key> (<reader>)` for every difference or throw and exits 1; then
// `readers: <names>`. Values are compared as digests and never printed.
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [repo, dotenv, emptyHome, home, root, ...keys] = process.argv.slice(2);

// A reader that throws proves nothing, so a throw never compares equal.
const digest = (read) => {
  try { return `ok:${createHash('sha256').update(String(read() ?? '')).digest('hex')}`; } catch { return 'throw'; }
};
// A reader that is missing cannot be checked, so the move stops instead of skipping it.
const load = async (path, missing) => {
  if (!existsSync(path)) {
    console.log(`verify: ${missing}`);
    process.exit(1);
  }
  return import(pathToFileURL(path).href);
};

const readers = [];
try {
  const jira = join(root, 'scripts/jira/dist');
  const unbuilt = 'the Jira CLI is not built (scripts/jira/dist); build it, then run the migration again';
  const { behaviourKey, handoverRoot } = await load(join(jira, 'handover-root.js'), unbuilt);
  readers.push(['jira config reader', (env) => keys.map((k) => [k, digest(() => behaviourKey(k, env))])]);
  if (keys.includes('HANDOVER_DIR')) {
    readers.push(['jira handover root', (env) => [['HANDOVER_DIR', digest(() => handoverRoot(env))]]]);
  }
  // The release root is the handover root plus USER_SLUG and throws without
  // the slug, so it checks USER_SLUG; HANDOVER_DIR is the handover root's.
  if (keys.includes('USER_SLUG')) {
    const { releaseRoot } = await load(join(jira, 'release/paths.js'), unbuilt);
    readers.push(['jira release state', (env) => [['USER_SLUG', digest(() => releaseRoot(env))]]]);
  }
  const { buildCtx } = await load(join(root, 'scripts/lanes/resolve.mjs'), 'scripts/lanes/resolve.mjs is missing');
  readers.push(['lanes resolve', (env) => {
    const ctx = buildCtx(repo, env);
    return keys.map((k) => [k, digest(() => ctx.env[k])]);
  }]);
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
  const a = after.get(id);
  if (a === d && d !== 'throw') continue;
  const [k, name] = id.split('\t');
  console.log(`MISMATCH ${k} (${name}${d === 'throw' || a === 'throw' ? ', the reader threw' : ''})`);
  failed = true;
}
console.log(`readers: ${readers.map(([name]) => name).join(', ')}`);
process.exit(failed ? 1 : 0);
