'use strict';
// scripts/himmelctl/lib/wiring-rows.js — the wiring layers behind
// `himmelctl report --json --deep` (spec A15): pre-commit ids, Claude hooks,
// git hooks, CI workflows. Read-only: declared and installed come from config
// files under the checkout; `fires` is always unverified (A9) because none of
// these components leave run evidence we can read.
//
// Returns row options for config-feed.js's mkRow (no I/O beyond reads).

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const UNVERIFIED = { state: 'unverified', evidence: null, at: null };
// pre-commit stage names -> the git hook file that serves them
const STAGE_HOOK = { commit: 'pre-commit', 'pre-commit': 'pre-commit', push: 'pre-push', 'pre-push': 'pre-push', 'commit-msg': 'commit-msg', 'prepare-commit-msg': 'prepare-commit-msg', 'pre-merge-commit': 'pre-merge-commit', 'post-commit': 'post-commit', 'post-checkout': 'post-checkout', 'post-merge': 'post-merge', 'post-rewrite': 'post-rewrite' };
// the runner every chained command goes through; not a rule of its own
const RUNNERS = new Set(['run-hook-with-bash.js']);

function exists(p) {
  try { return fs.statSync(p).isFile(); } catch { return false; }
}

// line-based: `- id: X` opens a block, an optional `stages: [a, b]` in it
// names the stages (default pre-commit). Enough for the repo's own config.
function precommitIds(file) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return []; }
  const out = [];
  let cur = null;
  for (const line of text.split('\n')) {
    const id = /^\s*-\s+id:\s*([^\s#]+)/.exec(line);
    if (id) { cur = { id: id[1], stages: [] }; out.push(cur); continue; }
    if (/^\s*-\s+repo:/.test(line)) { cur = null; continue; }
    const st = cur && /^\s*stages:\s*\[([^\]]*)\]/.exec(line);
    if (st) cur.stages = st[1].split(',').map((s) => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean);
  }
  return out;
}

function gitHooksDir(root) {
  const r = spawnSync('git', ['-C', root, 'rev-parse', '--git-path', 'hooks'], { encoding: 'utf8', timeout: 5000 });
  const p = r.status === 0 ? r.stdout.trim() : '';
  return p ? path.resolve(root, p) : path.join(root, '.git', 'hooks');
}

// ponytail: only commands naming scripts/hooks/<file> become rows; inline
// shell hooks are skipped, add a row per command when one needs reporting.
function claudeHooks(root) {
  let cfg;
  try { cfg = JSON.parse(fs.readFileSync(path.join(root, '.claude', 'settings.json'), 'utf8')); } catch { return []; }
  const out = [];
  for (const [event, entries] of Object.entries((cfg && cfg.hooks) || {})) {
    const seen = new Set();
    for (const entry of Array.isArray(entries) ? entries : []) {
      for (const h of Array.isArray(entry && entry.hooks) ? entry.hooks : []) {
        const re = /scripts\/hooks\/([\w.-]+\.(?:sh|js|mjs|ps1))/g;
        let m;
        while ((m = re.exec(String(h && h.command || ''))) !== null) {
          if (RUNNERS.has(m[1]) || seen.has(m[1])) continue;
          seen.add(m[1]);
          out.push({ event, script: m[1] });
        }
      }
    }
  }
  return out;
}

function wiringRows({ root, probedAt }) {
  const rows = [];
  const hooksDir = gitHooksDir(root);
  const hookInstalled = (name) => exists(path.join(hooksDir, name));
  const base = { source: 'wiring', fires: UNVERIFIED, probedAt };
  const row = (o) => {
    const present = o.present;
    return {
      ...base, id: o.id, group: 'guard', title: o.title,
      declared: { where: o.where, desired: 'declared', profile: 'all' },
      installed: { state: present === null ? 'n/a' : present ? 'present' : 'absent', detail: o.detail },
      health: present === false ? 'fail' : present === null ? 'info' : 'ok',
      fix: { remedy: present === false ? o.remedy : '', owner: 'user' },
    };
  };

  const hookTypes = new Set(['pre-commit']);
  for (const p of precommitIds(path.join(root, '.pre-commit-config.yaml'))) {
    const stages = p.stages.length > 0 ? p.stages : ['commit'];
    const files = [...new Set(stages.map((s) => STAGE_HOOK[s]).filter(Boolean))];
    files.forEach((f) => hookTypes.add(f));
    const present = files.length === 0 ? null : files.every(hookInstalled);
    rows.push(row({
      id: `precommit:${p.id}`, title: `pre-commit: ${p.id}`, where: `.pre-commit-config.yaml#${p.id}`, present,
      detail: files.length === 0 ? `stages ${stages.join(',')} run on demand, no git hook` : `served by git hook ${files.join(', ')}`,
      remedy: 'pre-commit install --install-hooks --hook-type pre-commit --hook-type pre-push --hook-type commit-msg',
    }));
  }

  for (const h of claudeHooks(root)) {
    const present = exists(path.join(root, 'scripts', 'hooks', h.script));
    rows.push(row({
      id: `claude-hook:${h.event}:${h.script}`, title: `Claude hook ${h.event}: ${h.script}`,
      where: `.claude/settings.json#hooks.${h.event}`, present,
      detail: present ? `scripts/hooks/${h.script}` : `scripts/hooks/${h.script} not found`,
      remedy: `git checkout scripts/hooks/${h.script}   # settings.json references it`,
    }));
  }

  for (const name of [...hookTypes].sort()) {
    const present = hookInstalled(name);
    rows.push(row({
      id: `git-hook:${name}`, title: `git hook: ${name}`, where: '.pre-commit-config.yaml', present,
      detail: present ? path.join(hooksDir, name) : `${path.join(hooksDir, name)} not found`,
      remedy: `pre-commit install --hook-type ${name}`,
    }));
  }

  let flows = [];
  try { flows = fs.readdirSync(path.join(root, '.github', 'workflows')).filter((f) => /\.ya?ml$/.test(f)).sort(); } catch { /* no workflows dir */ }
  for (const f of flows) {
    rows.push(row({
      id: `ci:${f}`, title: `CI workflow: ${f}`, where: `.github/workflows/${f}`, present: true,
      detail: 'workflow file present; whether it ran is on GitHub, not read here', remedy: '',
    }));
  }
  return rows;
}

module.exports = { wiringRows, precommitIds };
