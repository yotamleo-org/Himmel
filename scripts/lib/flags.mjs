#!/usr/bin/env node
// scripts/lib/flags.mjs — the Node reader of scripts/lib/flags.tsv.
//
//   import { himmelFlag } from './flags.mjs';    // himmelFlag('chain_soft_edges') -> boolean
//   node scripts/lib/flags.mjs chain_soft_edges  // exit 0 on, 1 off, 2 unknown or invalid
//
// Same rules as flags.sh: HIMMEL_FLAG_<NAME> in the environment, then himmel.conf.local, then
// himmel.conf under HIMMEL_CONFIG_DIR (default ~/.himmel), then the registry default; never .env.
// HIMMEL_FLAGS_TSV points at another registry. An unknown name throws.
import { readFileSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

function confValue(key) {
  const dir = process.env.HIMMEL_CONFIG_DIR || join(homedir(), '.himmel');
  for (const fn of ['himmel.conf.local', 'himmel.conf']) {
    let text;
    try {
      text = readFileSync(join(dir, fn), 'utf8');
    } catch {
      continue; // swallow-ok: a missing layer falls through to the next one
    }
    for (const raw of text.split('\n')) {
      const line = raw.replace(/\r$/, '');
      if (!line.trim() || line.trimStart().startsWith('#') || !line.includes('=')) continue;
      const i = line.indexOf('=');
      if (line.slice(0, i).trim() !== key) continue;
      let v = line.slice(i + 1).trim();
      if ((v[0] === '"' || v[0] === "'") && v.indexOf(v[0], 1) > 0) v = v.slice(1, v.indexOf(v[0], 1));
      else v = v.split(/\s#/, 1)[0].trim();
      if (v) return v;
    }
  }
  return '';
}

export function himmelFlag(name) {
  if (!/^[a-z][a-z0-9_]*$/.test(name || '')) throw new Error(`'${name}' is not a flag name (lower_snake_case)`);
  const reg = process.env.HIMMEL_FLAGS_TSV || join(dirname(fileURLToPath(import.meta.url)), 'flags.tsv');
  let rows;
  try {
    rows = readFileSync(reg, 'utf8').split('\n');
  } catch (e) {
    throw new Error(`cannot read the registry ${reg} (${e.code})`);
  }
  let def = null;
  for (const line of rows) {
    if (line && !line.startsWith('#')) {
      const cols = line.split('\t');
      if (cols[0] === name) {
        def = cols[1] ?? '';
        break;
      }
    }
  }
  if (def === null) throw new Error(`unknown flag '${name}' (not registered in ${reg})`);
  const key = `HIMMEL_FLAG_${name.toUpperCase()}`;
  const val = process.env[key] || confValue(key) || def;
  if (['1', 'on', 'true'].includes(val)) return true;
  if (['0', 'off', 'false'].includes(val)) return false;
  throw new Error(`${name} has the value '${val}' (want 1, 0, on or off)`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
  try {
    process.exit(himmelFlag(process.argv[2] || '') ? 0 : 1);
  } catch (e) {
    console.error(`himmel_flag: ${e.message}`);
    process.exit(2);
  }
}
