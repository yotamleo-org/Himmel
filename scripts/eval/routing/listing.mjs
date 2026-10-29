// scripts/eval/routing/listing.mjs - render the routing listing the eval shows a model:
// every skill, command, agent and MCP tool named in inventory.json with its description, read
// from the working tree, plus the frozen entries of external.json.
//
//   node listing.mjs [--repo DIR] [--inventory FILE] [--seed-broken A,B] [--json]
//
// Text (default): the listing a run feeds the model. --json: {entries, tokens, sha}, where tokens
// counts chars/4 per kind the way skill-cost.mjs does (name + 2 + description and when_to_use).
// --seed-broken A,B gives B the description of A in the output only: the eval's seeded-broken
// control. No file is written.
// ponytail: renders every description uncapped, as an operator session sees it; a profiled
// session shrinks non-plugin entries to name-only (skill-listing.mjs) and lists MCP tools by
// name until ToolSearch. Upgrade path: a --profile flag that applies those overrides.
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readSkillFrontmatter } from '../../lanes/skill-cost.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const KINDS = ['skill', 'agent', 'mcp'];
const HEAD = {
  skill: 'Skills and commands (the Skill tool)',
  agent: 'Agents (the Agent tool, subagent_type)',
  mcp: 'MCP tools',
};

const listDir = (dir) => (existsSync(dir) ? readdirSync(dir, { withFileTypes: true }) : []);

function fromMarkdown(kind, path, fallback, prefix, repo) {
  const fm = readSkillFrontmatter(readFileSync(path, 'utf8'));
  const description = [fm.description, fm.whenToUse].filter(Boolean).join(' ');
  return { kind, name: prefix + (fm.name || fallback), description, owned: true, source: path.slice(repo.length + 1) };
}

function scanTree(root, prefix, repo) {
  const out = [];
  for (const d of listDir(join(root, 'skills'))) {
    const md = join(root, 'skills', d.name, 'SKILL.md');
    if (d.isDirectory() && existsSync(md)) out.push(fromMarkdown('skill', md, d.name, prefix, repo));
  }
  for (const f of listDir(join(root, 'commands'))) {
    if (f.name.endsWith('.md')) out.push(fromMarkdown('skill', join(root, 'commands', f.name), basename(f.name, '.md'), prefix, repo));
  }
  for (const f of listDir(join(root, 'agents'))) {
    if (f.name.endsWith('.md')) out.push(fromMarkdown('agent', join(root, 'agents', f.name), basename(f.name, '.md'), prefix, repo));
  }
  return out;
}

// registerTool('<tool>', { ..., description: '<text>' in an MCP server source
function scanMcp(server, path, repo) {
  const src = readFileSync(join(repo, path), 'utf8');
  const re = /registerTool\(\s*'([^']+)'\s*,\s*\{[^}]*?description:\s*'((?:[^'\\]|\\.)*)'/g;
  return [...src.matchAll(re)].map((m) => ({
    kind: 'mcp', name: `mcp__${server}__${m[1]}`, description: m[2].replace(/\\'/g, "'"), owned: true, source: path,
  }));
}

export function renderEntries({ repo, inventory }) {
  const inv = JSON.parse(readFileSync(inventory, 'utf8'));
  const entries = scanTree(join(repo, '.claude'), '', repo);
  for (const p of inv.plugins) {
    const root = join(repo, 'marketplace', 'plugins', p);
    const name = JSON.parse(readFileSync(join(root, '.claude-plugin', 'plugin.json'), 'utf8')).name;
    entries.push(...scanTree(root, `${name}:`, repo));
  }
  for (const [server, path] of Object.entries(inv.mcp)) entries.push(...scanMcp(server, path, repo));
  const ext = JSON.parse(readFileSync(join(dirname(inventory), inv.external), 'utf8'));
  for (const kind of KINDS) {
    for (const e of ext[kind === 'skill' ? 'skills' : kind === 'agent' ? 'agents' : 'mcp']) {
      entries.push({ kind, name: e.name, description: e.description, owned: false, source: inv.external });
    }
  }
  // a plugin skill and its command twin list once: the skill, scanned first, wins
  const seen = new Set();
  return entries.filter((e) => (seen.has(`${e.kind}:${e.name}`) ? false : seen.add(`${e.kind}:${e.name}`)));
}

export function seedBroken(entries, a, b) {
  const src = entries.find((e) => e.name === a);
  const dst = entries.find((e) => e.name === b);
  if (!src || !dst || a === b) throw new Error(`--seed-broken needs two different listed names, got ${a},${b}`);
  return entries.map((e) => (e === dst ? { ...e, description: src.description } : e));
}

const line = (e) => (e.description ? `- ${e.name}: ${e.description}` : `- ${e.name}`);

export function renderText(entries) {
  const parts = [];
  for (const kind of KINDS) {
    const rows = entries.filter((e) => e.kind === kind).sort((x, y) => (x.name < y.name ? -1 : x.name > y.name ? 1 : 0));
    parts.push(`## ${HEAD[kind]}\n${rows.map(line).join('\n')}`);
  }
  return `${parts.join('\n\n')}\n`;
}

export function tokens(entries) {
  const t = { skill: 0, agent: 0, mcp: 0, owned: 0, total: 0 };
  for (const e of entries) {
    const n = (e.name.length + 2 + e.description.length) / 4;
    t[e.kind] += n;
    t.total += n;
    if (e.owned) t.owned += n;
  }
  for (const k of Object.keys(t)) t[k] = Math.round(t[k]);
  return t;
}

function main(argv) {
  const opt = { repo: resolve(HERE, '..', '..', '..'), inventory: join(HERE, 'inventory.json'), json: false, seed: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') opt.json = true;
    else if (['--repo', '--inventory', '--seed-broken'].includes(a) && argv[i + 1] !== undefined) {
      opt[{ '--repo': 'repo', '--inventory': 'inventory', '--seed-broken': 'seed' }[a]] = argv[++i];
    } else throw new Error(`unknown or incomplete argument: ${a}`);
  }
  opt.repo = resolve(opt.repo);
  let entries = renderEntries(opt);
  if (opt.seed) entries = seedBroken(entries, ...opt.seed.split(','));
  const text = renderText(entries);
  if (!opt.json) return process.stdout.write(text);
  const sha = createHash('sha256').update(text).digest('hex').slice(0, 16);
  process.stdout.write(`${JSON.stringify({ entries, tokens: tokens(entries), sha }, null, 1)}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`listing.mjs: ${e.message}\n`);
    process.exit(2);
  }
}
