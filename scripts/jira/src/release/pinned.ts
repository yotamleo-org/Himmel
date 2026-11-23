import { createHash } from 'node:crypto';
import { closeSync, constants, fstatSync, openSync, readSync, opendirSync, realpathSync } from 'node:fs';
import { isAbsolute, normalize, basename, dirname, join } from 'node:path';

const PINNED_MAX = 16 * 1024 * 1024;
export type Pinned = { bytes: Buffer; sha256: string } | { missing: true } | { unreadable: true };

// A pinned file is read once from one non-blocking fd: a FIFO, a device, a directory or a file over 16 MiB
// is unreadable, so a planted path never blocks the reader nor costs it more than 16 MiB.
export type PinnedRead = (Extract<Pinned, { bytes: Buffer }> & { mtime_ms: number }) | Exclude<Pinned, { bytes: Buffer }>;

export function pinnedRead(path: string): PinnedRead {
  let fd: number;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK);
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'ENOENT' ? { missing: true } : { unreadable: true };
  }
  try {
    const st = fstatSync(fd);
    if (!st.isFile() || st.size > PINNED_MAX) return { unreadable: true };
    const buf = Buffer.alloc(st.size + 1);
    let n = 0;
    for (let r = 1; r > 0 && n < buf.length; n += r) r = readSync(fd, buf, n, buf.length - n, null);
    if (n > st.size) return { unreadable: true };
    const bytes = buf.subarray(0, n);
    return { bytes, sha256: createHash('sha256').update(bytes).digest('hex'), mtime_ms: st.mtimeMs };
  } catch {
    return { unreadable: true };
  } finally {
    closeSync(fd);
  }
}

export function pinnedSha(path: string): Pinned {
  const read = pinnedRead(path);
  return 'bytes' in read ? { bytes: read.bytes, sha256: read.sha256 } : read;
}

export function returnSha(text: string): string {
  const lines = text.split('\n').filter(l => !l.startsWith('CONTENT-SHA256 ')).map(l => l.trimEnd());
  while (lines.length && lines.at(-1) === '') lines.pop();
  return createHash('sha256').update(Buffer.from(lines.length ? `${lines.join('\n')}\n` : '')).digest('hex');
}

export function boundedDirectoryNames(path: string): string[] {
  let dir;
  try { dir = opendirSync(path); }
  catch (e) {
    if (['ENOENT', 'ENOTDIR'].includes((e as NodeJS.ErrnoException).code ?? '')) return [];
    throw new Error(`${path}: cannot read the folder (${e instanceof Error ? e.message : e}); the page is not sent`);
  }
  try {
    const names: string[] = [];
    for (let entry = dir.readSync(); entry; entry = dir.readSync()) {
      if (names.length === 4096) throw new Error(`${path}: directory entry limit (4096) exceeded`);
      names.push(entry.name);
    }
    return names.sort();
  } finally { dir.closeSync(); }
}

export function selectDecisionNames(names: readonly string[], decision: string): string[] {
  if (!/^[0-9]+$/.test(decision)) throw new Error(`'${decision}' is not a decision number`);
  const pattern = new RegExp(`^verbatim-decision-${decision}-.*\\.txt$`);
  return names.filter(name => pattern.test(name)).sort();
}

export const SIGNATURE_DIRS = new Set(['design', 'designs', 'spec', 'plan', 'plans']);
export const KEY_FOLDER = /^[A-Z][A-Z0-9]+-[0-9]+$/;
export const CRITIC_FILE = /^(.+?)\.critic-(?:(spec|plan)-r(\d+)|r(\d+)-(spec|plan))\.md$/;
export const CRITIC_NAME = /^(.+?)\.critic-(?:(spec|plan)-)?r(\d+)[a-z]?\.md$/;
export const specsRootOf = (p: string) => { const parts = p.split('/'); const i = parts.lastIndexOf('specs'); return i < 0 ? null : parts.slice(0, i + 1).join('/'); };

export function keyOf(specPath: string): string | null {
  const parts = specPath.split('/');
  const folder = parts.at(-2);
  if (folder && KEY_FOLDER.test(folder) && parts.at(-3) === 'specs') return folder;
  return /^([A-Z][A-Z0-9]+-[0-9]+)(?=[-.])/.exec(parts.at(-1) ?? '')?.[1] ?? null;
}

export function canonicalDirectoryNames(directory: string) {
  let canonical: string | null;
  try { canonical = realpathSync(directory); }
  catch (e) {
    if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e;
    canonical = null;
  }
  if (canonical !== null && canonical !== directory) throw new Error(`capped-fold: directory lookup must be canonical: ${directory}`);
  return { canonical, names: boundedDirectoryNames(directory) };
}

export function returnDirectories(key: string, spec: string, plan: string, expected: readonly ReturnPin[]): string[] {
  const specs = specsRootOf(spec);
  if (!specs) throw new Error('capped-fold: spec must be under a specs root');
  return [...new Set([dirname(spec), dirname(plan), ...expected.map(r => dirname(r.path)), ...[...SIGNATURE_DIRS, key].map(d => join(specs, d))])];
}

export function checkLatestReturns(directory: string, names: readonly string[], key: string, expected: [ReturnPin, ReturnPin], history?: ReadonlySet<string>): void {
  for (const name of names) {
    const normal = CRITIC_FILE.exec(name); const legacy = CRITIC_NAME.exec(name);
    const stem = normal?.[1] ?? legacy?.[1];
    if (!stem || keyOf(join(directory, stem)) !== key) continue;
    const kind = (normal?.[2] ?? normal?.[5] ?? legacy?.[2]) as Kind | undefined;
    const round = Number(normal?.[3] ?? normal?.[4] ?? legacy?.[3]);
    const candidates = kind ? [expected[kind === 'spec' ? 0 : 1]] : expected;
    const path = join(directory, name);
    if (candidates.some(current => round >= current.round && path !== current.path && !history?.has(path))) throw new Error(`capped-fold: ambiguous or unaccounted latest return: ${path}`);
  }
}

const LEDGER_FILE_SUFFIX = '.jsonl';
export const ledgerDirOf = (specs: string): string => join(specs, 'ledgers', 'spec-rounds');
export const ledgerEntryNames = (key: string): { file: string; folder: string; lock: string } =>
  ({ file: `${key}${LEDGER_FILE_SUFFIX}`, folder: key, lock: `${key}${LEDGER_FILE_SUFFIX}.lock` });
export const ledgerKeyOfFile = (name: string): string | null =>
  name.endsWith(LEDGER_FILE_SUFFIX) ? name.slice(0, -LEDGER_FILE_SUFFIX.length) : null;

export function parseManifest(text: string): { keys: Record<string, unknown> } | null {
  let manifest: { keys?: unknown } | null;
  try { manifest = JSON.parse(text); } catch { return null; }
  if (!manifest || typeof manifest.keys !== 'object' || manifest.keys === null || Array.isArray(manifest.keys)) return null;
  return manifest as { keys: Record<string, unknown> };
}

export function memberLedgerState(listing: readonly string[], manifestKeys: readonly string[], members: readonly string[]): { present: string[] } {
  const listed = new Set(listing); const manifested = new Set(manifestKeys);
  return { present: members.filter(key => { const names = ledgerEntryNames(key); return listed.has(names.file) || listed.has(names.folder) || manifested.has(key); }) };
}

export const PINNED_READ_VERSION = 1;
export type Kind = 'spec' | 'plan';
export type FilePin = { path: string; sha256: string };
export type EvidenceFilePin = FilePin & {
  role: 'ledger' | 'manifest' | 'return' | 'artifact' | 'snapshot' | 'decision';
  mtime_ms?: number;
};
export type DecisionSelectionPin = { role: 'decision-selection'; directory: string; decision: string; names: string[] };
export type EvidencePin = EvidenceFilePin | DecisionSelectionPin;
export type ReturnPin = FilePin & { kind: Kind; round: number; return_sha: string; residuals: number };
export type Carried = {
  key: string; epoch: number; kind: Kind; round: number; return_path: string;
  return_sha: string; finding_id: string; severity: 'minor' | 'medium'; status: 'open-carried';
};
export type CappedFoldProof = {
  schema: 1; reader_version: 1; mode: 'capped-carry'; key: string; epoch: number;
  spec: FilePin; plan: FilePin; returns: [ReturnPin, ReturnPin]; pins: EvidencePin[]; carried: Carried[];
};
export const LEDGER_READ_VERSION = 2;
export type HistoryPin = FilePin & { role: 'history' };
export type MemberAbsencePin = { role: 'member-absence'; directory: string; keys: string[] };
export type LedgerEvidencePin = EvidencePin | HistoryPin | MemberAbsencePin;
export type CappedLedgerProof = {
  schema: 2; reader_version: 2; mode: 'capped-carry-ledger'; anchor: string; keys: string[]; epoch: number;
  spec: FilePin; plan: FilePin; returns: [ReturnPin, ReturnPin]; pins: LedgerEvidencePin[]; carried: Carried[];
};
export type AnyCappedProof = CappedFoldProof | CappedLedgerProof;

function proofAssert(ok: unknown): asserts ok {
  if (!ok) throw new Error('invalid capped-fold proof');
}
function fields(value: unknown, required: string[]): Record<string, unknown> {
  proofAssert(value !== null && typeof value === 'object' && !Array.isArray(value));
  const keys = Object.keys(value);
  proofAssert(keys.length === required.length && required.every(k => Object.hasOwn(value, k)));
  return value as Record<string, unknown>;
}
const count = (value: unknown, min = 0) => Number.isSafeInteger(value) && (value as number) >= min;
const hash = (value: unknown) => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const pathShape = (value: unknown) => typeof value === 'string' && !value.includes('\0') && isAbsolute(value)
  && normalize(value) === value && (value === '/' || !value.endsWith('/'));
function fileShape(value: Record<string, unknown>): void {
  proofAssert(pathShape(value.path) && hash(value.sha256));
}
function boundedArray(value: unknown): asserts value is unknown[] {
  proofAssert(Array.isArray(value) && value.length <= 4096);
}

export function validateCappedFoldProofShape(value: unknown): CappedFoldProof {
  const p = fields(value, ['schema', 'reader_version', 'mode', 'key', 'epoch', 'spec', 'plan', 'returns', 'pins', 'carried']);
  proofAssert(p.schema === 1 && p.reader_version === PINNED_READ_VERSION && p.mode === 'capped-carry');
  proofAssert(typeof p.key === 'string' && /^[A-Z][A-Z0-9]*-[0-9]+$/.test(p.key) && count(p.epoch));
  fileShape(fields(p.spec, ['path', 'sha256'])); fileShape(fields(p.plan, ['path', 'sha256']));
  proofAssert(Array.isArray(p.returns) && p.returns.length === 2);
  const returns = p.returns.map((v, i) => {
    const r = fields(v, ['path', 'sha256', 'kind', 'round', 'return_sha', 'residuals']);
    fileShape(r);
    proofAssert(r.kind === (i === 0 ? 'spec' : 'plan') && count(r.round, 1) && hash(r.return_sha) && count(r.residuals));
    return r as ReturnPin;
  });
  boundedArray(p.pins); boundedArray(p.carried);
  const files = new Map<string, EvidenceFilePin>(); const selections: DecisionSelectionPin[] = [];
  for (const pin of p.pins) {
    proofAssert(pin !== null && typeof pin === 'object');
    if ((pin as Record<string, unknown>).role === 'decision-selection') {
      const s = fields(pin, ['role', 'directory', 'decision', 'names']);
      proofAssert(pathShape(s.directory) && typeof s.decision === 'string');
      boundedArray(s.names);
      proofAssert(s.names.length === 1 && s.names.every(n => typeof n === 'string' && basename(n) === n && !n.includes('\0')));
      const names = s.names as string[];
      let matches: string[];
      try { matches = selectDecisionNames(names, s.decision); } catch { throw new Error('invalid capped-fold proof'); }
      proofAssert(matches.length === names.length && matches.every((n, i) => n === names[i]));
      selections.push(s as DecisionSelectionPin);
    } else {
      const role = (pin as Record<string, unknown>).role;
      proofAssert(typeof role === 'string' && ['ledger', 'manifest', 'return', 'artifact', 'snapshot', 'decision'].includes(role));
      const f = fields(pin, role === 'decision' ? ['role', 'path', 'sha256', 'mtime_ms'] : ['role', 'path', 'sha256']);
      fileShape(f);
      if (role === 'decision') proofAssert(typeof f.mtime_ms === 'number' && Number.isFinite(f.mtime_ms));
      proofAssert(!files.has(f.path as string));
      files.set(f.path as string, f as EvidenceFilePin);
    }
  }
  for (const role of ['ledger', 'manifest']) proofAssert([...files.values()].filter(f => f.role === role).length === 1);
  for (const r of returns) proofAssert(files.get(r.path)?.role === 'return' && files.get(r.path)?.sha256 === r.sha256);
  for (const artifact of [p.spec, p.plan] as FilePin[]) proofAssert(files.get(artifact.path)?.role === 'artifact' && files.get(artifact.path)?.sha256 === artifact.sha256);
  const selected = new Set<string>(); const selectionKeys = new Set<string>();
  for (const s of selections) {
    const key = JSON.stringify([s.directory, s.decision]);
    proofAssert(!selectionKeys.has(key)); selectionKeys.add(key);
    const path = join(s.directory, s.names[0]);
    proofAssert(!selected.has(path) && files.get(path)?.role === 'decision');
    selected.add(path);
  }
  for (const f of files.values()) if (f.role === 'decision') proofAssert(selected.has(f.path));
  const identities = new Set<string>(); const residuals = { spec: 0, plan: 0 };
  for (const item of p.carried) {
    const c = fields(item, ['key', 'epoch', 'kind', 'round', 'return_path', 'return_sha', 'finding_id', 'severity', 'status']);
    proofAssert(c.key === p.key && c.epoch === p.epoch && (c.kind === 'spec' || c.kind === 'plan'));
    const r = returns[c.kind === 'spec' ? 0 : 1];
    proofAssert(c.round === r.round && c.return_path === r.path && c.return_sha === r.return_sha);
    proofAssert(typeof c.finding_id === 'string' && /^[A-Za-z][\w.-]*$/.test(c.finding_id));
    proofAssert((c.severity === 'minor' || c.severity === 'medium') && c.status === 'open-carried');
    const identity = JSON.stringify([c.key, c.epoch, c.kind, c.round, c.return_sha, c.finding_id]);
    proofAssert(!identities.has(identity)); identities.add(identity); residuals[c.kind]++;
  }
  proofAssert(returns.every(r => residuals[r.kind] === r.residuals));
  return value as CappedFoldProof;
}

const TICKET_KEY = /^[A-Z][A-Z0-9]*-[0-9]+$/;
const ticketKey = (value: unknown): value is string => typeof value === 'string' && TICKET_KEY.test(value);

export function validateCappedLedgerProofShape(value: unknown): CappedLedgerProof {
  const p = fields(value, ['schema', 'reader_version', 'mode', 'anchor', 'keys', 'epoch', 'spec', 'plan', 'returns', 'pins', 'carried']);
  proofAssert(p.schema === 2 && p.reader_version === LEDGER_READ_VERSION && p.mode === 'capped-carry-ledger');
  proofAssert(ticketKey(p.anchor) && count(p.epoch));
  boundedArray(p.keys);
  const keys = p.keys;
  proofAssert(keys.length >= 1 && keys.every((k, i) => ticketKey(k) && (i === 0 || (keys[i - 1] as string) < k)) && keys.includes(p.anchor));
  fileShape(fields(p.spec, ['path', 'sha256'])); fileShape(fields(p.plan, ['path', 'sha256']));
  proofAssert(Array.isArray(p.returns) && p.returns.length === 2);
  const returns = p.returns.map((v, i) => {
    const r = fields(v, ['path', 'sha256', 'kind', 'round', 'return_sha', 'residuals']);
    fileShape(r);
    proofAssert(r.kind === (i === 0 ? 'spec' : 'plan') && count(r.round, 1) && hash(r.return_sha) && count(r.residuals));
    return r as ReturnPin;
  });
  boundedArray(p.pins); boundedArray(p.carried);
  const files = new Map<string, FilePin & { role: string }>(); const selections: DecisionSelectionPin[] = []; const absences: MemberAbsencePin[] = [];
  for (const pin of p.pins) {
    proofAssert(pin !== null && typeof pin === 'object');
    const role = (pin as Record<string, unknown>).role;
    if (role === 'decision-selection') {
      const s = fields(pin, ['role', 'directory', 'decision', 'names']);
      proofAssert(pathShape(s.directory) && typeof s.decision === 'string');
      boundedArray(s.names);
      proofAssert(s.names.length === 1 && s.names.every(n => typeof n === 'string' && basename(n) === n && !n.includes('\0')));
      const names = s.names as string[];
      let matches: string[];
      try { matches = selectDecisionNames(names, s.decision); } catch { throw new Error('invalid capped-fold proof'); }
      proofAssert(matches.length === names.length && matches.every((n, i) => n === names[i]));
      selections.push(s as DecisionSelectionPin);
    } else if (role === 'member-absence') {
      const a = fields(pin, ['role', 'directory', 'keys']);
      boundedArray(a.keys);
      proofAssert(pathShape(a.directory) && a.keys.every(k => typeof k === 'string'));
      absences.push(a as MemberAbsencePin);
    } else {
      proofAssert(typeof role === 'string' && ['ledger', 'manifest', 'return', 'artifact', 'snapshot', 'decision', 'history'].includes(role));
      const f = fields(pin, role === 'decision' ? ['role', 'path', 'sha256', 'mtime_ms'] : ['role', 'path', 'sha256']);
      fileShape(f);
      if (role === 'decision') proofAssert(typeof f.mtime_ms === 'number' && Number.isFinite(f.mtime_ms));
      proofAssert(!files.has(f.path as string));
      files.set(f.path as string, f as FilePin & { role: string });
    }
  }
  for (const role of ['ledger', 'manifest']) proofAssert([...files.values()].filter(f => f.role === role).length === 1);
  for (const r of returns) proofAssert(files.get(r.path)?.role === 'return' && files.get(r.path)?.sha256 === r.sha256);
  for (const artifact of [p.spec, p.plan] as FilePin[]) proofAssert(files.get(artifact.path)?.role === 'artifact' && files.get(artifact.path)?.sha256 === artifact.sha256);
  const selected = new Set<string>(); const selectionKeys = new Set<string>();
  for (const s of selections) {
    const key = JSON.stringify([s.directory, s.decision]);
    proofAssert(!selectionKeys.has(key)); selectionKeys.add(key);
    const path = join(s.directory, s.names[0]);
    proofAssert(!selected.has(path) && files.get(path)?.role === 'decision');
    selected.add(path);
  }
  for (const f of files.values()) if (f.role === 'decision') proofAssert(selected.has(f.path));
  proofAssert(absences.length === (keys.length > 1 ? 1 : 0));
  if (absences.length === 1) {
    const members = keys.filter(k => k !== p.anchor); const specs = specsRootOf((p.spec as FilePin).path);
    proofAssert(specs !== null && absences[0].directory === ledgerDirOf(specs));
    proofAssert(absences[0].keys.length === members.length && absences[0].keys.every((k, i) => k === members[i]));
  }
  const identities = new Set<string>(); const residuals = { spec: 0, plan: 0 };
  for (const item of p.carried) {
    const c = fields(item, ['key', 'epoch', 'kind', 'round', 'return_path', 'return_sha', 'finding_id', 'severity', 'status']);
    proofAssert(c.key === p.anchor && c.epoch === p.epoch && (c.kind === 'spec' || c.kind === 'plan'));
    const r = returns[c.kind === 'spec' ? 0 : 1];
    proofAssert(c.round === r.round && c.return_path === r.path && c.return_sha === r.return_sha);
    proofAssert(typeof c.finding_id === 'string' && /^[A-Za-z][\w.-]*$/.test(c.finding_id));
    proofAssert((c.severity === 'minor' || c.severity === 'medium') && c.status === 'open-carried');
    const identity = JSON.stringify([c.key, c.epoch, c.kind, c.round, c.return_sha, c.finding_id]);
    proofAssert(!identities.has(identity)); identities.add(identity); residuals[c.kind]++;
  }
  proofAssert(returns.every(r => residuals[r.kind] === r.residuals));
  return value as CappedLedgerProof;
}

export function validateCappedProofShape(value: unknown): AnyCappedProof {
  const schema = value !== null && typeof value === 'object' ? (value as Record<string, unknown>).schema : undefined;
  proofAssert(schema === 1 || schema === 2);
  return schema === 1 ? validateCappedFoldProofShape(value) : validateCappedLedgerProofShape(value);
}

const ANNOTATION_MAX = 200;
const FRONT_MATTER = /^---\n([\s\S]*?)\n---(?:\n|$)/;
const TICKET_ITEM = /^([A-Z][A-Z0-9]*-[0-9]+)[ \t]*(?:\(([^()]*)\))?$/;
const KEY_SHAPED = /[A-Z][A-Z0-9]*-[0-9]+/;

export function declaredTickets(specText: string): string[] | null {
  const front = FRONT_MATTER.exec(specText)?.[1];
  if (front === undefined) return null;
  const lines = [...front.matchAll(/^tickets:[ \t]*(.*)$/gm)];
  if (lines.length !== 1) return null;
  let value = lines[0][1].trim();
  if (value.startsWith('[')) {
    if (!value.endsWith(']')) return null;
    value = value.slice(1, -1);
  }
  const items: string[] = []; let depth = 0; let start = 0;
  for (let i = 0; i <= value.length; i++) {
    const c = value[i];
    if (c === '(') depth++;
    else if (c === ')') depth--;
    else if (i === value.length || (c === ',' && depth === 0)) {
      if (items.length === 4096) return null;
      items.push(value.slice(start, i)); start = i + 1;
    }
  }
  const keys: string[] = []; const seen = new Set<string>();
  for (const item of items) {
    const match = TICKET_ITEM.exec(item.trim());
    if (!match || seen.has(match[1])) return null;
    if (match[2] !== undefined && (match[2].length > ANNOTATION_MAX || KEY_SHAPED.test(match[2]))) return null;
    keys.push(match[1]); seen.add(match[1]);
  }
  return keys;
}

export const FINDING_ID = '[A-Za-z][\\w.-]*';
export const FINDING_LINE = new RegExp(`^[-*] \\*\\*(${FINDING_ID})\\*\\* \\(([^)]*)\\)`);
export const FINDING_SEVERITIES = ['major', 'medium', 'minor'] as const;
export const findingTags = (parenthetical: string): string[] => parenthetical.replace(/`[^`]*(`|$)/g, '').split(';').map(s => s.trim());

export function findingIds(text: string): string[] {
  const ids: string[] = [];
  for (const line of text.split('\n')) {
    const m = FINDING_LINE.exec(line);
    if (!m || !(FINDING_SEVERITIES as readonly string[]).includes(findingTags(m[2])[0])) continue;
    if (ids.includes(m[1])) throw new Error(`duplicate ${m[1]}`);
    ids.push(m[1]);
  }
  return ids;
}

const DISPOSITION_WORD = '(?:fixed|ASSUMPTION|ceiling|ponytail|deferred)';
const LEGACY_LINE = /^\s*[-*]\s+R(\d+):\s+(fixed|ASSUMPTION|ceiling|ponytail|deferred → HIMMEL-\d+)\b/;
const QUALIFIED_LINE = new RegExp(`^\\s*[-*]\\s+([RP])(\\d+)[- ](${FINDING_ID}):\\s+(?:fixed|ASSUMPTION|ceiling|ponytail|deferred (?:→|->) HIMMEL-\\d+)\\b`);
const ID_LIST_LINE = new RegExp(`^\\s*[-*]\\s+R\\d+:\\s+(?=[A-Za-z][\\w.-]*\\d)${FINDING_ID}(?:\\s*,\\s*(?:${FINDING_ID}|\\d+))*\\s+${DISPOSITION_WORD}\\b`);
const NEAR_MISS_LINE = new RegExp(`^\\s*[-*]\\s+([RP])(\\d+)[- ][^\\s:]+:\\s*${DISPOSITION_WORD}\\b`);

export function criticRounds(specText: string): string[] {
  const lines = specText.split('\n');
  const start = lines.findIndex((l) => /^##\s+critic rounds\s*$/i.test(l));
  if (start < 0) return [];
  const end = lines.slice(start + 1).findIndex((l) => /^##?\s/.test(l));
  return lines.slice(start + 1, end < 0 ? lines.length : start + 1 + end);
}

export type QualifiedResidual ={ kind: Kind; round: number; id: string; line: string };
export type ResidualLines = { legacy: Set<number>; qualified: QualifiedResidual[]; idList: string[]; nearMiss: string[] };

export function parseResidualLines(section: readonly string[]): ResidualLines {
  const out: ResidualLines = { legacy: new Set(), qualified: [], idList: [], nearMiss: [] };
  const heads: { kind: Kind; round: number; line: string }[] = [];
  for (const line of section) {
    const q = QUALIFIED_LINE.exec(line);
    const legacy = q ? null : LEGACY_LINE.exec(line);
    const near = q || legacy ? null : NEAR_MISS_LINE.exec(line);
    if (q) out.qualified.push({ kind: q[1] === 'R' ? 'spec' : 'plan', round: Number(q[2]), id: q[3], line });
    else if (legacy) out.legacy.add(Number(legacy[1]));
    else if (ID_LIST_LINE.test(line)) out.idList.push(line);
    else if (near) heads.push({ kind: near[1] === 'R' ? 'spec' : 'plan', round: Number(near[2]), line });
  }
  const top = (kind: Kind) => Math.max(-1, ...out.qualified.filter(q => q.kind === kind).map(q => q.round));
  out.nearMiss = heads.filter(h => h.round === top(h.kind)).map(h => h.line);
  return out;
}

const REVIEWED = /^Reviewed: spec ([0-9a-f]{64})\b/gm;

export function reviewedSpecHashes(text: string): string[] {
  return [...text.matchAll(REVIEWED)].map((m) => m[1]);
}

const RETURN_KEYS_LINE = /^Keys?:[ \t]*(.*)$/gm;
const RETURN_REVIEWED_LINE = /^Reviewed:[ \t]+spec\b[^\n]*/gm;
const RETURN_REVIEWED_VALUE = /^Reviewed:[ \t]+spec[ \t]+([0-9a-f]{64})(?:,[ \t]+plan[ \t]+[0-9a-f]{64})?[ \t]*\r?$/;

function keysLineNames(value: string, keys: readonly string[]): boolean {
  let list = value.trim();
  if (list.startsWith('[') && list.endsWith(']')) list = list.slice(1, -1);
  const named = list.split(',').map(k => k.trim()); const expected = new Set(keys);
  return named.length === expected.size && new Set(named).size === named.length && named.every(k => expected.has(k));
}

export function optionalReturnAgreement(text: string, expect: { keys?: readonly string[]; specSha?: string }): void {
  if (expect.keys !== undefined) {
    const lines = [...text.matchAll(RETURN_KEYS_LINE)];
    if (lines.length > 1 || (lines.length === 1 && !keysLineNames(lines[0][1], expect.keys))) throw new Error('capped return Keys? declaration disagrees with the declared keys');
  }
  if (expect.specSha !== undefined) {
    const lines = [...text.matchAll(RETURN_REVIEWED_LINE)];
    if (lines.length > 1 || (lines.length === 1 && RETURN_REVIEWED_VALUE.exec(lines[0][0])?.[1] !== expect.specSha)) throw new Error('capped return Reviewed declaration disagrees with the current spec');
  }
}
