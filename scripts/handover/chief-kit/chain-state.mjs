#!/usr/bin/env node
// chain-state.mjs — the chain read that board v4's Chains tab and chain badges share
// (board v4 rulings L1 to L5). READ-ONLY: it prints one JSON document and writes nothing.
//
//   node chain-state.mjs --json [--mirror DIR] [--state DIR] [--version V] [--now ISO]
//
// Sources:
//   the Jira mirror (one <KEY>.md per issue, default ~/.himmel/state/jira-mirror/HIMMEL): a
//     `parent` epic or a `chain-<slug>` label names a chain (L2); `links.blocked_by` are hard links.
//   chain-log.jsonl in the state dir (L4, append-only): `hold` rows (kind, on, who, reason, until)
//     and `release` rows, written by ticket-hold.sh; every row naming a chain or one of its
//     tickets is listed in that chain's change log.
//   status-events.jsonl beside it: merge rows (contract=yes completes a ticket, L5; the others
//     are partial PR ticks), hold-release rows, and holds set without --kind/--on.
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
// membership is the mirror's today.
//
// PLATFORM GUARD: no .ps1 twin, by design (the chief kit is Linux-only). Node ESM, no dependencies.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const SCHEMA = 'himmel.chains/1';
const IN_FLIGHT = new Set(['In Progress', 'In Review', 'IN CI']);

function usage() {
    process.stderr.write('usage: chain-state.mjs --json [--mirror DIR] [--state DIR] [--version V] [--now ISO]\n');
    process.exit(2);
}

const opt = { json: false, mirror: null, state: null, version: null, now: null };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') opt.json = true;
    else if (['--mirror', '--state', '--version', '--now'].includes(a) && i + 1 < argv.length) opt[a.slice(2)] = argv[++i];
    else usage();
}
if (!opt.json) usage();

const home = process.env.HOME || '/tmp';
const stateDir = opt.state || process.env.TICKET_STATUS_STATE_DIR || join(home, '.himmel/state');
const mirrorDir = opt.mirror || join(stateDir, 'jira-mirror/HIMMEL');
const ms = s => { const v = Date.parse(s); return Number.isNaN(v) ? null : v; };
const iso = v => new Date(v).toISOString().replace(/\.\d{3}Z$/, 'Z');
const now = opt.now ? ms(opt.now) : Date.now();
if (now === null) usage();

// ---------------------------------------------------------------- reads
function readMirror(dir) {
    const out = new Map();
    let names = [];
    try { names = readdirSync(dir).filter(n => /^[A-Z][A-Z0-9]*-\d+\.md$/.test(n)); } catch { return out; }
    for (const n of names) {
        const m = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/.exec(readFileSync(join(dir, n), 'utf8'));
        if (!m) continue;
        const fm = {};
        for (const line of m[1].split('\n')) {
            const kv = /^ *(\w+): (.*)$/.exec(line);
            if (kv) { try { fm[kv[1]] = JSON.parse(kv[2]); } catch { fm[kv[1]] = kv[2]; } }
        }
        if (typeof fm.key !== 'string') continue;
        const arr = v => (Array.isArray(v) ? v.map(String) : []);
        const title = /^# [A-Z][A-Z0-9]*-\d+: (.*)$/m.exec(m[2]);
        out.set(fm.key, {
            key: fm.key, title: title ? title[1].trim() : '', type: fm.type, status: fm.status,
            done: fm.statusCategory === 'Done', labels: arr(fm.labels), versions: arr(fm.fixVersions),
            parent: typeof fm.parent === 'string' ? fm.parent : null,
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

// completing(key): the merge that completes the ticket (L5), or null.
function completing(key) {
    const rows = mergesOf.get(key) || [];
    const yes = rows.filter(r => r.contract === 'yes');
    if (yes.length) return yes[yes.length - 1];
    const iss = issues.get(key);
    if (!iss || !iss.done) return null;
    const before = iss.resolved === null ? rows : rows.filter(r => ms(r.ts) <= iss.resolved);
    return before.length ? before[before.length - 1] : null;
}

// completeAt(key): when the ticket completed, or null while it is open.
function completeAt(key) {
    const m = completing(key);
    if (m) return ms(m.ts);
    const iss = issues.get(key);
    if (iss && iss.done) return iss.resolved === null ? 0 : iss.resolved;
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
// a hold set with --kind or --on has its chain-log row; one set without them has only its event row
for (const r of events) {
    if (r.event !== 'hold' || r.result !== 'moved' || r.kind || r.on) continue;
    holds.push({ key: r.key, on: null, kind: 'hold', source: 'status-events', added: ms(r.ts), reason: null, owner: null, until: null });
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
        const c = l.on ? completeAt(l.on) : null;
        if (c !== null && c <= at) ends.push(['cleared', c]);
        const u = l.kind === 'date' && l.until ? ms(l.until) : null;
        if (u !== null && u <= at) ends.push(['cleared', u]);
        ends.sort((a, b) => a[1] - b[1]);
        const clears = l.kind === 'date' ? l.until : l.on ? `${l.on} completes` : 'a release';
        return { on: l.on, kind: l.kind, source: l.source, added: l.added === null ? null : iso(l.added),
            reason: l.reason, owner: l.owner, until: l.until, clears,
            status: ends.length ? ends[0][0] : 'open', at: ends.length ? iso(ends[0][1]) : null };
    });
}

// ---------------------------------------------------------------- chains
const inVersion = iss => !opt.version || iss.versions.includes(opt.version);
const chains = new Map();
function addMember(id, name, source, key) {
    if (!chains.has(id)) chains.set(id, { id, name, source, members: new Set() });
    chains.get(id).members.add(key);
}
for (const iss of issues.values()) {
    if (!inVersion(iss)) continue;
    const p = iss.parent && issues.get(iss.parent);
    if (iss.parent && (!p || p.type === 'Epic')) addMember(iss.parent, p ? p.title : iss.parent, 'epic', iss.key);
    for (const l of iss.labels) if (/^chain-./.test(l)) addMember(l, l.slice(6), 'label', iss.key);
}
const chainsOf = key => [...chains.values()].filter(c => c.members.has(key)).map(c => c.id).sort();

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
        for (const on of iss.blockedBy) if (chain.members.has(on)) edges.set(`${k}>${on}`, -Infinity);
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
    return { result: links.some(l => l.status === 'open') ? 'out-of-order' : 'order-held', merge, links };
}

const outside = k => !issues.has(k) || !inVersion(issues.get(k));

function stateIn(key, id, links, check) {
    if (isDone(key)) {
        if (check.result === 'order-held') return 'done · order held';
        if (check.result === 'out-of-order') return 'done · out of order';
        return 'done';
    }
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
        key, title: iss.title, status: iss.status, done, state: memberOf[0].state, chains: memberOf,
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
        next: first === null ? null : { step: first, keys: launch.filter(k => st.get(k) === first) },
        across,
        log: chainLog.filter(r => r.chain === c.id || c.members.has(r.key) || c.members.has(r.on)),
    });
}

process.stdout.write(`${JSON.stringify({ schema: SCHEMA, now: iso(now), version: opt.version, chains: out, tickets }, null, 2)}\n`);
