#!/usr/bin/env node
// chain-state.mjs — the chain read that board v4's Chains tab and chain badges share
// (board v4 rulings L1 to L5). READ-ONLY: it prints one JSON document and writes nothing.
//
//   node chain-state.mjs --json --registry FILE [--mirror DIR] [--state DIR] [--version V] [--now ISO]
//
// Sources:
//   --registry names every chain's goal and members (himmel.chain-registry/1).
//   the Jira mirror (one <KEY>.md per issue, default ~/.himmel/state/jira-mirror/HIMMEL):
//     current status decides readiness; `links.blocked_by` are hard links.
//   chain-log.jsonl in the state dir (L4, append-only): `hold` rows (kind, on, who, reason, until)
//     and `release` rows, written by ticket-hold.sh; every row naming a chain or one of its
//     tickets is listed in that chain's change log.
//   status-events.jsonl beside it: merge rows (contract=yes that moved Jira completes a ticket, L5; the others
//     are partial PR ticks), hold-release rows, and hold rows that have no chain-log row.
// --version keeps only tickets in that fixVersion; an open blocker outside it is a real block.
//
// Per chain: steps (L1: a topological layer over the chain's links, so tickets that can run
// side by side share a step), done/total, next, and links across other work (L2).
// Per ticket: the state word, its step in each chain, badges (L3: two, then `more`), partial PR
// ticks, the order check and the Why fields of each link. The order check (L5) reads the
// completing merge (contract=yes; for a ticket closed by hand, its last PR merged before Jira
// went Done) against the holds as they stood at that merge, so a later reorder never rewrites it.
//
// ponytail: Jira links carry no time, so the order check reads today's blocked_by links as if
// they stood at every merge; upgrade path = the mirror's link history.
// ponytail: a release clears every hold on its ticket (ticket-hold.sh releases the one `held`
// label); upgrade path = a release naming its link.
// ponytail: no `add`/`remove` writer exists yet; such rows are listed in the change log, and
// membership is the registry's today.
//
// PLATFORM GUARD: the chief kit is Linux-only. Node ESM, no dependencies.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { createHash } from 'node:crypto';

const SCHEMA = 'himmel.chains/1';
const IN_FLIGHT = new Set(['In Progress', 'In Review', 'IN CI']);

function usage() {
    process.stderr.write('usage: chain-state.mjs --json --registry FILE [--mirror DIR] [--state DIR] [--version V] [--now ISO]\n');
    process.exit(2);
}

const opt = { json: false, registry: null, mirror: null, state: null, version: null, now: null };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') opt.json = true;
    else if (['--registry', '--mirror', '--state', '--version', '--now'].includes(a) && i + 1 < argv.length) opt[a.slice(2)] = argv[++i];
    else usage();
}
if (!opt.json || !opt.registry) usage();

const home = process.env.HOME || '/tmp';
const stateDir = opt.state || process.env.TICKET_STATUS_STATE_DIR || join(home, '.himmel/state');
const mirrorDir = opt.mirror || join(stateDir, 'jira-mirror/HIMMEL');
const ms = s => { const v = Date.parse(s); return Number.isNaN(v) ? null : v; };
const iso = v => new Date(v).toISOString().replace(/\.\d{3}Z$/, 'Z');
const now = opt.now ? ms(opt.now) : Date.now();
if (now === null) usage();
const fail = message => { process.stderr.write(`chain-state: ${message}\n`); process.exit(2); };
const warn = message => process.stderr.write(`WARN ${message}\n`);
const registryPath = resolve(opt.registry);
let registryBytes, registry;
try {
    registryBytes = readFileSync(registryPath);
    registry = JSON.parse(registryBytes.toString('utf8'));
} catch (e) { fail(`registry ${registryPath}: ${e.message}`); }
if (registry?.schema !== 'himmel.chain-registry/1' || !Array.isArray(registry.chains)) fail(`registry ${registryPath}: bad schema or chains`);
const ids = new Set();
for (const c of registry.chains) {
    if (!c || typeof c.id !== 'string' || !/^[a-z0-9][a-z0-9-]{1,40}$/.test(c.id) || ids.has(c.id)) fail(`registry ${registryPath}: bad or duplicate id`);
    ids.add(c.id);
    if (typeof c.goal !== 'string' || c.goal.trim().split(/\s+/).length < 3 || [...c.goal].length > 90
        || c.goal.trim() === c.id || c.goal.trim() === c.id.replaceAll('-', ' ')) fail(`registry ${registryPath}: bad goal for ${c.id}`);
    if (!Array.isArray(c.members) || !c.members.length || !c.members.every(k => typeof k === 'string' && /^HIMMEL-\d+$/.test(k))
        || new Set(c.members).size !== c.members.length) fail(`registry ${registryPath}: bad or duplicate member for ${c.id}`);
}
const provenance = { path: registryPath, sha256: createHash('sha256').update(registryBytes).digest('hex') };
let sourceTime = null;

// ---------------------------------------------------------------- reads
function readMirror(dir) {
    const out = new Map();
    let names = [];
    try { names = readdirSync(dir).filter(n => /^[A-Z][A-Z0-9]*-\d+\.md$/.test(n)); }
    catch (e) { fail(`mirror missing or unreadable ${dir}: ${e.message}`); }
    for (const n of names) {
        let text, stamp;
        try { text = readFileSync(join(dir, n), 'utf8'); stamp = statSync(join(dir, n)).mtimeMs; }
        catch (e) { fail(`mirror unreadable ${join(dir, n)}: ${e.message}`); }
        sourceTime = sourceTime === null ? stamp : Math.min(sourceTime, stamp);
        const m = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/.exec(text);
        if (!m) continue;
        const fm = Object.create(null);
        for (const line of m[1].split('\n')) {
            const kv = /^ *(\w+): (.*)$/.exec(line);
            if (kv) { try { fm[kv[1]] = JSON.parse(kv[2]); } catch { fm[kv[1]] = kv[2]; } }
        }
        if (fm.key !== n.slice(0, -3)) continue;
        const arr = v => (Array.isArray(v) ? v.map(String) : []);
        const title = /^# [A-Z][A-Z0-9]*-\d+: (.*)$/m.exec(m[2]);
        out.set(fm.key, {
            key: fm.key, title: title ? title[1].trim() : '', type: fm.type, status: fm.status,
            known: typeof fm.status === 'string' && ['To Do', 'In Progress', 'Done'].includes(fm.statusCategory),
            done: fm.statusCategory === 'Done', labels: arr(fm.labels), versions: arr(fm.fixVersions),
            epoch: typeof fm.statuscategorychangedate === 'string' ? ms(fm.statuscategorychangedate) : null,
            resolved: typeof fm.resolved === 'string' ? ms(fm.resolved) : null,
            blockedBy: arr(fm.blocked_by).map(s => (/[A-Z][A-Z0-9]*-\d+/.exec(s) || [])[0]).filter(Boolean),
        });
    }
    return out;
}

function readJsonl(file) {
    let txt = '';
    try { txt = readFileSync(file, 'utf8'); } catch { return []; }
    const rows = [];
    for (const line of txt.split('\n')) {
        if (!line.trim()) continue;
        try {
            const r = JSON.parse(line);
            if (r && typeof r.ts === 'string' && ms(r.ts) !== null) rows.push(r);
        } catch { /* a torn line is skipped */ }
    }
    return rows.sort((a, b) => ms(a.ts) - ms(b.ts));
}

const issues = readMirror(mirrorDir);
const events = readJsonl(join(stateDir, 'status-events.jsonl'));
const chainLog = readJsonl(join(stateDir, 'chain-log.jsonl'));

// ---------------------------------------------------------------- merges and completion
const mergesOf = new Map();
for (const r of events) {
    if (r.event !== 'merge' || !r.key) continue;
    if (!mergesOf.has(r.key)) mergesOf.set(r.key, []);
    mergesOf.get(r.key).push(r);
}

// completing(key): the merge that completes the ticket (L5), or null. A contract
// merge that did not move Jira (ts_done_pending's rule) completes only once Jira goes Done.
function completing(key) {
    const iss = issues.get(key);
    if (!iss?.known || !iss.done) return null;
    // Preserve the completing PR for the audit, including a PR merged before manual closure.
    const rows = mergesOf.get(key) || [];
    const yes = rows.filter(r => r.contract === 'yes' && (r.result === 'moved' || r.result === 'noop'));
    if (yes.length) return yes[yes.length - 1];
    const before = iss.resolved === null ? rows : rows.filter(r => ms(r.ts) <= iss.resolved);
    return before.length ? before[before.length - 1] : null;
}

// completeAt(key): when the ticket completed, or null while it is open.
function completeAt(key, at = now) {
    const iss = issues.get(key);
    // A reopen changes readiness today, not an order audit made before that reopen.
    if (iss?.known && !iss.done && iss.epoch !== null && at < iss.epoch) {
        const before = (mergesOf.get(key) || []).filter(r => ms(r.ts) <= at && r.contract === 'yes'
            && (r.result === 'moved' || r.result === 'noop'));
        if (before.length) return ms(before[before.length - 1].ts);
        return iss.resolved !== null && iss.resolved <= at ? iss.resolved : null;
    }
    const m = completing(key);
    // Audit identity and current clearing time are separate: an older merge cannot clear a new Done epoch.
    if (iss?.known && iss.done) return Math.max(m ? ms(m.ts) : iss.resolved ?? 0, iss.epoch ?? 0);
    return null;
}
const isDone = key => completeAt(key) !== null && completeAt(key) <= now;

// ---------------------------------------------------------------- holds
const releases = [];
for (const r of events) if (r.event === 'hold-release' && r.result === 'moved') releases.push({ key: r.key, at: ms(r.ts) });
for (const r of chainLog) if (r.change === 'release') releases.push({ key: r.key, at: ms(r.ts) });

const holds = [];
for (const r of chainLog) {
    if (r.change !== 'hold' || !r.key) continue;
    holds.push({ key: r.key, on: r.on || null, kind: r.kind || 'hold', source: 'chain-log', added: ms(r.ts),
        reason: r.reason || null, owner: r.who || null, until: r.until || null });
}
// a hold set with --kind or --on has its chain-log row; the event row stands in for one set
// without them, or one whose chain-log row was not written (written within a minute of the event)
const logged = (key, at) => chainLog.some(c => c.change === 'hold' && c.key === key && Math.abs(ms(c.ts) - at) <= 60000);
for (const r of events) {
    if (r.event !== 'hold' || r.result !== 'moved' || logged(r.key, ms(r.ts))) continue;
    holds.push({ key: r.key, on: r.on || null, kind: r.kind || 'hold', source: 'status-events', added: ms(r.ts), reason: null, owner: null, until: r.until || null });
}
for (const h of holds) {
    const rel = releases.filter(r => r.key === h.key && r.at >= h.added).map(r => r.at);
    h.released = rel.length ? Math.min(...rel) : null;
}

// linksAt(key, at): what the ticket waits on as it stood at `at`, each with its Why fields.
function linksAt(key, at) {
    const iss = issues.get(key);
    const raw = (iss ? iss.blockedBy : []).map(on => ({ on, kind: 'jira-link', source: 'jira', added: null,
        reason: null, owner: null, until: null, released: null }));
    for (const h of holds) if (h.key === key && h.added <= at) raw.push(h);
    return raw.map(l => {
        const ends = [];
        if (l.released !== null && l.released <= at) ends.push(['released', l.released]);
        const c = l.on ? completeAt(l.on, at) : null;
        if (c !== null && c <= at) ends.push(['cleared', c]);
        const u = l.kind === 'date' && l.until ? ms(l.until) : null;
        if (u !== null && u <= at) ends.push(['cleared', u]);
        ends.sort((a, b) => a[1] - b[1]);
        const clears = l.kind === 'date' ? l.until : l.on ? `${l.on} completes` : 'a release';
        return { on: l.on, kind: l.kind, source: l.source, added: l.added === null ? null : iso(l.added),
            reason: l.reason, owner: l.owner, until: l.until, clears,
            status: ends.length ? ends[0][0] : l.on && !issues.get(l.on)?.known ? 'unknown' : 'open',
            at: ends.length ? iso(ends[0][1]) : null };
    });
}

// ---------------------------------------------------------------- chains
const inVersion = iss => !opt.version || iss.versions.includes(opt.version);
const chains = new Map();
for (const c of registry.chains) {
    for (const key of c.members) if (!issues.get(key)?.known) warn(`unknown-member ${key}`);
    const members = c.members.filter(k => !issues.has(k) || inVersion(issues.get(k)));
    if (opt.version && !members.length) continue;
    chains.set(c.id, { id: c.id, name: c.goal.trim(), source: 'registry', members: new Set(members) });
}
const chainsOf = key => [...chains.values()].filter(c => c.members.has(key)).map(c => c.id).sort();

// Cycles are diagnosed over all current hard links, not just one chain's members.
const cycles = [];
const visited = new Set(), active = new Set(), stack = [];
function visit(key) {
    if (active.has(key)) {
        cycles.push(stack.slice(stack.indexOf(key)).sort());
        return;
    }
    if (visited.has(key) || isDone(key)) return;
    visited.add(key); active.add(key); stack.push(key);
    for (const l of linksAt(key, now)) if (l.on && l.status === 'open') visit(l.on);
    stack.pop(); active.delete(key);
}
for (const c of chains.values()) for (const k of c.members) visit(k);
for (const cycle of cycles) warn(`cycle ${cycle.join(' ')}`);
if (opt.version) {
    const members = new Set(registry.chains.flatMap(c => c.members));
    const unchained = [...issues.values()].filter(i => inVersion(i) && !isDone(i.key)
        && !members.has(i.key) && !i.labels.includes('standalone')).map(i => i.key).sort();
    warn(`unchained=${unchained.length}${unchained.length ? ' ' + unchained.join(' ') : ''}`);
}

// orders(h): a hold sets the chain's order once added, unless it was released before its target completed.
function orders(h) {
    if (h.added > now) return false;
    if (h.released === null || h.released > now) return true;
    const c = completeAt(h.on);
    return c !== null && c <= h.released;
}

// steps (L1): a ticket's step is one past its latest in-chain predecessor. A pair linked both
// ways (a reorder) keeps the later link; a cycle left after that is cut where the walk meets it.
function layer(chain) {
    const edges = new Map();
    for (const k of chain.members) {
        const iss = issues.get(k);
        for (const on of iss?.blockedBy || []) if (chain.members.has(on)) edges.set(`${k}>${on}`, -Infinity);
        for (const h of holds) {
            if (h.key === k && h.on && chain.members.has(h.on) && orders(h)) edges.set(`${k}>${h.on}`, Math.max(edges.get(`${k}>${h.on}`) ?? -Infinity, h.added));
        }
    }
    const preds = new Map();
    for (const [e, at] of edges) {
        const [k, on] = e.split('>');
        if ((edges.get(`${on}>${k}`) ?? -Infinity) > at) continue;
        if (!preds.has(k)) preds.set(k, []);
        preds.get(k).push(on);
    }
    const step = new Map();
    const walking = new Set();
    const go = k => {
        if (step.has(k)) return step.get(k);
        if (walking.has(k)) return 0;
        walking.add(k);
        let s = 1;
        for (const p of preds.get(k) || []) s = Math.max(s, go(p) + 1);
        walking.delete(k);
        step.set(k, s);
        return s;
    };
    [...chain.members].sort().forEach(go);
    return step;
}
const steps = new Map([...chains.values()].map(c => [c.id, layer(c)]));
const nSteps = id => Math.max(0, ...steps.get(id).values());

// since(chain): the first chain-log row about the chain or one of its tickets; a ticket that
// completed before every chain it sits in existed is not checked.
function since(id) {
    const c = chains.get(id);
    const r = chainLog.find(x => x.chain === id || c.members.has(x.key) || c.members.has(x.on));
    return r ? ms(r.ts) : null;
}

function orderCheck(key) {
    const m = completing(key);
    if (!m) return { result: 'not-checked', merge: null, links: [] };
    const at = ms(m.ts);
    const merge = { pr: m.pr ?? null, ts: m.ts };
    const starts = chainsOf(key).map(since);
    if (starts.every(s => s !== null && at < s)) return { result: 'not-checked', merge, links: [] };
    const links = linksAt(key, at);
    if (!links.length) return { result: 'nothing-to-check', merge, links };
    return { result: links.some(l => l.status === 'open' || l.status === 'unknown') ? 'out-of-order' : 'order-held', merge, links };
}

const outside = k => !issues.has(k) || !inVersion(issues.get(k));

function stateIn(key, id, links, check) {
    if (isDone(key)) {
        if (check.result === 'order-held') return 'done · order held';
        if (check.result === 'out-of-order') return 'done · out of order';
        return 'done';
    }
    if (!issues.get(key)?.known || links.some(l => l.status === 'unknown')) return 'unknown';
    const open = links.filter(l => l.status === 'open');
    if (open.some(l => l.on && outside(l.on))) return 'blocked';
    if (open.some(l => l.kind === 'operator')) return 'waits on you';
    if (open.some(l => l.kind === 'date')) return 'date-gated';
    if (IN_FLIGHT.has(issues.get(key).status)) return 'in flight';
    if (!open.length) return 'can launch';
    const mine = open.filter(l => l.on && chains.get(id).members.has(l.on));
    if (mine.length) return `waits on step ${Math.max(...mine.map(l => steps.get(id).get(l.on)))}`;
    const other = open.find(l => l.on);
    return other ? `waits on ${other.on}` : `waits on ${open[0].kind}`;
}

// ---------------------------------------------------------------- output
const tickets = {};
for (const key of [...new Set([...chains.values()].flatMap(c => [...c.members]))].sort()) {
    const iss = issues.get(key);
    const links = linksAt(key, now);
    const done = isDone(key);
    const check = done ? orderCheck(key) : null;
    const done1 = completing(key);
    const memberOf = chainsOf(key).map(id => ({ id, step: steps.get(id).get(key), steps: nSteps(id), state: stateIn(key, id, links, check) }));
    tickets[key] = {
        key, title: iss?.title || '', status: iss?.status || null, done, state: memberOf[0].state, chains: memberOf,
        badges: memberOf.slice(0, 2).map(c => c.id), more: Math.max(0, memberOf.length - 2),
        ticks: (mergesOf.get(key) || []).filter(r => r !== done1).map(r => ({ pr: r.pr ?? null, ts: r.ts })),
        check, links,
    };
}

const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const out = [];
for (const c of [...chains.values()].sort((a, b) => cmp(a.id, b.id))) {
    const st = steps.get(c.id);
    const members = [...c.members].sort((a, b) => st.get(a) - st.get(b) || cmp(a, b));
    const launch = members.filter(k => tickets[k].chains.find(x => x.id === c.id).state === 'can launch');
    const first = launch.length ? Math.min(...launch.map(k => st.get(k))) : null;
    const across = [];
    for (const k of Object.keys(tickets)) {
        for (const l of tickets[k].links) {
            if (!l.on || c.members.has(k) === c.members.has(l.on)) continue;
            const mine = c.members.has(k);
            across.push({ dir: mine ? 'waits-on' : 'holds-up', key: k, on: l.on, kind: l.kind, status: l.status,
                chains: chainsOf(mine ? l.on : k) });
        }
    }
    out.push({
        id: c.id, name: c.name, source: c.source, members, total: members.length,
        done: members.filter(k => tickets[k].done).length, steps: nSteps(c.id),
        // All ready members are next, even when completed ancestors give them different historical steps.
        next: first === null ? null : { step: first, keys: launch },
        across,
        log: chainLog.filter(r => r.chain === c.id || c.members.has(r.key) || c.members.has(r.on)),
    });
}

// Oldest issue mtime: a partial refresh must not make the whole snapshot look fresh.
const sourceAge = sourceTime === null ? null : Math.max(0, Math.floor((now - sourceTime) / 60000));
process.stdout.write(`${JSON.stringify({ schema: SCHEMA, now: iso(now), version: opt.version,
    registry: provenance, source_age_min: sourceAge, cycles, chains: out, tickets }, null, 2)}\n`);
