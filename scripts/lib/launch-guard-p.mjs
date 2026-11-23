#!/usr/bin/env node
// launch-guard-p.mjs - layer P of launch-guard-check.sh: does a himmel project
// settings file carry the full guard hook chain?
//
// Usage: node launch-guard-p.mjs <anchor> <settings-file> [added-hook.sh ...]
//
// Imports rewriteSettingsText from the ANCHOR's trusted wire-hook-bash.mjs
// (never the candidate tree's), reads <settings-file> as data, and passes only
// when it parses and nothing would be rewritten (changed === 0). No lock, no write.
//
// added-hook.sh: scripts/hooks/ names the folder's own branch adds (the caller
// proves each is in the branch diff and executable in the folder); a name the
// anchor's EXPECTED_SCRIPT_ORDER owns is never one. Their wiring
// is taken out of a copy of the settings before the anchor judges it: a hook entry
// naming only added scripts is dropped, and an added member is cut from a --chain
// member list. A kept entry naming an added script anywhere else refuses.
// Anything else in the file is judged as written.
//
// Adopted mode: node launch-guard-p.mjs <anchor> <settings-file> --adopted <dir>
// judges a folder that adopt.sh gave the chain at project scope, in this order:
// <dir> is in the station list of given projects (os.homedir(), never an
// inherited HIMMELCTL_CACHE_DIR); every settings layer reads and none turns
// hooks off; each chain entry of <settings-file> is byte-equal to the anchor's
// composer output (scripts/lib/wire-pretooluse-hooks.sh); each hook's matchers
// cover every tool it guards; each hook script is in <dir>; and the local file
// beside <settings-file> carries the anchor guard trio (the anchor's wrapper and
// scripts, with a bash and node that are executable).
//
// Exit codes: 0 chain complete | 1 incomplete or unreadable (one line on stderr)
import { execFileSync } from 'node:child_process';
import { accessSync, constants, readFileSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import os from 'node:os';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [anchor, file, ...added] = process.argv.slice(2);
if (!anchor || !file) {
  console.error('usage: launch-guard-p.mjs <anchor> <settings-file> [added-hook.sh ...]');
  console.error('       launch-guard-p.mjs <anchor> <settings-file> --adopted <dir>');
  process.exit(1);
}

class Refuse extends Error {}

function wireLib(args) {
  const lib = join(anchor, 'scripts', 'lib', 'wire-pretooluse-hooks.sh');
  const { resolveBash } = createRequire(import.meta.url)(join(anchor, 'scripts', 'hooks', 'run-hook-with-bash.js'));
  return JSON.parse(execFileSync(resolveBash(), [lib, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
}

function isExecutable(p) {
  try {
    if (!statSync(p).isFile()) return false;
    accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function groupsOf(settings) {
  const g = settings && settings.hooks && settings.hooks.PreToolUse;
  return Array.isArray(g) ? g.filter((x) => x && typeof x === 'object') : [];
}

function owned(spec, groups) {
  const re = new RegExp(spec.pat);
  const out = [];
  for (const g of groups) {
    for (const h of Array.isArray(g.hooks) ? g.hooks : []) {
      if (h && typeof h.command === 'string' && re.test(h.command)) out.push({ matcher: g.matcher, command: h.command });
    }
  }
  return out;
}

function checkCoverage(spec, entries, matcherMatches) {
  for (const tool of spec.stanza.matcher.split('|')) {
    if (!entries.some((e) => matcherMatches(e.matcher, tool))) {
      throw new Refuse(`matcher for ${spec.name} does not cover ${tool}: re-run adopt --repair-matchers`);
    }
  }
}

const QUOTED = '"(?:[^"\\\\]|\\\\.)*"';
const TRIO_HEAD = new RegExp(`^GUARDRAIL_BASH=(${QUOTED}) (${QUOTED}) `);

async function adoptedCheck(dir) {
  const stateJs = join(anchor, 'scripts', 'himmelctl', 'lib', 'state.js');
  const env = { ...process.env };
  delete env.HIMMELCTL_CACHE_DIR;
  const rows = JSON.parse(execFileSync(process.execPath, [stateJs, 'list-targets', '--json', '--station', '--for', dir],
    { encoding: 'utf8', env, stdio: ['ignore', 'pipe', 'pipe'] }));
  if (!Array.isArray(rows) || rows.length === 0) {
    throw new Refuse(`not a given scope: ${dir} (run himmelctl migrate-scopes --adopt ${dir}, or adopt it at project scope)`);
  }

  const localFile = join(dirname(file), 'settings.local.json');
  const userFile = join(process.env.CLAUDE_CONFIG_DIR || join(os.homedir(), '.claude'), 'settings.json');
  const layers = [
    { name: 'user', path: userFile },
    { name: 'project', path: file },
    { name: 'local', path: localFile },
  ];
  const hb = await import(pathToFileURL(join(anchor, 'scripts', 'lib', 'self-heartbeat-settings.mjs')).href);
  const eff = hb.readSelfHeartbeatEffectiveness({ layers });
  if (eff.state === 'unknown') {
    const bad = eff.provenance.layers.find((l) => l.status !== 'read' && l.status !== 'absent');
    throw new Refuse(`settings layer unreadable: ${bad && bad.path ? bad.path : file}`);
  }
  const docs = {};
  for (const l of layers) {
    let text = null;
    try {
      text = readFileSync(l.path, 'utf8');
    } catch {
      text = null;
    }
    docs[l.name] = text === null ? null : JSON.parse(text);
  }
  if (eff.reason === 'disable-all-hooks') {
    const top = [...layers].reverse().find((l) => docs[l.name] && docs[l.name].disableAllHooks !== undefined);
    throw new Refuse(`hooks disabled in ${top.path}`);
  }

  const { matcherMatches } = await import(pathToFileURL(join(anchor, 'scripts', 'hooks', 'bench-hook-stack.mjs')).href);
  const shared = groupsOf(docs.project);
  const chain = wireLib(['--print-chain', '$CLAUDE_PROJECT_DIR']);
  const sharedEntries = chain.map((spec) => owned(spec, shared));
  chain.forEach((spec, i) => {
    const es = sharedEntries[i];
    if (es.length === 0 || es.some((e) => e.command !== spec.cmd)) throw new Refuse('adopted chain differs: re-run adopt');
  });
  chain.forEach((spec, i) => checkCoverage(spec, sharedEntries[i], matcherMatches));
  for (const e of wireLib(['--print-hook-set'])) {
    try {
      if (!statSync(join(dir, e.script)).isFile()) throw new Error('not a file');
      accessSync(join(dir, e.script), constants.R_OK);
    } catch {
      throw new Refuse('guard script missing: re-run adopt');
    }
  }

  const trioMissing = new Refuse('anchor guard trio missing from the local file: re-run adopt');
  const local = groupsOf(docs.local);
  const composed = new Map();
  for (const spec of wireLib(['--print-trio', anchor, '--node', 'node', '--bash', 'bash'])) {
    const es = owned(spec, local);
    if (es.length === 0) throw trioMissing;
    for (const e of es) {
      const m = e.command.match(TRIO_HEAD);
      if (!m) throw trioMissing;
      const bashPath = JSON.parse(m[1]);
      const nodePath = JSON.parse(m[2]);
      const key = JSON.stringify([nodePath, bashPath]);
      if (!composed.has(key)) composed.set(key, wireLib(['--print-trio', anchor, '--node', nodePath, '--bash', bashPath]));
      const want = composed.get(key).find((t) => t.name === spec.name);
      if (!want || e.command !== want.cmd || !isExecutable(bashPath) || !isExecutable(nodePath)) throw trioMissing;
    }
    checkCoverage(spec, es, matcherMatches);
  }
}

if (added[0] === '--adopted') {
  if (added.length !== 2 || !added[1]) {
    console.error('usage: launch-guard-p.mjs <anchor> <settings-file> --adopted <dir>');
    process.exit(1);
  }
  try {
    await adoptedCheck(added[1]);
    process.exit(0);
  } catch (e) {
    if (e instanceof Refuse) console.error(e.message);
    else console.error(`launch-guard-p: ${e && e.message ? e.message : e}`);
    process.exit(1);
  }
}

const HOOK_SCRIPT = /scripts\/hooks\/([A-Za-z0-9._-]+\.sh)/g;
const MEMBER_PREFIX = '"$CLAUDE_PROJECT_DIR/scripts/hooks/';
const CHAIN_MEMBERS = /(run-hook-with-bash\.js" --chain (?:--lifecycle )?)((?:"\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/[A-Za-z0-9._-]+\.sh" )*"\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/[A-Za-z0-9._-]+\.sh")(?=;|$)/g;

function withoutAddedHooks(text, names) {
  const settings = JSON.parse(text);
  const hooks = settings && settings.hooks;
  if (!hooks || typeof hooks !== 'object' || Array.isArray(hooks)) return text;
  const addedSet = new Set(names);
  for (const event of Object.keys(hooks)) {
    if (!Array.isArray(hooks[event])) continue;
    hooks[event] = hooks[event].filter((group) => {
      if (!group || !Array.isArray(group.hooks) || group.hooks.length === 0) return true;
      group.hooks = group.hooks.filter((hook) => {
        if (!hook || typeof hook.command !== 'string') return true;
        const used = [...hook.command.matchAll(HOOK_SCRIPT)].map((m) => m[1]);
        if (used.length > 0 && used.every((s) => addedSet.has(s))) return false;
        if (!used.some((s) => addedSet.has(s))) return true;
        hook.command = hook.command.replace(CHAIN_MEMBERS, (whole, head, list) => {
          const kept = list.split(' ').filter((m) => !addedSet.has(m.slice(MEMBER_PREFIX.length, -1)));
          return kept.length > 0 ? head + kept.join(' ') : whole;
        });
        const left = [...hook.command.matchAll(HOOK_SCRIPT)].map((m) => m[1]).filter((s) => addedSet.has(s));
        if (left.length > 0) throw new Error(`added hook ${left[0]} is named outside a --chain member list`);
        return true;
      });
      return group.hooks.length > 0;
    });
  }
  return JSON.stringify(settings, null, 2);
}

try {
  const mod = await import(pathToFileURL(join(anchor, 'scripts', 'hooks', 'wire-hook-bash.mjs')).href);
  const text = readFileSync(file, 'utf8');
  const owned = new Set(mod.EXPECTED_SCRIPT_ORDER || []);
  const unowned = added.filter((s) => !owned.has(s));
  const res = mod.rewriteSettingsText(unowned.length > 0 ? withoutAddedHooks(text, unowned) : text);
  if (res.changed !== 0) {
    console.error(`launch-guard-p: ${res.changed} hook command(s) would be rewritten`);
    process.exit(1);
  }
} catch (e) {
  console.error(`launch-guard-p: ${e && e.message ? e.message : e}`);
  process.exit(1);
}
