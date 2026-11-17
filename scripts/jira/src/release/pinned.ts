import { createHash } from 'node:crypto';
import { closeSync, constants, fstatSync, openSync, readSync, opendirSync } from 'node:fs';
import { isAbsolute, normalize, basename, join } from 'node:path';

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

// Read entries incrementally so an untrusted directory cannot allocate an unbounded list.
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

// Shape validation is lexical and pure. Consumers must separately verify canonical locations and bytes.
export function validateCappedFoldProof(value: unknown): CappedFoldProof {
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

const REVIEWED = /^Reviewed: spec ([0-9a-f]{64})\b/gm;

export function reviewedSpecHashes(text: string): string[] {
  return [...text.matchAll(REVIEWED)].map((m) => m[1]);
}
