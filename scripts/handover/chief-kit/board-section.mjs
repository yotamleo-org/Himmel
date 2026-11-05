#!/usr/bin/env node
// board-section.mjs — the one writer (and the one reader) of a chief's board sections.
// A section is a text block the chief owns, stored beside its doc in
// <doc stem>.sections.json (schema himmel.board-sections/1) and shown by the AG-UI board.
//
//   node board-section.mjs --doc <chief doc> set <id> --title <t> [--tone info|warn|ok] [--order <n>]
//        [--expect-rev <n>] (--body <text> | --body-file <path>)
//   node board-section.mjs --doc <chief doc> rm <id> [--expect-rev <n>]
//   node board-section.mjs --doc <chief doc> list
//
// Exit 0 ok, 2 invalid input or a symlinked sidecar, 3 --expect-rev moved. `set` prints `redacted: <n>`.
//
// Exports the seam a later state-database backend replaces: readSections(doc) and
// applySection(doc, op). The path helper stays private; no other script opens a sidecar (I9).
import { promises as fs, realpathSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { redact } from './redact.mjs';

const SCHEMA = 'himmel.board-sections/1';
const MAX_FILE = 64 * 1024;
const MAX_TITLE = 80;
const MAX_BODY = 4000;
const MAX_SECTIONS = 20;
const ID_RE = /^[a-z0-9][a-z0-9-]{0,40}$/;
const TONES = ['info', 'warn', 'ok'];

class SectionError extends Error {
    constructor(code, message) { super(message); this.code = code; }
}
const invalid = (m) => new SectionError('INVALID', m);

// <real doc dir>/<doc stem>.sections.json. realpath, so a symlinked --doc lands beside the real doc.
function sectionsPathOf(doc) {
    const real = realpathSync(doc);
    return join(dirname(real), `${basename(real, '.md')}.sections.json`);
}

const cache = new Map(); // path -> { key: "mtimeMs:size", result }

// readSections(doc) → { sections, error? }. Cached on mtime and size; only the size and parse bounds apply here.
export async function readSections(doc) {
    let p;
    try { p = sectionsPathOf(doc); } catch { return { sections: [] }; }
    let st;
    try { st = await fs.lstat(p); } catch { cache.delete(p); return { sections: [] }; }
    if (st.isSymbolicLink()) return { sections: [], error: 'sidecar is a symlink' };
    const key = `${st.mtimeMs}:${st.size}`;
    const hit = cache.get(p);
    if (hit && hit.key === key) return hit.result;
    let result;
    if (st.size > MAX_FILE) {
        result = { sections: [], error: `sections file over ${MAX_FILE} bytes` };
    } else {
        try {
            const j = JSON.parse(await fs.readFile(p, 'utf8'));
            if (!j || !Array.isArray(j.sections)) throw new Error('no sections array');
            result = { sections: j.sections };
        } catch (e) {
            result = { sections: [], error: `sections file does not parse: ${String(e.message).split('\n')[0]}` };
        }
    }
    cache.set(p, { key, result });
    return result;
}

async function loadForWrite(p) {
    let lst;
    try { lst = await fs.lstat(p); } catch { return { rev: 0, sections: [] }; }
    if (lst.isSymbolicLink()) throw invalid(`sidecar is a symlink: ${p}`);
    if (lst.size > MAX_FILE) throw invalid('sections file is over 64 KB');
    try {
        const j = JSON.parse(await fs.readFile(p, 'utf8'));
        if (!j || j.schema !== SCHEMA || !Array.isArray(j.sections) || !Number.isInteger(j.rev)) throw new Error('bad shape');
        return { rev: j.rev, sections: j.sections };
    } catch (e) {
        throw invalid(`existing sections file does not parse (${e.message}); not overwriting`);
    }
}

// applySection(doc, op) → { rev, redacted }. op: { kind: 'set', id, title, body, tone?, order?, expectRev? } | { kind: 'rm', id, expectRev? }.
export async function applySection(doc, op) {
    if (!op || !ID_RE.test(String(op.id ?? ''))) throw invalid('id must match ^[a-z0-9][a-z0-9-]{0,40}$');
    if (op.kind !== 'set' && op.kind !== 'rm') throw invalid('kind must be set or rm');
    let p;
    try { p = sectionsPathOf(doc); } catch (e) { throw invalid(`cannot resolve --doc: ${e.message}`); }
    const cur = await loadForWrite(p);
    if (op.expectRev !== undefined && op.expectRev !== cur.rev) {
        throw new SectionError('REV', `rev is ${cur.rev}, expected ${op.expectRev}`);
    }
    let sections = cur.sections.filter((s) => s.id !== op.id);
    let redacted = 0;
    if (op.kind === 'rm') {
        if (sections.length === cur.sections.length) throw invalid(`no section ${op.id}`);
    } else {
        const tone = op.tone ?? 'info';
        if (!TONES.includes(tone)) throw invalid('tone must be info, warn or ok');
        if (typeof op.title !== 'string' || op.title === '') throw invalid('--title is required');
        if (typeof op.body !== 'string') throw invalid('a body is required');
        if (op.title.length > MAX_TITLE) throw invalid(`title over ${MAX_TITLE} characters`);
        if (op.body.length > MAX_BODY) throw invalid(`body over ${MAX_BODY} characters`);
        const prev = cur.sections.find((s) => s.id === op.id);
        const order = op.order ?? prev?.order ?? Math.max(0, ...cur.sections.map((s) => s.order || 0)) + 10;
        if (!Number.isInteger(order)) throw invalid('order must be an integer');
        const title = redact(op.title);
        const body = redact(op.body);
        redacted = (title !== op.title ? 1 : 0) + (body !== op.body ? 1 : 0);
        sections.push({ id: op.id, title, body, tone, order });
        if (sections.length > MAX_SECTIONS) throw invalid(`more than ${MAX_SECTIONS} sections`);
    }
    sections.sort((a, b) => (a.order - b.order) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    const rev = cur.rev + 1;
    const text = JSON.stringify({ schema: SCHEMA, rev, sections }, null, 2) + '\n';
    if (Buffer.byteLength(text) > MAX_FILE) throw invalid('result would exceed 64 KB');
    const tmp = `${p}.tmp${process.pid}`;
    await fs.writeFile(tmp, text, { flag: 'wx' });
    await fs.rename(tmp, p);
    cache.delete(p);
    return { rev, redacted };
}

function parseArgs(argv) {
    const o = { _: [] };
    const valued = new Set(['--doc', '--title', '--tone', '--order', '--expect-rev', '--body', '--body-file']);
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (valued.has(a)) {
            if (i + 1 >= argv.length) throw invalid(`${a} needs a value`);
            o[a.slice(2)] = argv[++i];
        } else if (a.startsWith('--')) throw invalid(`unknown flag ${a}`);
        else o._.push(a);
    }
    return o;
}

const intOf = (v, name) => {
    if (!/^-?\d+$/.test(String(v))) throw invalid(`${name} must be an integer`);
    return Number(v);
};

async function main() {
    const o = parseArgs(process.argv.slice(2));
    const [cmd, id, ...extra] = o._;
    if (!o.doc) throw invalid('--doc is required');
    if (!['set', 'rm', 'list'].includes(cmd)) throw invalid('usage: --doc <doc> set|rm|list');
    if (extra.length || (cmd === 'list' && id)) throw invalid('unexpected argument');
    if (cmd === 'list') {
        try { realpathSync(o.doc); } catch (e) { throw invalid(`cannot resolve --doc: ${e.message}`); }
        const r = await readSections(o.doc);
        if (r.error) throw invalid(r.error);
        for (const s of r.sections) console.log(`${s.id}\t${s.order}\t${s.tone}\t${String(s.title).replace(/[\t\r\n]/g, ' ')}`);
        return;
    }
    const expectRev = o['expect-rev'] === undefined ? undefined : intOf(o['expect-rev'], '--expect-rev');
    let op;
    if (cmd === 'rm') op = { kind: 'rm', id, expectRev };
    else {
        if (o.body !== undefined && o['body-file'] !== undefined) throw invalid('--body and --body-file are exclusive');
        let body = o.body;
        if (o['body-file'] !== undefined) {
            try { body = await fs.readFile(o['body-file'], 'utf8'); } catch (e) { throw invalid(`cannot read --body-file: ${e.message}`); }
        }
        op = {
            kind: 'set', id, title: o.title, body, tone: o.tone, expectRev,
            order: o.order === undefined ? undefined : intOf(o.order, '--order'),
        };
    }
    const r = await applySection(o.doc, op);
    console.log(`rev: ${r.rev}`);
    if (cmd === 'set') console.log(`redacted: ${r.redacted}`);
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
    main().catch((e) => {
        console.error(`board-section: ${e.message}`);
        process.exit(e.code === 'REV' ? 3 : 2);
    });
}
