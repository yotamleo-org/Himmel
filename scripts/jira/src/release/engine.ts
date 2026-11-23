import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { hostname } from 'node:os';
import { basename, dirname, isAbsolute, join } from 'node:path';
import { releaseRoot } from './paths.js';
export { pinnedSha, type Pinned } from './pinned.js';
import { journalPath, readVersionWrites, type Getter, type VersionWriteRow } from './version-writes.js';
import { appendChain, contentSha, mintKey, readChain, readSigned, withLock, withLockAsync, writeSigned, type Chain } from './ledger.js';
import { SECTOR_OPT_OUT, sectorField } from '../commands/sector.js';
import { appendAdmission, assertAdmissionsWritable, readAdmissions, readAdmissionsTolerant, type Admission } from '../commands/admissions-ledger.js';
import { baselineId, effectOn, reduce, recordOf, scopeOk, terminalOf, unknownState, type ReleaseState } from './reducer.js';
import { checkWords, decisionsDirFor, resolveDecision } from './verbatim.js';
import { asksOperator, type TicketFacts } from './operator-work.js';
import { judgeOperatorRows } from './judge-input.js';
import type { Authority, Baseline, Declaration, EventRow, IssueSnap, Lease, Op, OperatorRow, OutOfVersionRow, PlacementClass, RequestRow, RulingRow, Verb } from './types.js';
import { type JiraPort, type Ctx, f, ts, seq, operatorFence, type Loaded, load, loadOrThrow, locked, lockedAcross, readMirror, appendOperator, type ReleaseRecord, readOperatorRecords } from './engine-core.js';
export { operatorFence, readMirror, readMirrorFilesUnverified, readOperatorRecords, type Ctx, type JiraPort, type ReleaseRecord } from './engine-core.js';
export { signSpec, specCheck, specReview, type SpecAnswer } from './spec-sign.js';

// The release engine's I/O (design §5). The authority files under release/<R>/ are written from
// this file, spec-sign.ts and engine-core.ts. Every caller reads `jira release state --json`.

const OUTCOMES: Record<Verb, Record<string, Op['kind'][]>> = {
  INTAKE: { ADMIT: ['add', 'move'], BACKLOG: ['remove', 'move', 'none'], 'AD-HOC': ['none'] },
  REVERSION: { MOVE: ['move', 'remove'], KEEP: ['keep'] },
  DISCHARGE: { ACCEPT: ['discharge'], REJECT: ['none'] },
};

// Idempotent (a clean key makes no write); reads back and fails loud when a label survives.
export async function clearProposedLabels(jira: Pick<JiraPort, 'labels' | 'removeLabels'>, key: string): Promise<string[]> {
  const proposed = (await jira.labels(key)).filter((l) => /^proposed-/.test(l));
  if (!proposed.length) return [];
  await jira.removeLabels(key, proposed);
  const left = (await jira.labels(key)).filter((l) => /^proposed-/.test(l));
  if (left.length) throw new Error(`release: ${key} still carries ${left.join(', ')} after the removal; clear it by hand (jira edit ${key} --labels)`);
  return proposed;
}

function lockedAsync<T>(ctx: Ctx, fn: (l: Loaded) => Promise<T>): Promise<T> {
  loadOrThrow(ctx);
  return withLockAsync(ctx.dir, () => fn(loadOrThrow(ctx)));
}

function reduceLoaded(l: Loaded, mirror: ReturnType<typeof readMirror>): ReleaseState {
  return reduce({
    decl: l.decl, baselines: l.baselines, base_history: l.base_history, rulings: l.rulings, operator: l.operator, events: l.events,
    issues: mirror.issues, mirrorSync: mirror.sync, admissions: admissionsOrNull(),
  });
}

// A bad ledger line (or no ledger location) reads UNKNOWN for the reducer's admissions input only: the overall
// status stays OK, so rm-queue and rm-run keep working on one bad line in an unsigned, lock-free ledger.
function admissionsOrNull(): Admission[] | null {
  try {
    return readAdmissions();
  } catch {
    return null;
  }
}

function readLease(ctx: Ctx, k: Buffer): Lease {
  const p = f(ctx, 'lease.json');
  if (!existsSync(p)) {
    return { release: ctx.release, epoch: 0, owner_session: null, owner_doc: null, acquired: null, released: true, prev_epoch: null };
  }
  const l = readSigned<Lease>(p, k);
  if (!l.ok || !l.value) throw new Error(`release ${ctx.release} is UNKNOWN: lease.json does not verify`);
  return l.value;
}

function latestRequests(requests: Chain<RequestRow>): Map<string, RequestRow> {
  if (requests.bad.length) throw new Error(`release: requests.jsonl does not verify (${requests.bad[0]})`);
  const m = new Map<string, RequestRow>();
  for (const r of requests.verified) m.set(r.req, r);
  return m;
}

// --- operator acts (the chief, on an operator decision) ---------------------

export function declare(ctx: Ctx, o: { project: string; versions: string[]; decision: string; verbatim: string; mode: Declaration['mode'] }): Declaration {
  operatorFence(ctx);
  if (!/^[A-Za-z0-9._-]+$/.test(ctx.release)) throw new Error(`release: bad release name '${ctx.release}'`);
  if (!o.versions.length) throw new Error('release operator declare: --versions needs at least one version');
  if (o.mode === 'live') throw new Error('release operator declare: a release is declared observe; live waits for the signed activation barrier');
  if (existsSync(f(ctx, 'release.json'))) throw new Error(`release ${ctx.release} is already declared`);
  mkdirSync(ctx.dir, { recursive: true });
  const k = mintKey(ctx.keyPath);
  return withLock(ctx.dir, () => {
    const decl: Declaration = {
      project: o.project, release: ctx.release, versions: o.versions, current: o.versions[0], mode: o.mode,
      decision: o.decision, ts: ts(ctx),
    };
    writeSigned(f(ctx, 'release.json'), k, decl);
    appendOperator(ctx, k, { kind: 'declare', decision: o.decision, verbatim: o.verbatim, file: 'release.json', sha: contentSha(decl) });
    appendOperator(ctx, k, {
      id: `O-${ctx.release}-emergency`, kind: 'emergency', decision: '109',
      verbatim: 'standing record: an evidenced emergency (Highest or Blocker, a red main run, or a regression of a merged PR) is placed in the current version',
    });
    appendOperator(ctx, k, { id: `O-${ctx.release}-blocker-pull`, kind: 'blocker-pull', decision: BLOCKER_PULL_DECISION, verbatim: BLOCKER_PULL_VERBATIM });
    appendOperator(ctx, k, { id: `O-${ctx.release}-delivered-follows-merge`, kind: 'delivered-follows-merge', decision: DELIVERED_DECISION, verbatim: DELIVERED_VERBATIM });
    return decl;
  });
}

const DELIVERED_DECISION = '929';
const DELIVERED_VERBATIM = 'standing record: a ticket whose work merges while it sits in a later version moves to the version open at merge time ("471 standing it should move to 1.1.3")';

// Decision 385: a blocker of a current-version ticket is fixed in the current version as its related item.
const BLOCKER_PULL_DECISION = '385';
const BLOCKER_PULL_VERBATIM = 'standing record: a blocker of a ticket in the current version is placed in the current version as its related item';

// The standing records a release declared before they existed take their row from the chief here.
export function standing(ctx: Ctx, o: { kind: 'blocker-pull' | 'delivered-follows-merge'; decision: string; verbatim: string }): OperatorRow {
  operatorFence(ctx);
  if (o.kind !== 'blocker-pull' && o.kind !== 'delivered-follows-merge') throw new Error('release operator standing: --kind is blocker-pull or delivered-follows-merge');
  return locked(ctx, (l) => {
    const id = `O-${ctx.release}-${o.kind}`;
    if (l.operator.verified.some((x) => x.id === id)) throw new Error(`release operator standing: ${id} is already recorded`);
    return appendOperator(ctx, l.k, { id, kind: o.kind, decision: o.decision, verbatim: o.verbatim });
  });
}

export function freeze(ctx: Ctx, o: { version: string; keys: string[]; decision: string; verbatim: string }): Baseline {
  operatorFence(ctx);
  return locked(ctx, (l) => {
    if (!l.decl.versions.includes(o.version)) throw new Error(`release operator freeze: ${o.version} is not a version of ${ctx.release}`);
    const gen = 1 + l.operator.verified.filter((x) => x.kind === 'freeze' && x.file?.startsWith(`baseline-${o.version}-g`)).length;
    const b: Baseline = { release: ctx.release, version: o.version, gen, keys: [...new Set(o.keys)].sort(), decision: o.decision, ts: ts(ctx) };
    const resolved = new Set(l.rulings.verified.filter((r) => r.phase !== 'intent').map((r) => r.id));
    const pending = l.rulings.verified.find((r) => r.phase === 'intent' && !resolved.has(r.id)
      && b.keys.includes(r.key) && effectOn(r.op, o.version));
    if (pending) throw new Error(`release operator freeze: ${pending.id} is a pending intent on ${pending.key}@${o.version}; apply or void it first`);
    const file = `${baselineId(b)}.json`;
    if (existsSync(f(ctx, file))) throw new Error(`release: ${file} exists; a baseline is immutable`);
    writeSigned(f(ctx, file), l.k, b);
    appendOperator(ctx, l.k, { kind: 'freeze', decision: o.decision, verbatim: o.verbatim, file, sha: contentSha(b) });
    return b;
  });
}

type DecisionWords = { decision_file: string; decision_sha256: string; words: 1 };

export function decisionWords(ctx: Ctx, decision: string, words: string): DecisionWords {
  const d = resolveDecision(decisionsDirFor(ctx.dir), decision);
  const c = checkWords(d.text, words);
  if (!c.ok) throw new Error(`release: --words for decision ${decision} (${d.rel}): ${c.why}`);
  return { decision_file: d.rel, decision_sha256: d.sha256, words: 1 };
}

const sameKeys = (a: string[] = [], b: string[]) => a.length === b.length && [...a].sort().every((k, i) => k === [...b].sort()[i]);

export function operatorDecision(ctx: Ctx, o: { decision: string; keys: string[]; op: string; from_v: string | null; to_v: string | null; verbatim: string } & Partial<DecisionWords>): OperatorRow {
  operatorFence(ctx);
  if (!o.keys.length) throw new Error('release operator decision: --keys names the exact keys it covers');
  return locked(ctx, (l) => {
    const again = o.decision_sha256 === undefined ? undefined : l.operator.verified.find((x) => x.kind === 'decision' && x.decision === o.decision
      && sameKeys(x.keys, o.keys) && x.op === o.op && (x.from_v ?? null) === o.from_v && (x.to_v ?? null) === o.to_v
      && x.decision_sha256 === o.decision_sha256 && x.verbatim === o.verbatim);
    if (again) return again;
    const placement = placementOf(o);
    const latest = placement === undefined ? new Map<string, RequestRow>() : latestRequests(l.requests);
    const words = o.decision_sha256 === undefined ? {} : { decision_file: o.decision_file, decision_sha256: o.decision_sha256, words: 1 as const };
    const row = appendOperator(ctx, l.k, {
      kind: 'decision', decision: o.decision, keys: o.keys, op: o.op, from_v: o.from_v, to_v: o.to_v, verbatim: o.verbatim, ...words,
    });
    const named = [o.from_v, o.to_v].filter((v) => v !== null);
    for (const r of latest.values()) {
      const overlaps = [r.from_v, r.to_v].some((v) => v !== null && named.includes(v));
      if (retirable(r) && o.keys.includes(r.key) && overlaps && (r.verb === 'DISCHARGE' ? r.from_v : r.to_v) !== placement) {
        appendWithdrawal(ctx, l.k, r, row.id, `contradicts operator decision ${o.decision} (${row.id})`);
      }
    }
    return row;
  });
}

// Where an operator decision puts its keys; undefined for an op that places nothing.
export function placementOf(o: { op?: string; from_v?: string | null; to_v?: string | null }): string | null | undefined {
  if (o.op === 'keep' || o.op === 'discharge') return o.from_v ?? null;
  if (o.op === 'remove') return null;
  if (o.op === 'add' || o.op === 'move') return o.to_v ?? null;
  return undefined;
}

const pending = (r: RequestRow) => r.state === 'open' || r.state.startsWith('claimed:');
// A held version-repair request is not pending (request() dedupe and state() rely on that), but a chief act can still retire it.
const retirable = (r: RequestRow) => pending(r) || r.state === 'held';
const isRepair = (r: RequestRow | undefined): boolean => (r?.evidence as { rule?: unknown } | null)?.rule === 'version-repair';

function appendWithdrawal(ctx: Ctx, k: Buffer, r: RequestRow, by: string, reason: string): RequestRow {
  const { prev: _p, mac: _m, ...rest } = r;
  return appendChain<RequestRow>(f(ctx, 'requests.jsonl'), k, { ...rest, ts: ts(ctx), state: `withdrawn:${by}`, reason });
}

// The chief retires an open, claimed or held request with a reason; --by cites the
// operator decision that settles it, which must cover the request's key.
export function withdraw(ctx: Ctx, o: { req: string; reason: string; by?: string }): RequestRow {
  operatorFence(ctx);
  if (!o.reason.trim()) throw new Error('release withdraw: --reason is mandatory');
  return locked(ctx, (l) => {
    const r = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(o.req);
    if (!r) throw new Error(`release withdraw: no request ${o.req}`);
    if (!retirable(r)) throw new Error(`release withdraw: ${o.req} is ${r.state.startsWith('ruled:') ? 'ruled' : r.state}; only an open, claimed or held request is withdrawn`);
    if (o.by !== undefined) {
      const d = l.operator.verified.find((x) => x.id === o.by && x.kind === 'decision');
      if (!d) throw new Error(`release withdraw: ${o.by} is no verified decision row of ${ctx.release}`);
      if (!d.keys?.includes(r.key)) throw new Error(`release withdraw: ${o.by} does not cover ${r.key}`);
    }
    return appendWithdrawal(ctx, l.k, r, o.by ?? 'console', o.reason.trim());
  });
}

// The version repair retires a held repair request its classifier found answered or out of date: `withdrawn:repair`, with the reason.
export function withdrawHeldRepair(ctx: Ctx, o: { req: string; reason: string }): RequestRow | null {
  operatorFence(ctx);
  return locked(ctx, (l) => {
    const r = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(o.req);
    if (!r || r.state !== 'held' || !isRepair(r)) return null;
    return appendWithdrawal(ctx, l.k, r, 'repair', o.reason);
  });
}

export function takeover(ctx: Ctx, o: { epoch: number; doc: string }): OperatorRow {
  operatorFence(ctx);
  if (!isAbsolute(o.doc)) throw new Error('release operator takeover: the successor doc must be an absolute path');
  return locked(ctx, (l) => appendOperator(ctx, l.k, { kind: 'takeover', decision: null, epoch: o.epoch, doc: o.doc }));
}

// --- out-of-version approvals, the bucket check and the operator's words -----

export const OUT_OF_VERSION_MS = 14 * 86_400_000;

const byIso = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

export function outOfVersionApproval(env: Record<string, string | undefined>, key: string, now: Date): ReleaseRecord | null {
  let records: ReleaseRecord[];
  try {
    records = readOperatorRecords('out-of-version', env);
  } catch {
    return null;
  }
  return records.filter((r) => {
    const age = now.getTime() - Date.parse(r.ts);
    return r.keys?.includes(key) && age >= 0 && age < OUT_OF_VERSION_MS;
  }).sort((a, b) => byIso(a.ts, b.ts)).at(-1) ?? null;
}

export function poolCurrent(versionsTsv: string): string | null {
  const nat = (v: string) => v.split(/(\d+)/).map((x) => (/^\d+$/.test(x) ? Number(x) : x));
  const cmp = (a: string, b: string): number => {
    const x = nat(a);
    const y = nat(b);
    for (let i = 0; i < Math.min(x.length, y.length); i++) {
      if (x[i] === y[i]) continue;
      if (typeof x[i] === 'number' && typeof y[i] === 'number') return (x[i] as number) - (y[i] as number);
      return String(x[i]) < String(y[i]) ? -1 : 1;
    }
    return x.length - y.length;
  };
  return versionsTsv.split('\n').map((l) => l.split('\t'))
    .filter((p) => p.length >= 2 && p[1].trim() === 'false' && !(p.length >= 4 && p[3].trim() === 'true') && !p[0].startsWith('zz-'))
    .map((p) => p[0]).sort(cmp)[0] ?? null;
}

type ParsedDeclared = { path: string; parsed: true; project: unknown; current: unknown; ts: unknown };
type Declared = ParsedDeclared | { path: string; parsed: false };

const unparsedOrNamesProject = (d: Declared, project: string): boolean => !d.parsed || d.project === project;

function declaredReleases(env: Record<string, string | undefined>): Declared[] {
  const root = releaseRoot(env);
  if (!existsSync(root)) return [];
  return readdirSync(root).sort().flatMap((name): Declared[] => {
    const path = join(root, name, 'release.json');
    if (!existsSync(path)) return [];
    let got: unknown;
    try {
      got = JSON.parse(readFileSync(path, 'utf8'));
    } catch {
      return [{ path, parsed: false }];
    }
    if (got === null || typeof got !== 'object' || Array.isArray(got)) return [{ path, parsed: false }];
    const d = got as Record<string, unknown>;
    return [{ path, parsed: true, project: d.project, current: d.current, ts: d.ts }];
  });
}

function withinDeadline<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`no answer within ${ms} ms`)), ms);
  });
  return Promise.race([p, deadline]).finally(() => clearTimeout(timer));
}

export interface BucketOptions { get: Getter; deadlineMs: number; now: Date }

export async function bucketCheck(env: Record<string, string | undefined>, keys: string[], mirrorRoot: string, o: BucketOptions): Promise<string[]> {
  const { issues } = readMirror(mirrorRoot);
  const versionsPath = `${mirrorRoot.replace(/\/+$/, '')}.versions.tsv`;
  const lines: string[] = [];
  for (const key of keys) lines.push(await bucketLine(env, key, mirrorRoot, versionsPath, issues, o));
  return lines;
}

async function bucketLine(env: Record<string, string | undefined>, key: string, mirrorRoot: string, versionsPath: string,
  issues: Map<string, IssueSnap> | null, o: BucketOptions): Promise<string> {
  const failed = (why: string) => `FAILED ${key} ${why.replace(/\s+/g, ' ')}`;
  if (!ISSUE_KEY.test(key)) return failed('is not a ticket key');
  if (!issues) return failed(`no readable mirror at ${mirrorRoot}`);
  const project = key.split('-')[0];
  let naming: Declared[];
  try {
    naming = declaredReleases(env).filter((d) => unparsedOrNamesProject(d, project));
  } catch (e) {
    return failed(`the release root cannot be read: ${(e as Error).message}`);
  }
  if (!existsSync(versionsPath)) {
    return naming.length ? failed(`no versions file at ${versionsPath} while ${naming[0].path} names ${project}`) : `NONE ${key} ${mirrorRoot}`;
  }
  let current: string | null;
  try {
    current = poolCurrent(readFileSync(versionsPath, 'utf8'));
  } catch (e) {
    return failed(`the versions file ${versionsPath} cannot be read: ${(e as Error).message}`);
  }
  if (!current) return failed(`the versions file ${versionsPath} has no current version`);
  const broken = naming.find((d) => !d.parsed);
  if (broken) return failed(`${broken.path} does not parse, so the declared current cannot be read`);
  const declared = naming.filter((d): d is ParsedDeclared => d.parsed).sort((a, b) => byIso(String(a.ts ?? ''), String(b.ts ?? ''))).at(-1);
  if (declared && declared.current !== current) {
    return failed(`the declared current ${String(declared.current)} (${declared.path}) differs from the versions-file current ${current}`);
  }
  const approval = outOfVersionApproval(env, key, o.now);
  if (approval) return `APPROVED ${key} decision=${approval.decision} record=${approval.id}`;
  const snap = issues.get(key);
  if (snap?.statusCategory === 'Done') return `DONE ${key}`;
  if (snap?.fixVersions.includes(current)) return `IN ${key} current=${current} via=mirror`;
  let versions: string[];
  try {
    const got = await withinDeadline(o.get<{ fields?: { fixVersions?: Array<{ name?: string }> } }>(`/issue/${key}?fields=fixVersions`), o.deadlineMs);
    versions = (got.fields?.fixVersions ?? []).map((v) => v.name ?? '').filter(Boolean);
  } catch (e) {
    return failed(`the live read of ${key} failed: ${(e as Error).message}`);
  }
  if (versions.includes(current)) return `IN ${key} current=${current} via=jira`;
  const open = [...issues.values()].filter((i) => i.fixVersions.includes(current) && i.statusCategory !== 'Done').length;
  return `OUTSIDE ${key} ${versions.join(',') || 'none'} current=${current} open=${open}`;
}

export function operatorWords(text: string): string {
  const lines = text.split(/\r?\n/);
  const at = lines.findIndex((l) => l.startsWith('Verbatim:'));
  if (at < 0) throw new Error('operatorWords: the file has no line starting \'Verbatim:\'; add one with the operator\'s words on it or in the lines below it');
  let words = lines[at].slice('Verbatim:'.length).trim();
  if (!words) {
    const end = lines.findIndex((l, i) => i > at && !l.trim());
    words = lines.slice(at + 1, end < 0 ? undefined : end).join('\n').trim();
  }
  if (words.length >= 2 && words.startsWith('"') && words.endsWith('"')) words = words.slice(1, -1);
  if (!words) throw new Error('operatorWords: the Verbatim: block is empty; put the operator\'s words on that line or in the lines below it');
  return words;
}

// --- core-gate bypass records (spec §4); coreMatch reads them through readOperatorRecords ---

function coreKeys(verb: string, keys: string[]): string[] {
  if (!keys.length) throw new Error(`release operator ${verb}: no keys given`);
  const bad = keys.find((k) => !ISSUE_KEY.test(k));
  if (bad !== undefined) throw new Error(`release operator ${verb}: '${bad}' is not a ticket key`);
  return [...new Set(keys)].sort();
}

// The operator lets the named core keys build without a signed spec.
export function coreBypass(ctx: Ctx, o: { keys: string[]; decision: string; verbatim: string }): OperatorRow {
  operatorFence(ctx);
  const keys = coreKeys('core-bypass', o.keys);
  return locked(ctx, (l) => appendOperator(ctx, l.k, { kind: 'core-bypass', decision: o.decision, keys, verbatim: o.verbatim }));
}

// The tickets in flight when the gate turns on; written once across every declared release.
export function coreSnapshot(ctx: Ctx, o: { keys: string[] }): OperatorRow {
  operatorFence(ctx);
  const keys = coreKeys('core-snapshot', o.keys);
  return lockedAcross(ctx, (l) => {
    const prior = readOperatorRecords('core-snapshot', ctx.env)[0];
    if (prior) throw new Error(`release operator core-snapshot: ${prior.id} is already recorded; the snapshot is written once, at flag-on`);
    return appendOperator(ctx, l.k, { kind: 'core-snapshot', decision: null, keys });
  });
}

export const PLACEHOLDER = /^(tbd|todo|test|testing|placeholder|wip|n\/?a|x+|w+|-+|\.+)$/i;

export interface ApprovalAlert { key: string; version: string; decision: string; open: number; words: string }

const DECISION_FILE = /^verbatim-decision-(\d+)-/;

export function outOfVersion(ctx: Ctx, o: { key: string; decision: string; verbatimFile: string; reason: string; alert: (a: ApprovalAlert) => number }): OutOfVersionRow {
  operatorFence(ctx);
  const verb = 'release operator out-of-version';
  if (!ISSUE_KEY.test(o.key)) throw new Error(`${verb}: '${o.key}' is not one ticket key; a record covers one key`);
  const decisions = join(dirname(releaseRoot(ctx.env)), 'specs', 'decisions');
  let file: string;
  try {
    file = realpathSync(o.verbatimFile);
  } catch {
    throw new Error(`${verb}: cannot read ${o.verbatimFile}`);
  }
  const n = DECISION_FILE.exec(basename(file))?.[1];
  if (!existsSync(decisions) || dirname(file) !== realpathSync(decisions) || n === undefined) {
    throw new Error(`${verb}: ${o.verbatimFile} is not a verbatim-decision-<n>-* file in ${decisions}`);
  }
  if (n !== o.decision) throw new Error(`${verb}: ${basename(file)} is decision ${n}, not --decision ${o.decision}`);
  const verbatim = readFileSync(file, 'utf8');
  let words: string;
  try {
    words = operatorWords(verbatim);
  } catch (e) {
    throw new Error(`${verb}: ${basename(file)}: ${(e as Error).message}`);
  }
  const reason = o.reason.trim();
  if (PLACEHOLDER.test(reason)) throw new Error(`${verb}: "${o.reason}" is a placeholder reason; say why this ticket now`);
  if (reason.length < 8) throw new Error(`${verb}: the reason "${o.reason}" is under 8 characters; say why this ticket now`);
  return locked(ctx, (l) => {
    if (l.operator.bad.length) throw new Error(`${verb}: ${f(ctx, 'operator.jsonl')} does not verify (${l.operator.bad[0]}); no alert sent, no record written`);
    const { issues } = readMirror(ctx.mirrorRoot);
    const snap = issues?.get(o.key);
    if (!snap) throw new Error(`${verb}: ${issues ? `${o.key} is not in the mirror` : 'the Jira mirror is unreadable'}; sync it first (jira mirror)`);
    const version = snap.fixVersions.join(',') || 'none';
    const now = ctx.now().getTime();
    const open = 1 + readOperatorRecords('out-of-version', ctx.env).filter((r) => {
      const age = now - Date.parse(r.ts);
      return age >= 0 && age < OUT_OF_VERSION_MS;
    }).length;
    const rc = o.alert({ key: o.key, version, decision: o.decision, open, words });
    if (rc !== 0) throw new Error(`${verb}: the operator alert exited ${rc}${rc === 77 ? ' (the send was refused)' : ''}; no record written`);
    return appendOperator<OutOfVersionRow>(ctx, l.k, { kind: 'out-of-version', decision: o.decision, keys: [o.key], version, verbatim: verbatim.trim(), reason });
  });
}

// --- fold: a finished ticket recorded as delivered in a version (the chief) ---------

export interface FoldItem { key: string; pr: number }
export interface FoldSkip { key: string; terminal: string; resolution: string }
export interface FoldOut { folded: EventRow[]; already: string[]; skipped: FoldSkip[] }

const ISSUE_KEY = /^[A-Z][A-Z0-9]*-\d+$/;

const lastBookkeeping = (events: EventRow[], key: string) =>
  [...events].reverse().find((e) => e.key === key && (e.kind === 'fold' || e.kind === 'reopen'));

function foldVersion(ctx: Ctx, l: Loaded, v: string): void {
  if (!l.decl.versions.includes(v)) throw new Error(`release: ${v} is not a version of ${ctx.release}`);
  if (l.events.bad.length) throw new Error(`release: events.jsonl does not verify (${l.events.bad[0]})`);
}

// One signed events row per key. Only a key the mirror reads as terminal Done folds;
// every other key is returned in `skipped` with its terminal and resolution, and stays
// a leak until a ruling moves it out of the version. A key already folded to this
// version under this PR is skipped silently, so a batch can be re-run.
export function fold(ctx: Ctx, o: { to: string; items: FoldItem[] }): FoldOut {
  operatorFence(ctx);
  for (const it of o.items) {
    if (!ISSUE_KEY.test(it.key)) throw new Error(`release fold: '${it.key}' is not an issue key`);
    if (!Number.isSafeInteger(it.pr) || it.pr <= 0) throw new Error(`release fold: ${it.key} needs a positive PR number`);
  }
  return locked(ctx, (l) => {
    foldVersion(ctx, l, o.to);
    const { issues } = readMirror(ctx.mirrorRoot);
    if (!issues) throw new Error('release fold: the Jira mirror is unreadable; sync it first');
    const eventsPath = f(ctx, 'events.jsonl');
    const seen = [...l.events.verified];
    const out: FoldOut = { folded: [], already: [], skipped: [] };
    for (const { key: k, pr } of o.items) {
      const issue = issues.get(k);
      const terminal = terminalOf(issue);
      if (terminal !== 'Done') {
        out.skipped.push({ key: k, terminal: terminal ?? (issue ? 'open' : 'not-in-mirror'), resolution: issue?.resolution ?? 'none' });
        continue;
      }
      const last = lastBookkeeping(seen, k);
      if (last?.kind === 'fold' && last.to === o.to && last.pr === pr) {
        out.already.push(k);
        continue;
      }
      const row = appendChain<EventRow>(eventsPath, l.k, { ts: ts(ctx), kind: 'fold', key: k, from: null, to: o.to, pr });
      seen.push(row);
      out.folded.push(row);
    }
    return out;
  });
}

// The twin of fold: the newest bookkeeping row of the key must be a fold into `from`.
export function reopen(ctx: Ctx, o: { key: string; from: string }): EventRow {
  operatorFence(ctx);
  if (!ISSUE_KEY.test(o.key)) throw new Error(`release reopen: '${o.key}' is not an issue key`);
  return locked(ctx, (l) => {
    foldVersion(ctx, l, o.from);
    const last = lastBookkeeping(l.events.verified, o.key);
    if (last?.kind !== 'fold' || last.to !== o.from) throw new Error(`release reopen: ${o.key} has no fold into ${o.from} to reverse`);
    return appendChain<EventRow>(f(ctx, 'events.jsonl'), l.k, { ts: ts(ctx), kind: 'reopen', key: o.key, from: o.from, to: null });
  });
}

// --- the request queue (the chief writes, the RM claims) ---------------------

const sameMove = (a: Pick<RequestRow, 'verb' | 'from_v' | 'to_v'>, b: Pick<RequestRow, 'verb' | 'from_v' | 'to_v'>): boolean =>
  a.verb === b.verb && a.from_v === b.from_v && a.to_v === b.to_v;

export function request(ctx: Ctx, o: Omit<RequestRow, 'req' | 'ts' | 'state'>): RequestRow {
  if (ctx.env.HIMMEL_RELEASE_MANAGER === '1') throw new Error('release request: the chief writes requests; the RM claims them');
  return locked(ctx, (l) => {
    const placement = ((o.evidence ?? {}) as Record<string, unknown>).chief_placement;
    if (placement !== undefined) {
      const waiting = [...latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).values()]
        .find((r) => r.key === o.key && (r.state === 'open' || r.state.startsWith('claimed:')));
      if (waiting?.state.startsWith('claimed:')) throw new Error(`release request: ${waiting.req} on ${o.key} is claimed; ask again after the run`);
      if (waiting && !sameMove(waiting, o)) {
        throw new Error(`release request: ${waiting.req} on ${o.key} waits for ${waiting.verb} ${waiting.from_v ?? 'backlog'} to ${waiting.to_v ?? 'backlog'}; withdraw it to place the key elsewhere`);
      }
      if (waiting) {
        const { prev: _p, mac: _m, ...rest } = waiting;
        return appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, evidence: { ...((waiting.evidence ?? {}) as Record<string, unknown>), chief_placement: placement } });
      }
    }
    return fileRequest(ctx, l, o);
  });
}

// The filing, on state a caller loaded under the release lock and still holds: it takes no lock, because the lock is not re-entrant.
function fileRequest(ctx: Ctx, l: Loaded, o: Omit<RequestRow, 'req' | 'ts' | 'state'>): RequestRow {
  const latest = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k));
  // A blocker pull is asked for once, in any state, so two racing pull runs cannot file it twice.
  const pullAgain = (r: RequestRow) => isPullRequest(r) && isPullRequest(o as RequestRow);
  const dup = [...latest.values()].find((r) => (pending(r) || pullAgain(r)) && r.key === o.key && r.verb === o.verb
    && r.from_v === o.from_v && r.to_v === o.to_v);
  // A pending ask that lacks the required-parent relation this ask carries takes it by a signed row of the same request
  // (same state, so a claim and its epoch stand): returning the older request would drop the relation the chief just stated.
  if (dup) return pending(dup) ? withRelation(ctx, l.k, dup, o) : dup;
  // An ask the RM already refused, repeated word for word with nothing new, files nothing: the refusal and its remedy stand.
  const same = unchangedRefusal(l, o);
  if (same) return same;
  const req = seq(`Q-${ctx.release}`, latest.keys());
  return appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...o, req, ts: ts(ctx), state: 'open' });
}

const RELATION = ['follow_up_of', 'remainder'] as const;
const relationOf = (r: { evidence?: unknown }): string => canon(Object.fromEntries(RELATION.flatMap((k) => {
  const v = ((r.evidence ?? {}) as Record<string, unknown>)[k];
  return v === undefined ? [] : [[k, v]];
})));

const pointerOf = (r: { evidence?: unknown }): unknown => ((r.evidence ?? {}) as Record<string, unknown>).operator_record;

function withRelation(ctx: Ctx, k: Buffer, dup: RequestRow, o: Omit<RequestRow, 'req' | 'ts' | 'state'>): RequestRow {
  const want = relationOf(o);
  const relation = want !== '{}' && want !== relationOf(dup);
  const pointer = pointerOf(o) !== undefined && pointerOf(o) !== pointerOf(dup);
  if (!relation && !pointer) return dup;
  const { prev: _p, mac: _m, ...rest } = dup;
  const evidence = { ...((dup.evidence ?? {}) as Record<string, unknown>) };
  if (relation) {
    for (const key of RELATION) delete evidence[key];
    Object.assign(evidence, JSON.parse(want));
  }
  if (pointer) evidence.operator_record = pointerOf(o);
  return appendChain<RequestRow>(f(ctx, 'requests.jsonl'), k, { ...rest, evidence });
}

export function requiredParentOf(history: RequestRow[]): Record<string, string> {
  const latest = new Map<string, RequestRow>();
  for (const r of history) latest.set(r.req, r);
  const out: Record<string, string> = {};
  for (const r of latest.values()) {
    if (r.state.startsWith('withdrawn')) continue;
    if (relationOf(r) === '{}') continue;
    const e = r.evidence as { follow_up_of?: unknown; remainder?: unknown };
    if (e.remainder === true && typeof e.follow_up_of === 'string') out[r.key] = e.follow_up_of;
    else delete out[r.key];
  }
  return out;
}

// The op a request into a version asks for, as a record of the operator's words names it: an INTAKE from backlog adds, anything else moves.
const askOp = (verb: Verb, from_v: string | null): 'add' | 'move' => (verb === 'INTAKE' && from_v === null ? 'add' : 'move');

export function recordRequestDecision(ctx: Ctx, o: { decision: string; words: string; key: string; verb: Verb; from_v: string | null; to_v: string | null }): OperatorRow {
  operatorFence(ctx);
  if (o.to_v === null) throw new Error('release request: --decision records the operator\'s words for a request into a version');
  const op = askOp(o.verb, o.from_v);
  return operatorDecision(ctx, {
    decision: o.decision, keys: [o.key], op, from_v: o.from_v, to_v: o.to_v, verbatim: o.words, ...decisionWords(ctx, o.decision, o.words),
  });
}

const citedOperator = (r: RequestRow): unknown => (r.evidence as { operator?: unknown } | null)?.operator;

export function requestWithWords(ctx: Ctx, row: Omit<RequestRow, 'req' | 'ts' | 'state'>, o: { decision: string; words: string }): {
  operator: OperatorRow; withdrawn: RequestRow | null; request: RequestRow;
} {
  const operator = recordRequestDecision(ctx, { decision: o.decision, words: o.words, key: row.key, verb: row.verb, from_v: row.from_v, to_v: row.to_v });
  const dup = locked(ctx, (l) => [...latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).values()]
    .find((r) => pending(r) && r.key === row.key && r.verb === row.verb && r.from_v === row.from_v && r.to_v === row.to_v));
  const withdrawn = dup && citedOperator(dup) === undefined
    ? withdraw(ctx, { req: dup.req, reason: `refiled citing the operator's words (${operator.id})`, by: operator.id })
    : null;
  // The refiled ask keeps the required-parent relation of the request it replaces unless it states its own (an explicit remainder:false included).
  const carried = withdrawn && dup && relationOf(row) === '{}' ? JSON.parse(relationOf(dup)) as Record<string, unknown> : {};
  const evidence = { ...carried, ...((row.evidence ?? {}) as Record<string, unknown>), operator: operator.id };
  return { operator, withdrawn, request: request(ctx, { ...row, why: `${row.why} (operator words: ${operator.id})`, evidence }) };
}

// A row after the verified prefix of the operator or rulings chain hides whatever it says (a newer reversal, a newer refusal),
// so a record on such a chain is not cited: what is named here is the first row that stopped the chain.
function chainFaultOf(l: Loaded): string | undefined {
  const [which, why] = l.operator.bad.length ? ['operator', l.operator.bad[0]] : l.rulings.bad.length ? ['rulings', l.rulings.bad[0]] : [];
  return which === undefined ? undefined : `the ${which} chain of ${l.decl.release} could not be verified to its end (${why})`;
}

export function chainFault(ctx: Ctx): string | undefined {
  const l = load(ctx);
  return 'unknown' in l ? undefined : chainFaultOf(l);
}

// The operator's words record that already places a gated ask, or undefined. It is the newest decision naming the key on the
// versions the ask touches, on no version, or a keep in the backlog whatever --to it names (each retracts an older add;
// rule()'s own selection leaves such rows out, so this reading is stricter); two at the newest instant are a tie and refuse. It holds checked words (words: 1, never a legacy row),
// covers exactly this placement under the reducer's scopeOk, and is newer than every ruling on the key. Only the verified
// chain is read, and a chain with a row after its verified prefix is not read at all: a row that does not verify places nothing.
function coveringDecision(l: Loaded, ask: Pick<RequestRow, 'verb' | 'key' | 'from_v' | 'to_v'>): OperatorRow | undefined {
  if ((ask.verb !== 'INTAKE' && ask.verb !== 'REVERSION') || ask.to_v === null) return undefined;
  if (chainFaultOf(l) !== undefined) return undefined;
  const touched = [ask.from_v, ask.to_v].filter((v) => v !== null);
  const named = l.operator.verified.filter((x) => x.kind === 'decision' && (x.keys ?? []).includes(ask.key)
    && ([x.from_v, x.to_v].some((v) => v != null && touched.includes(v)) || (x.from_v == null && x.to_v == null) || (x.op === 'keep' && x.from_v == null)));
  const newest = Math.max(...named.map((x) => Date.parse(x.ts)));
  const top = named.filter((x) => Date.parse(x.ts) === newest);
  if (top.length !== 1 || top[0].words !== 1) return undefined;
  const [rec] = top;
  const op: Op = { kind: askOp(ask.verb, ask.from_v), from_v: ask.from_v, to_v: ask.to_v };
  if (!scopeOk({ authority: { kind: 'operator', ref: rec.id }, key: ask.key, op }, new Map([[rec.id, rec]]), l.decl.current)) return undefined;
  const ruled = Math.max(-Infinity, ...l.rulings.verified.filter((r) => r.key === ask.key).map((r) => Date.parse(r.ts)));
  return newest > ruled ? rec : undefined;
}

// Read-only: the record requestOnRecord would cite. A release that is not declared, or does not verify, has none.
export function coveringRecord(ctx: Ctx, ask: Pick<RequestRow, 'verb' | 'key' | 'from_v' | 'to_v'>): OperatorRow | undefined {
  if ('unknown' in load(ctx)) return undefined;
  return locked(ctx, (l) => coveringDecision(l, ask));
}

// A gated ask that a record already places is filed citing that record: no operator row and no words. The fence is the
// words path's own, so the release manager, a bridge session and a worker still cannot file it. The match and the filing run
// under ONE hold of the release lock, so the record cited is the one that governs when the request is written: a decision, a
// ruling or a row that does not verify cannot land between them. Citing writes no row, so unlike a new record it withdraws no
// pending request for another placement.
export function requestOnRecord(ctx: Ctx, row: Omit<RequestRow, 'req' | 'ts' | 'state'>): { operator: OperatorRow; request: RequestRow } | undefined {
  operatorFence(ctx);
  if ('unknown' in load(ctx)) return undefined;
  return locked(ctx, (l) => {
    const operator = coveringDecision(l, row);
    if (!operator) return undefined;
    const evidence = { ...((row.evidence ?? {}) as Record<string, unknown>), operator: operator.id };
    return { operator, request: fileRequest(ctx, l, { ...row, evidence }) };
  });
}

// --- the blocker pull ------------------------------------------------------------

// Each pull files at most this many requests, so one deep tree cannot flood the RM queue.
export const PULL_MAX = 5;

export interface PullRow {
  key: string;
  blocks: string[];
  from_v: string | null;
  to_v: string;
}

export interface PullOut {
  current: string;
  rows: PullRow[];
  filed: RequestRow[];
  deferred: PullRow[];
  /** Epic blockers: an Epic is not worked, so the chief decides. */
  skipped: string[];
  /** Blockers the mirror does not hold. */
  unknown: string[];
}

const isPullRequest = (q: RequestRow): boolean => (q.evidence as { rule?: unknown } | null)?.rule === 'blocker-pull';

// Every open ticket of the current version that waits on an open ticket outside it files one INTAKE for that
// blocker, naming everything it unblocks. A blocker is asked for once: a request in any state stops a second one
// unless the blocker's own version changed.
export function pull(ctx: Ctx, o: { max?: number; dryRun?: boolean } = {}): PullOut {
  const l = loadOrThrow(ctx);
  const standingId = `O-${ctx.release}-blocker-pull`;
  if (!l.operator.verified.some((x) => x.id === standingId && x.kind === 'blocker-pull')) {
    throw new Error(`release pull: ${ctx.release} has no standing blocker-pull record; the chief records it with release operator standing`);
  }
  const { issues } = readMirror(ctx.mirrorRoot);
  if (!issues) throw new Error('release pull: the Jira mirror is missing or unreadable, so no pull');
  const current = l.decl.current;
  const waiting = new Map<string, Set<string>>();
  for (const i of issues.values()) {
    if (!i.fixVersions.includes(current) || terminalOf(i) !== null || i.type === 'Epic' || i.type === 'Sub-task') continue;
    for (const b of i.blockedBy ?? []) waiting.set(b, (waiting.get(b) ?? new Set()).add(i.key));
  }
  const asked = [...latestRequests(l.requests).values()].filter((r) => isPullRequest(r));
  const out: PullOut = { current, rows: [], filed: [], deferred: [], skipped: [], unknown: [] };
  for (const key of [...waiting.keys()].sort()) {
    const snap = issues.get(key);
    if (!snap) {
      out.unknown.push(key);
      continue;
    }
    if (terminalOf(snap) !== null || snap.fixVersions.includes(current)) continue;
    if (snap.type === 'Epic') {
      out.skipped.push(key);
      continue;
    }
    const from_v = l.decl.versions.find((v) => snap.fixVersions.includes(v)) ?? null;
    if (asked.some((r) => r.key === key && r.from_v === from_v && r.to_v === current)) continue;
    out.rows.push({ key, blocks: [...(waiting.get(key) ?? [])].sort(), from_v, to_v: current });
  }
  const max = o.max ?? PULL_MAX;
  const todo = out.rows.slice(0, max);
  out.deferred = out.rows.slice(max);
  if (o.dryRun) return out;
  for (const r of todo) {
    out.filed.push(request(ctx, {
      verb: 'INTAKE', key: r.key, from_v: r.from_v, to_v: r.to_v, from: 'blocker-pull',
      why: `blocks ${r.blocks.join(', ')} in ${current}; standing rule ${standingId} (decision ${BLOCKER_PULL_DECISION})`,
      evidence: { blocks: r.blocks, rule: 'blocker-pull' },
    }));
  }
  return out;
}

// --- the lease (§5.8) ------------------------------------------------------------

function rmFence(ctx: Ctx, l: Loaded): Lease {
  if (ctx.env.HIMMEL_RELEASE_MANAGER !== '1') throw new Error('release: only the release-manager session (HIMMEL_RELEASE_MANAGER=1) may do this');
  if (ctx.env.HIMMEL_RM_RELEASE && ctx.env.HIMMEL_RM_RELEASE !== ctx.release) {
    throw new Error(`release: this session is bound to ${ctx.env.HIMMEL_RM_RELEASE}, not ${ctx.release}`);
  }
  const lease = readLease(ctx, l.k);
  if (!lease.owner_doc || lease.released) throw new Error(`release ${ctx.release}: no lease owner; run release lease acquire first`);
  if (ctx.env.HIMMEL_RM_DOC !== lease.owner_doc) {
    throw new Error(`release ${ctx.release}: ${ctx.env.HIMMEL_RM_DOC ?? '(no HIMMEL_RM_DOC)'} is not the lease owner (${lease.owner_doc}, epoch ${lease.epoch})`);
  }
  return lease;
}

export type RunLease = Lease & { owner_pid?: number; owner_host?: string };

export function ownerGone(lease: RunLease): boolean {
  if (!lease.owner_pid || lease.owner_host !== hostname()) return false;
  try {
    process.kill(lease.owner_pid, 0);
    return false;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'ESRCH';
  }
}

export function leaseAcquire(ctx: Ctx, o: { expectEpoch: number; doc: string; session: string; pid?: number; reclaim?: boolean }): RunLease {
  if (ctx.env.HIMMEL_RELEASE_MANAGER !== '1') throw new Error('release lease: only the release-manager session (HIMMEL_RELEASE_MANAGER=1) holds the lease');
  if (!isAbsolute(o.doc) || ctx.env.HIMMEL_RM_DOC !== o.doc) throw new Error('release lease acquire: --doc must be this session\'s absolute HIMMEL_RM_DOC');
  return locked(ctx, (l) => {
    const cur: RunLease = readLease(ctx, l.k);
    if (cur.epoch !== o.expectEpoch) throw new Error(`release lease: epoch is ${cur.epoch}, expected ${o.expectEpoch}`);
    const takeoverRow = readChain<OperatorRow>(f(ctx, 'operator.jsonl'), l.k).verified
      .some((x) => x.kind === 'takeover' && x.epoch === cur.epoch && x.doc === o.doc);
    if (cur.owner_doc && !cur.released && !takeoverRow && !(o.reclaim && ownerGone(cur))) {
      throw new Error(`release lease: held by ${cur.owner_doc} at epoch ${cur.epoch}; it needs a release or a chief takeover row`);
    }
    const next: RunLease = {
      release: ctx.release, epoch: cur.epoch + 1, owner_session: o.session, owner_doc: o.doc, acquired: ts(ctx),
      released: false, prev_epoch: cur.epoch, ...(o.pid ? { owner_pid: o.pid, owner_host: hostname() } : {}),
    };
    writeSigned(f(ctx, 'lease.json'), l.k, next);
    return next;
  });
}

export function leaseRelease(ctx: Ctx): Lease {
  return locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const next = { ...lease, released: true };
    writeSigned(f(ctx, 'lease.json'), l.k, next);
    return next;
  });
}

// --- claim, rule, apply (§5.6, §5.7) ------------------------------------------------

export function claim(ctx: Ctx): RequestRow[] {
  return locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const latest = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k));
    const mine = `claimed:${lease.epoch}`;
    const out: RequestRow[] = [];
    for (const r of latest.values()) {
      const claimedEpoch = /^claimed:(\d+)$/.exec(r.state)?.[1];
      if (r.state === mine) out.push(r);
      else if (r.state === 'open' || (claimedEpoch !== undefined && Number(claimedEpoch) < lease.epoch)) {
        const { prev: _p, mac: _m, ...rest } = r;
        out.push(appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: mine }));
      }
    }
    const byKey = new Map<string, RequestRow[]>();
    for (const r of out) byKey.set(r.key, [...(byKey.get(r.key) ?? []), r]);
    return [...byKey.values()].flatMap((rs) => [...rs.filter((r) => pointerOf(r) !== undefined), ...rs.filter((r) => pointerOf(r) === undefined)]);
  });
}

function classOf(decl: Declaration, op: Op): PlacementClass {
  const target = op.kind === 'keep' || op.kind === 'discharge' ? op.from_v : op.kind === 'remove' || op.kind === 'none' ? null : op.to_v;
  if (target === decl.current) return 'current';
  return target && decl.versions.includes(target) ? 'next' : 'backlog';
}

function checkOp(decl: Declaration, op: Op): void {
  const inR = (v: string | null) => v !== null && decl.versions.includes(v);
  const ok = {
    add: inR(op.to_v),
    remove: inR(op.from_v) && op.to_v === null,
    move: op.from_v !== op.to_v && (inR(op.from_v) || inR(op.to_v)),
    keep: inR(op.from_v) && op.to_v === op.from_v,
    discharge: inR(op.from_v) && op.to_v === op.from_v,
    none: true,
  }[op.kind];
  if (!ok) throw new Error(`release rule: ${op.kind} ${op.from_v ?? 'backlog'}→${op.to_v ?? 'backlog'} is not a valid operation on ${decl.release}`);
}

export interface RuleOptions {
  req: string;
  outcome: string;
  op: Op;
  sector: string;
  ground: string;
  reason: string;
  supersedes: string[];
  authority: Authority;
}

// The standing pull is mechanical: every ticket it unblocks must still wait on the key, and a newer explicit
// operator record naming the key wins. True when the authority is that standing record.
function checkBlockerPull(ctx: Ctx, p: {
  decl: Declaration; ops: Map<string, OperatorRow>; governing: OperatorRow | undefined; key: string; op: Op; authority: Authority;
}): boolean {
  const standingRow = p.authority.kind === 'operator' && p.authority.ref ? p.ops.get(p.authority.ref) : undefined;
  if (standingRow?.kind !== 'blocker-pull') return false;
  if (!scopeOk({ authority: p.authority, key: p.key, op: p.op }, p.ops, p.decl.current)) {
    throw new Error(`release rule: ${p.authority.ref} does not cover ${p.key} ${p.op.kind} ${p.op.from_v}→${p.op.to_v}`);
  }
  const blocks = p.authority.blocks ?? [];
  const { issues } = readMirror(ctx.mirrorRoot);
  for (const b of blocks) {
    const snap = issues?.get(b);
    if (!snap || terminalOf(snap) !== null || !snap.fixVersions.includes(p.decl.current) || !snap.blockedBy?.includes(p.key)) {
      throw new Error(`release rule: blocker-pull: ${b} is no longer an open ${p.decl.current} ticket blocked by ${p.key}`);
    }
  }
  const g = p.governing;
  if (g && Date.parse(g.ts) > Date.parse(standingRow.ts)) {
    throw new Error(`release rule: CONFLICT ${p.key}: ${g.id} (newer) ${g.op} ${vName(g.from_v ?? null)}→${vName(g.to_v ?? null)} governs ${p.key}; ${blocks.join(', ')} blocked by it`);
  }
  return true;
}

function checkDelivered(ctx: Ctx, p: {
  decl: Declaration; ops: Map<string, OperatorRow>; governing: OperatorRow | undefined; key: string; op: Op; authority: Authority; req: RequestRow;
}): boolean {
  const standingRow = p.authority.kind === 'operator' && p.authority.ref ? p.ops.get(p.authority.ref) : undefined;
  if (standingRow?.kind !== 'delivered-follows-merge') return false;
  if (!scopeOk({ authority: p.authority, key: p.key, op: p.op }, p.ops, p.decl.current)) {
    throw new Error(`release rule: ${p.authority.ref} does not cover ${p.key} ${p.op.kind} ${p.op.from_v}→${p.op.to_v}`);
  }
  const snap = readMirror(ctx.mirrorRoot).issues?.get(p.key);
  const from = p.op.from_v;
  if (!snap || !from || !snap.fixVersions.includes(from) || snap.fixVersions.includes(p.decl.current)) {
    throw new Error(`release rule: delivered-follows-merge: ${p.key} no longer sits in ${from ?? 'a later version'} outside ${p.decl.current}`);
  }
  const t = terminalOf(snap);
  if (t !== 'Done' && t !== 'Duplicate') throw new Error(`release rule: delivered-follows-merge: ${p.key} is ${t ?? 'not closed'}, not delivered`);
  const evidence = mergeEvidenceFor(p.req, t, ctx.deliveredPr);
  if (!evidence || evidence !== p.authority.delivered) {
    throw new Error(`release rule: delivered-follows-merge: ${p.key} has no verifiable merge evidence (${p.authority.delivered ?? 'none'})`);
  }
  const g = p.governing;
  if (g && Date.parse(g.ts) > Date.parse(standingRow.ts)) {
    throw new Error(`release rule: CONFLICT ${p.key}: ${g.id} (newer) ${g.op} ${vName(g.from_v ?? null)}→${vName(g.to_v ?? null)} governs ${p.key}; its work merged`);
  }
  return true;
}

// The operator's newest decision naming the key, whatever version it touches: the key's latest word.
const keyNewestDecision = (rows: OperatorRow[], key: string): OperatorRow | undefined =>
  rows.filter((x) => x.kind === 'decision' && (x.keys ?? []).includes(key)).sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts)).pop();

// A REVERSION can only rule a move, but an operator `add` into a version places the key there too: the restore
// is that add, so the record covers it. Only when that add is also the key's newest decision of any kind: a newer
// record elsewhere (another version, a keep) is the operator's latest word and the restore stays refused.
// Any other op stays as it is and is checked against the record.
function restoreAsAdd(verb: Verb, op: Op, governing: OperatorRow | undefined, newest: OperatorRow | undefined): Op {
  const same = verb === 'REVERSION' && op.kind === 'move' && op.from_v === null && governing?.op === 'add'
    && (governing.from_v ?? null) === null && (governing.to_v ?? null) === op.to_v && newest?.id === governing.id;
  return same ? { kind: 'add', from_v: null, to_v: op.to_v } : op;
}

function replacedByGoverning(prior: RulingRow | undefined, governing: OperatorRow | undefined, rulings: RulingRow[]): boolean {
  if (prior?.authority.kind !== 'operator' || !governing) return false;
  return Date.parse(governing.ts) > Date.parse(rulings.find((r) => r.id === prior.id)?.ts ?? prior.ts);
}

const citesGoverning = (authority: RulingRow['authority'], governing: OperatorRow | undefined): boolean =>
  authority.kind === 'operator' && governing !== undefined && authority.ref === governing.id;

export function rule(ctx: Ctx, o: RuleOptions): RulingRow {
  return locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const latest = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k));
    const req = latest.get(o.req);
    if (!req) throw new Error(`release rule: no request ${o.req}`);
    if (req.state !== `claimed:${lease.epoch}`) throw new Error(`release rule: ${o.req} is ${req.state}, not claimed:${lease.epoch}`);
    const kinds = OUTCOMES[req.verb][o.outcome];
    if (!kinds) throw new Error(`release rule: ${req.verb} outcomes are ${Object.keys(OUTCOMES[req.verb]).join(', ')}`);
    if (!kinds.includes(o.op.kind)) throw new Error(`release rule: ${o.outcome} takes --op ${kinds.join('|')}`);
    checkOp(l.decl, o.op);
    const given = o.sector.trim();
    const sector = sectorField() ? (given.toLowerCase() === SECTOR_OPT_OUT ? '' : given) : given || SECTOR_OPT_OUT;
    if (!sector) throw new Error('release rule: a ruling without a sector refuses; ask the chief to set it');
    if (!o.ground.trim() || !o.reason.trim()) throw new Error('release rule: --ground and --reason are required');

    const s = reduceLoaded(l, { issues: null, sync: null });
    if (s.status !== 'OK') throw new Error(`release ${ctx.release} is UNKNOWN: ${s.integrity[0]}`);
    const rulings = l.rulings.verified;
    const applied = new Map(rulings.filter((r) => r.phase === 'applied' || r.phase === 'receipted').map((r) => [r.id, r]));
    const baselineIds = new Set(l.baselines.map(baselineId));
    for (const id of o.supersedes) {
      if (!applied.has(id) && !baselineIds.has(id)) throw new Error(`release rule: supersedes names ${id}, which is not an effective ruling`);
    }
    if (o.op.kind === 'none' && o.supersedes.length) throw new Error('release rule: a ruling that changes nothing supersedes nothing');
    const ops = new Map(l.operator.verified.map((x) => [x.id, x]));
    const touched = [o.op.from_v, o.op.to_v].filter((v) => v !== null);
    // The newest operator decision naming the key on a version this op touches governs it.
    const governing = l.operator.verified.filter((x) => x.kind === 'decision' && (x.keys ?? []).includes(req.key)
      && [x.from_v, x.to_v].some((v) => v != null && touched.includes(v)))
      .sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts)).pop();
    let authority = o.authority;
    let op = o.op;
    let supersedes = o.supersedes;
    const restored = restoreAsAdd(req.verb, o.op, governing, keyNewestDecision(l.operator.verified, req.key));
    const checked = { decl: l.decl, ops, governing, key: req.key, op: o.op, authority, req };
    const pulling = checkBlockerPull(ctx, checked) || checkDelivered(ctx, checked);
    for (const v of l.decl.versions) {
      if (!effectOn(o.op, v) && !(o.op.kind === 'none' && (o.op.from_v === v || o.op.to_v === v))) continue;
      const rec = recordOf(s, req.key, v);
      if (rec?.placement === 'unknown') throw new Error(`release rule: ${req.key}@${v} is UNKNOWN`);
      if (rec?.placement === 'pending') throw new Error(`release rule: ${req.key}@${v} has a pending intent; apply or void it first`);
      if (o.op.kind === 'none') continue;
      const prior = rec?.ruling ? applied.get(rec.ruling) : undefined;
      if (rec?.ruling && !supersedes.includes(rec.ruling)) {
        if (!replacedByGoverning(prior, governing, rulings)) throw new Error(`release rule: supersedes must name ${rec.ruling} (in effect for ${req.key}@${v})`);
        supersedes = [...supersedes, rec.ruling];
      }
      if (prior?.authority.kind !== 'operator') continue;
      // The pull passed the newer-record check above, so it supersedes the operator ruling it finds.
      if (pulling) continue;
      // Only an operator decision newer than the ruling supersedes it, and only the governing one.
      const since = Date.parse(rulings.find((r) => r.id === prior.id)?.ts ?? prior.ts);
      const cited = authority.kind === 'operator' && authority.ref ? ops.get(authority.ref) : undefined;
      if (cited?.kind === 'decision' && Date.parse(cited.ts) <= since) {
        throw new Error(`release rule: ${cited.id} predates ${prior.id}; an older operator record never supersedes a newer ruling`);
      }
      const conflict = (g: OperatorRow) => new Error(`release rule: CONFLICT ${req.key}: ${g.id} (newer) ${g.op} ${vName(g.from_v ?? null)}→${vName(g.to_v ?? null)} governs ${req.key}; rule under it`);
      if (cited?.kind === 'decision') {
        if (governing && governing.id !== cited.id) throw conflict(governing);
        op = restored;
        continue;
      }
      if (authority.kind === 'operator') continue;
      if (!governing || Date.parse(governing.ts) <= since) throw new Error(`release rule: ${prior.id} carries operator authority; only an operator record supersedes it`);
      if (!scopeOk({ authority: { kind: 'operator', ref: governing.id }, key: req.key, op: restored }, ops, l.decl.current)) throw conflict(governing);
      op = restored;
      authority = { kind: 'operator', ref: governing.id };
    }
    if (citesGoverning(authority, governing)) op = restored;
    if (authority.kind === 'operator') {
      if (!scopeOk({ authority, key: req.key, op }, ops, l.decl.current)) throw new Error(`release rule: ${authority.ref ?? '(no ref)'} does not cover ${req.key} ${op.kind} ${op.from_v}→${op.to_v}`);
    }
    if (authority.kind === 'import' && !authority.ref) throw new Error('release rule: an import names its source in --ref');

    const id = seq(`R-${ctx.release}`, l.rulings.rows.map((r) => r.id));
    const row = appendChain<RulingRow>(f(ctx, 'rulings.jsonl'), l.k, {
      id, epoch: lease.epoch, req: req.req, ts: ts(ctx), verb: req.verb, key: req.key, op, outcome: o.outcome,
      class: classOf(l.decl, op), sector, ground: o.ground, reason: o.reason, supersedes,
      authority, phase: 'intent',
    });
    const { prev: _p, mac: _m, ...rest } = req;
    appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: `ruled:${id}` });
    return row;
  });
}

const vName = (v: string | null) => v ?? 'backlog';

export const rulingLine = (r: RulingRow): string =>
  `RULING ${r.id} ${r.req} ${r.verb} ${r.key} ${r.op.kind} ${vName(r.op.from_v)}→${vName(r.op.to_v)} ${r.outcome} ${r.class} sector=${r.sector} — ${r.ground}: ${r.reason}`;

function landed(op: Op, cur: string[]): boolean {
  const has = (v: string | null) => v !== null && cur.includes(v);
  switch (op.kind) {
    case 'add': return has(op.to_v);
    case 'remove': return !has(op.from_v);
    case 'move': return (op.to_v === null || has(op.to_v)) && !has(op.from_v);
    case 'keep':
    case 'discharge': return has(op.from_v);
    default: return true;
  }
}

// Jira still shows the state from before the ruling's write.
function untouched(op: Op, cur: string[]): boolean {
  const has = (v: string | null) => v !== null && cur.includes(v);
  return op.kind !== 'move' || ((op.from_v === null || has(op.from_v)) && !has(op.to_v));
}

const sameSet = (a: string[], b: string[]): boolean => [...a].sort().join('\n') === [...b].sort().join('\n');

// The journalled RM removal of this move's source that produced exactly the set the key shows now, written after the intent.
function boundRemoval(env: Record<string, string | undefined>, r: RulingRow, cur: string[]): VersionWriteRow | null {
  const from = r.op.from_v;
  const to = r.op.to_v;
  if (r.op.kind !== 'move' || !from || !to) return null;
  try {
    const path = journalPath(env);
    if (!path) return null;
    return readVersionWrites(path).filter((w) => w.key === r.key && w.mechanism === 'rm-apply' && w.from.includes(from) && !w.to.includes(from)
      && !w.to.includes(to) && w.ts >= r.ts && sameSet(w.to, cur)).sort((a, b) => a.ts.localeCompare(b.ts)).at(-1) ?? null;
  } catch {
    return null;
  }
}

// Attribution: the source removal is this ruling's own write, and nobody has changed the key's Fix Versions since.
async function ownedRemoval(ctx: Ctx, r: RulingRow, cur: string[]): Promise<boolean> {
  const row = boundRemoval(ctx.env, r, cur);
  if (!row || typeof ctx.jira.newestFixVersionEntry !== 'function') return false;
  try {
    return (await ctx.jira.newestFixVersionEntry(r.key)).id === row.entry;
  } catch {
    return false;
  }
}

// The operator's latest placing decision on the key, when it is newer than the ruling and puts the key anywhere but this move's destination:
// the destination add would write against it.
function newerElsewhere(operator: OperatorRow[], r: RulingRow): OperatorRow | undefined {
  const latest = keyNewestDecision(operator.filter((x) => placementOf(x) !== undefined), r.key);
  return latest && Date.parse(latest.ts) > Date.parse(r.ts) && placementOf(latest) !== r.op.to_v ? latest : undefined;
}

const againstOf = (g: OperatorRow, r: RulingRow): string =>
  `${g.id} (newer than ${r.id}) ${g.op} ${vName(g.from_v ?? null)}→${vName(g.to_v ?? null)} places ${r.key} outside ${vName(r.op.to_v)}`;

const observedOf = (r: RulingRow, cur: string[], source: 'Jira' | 'mirror'): string =>
  `${r.key} is in ${cur.length ? cur.join(', ') : 'no version'} (${source}); the ${r.op.kind} wants ${vName(r.op.from_v)} -> ${vName(r.op.to_v)}`;

// The chief's two safe ends for a move that sits in neither state, each followed by the replay that writes the row and receipt once.
function repairOf(release: string, r: RulingRow, live: boolean, cur: string[]): string {
  const both = r.op.from_v !== null && r.op.to_v !== null && cur.includes(r.op.from_v) && cur.includes(r.op.to_v);
  const finish = `jira fix-version ${r.key} ${both ? '--remove ' + r.op.from_v : '--add ' + vName(r.op.to_v)}`;
  const restore = `jira fix-version ${r.key} ${both ? '--remove ' + r.op.to_v : '--add ' + vName(r.op.from_v)}`;
  const gate = both ? '' : ` (add --gate <reason> when ${vName(r.op.to_v)} is frozen)`;
  return `${live ? '' : 'run `jira mirror` and read this again; if it still holds, '}the chief completes it with \`${finish}\`${gate} or restores the source with \`${restore}\`, then \`jira release rm-run ${release}\` replays the row and receipt once`;
}

function phaseRow(ctx: Ctx, r: RulingRow, phase: RulingRow['phase'], extra: Partial<RulingRow>): Omit<RulingRow, 'prev' | 'mac'> {
  const { prev: _p, mac: _m, ...rest } = r;
  return { ...rest, ...extra, phase, ts: ts(ctx) };
}

// Runs a ruling from its newest phase to receipted. Idempotent: the comment id
// in the receipted row is the idempotency key, and a replay finds the comment
// by its marker before it would post another.
export async function apply(ctx: Ctx, id: string): Promise<{ phase: RulingRow['phase']; line: string; note?: string }> {
  let note: string | undefined;
  return lockedAsync(ctx, async (l) => {
    const lease = rmFence(ctx, l);
    const rows = readChain<RulingRow>(f(ctx, 'rulings.jsonl'), l.k);
    if (rows.bad.length) throw new Error(`release: rulings.jsonl does not verify (${rows.bad[0]})`);
    const mine = rows.verified.filter((r) => r.id === id);
    if (!mine.length) throw new Error(`release apply: no ruling ${id}`);
    let last = mine[mine.length - 1];
    if (last.phase === 'void') return { phase: 'void', line: `VOID ${id}` };
    const rulingsPath = f(ctx, 'rulings.jsonl');
    const membership = ['add', 'remove', 'move'].includes(last.op.kind);
    const event = (readback: 'ok' | 'mismatch') => {
      if (!membership) return;
      // The applied row lands before its event, so a retry re-creates a missing one. A run that finds the same ruling refused again
      // appends nothing: the recorded mismatch already says so, and the same row every run only grows the ledger.
      const eventsPath = f(ctx, 'events.jsonl');
      if (readChain<EventRow>(eventsPath, l.k).verified.some((e) => e.kind === 'ruled' && e.ruling === id && e.readback === readback)) return;
      appendChain<EventRow>(eventsPath, l.k, {
        ts: ts(ctx), kind: 'ruled', key: last.key, from: last.op.from_v, to: last.op.to_v, ruling: id, readback,
      });
    };

    if (last.phase === 'intent' && last.epoch !== lease.epoch) {
      // An older epoch's intent: resolve by readback, never by re-writing Jira.
      const cur = await ctx.jira.fixVersions(last.key);
      if (!landed(last.op, cur) && !untouched(last.op, cur)) {
        // The key sits in neither end state. Only a journalled RM removal that is still the key's newest Fix Version entry proves it
        // is this ruling's own interrupted write; then the one write left is the destination add. Anything else is a hand fix.
        if (!(await ownedRemoval(ctx, last, cur))) {
          event('mismatch');
          throw new Error(`release apply: ${id} is partly applied in Jira and nothing proves the removal was this ruling's own, so nothing was written: ${observedOf(last, cur, 'Jira')}; ${repairOf(ctx.release, last, true, cur)}`);
        }
        const newer = newerElsewhere(l.operator.verified, last);
        if (newer) {
          event('mismatch');
          throw new Error(`release apply: ${id} is partly applied in Jira and ${againstOf(newer, last)}, so nothing was written: ${observedOf(last, cur, 'Jira')}; ${repairOf(ctx.release, last, true, cur)}`);
        }
        assertAdmissionsWritable();
        await ctx.jira.setFixVersion(last.key, 'add', last.op.to_v as string);
        if (!landed(last.op, await ctx.jira.fixVersions(last.key))) {
          event('mismatch');
          throw new Error(`release apply: ${id} readback does not match ${last.op.kind} ${vName(last.op.from_v)}→${vName(last.op.to_v)}`);
        }
        last = appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'applied', { epoch: lease.epoch, readback: 'ok' }));
      } else if (!landed(last.op, cur)) {
        const req = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(last.req);
        appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'void', { epoch: lease.epoch }));
        if (req && isRepair(req)) {
          appendWithdrawal(ctx, l.k, req, 'repair', 'never-landed');
          return { phase: 'void', line: `VOID ${id} (epoch ${last.epoch} intent never reached Jira; ${last.req} withdrawn)` };
        }
        if (req) {
          const { prev: _p, mac: _m, ...rest } = req;
          appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: 'open' });
        }
        return { phase: 'void', line: `VOID ${id} (epoch ${last.epoch} intent never reached Jira; ${last.req} reopened)` };
      } else {
        last = appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'applied', { epoch: lease.epoch, readback: 'ok' }));
      }
    } else if (last.phase === 'intent') {
      const { op, key: k } = last;
      if ((last.verb === 'INTAKE' && last.outcome === 'ADMIT') || (last.verb === 'REVERSION' && op.kind === 'add')
        || ((op.kind === 'remove' || op.kind === 'move') && op.from_v)) assertAdmissionsWritable();
      const cur = await ctx.jira.fixVersions(k);
      const req = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(last.req);
      if (req && isRepair(req)) {
        if (typeof ctx.jira.newestFixVersionEntry !== 'function') throw new Error(`release apply: the Jira port has no newestFixVersionEntry; ${last.req} is a version-repair request`);
        const newest = await ctx.jira.newestFixVersionEntry(k);
        if (newest.id !== (req.evidence as { entry?: unknown }).entry && !landed(op, cur)) {
          if (!untouched(op, cur)) {
            event('mismatch');
            throw new Error(`release apply: ${id} is partly applied in Jira; ${k} needs a hand fix before it is re-ruled`);
          }
          appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'void', {}));
          appendWithdrawal(ctx, l.k, req, 'repair', 'entry-moved');
          return { phase: 'void', line: `VOID ${id} (${k} Fix Version entry moved since ${last.req} was filed; ${last.req} withdrawn)` };
        }
      }
      if ((op.kind === 'remove' || op.kind === 'move') && op.from_v && cur.includes(op.from_v)) await ctx.jira.setFixVersion(k, 'remove', op.from_v);
      if ((op.kind === 'add' || op.kind === 'move') && op.to_v && !cur.includes(op.to_v)) await ctx.jira.setFixVersion(k, 'add', op.to_v);
      if (!landed(op, await ctx.jira.fixVersions(k))) {
        event('mismatch');
        throw new Error(`release apply: ${id} readback does not match ${op.kind} ${vName(op.from_v)}→${vName(op.to_v)}`);
      }
      last = appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'applied', { readback: 'ok' }));
    }

    if (last.phase === 'applied') {
      event('ok');
      // A later applied ruling that supersedes this one owns the ledger now; a replay must not write after it.
      const phaseOf = new Map(rows.verified.map((r) => [r.id, r.phase]));
      const superseded = rows.verified.some((s) => s.supersedes.includes(id) && ['applied', 'receipted'].includes(phaseOf.get(s.id) ?? ''));
      // An RM admission is a ledger row like the chief's, so the board counts it; a replay finds the row first.
      // A REVERSION move into a version is an admission there too; readers ignore the row for an unfrozen version.
      const admitted = last.verb === 'INTAKE' && last.outcome === 'ADMIT'
        || last.verb === 'REVERSION' && (last.op.kind === 'move' || last.op.kind === 'add');
      if (!superseded && admitted && last.op.to_v) {
        const version = last.op.to_v;
        const key = last.key;
        if (!readAdmissionsTolerant(version).some((r) => r.kind === 'rm-admit' && r.key === key && r.ruling === id)) {
          appendAdmission({ version, key, kind: 'rm-admit', reason: `${last.ground}: ${last.reason}`, by: lease.owner_session ?? 'rm', ruling: id });
        }
      }
      // A removal is a ledger row too, so a later reader sees the ruling-in withdrawn.
      if (!superseded && (last.op.kind === 'remove' || last.op.kind === 'move') && last.op.from_v) {
        const version = last.op.from_v;
        const key = last.key;
        if (!readAdmissionsTolerant(version).some((r) => r.kind === 'rm-remove' && r.key === key && r.ruling === id)) {
          appendAdmission({ version, key, kind: 'rm-remove', reason: `${last.ground}: ${last.reason}`, by: lease.owner_session ?? 'rm', ruling: id });
        }
      }
      // Every INTAKE ruling settles the filer's proposal, so its proposed-* label goes before the receipt; a failure leaves the ruling applied for a replay.
      if (last.verb === 'INTAKE') await clearProposedLabels(ctx.jira, last.key);
      note = await backlogLabel(ctx.jira as DoorJiraPort, last);
      const marker = `[release-ruling ${id}]`;
      const authority = last.authority.kind === 'rm' ? 'rm' : `${last.authority.kind} ${last.authority.ref}`;
      const commentId = await ctx.jira.findComment(last.key, marker)
        ?? await ctx.jira.addComment(last.key, `${marker} ${rulingLine(last)}\n\nAuthority: ${authority}. Audit copy; the release ledger is the record.`);
      last = appendChain<RulingRow>(rulingsPath, l.k, phaseRow(ctx, last, 'receipted', { comment_id: commentId }));
    }
    return { phase: last.phase, line: rulingLine(last), ...(note ? { note } : {}) };
  });
}

export type DoorJiraPort = JiraPort & {
  addLabels?(key: string, labels: string[]): Promise<void>;
  issue?(key: string, opts?: { signal?: AbortSignal }): Promise<IssueSnap | null>;
};

async function backlogLabel(jira: DoorJiraPort, r: RulingRow): Promise<string | undefined> {
  if (!r.ground.startsWith('door:')) return undefined;
  const cur = await jira.fixVersions(r.key);
  if (cur.length) {
    if ((r.op.kind === 'add' || r.op.kind === 'move') && r.op.to_v && (await jira.labels(r.key)).includes('backlog')) await jira.removeLabels(r.key, ['backlog']);
    return undefined;
  }
  if (!jira.addLabels) return `the backlog label on ${r.key}: this Jira port cannot add labels`;
  await jira.addLabels(r.key, ['backlog']);
  return undefined;
}

// --- state ---------------------------------------------------------------------------

export interface StateOut extends ReleaseState {
  /** Per version: the keys of today's (UTC) operator decisions that add or move into it. */
  admissions_today: Record<string, number>;
  /** owner_gone is present (true) only for a held lease whose recorded owner pid is absent on this host: the proof rm-run's own reclaim uses. */
  lease: (Omit<Lease, 'mac'> & { owner_pid?: number; owner_host?: string; owner_gone?: true }) | null;
  requests: { open: string[]; claimed: string[]; /** ts of the oldest open request, null with none. */ oldest_open: string | null };
  heads: { rulings: string; operator: string; events: string; requests: string; mirror: string | null };
  refused_asks: RefusedAsk[];
  /** Every verified `words: 1` O- row: the records a hold line may cite. */
  words_records: WordsRecord[];
  /** Open mirror keys labelled operator-directed or of priority High or Highest. */
  asks_operator_keys: string[];
  /** Rulings whose newest phase is intent or applied: the Jira write, the admissions row or the receipt may still be owed. A normal rm-run replays each. */
  unfinished_rulings: UnfinishedRuling[];
  /** Required-remainder children (request evidence `remainder: true`) of an open current-version parent that are open outside the version. A read of existing evidence: it admits nothing. */
  remainder_conflicts: RemainderConflict[];
}

export interface UnfinishedRuling {
  ruling: string; req: string; key: string; phase: 'intent' | 'applied'; op: string;
  /** replay: a normal rm-run finishes it. blocked: a move the key's mirror shows in neither end state with no journalled proof it is this ruling's own, or with an operator record newer than the ruling that puts the key elsewhere; the chief repairs it by hand. */
  status: 'replay' | 'blocked'; owner: 'release-manager' | 'chief'; next: string;
  /** What the mirror shows of a blocked move; null otherwise. */
  observed: string | null;
}

/** asks_operator is null when the mirror cannot say: it is unreadable, or does not hold the key. */
export interface RefusedAsk { key: string; ruling: string; req: string; reason: string; ground: string; remedy: string; asks_operator: boolean | null }

/** A current-version parent whose recorded remainder sits outside the version: the contradiction, who owns it and the next command. */
export interface RemainderConflict {
  parent: string; child: string; req: string; ruling: string | null;
  phase: 'open' | 'claimed' | 'held' | 'refused' | 'ruled'; owner: 'chief' | 'release-manager'; next: string;
  /** What the mirror cannot say (the parent's or the child's state, or anything when it is unreadable); null when both are read. */
  unknown: 'parent' | 'child' | 'mirror' | null;
}

// The exact next command for a refused ask: operator words for an operator-asked (or unknown) key; changed facts or an ack otherwise.
// The parent a request records as requiring it (follow_up_of with remainder: true), the same test the remainder conflicts apply.
function requiredParent(q: RequestRow | undefined): string | null {
  const ev = (q?.evidence ?? {}) as { follow_up_of?: unknown; remainder?: unknown };
  return ev.remainder === true && typeof ev.follow_up_of === 'string' ? ev.follow_up_of : null;
}

// A refused ask that recorded a required parent keeps it in the command, as the conflict's remedy does.
function remedyOf(release: string, q: RequestRow, ruling: string, asksOperator: boolean | null, parent: string | null): string {
  const base = `jira release request ${release} --verb ${q.verb} --key ${q.key} --from ${vName(q.from_v)} --to ${vName(q.to_v)}${parent === null ? '' : ` --required-by ${parent}`}`;
  if (asksOperator !== false) return `${base} --why "<why>" --decision <n> --words "<the operator's exact words>"`;
  return `new facts: ${base} --why "<what changed>" --evidence '{"<changed requirement>":"<value>"}'; or if the refusal is right: jira release ack ${release} --ruling ${ruling} --reason "<why>"`;
}

const canon = (v: unknown): string => JSON.stringify(v, (_k, x) => (x && typeof x === 'object' && !Array.isArray(x)
  ? Object.fromEntries(Object.entries(x as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) : x));

// The open refused ask this request repeats unchanged: same key, verb, versions, why and evidence, with no ack, newer operator row, newer different ask or Done since.
function unchangedRefusal(l: Loaded, o: Omit<RequestRow, 'req' | 'ts' | 'state'>): RequestRow | undefined {
  const a = refusedAsks(l, null).find((x) => x.key === o.key);
  const first = a ? l.requests.verified.find((x) => x.req === a.req) : undefined;
  const now = first ? latestRequests(l.requests).get(first.req) : undefined;
  if (!first || !now || first.verb !== o.verb || first.from_v !== o.from_v || first.to_v !== o.to_v || first.why !== o.why || canon(now.evidence ?? {}) !== canon(o.evidence ?? {})) return undefined;
  return now;
}
export interface WordsRecord { id: string; decision: string | null; keys: string[]; op: string | null; verbatim: string }

const factsOf = (i: IssueSnap | undefined): TicketFacts | null =>
  (i ? { labels: i.labels ?? [], priority: i.priority, open: terminalOf(i) === null } : null);

function refusedAsks(l: Loaded, issues: Map<string, IssueSnap> | null): RefusedAsk[] {
  const firstOf = new Map<string, RequestRow>();
  for (const q of l.requests.verified) if (!firstOf.has(q.req)) firstOf.set(q.req, q);
  // The relation may have been added after the first row (a signed update of the same request), so the remedy reads the newest row.
  const now = latestOrEmpty(l.requests);
  const ruledAt = new Map<string, string>();
  const latest = new Map<string, RulingRow>();
  for (const r of l.rulings.verified) {
    if (!ruledAt.has(r.id)) ruledAt.set(r.id, r.ts);
    if (r.phase === 'receipted') latest.set(r.key, r);
  }
  const newest = (into: Map<string, number>, key: string, t: string) => into.set(key, Math.max(into.get(key) ?? -Infinity, Date.parse(t)));
  const asksOf = new Map<string, RequestRow[]>();
  for (const q of firstOf.values()) asksOf.set(q.key, [...(asksOf.get(q.key) ?? []), q]);
  const named = new Map<string, number>();
  for (const o of l.operator.verified) for (const k of o.keys ?? []) newest(named, k, o.ts);
  const acked = new Set(l.events.verified.filter((e) => e.kind === 'ack').map((e) => e.ruling));
  const out: RefusedAsk[] = [];
  for (const [key, r] of latest) {
    const q = firstOf.get(r.req);
    if (!q || q.from_v !== null || q.to_v === null) continue;
    if (r.outcome !== 'BACKLOG' && !(r.verb === 'REVERSION' && r.outcome === 'KEEP')) continue;
    const since = Date.parse(ruledAt.get(r.id) ?? r.ts);
    // A later ask that was withdrawn no longer stands, so it does not hide the refusal.
    const askedAgain = (asksOf.get(key) ?? []).some((x) => x.req !== r.req && Date.parse(x.ts) > since && !now.get(x.req)?.state.startsWith('withdrawn:'));
    if (acked.has(r.id) || askedAgain || (named.get(key) ?? -Infinity) > since) continue;
    const issue = issues?.get(key);
    if (issue && terminalOf(issue) !== null) continue;
    const asks = issue ? asksOperator(factsOf(issue)) : null;
    out.push({ key, ruling: r.id, req: r.req, reason: r.reason, ground: r.ground, remedy: remedyOf(l.decl.release, q, r.id, asks, requiredParent(now.get(r.req))), asks_operator: asks });
  }
  return out.sort((a, b) => a.key.localeCompare(b.key, 'en', { numeric: true }));
}

function wordsRecords(l: Loaded): WordsRecord[] {
  return l.operator.verified.filter((o) => o.words === 1)
    .map((o) => ({ id: o.id, decision: o.decision, keys: o.keys ?? [], op: o.op ?? null, verbatim: o.verbatim ?? '' }));
}

const asksOperatorKeys = (issues: Map<string, IssueSnap> | null): string[] =>
  [...(issues?.values() ?? [])].filter((i) => terminalOf(i) === null && asksOperator(factsOf(i))).map((i) => i.key).sort((a, b) => a.localeCompare(b, 'en', { numeric: true }));

export function ack(ctx: Ctx, o: { ruling: string; reason: string }): EventRow {
  operatorFence(ctx);
  if (!o.reason.trim()) throw new Error('release ack: --reason says why the refusal is right');
  return locked(ctx, (l) => {
    if (l.events.bad.length) throw new Error(`release: events.jsonl does not verify (${l.events.bad[0]})`);
    const { issues } = readMirror(ctx.mirrorRoot);
    if (!issues) throw new Error('release ack: the Jira mirror is unreadable, so whether the key is operator-asked is unknown; sync it first');
    const a = refusedAsks(l, issues).find((x) => x.ruling === o.ruling);
    if (!a) throw new Error(`release ack: ${o.ruling} is no open refused ask of ${ctx.release}`);
    if (a.asks_operator === null) throw new Error(`release ack: ${a.key} is not in the Jira mirror, so whether it is operator-asked is unknown; sync it first`);
    if (a.asks_operator) {
      throw new Error(`release ack: ${a.key} is operator-asked (labelled operator-directed, or High or Highest); its refusal ends only by a new request, an O- record of the operator's words, or the ticket closing`);
    }
    return appendChain<EventRow>(f(ctx, 'events.jsonl'), l.k, { ts: ts(ctx), kind: 'ack', key: a.key, from: null, to: null, ruling: a.ruling, reason: o.reason.trim() });
  });
}

function admissionsToday(ctx: Ctx, l: Loaded): Record<string, number> {
  const today = ts(ctx).slice(0, 10);
  const counts: Record<string, number> = Object.fromEntries(l.decl.versions.map((v) => [v, 0]));
  for (const o of l.operator.verified) {
    if (o.kind !== 'decision' || (o.op !== 'add' && o.op !== 'move') || !o.to_v || !(o.to_v in counts) || !o.ts.startsWith(today)) continue;
    counts[o.to_v] += o.keys?.length ?? 0;
  }
  return counts;
}

export function state(ctx: Ctx): StateOut {
  const l = load(ctx);
  const empty = {
    admissions_today: {}, lease: null, requests: { open: [], claimed: [], oldest_open: null }, heads: { rulings: '', operator: '', events: '', requests: '', mirror: null },
    refused_asks: [], words_records: [], asks_operator_keys: [], unfinished_rulings: [], remainder_conflicts: [],
  };
  if ('unknown' in l) return { ...unknownState(ctx.release, l.unknown), ...empty };
  const mirror = readMirror(ctx.mirrorRoot);
  const s = reduceLoaded(l, mirror);
  let lease: Lease | null = null;
  try {
    lease = readLease(ctx, l.k);
  } catch (e) {
    s.integrity.push((e as Error).message);
  }
  const open: string[] = [];
  const claimed: string[] = [];
  let oldestOpen: string | null = null;
  if (l.requests.bad.length) s.integrity.push(...l.requests.bad.map((b) => `requests.jsonl ${b}`));
  for (const r of latestOrEmpty(l.requests).values()) {
    if (r.state === 'open') {
      open.push(r.req);
      if (oldestOpen === null || r.ts < oldestOpen) oldestOpen = r.ts;
    } else if (r.state.startsWith('claimed:')) claimed.push(r.req);
  }
  const { mac: _m, ...leaseOut } = lease ?? ({} as Lease);
  const unfinished = unfinishedOf(l.rulings, l.events.verified, l.operator.verified, ctx, mirror.issues, lease);
  return {
    ...s,
    status: lease ? s.status : 'UNKNOWN',
    admissions_today: admissionsToday(ctx, l),
    lease: lease ? { ...leaseOut, ...(!lease.released && ownerGone(lease) ? { owner_gone: true as const } : {}) } : null,
    requests: { open, claimed, oldest_open: oldestOpen },
    heads: { rulings: l.rulings.head, operator: l.operator.head, events: l.events.head, requests: l.requests.head, mirror: mirror.sync },
    refused_asks: refusedAsks(l, mirror.issues),
    words_records: wordsRecords(l),
    asks_operator_keys: asksOperatorKeys(mirror.issues),
    unfinished_rulings: unfinished,
    remainder_conflicts: remainderConflicts(l, mirror.issues, ctx.release, unfinished),
  };
}

// A required remainder is recorded as request evidence `{follow_up_of: <parent>, remainder: true}` (create --follow-up-of --remainder,
// or request --required-by). The relation is the child's NEWEST live INTAKE-to-current request: a later request that drops the flag or
// names another parent replaces it before anything is filtered, and a withdrawn request states none. A parent that is done or outside
// the current version, or a child that is closed or already in it, is no contradiction; what the mirror cannot say stays listed as unknown.
// The refusal ack ends a notice, not the contradiction: a child with no request or ruling left to process is the chief's.
function remainderConflicts(l: Loaded, issues: Map<string, IssueSnap> | null, release: string, unfinished: UnfinishedRuling[]): RemainderConflict[] {
  const current = l.decl.current;
  const pending = new Map(unfinished.map((r) => [r.ruling, r]));
  const rulingOf = new Map<string, RulingRow>();
  for (const r of l.rulings.verified) rulingOf.set(r.req, r);
  const newest = new Map<string, RequestRow>();
  for (const q of [...latestOrEmpty(l.requests).values()].sort((a, b) => a.ts.localeCompare(b.ts))) {
    if (q.verb === 'INTAKE' && q.to_v === current && !q.state.startsWith('withdrawn:')) newest.set(q.key, q);
  }
  const out: RemainderConflict[] = [];
  for (const q of newest.values()) {
    const ev = (q.evidence ?? {}) as { follow_up_of?: unknown; remainder?: unknown };
    if (ev.remainder !== true || typeof ev.follow_up_of !== 'string') continue;
    const parentKey = ev.follow_up_of;
    const parent = issues?.get(parentKey);
    const child = issues?.get(q.key);
    if (issues && parent && (terminalOf(parent) !== null || !parent.fixVersions.includes(current))) continue;
    if (issues && child && (terminalOf(child) !== null || child.fixVersions.includes(current))) continue;
    const ruling = rulingOf.get(q.req) ?? null;
    const base = { parent: parentKey, child: q.key, req: q.req, ruling: ruling?.id ?? null };
    const remedy = conflictRemedy(release, q, parentKey, child ? asksOperator(factsOf(child)) : null);
    const unknown = !issues ? 'mirror' : !parent ? 'parent' : !child ? 'child' : null;
    const rm = (phase: 'open' | 'claimed' | 'ruled'): RemainderConflict => ({ ...base, phase, owner: 'release-manager', next: 'jira release rm-run ' + release, unknown });
    const chief = (phase: RemainderConflict['phase'], next: string): RemainderConflict => ({ ...base, phase, owner: 'chief', next, unknown });
    const unread = unknown === null ? '' : (unknown === 'mirror' ? 'both tickets' : unknown === 'parent' ? parentKey : q.key);
    const refresh = 'the Jira mirror cannot say ' + unread + ': run `jira mirror`, then read `jira release state ' + release + ' --json` again';
    const closed = q.state === 'held' ? 'held' : q.state.startsWith('ruled:') && ruling?.outcome === 'ADMIT' ? 'ruled' : 'refused';
    if (q.state === 'open') out.push(rm('open'));
    else if (q.state.startsWith('claimed:')) out.push(rm('claimed'));
    else if (q.state.startsWith('ruled:') && ruling && (ruling.phase === 'intent' || ruling.phase === 'applied')) {
      const action = pending.get(ruling.id);
      out.push(action?.status === 'blocked' ? chief('ruled', action.next) : rm('ruled'));
    }
    else if (unknown !== null) out.push(chief(closed, refresh));
    else if (q.state.startsWith('ruled:') && ruling?.outcome === 'ADMIT') {
      out.push(chief('ruled', 'the ruling admitted ' + q.key + ' but the mirror still shows it outside ' + current + ': run `jira mirror`; if it still sits outside, ' + remedy));
    } else out.push(chief(q.state === 'held' ? 'held' : 'refused', remedy));
  }
  return out.sort((a, b) => a.child.localeCompare(b.child, 'en', { numeric: true }));
}

// The next command for a required child that stays outside: new facts or the operator's words, keeping the relation, or the ask without it.
// The refusal ack is not offered: it ends the notice and leaves the requirement unmet.
function conflictRemedy(release: string, q: RequestRow, parent: string, asksOperator: boolean | null): string {
  const base = `jira release request ${release} --verb ${q.verb} --key ${q.key} --from ${vName(q.from_v)} --to ${vName(q.to_v)} --required-by ${parent}`;
  if (asksOperator !== false) return `${base} --why "<why>" --decision <n> --words "<the operator's exact words>"`;
  return `new facts: ${base} --why "<what changed>" --evidence '{"<changed requirement>":"<value>"}'; or, if ${parent} can close without ${q.key}, file the ask again without --required-by`;
}

function unfinishedOf(rulings: Chain<RulingRow>, events: EventRow[], operator: OperatorRow[], ctx: Ctx, issues: Map<string, IssueSnap> | null, lease: Lease | null): UnfinishedRuling[] {
  const last = new Map<string, RulingRow>();
  for (const r of rulings.verified) last.set(r.id, r);
  return [...last.values()].filter((r) => r.phase === 'intent' || r.phase === 'applied').map((r) => {
    const base = { ruling: r.id, req: r.req, key: r.key, phase: r.phase as 'intent' | 'applied', op: `${r.op.kind} ${vName(r.op.from_v)}→${vName(r.op.to_v)}` };
    const replay: UnfinishedRuling = { ...base, status: 'replay', owner: 'release-manager', next: `jira release rm-run ${ctx.release}`, observed: null };
    const snap = issues?.get(r.key);
    // The writing run still holds its lease: it is between its two writes, not interrupted.
    if (r.phase !== 'intent' || !snap || (lease && !lease.released && lease.epoch === r.epoch)) return replay;
    if (landed(r.op, snap.fixVersions) || untouched(r.op, snap.fixVersions)) return replay;
    // A replay that already refused this ruling left a `ruled` mismatch event: the journal binding it has was checked live and failed.
    const refused = events.some((e) => e.kind === 'ruled' && e.ruling === r.id && e.readback === 'mismatch');
    const newer = newerElsewhere(operator, r);
    if (!refused && !newer && boundRemoval(ctx.env, r, snap.fixVersions)) return replay;
    const repair = repairOf(ctx.release, r, false, snap.fixVersions);
    return { ...base, status: 'blocked', owner: 'chief', next: newer ? `${againstOf(newer, r)}, so the replay writes nothing; ${repair}` : repair, observed: observedOf(r, snap.fixVersions, 'mirror') };
  });
}

function latestOrEmpty(requests: Chain<RequestRow>): Map<string, RequestRow> {
  const m = new Map<string, RequestRow>();
  for (const r of requests.verified) m.set(r.req, r);
  return m;
}

// The rows the version repair reads that StateOut does not carry. A bad requests line is reported, never thrown, so the
// repair can stop on it; a bad admissions line reads as no rows here, and state().inputs.admissions already says UNKNOWN.
export function repairInputs(ctx: Ctx): {
  operator: OperatorRow[]; rulings: RulingRow[]; requests: RequestRow[]; admissions: Admission[]; requestsBad: boolean;
} {
  const l = loadOrThrow(ctx);
  return {
    operator: l.operator.verified,
    rulings: l.rulings.verified,
    requests: [...latestOrEmpty(l.requests).values()],
    admissions: (admissionsOrNull() ?? []).filter((a) => typeof a === 'object' && a !== null),
    requestsBad: l.requests.bad.length > 0,
  };
}

// --- rm-run: the release manager as one on-demand batch -------------------------------

// The judge cannot rule the request: only req and reason count, nothing is ruled and the request stays claimed (a version-repair request becomes held).
export interface HoldDecision {
  req: string;
  outcome: 'HOLD';
  reason: string;
}

export interface RuledDecision {
  req: string;
  outcome: string;
  op: Op['kind'];
  from: string | null;
  to: string | null;
  sector: string | null;
  ground: string;
  reason: string;
  supersedes?: string[];
  authority?: Authority['kind'];
  ref?: string | null;
  blocks?: string[];
  delivered?: string;
  queue?: QueuedRequest;
}

export interface QueuedRequest { verb: Verb; from_v: string | null; to_v: string | null; operator_record: string }

export interface RefuseDecision {
  req: string;
  outcome: 'REFUSE';
  ground: string;
  reason: string;
  queue?: QueuedRequest;
}

export type Decision = HoldDecision | RuledDecision | RefuseDecision;

// The ruling of a standing blocker pull: ADMIT under O-<R>-blocker-pull, with no model call. The shape is
// mechanical; rule() checks the mirror and a newer operator record.
function pullDecision(now: Loaded, mirror: ReturnType<typeof readMirror>, q: RequestRow): RuledDecision | { noop: string } {
  const release = now.decl.release;
  const id = `O-${release}-blocker-pull`;
  if (!now.operator.verified.some((x) => x.id === id && x.kind === 'blocker-pull')) throw new Error(`blocker-pull: ${id} is not recorded`);
  const given = (q.evidence as { blocks?: unknown } | null)?.blocks;
  const blocks = Array.isArray(given) ? given.filter((k): k is string => typeof k === 'string') : [];
  if (!blocks.length || q.to_v !== now.decl.current) throw new Error(`blocker-pull: ${q.req} does not name the tickets it unblocks in ${now.decl.current}`);
  const snap = mirror.issues?.get(q.key);
  if (snap?.fixVersions.includes(q.to_v)) return { noop: `${q.key} is already in ${q.to_v}; nothing to pull` };
  const op: Op = { kind: q.from_v ? 'move' : 'add', from_v: q.from_v, to_v: q.to_v };
  return {
    req: q.req, outcome: 'ADMIT', op: op.kind, from: q.from_v, to: q.to_v, sector: snap?.sector ?? null, ground: 'blocker-pull',
    reason: `blocks ${blocks.join(', ')} in ${now.decl.current}; standing rule ${id} (decision ${BLOCKER_PULL_DECISION})`,
    supersedes: supersedesOf(now, mirror, q.key, op), authority: 'operator', ref: id, blocks,
  };
}

function supersedesOf(now: Loaded, mirror: ReturnType<typeof readMirror>, key: string, op: Op): string[] {
  const s = reduceLoaded(now, mirror);
  return [...new Set(now.decl.versions.filter((v) => effectOn(op, v)).flatMap((v) => recordOf(s, key, v)?.ruling ?? []))];
}

function duplicateOf(evidence: unknown): string | undefined {
  const original = (evidence as { duplicate_of?: unknown } | null)?.duplicate_of;
  return typeof original === 'string' && ISSUE_KEY.test(original) ? original : undefined;
}

function mergeEvidenceFor(q: RequestRow, t: 'Done' | 'Duplicate', lookup?: (key: string) => number | undefined): string | undefined {
  if (!lookup) return undefined;
  const original = t === 'Duplicate' ? duplicateOf(q.evidence) : undefined;
  const found = lookup(q.key) ?? (original ? lookup(original) : undefined);
  return found !== undefined ? `PR #${found}` : undefined;
}

function deliveredDecision(now: Loaded, mirror: ReturnType<typeof readMirror>, q: RequestRow, lookup?: (key: string) => number | undefined): RuledDecision | null {
  const id = `O-${now.decl.release}-delivered-follows-merge`;
  if (!now.operator.verified.some((x) => x.id === id && x.kind === 'delivered-follows-merge')) return null;
  const { current, versions } = now.decl;
  if (q.verb !== 'INTAKE' || q.to_v !== current) return null;
  const snap = mirror.issues?.get(q.key);
  if (!snap || snap.fixVersions.includes(current)) return null;
  const t = terminalOf(snap);
  if (t !== 'Done' && t !== 'Duplicate') return null;
  const from = versions.find((v) => v !== current && snap.fixVersions.includes(v));
  if (!from || q.from_v !== from) return null;
  const evidence = mergeEvidenceFor(q, t, lookup);
  if (!evidence) return null;
  const op: Op = { kind: 'move', from_v: from, to_v: current };
  return {
    req: q.req, outcome: 'ADMIT', op: op.kind, from, to: current, sector: snap.sector ?? null, ground: 'delivered-follows-merge',
    reason: `${q.key} is ${t} with ${evidence}; merged work follows its merge version ${current}; standing rule ${id} (decision ${DELIVERED_DECISION})`,
    supersedes: supersedesOf(now, mirror, q.key, op), authority: 'operator', ref: id, delivered: evidence,
  };
}

const isHold = (d: Decision): d is HoldDecision => d.outcome === 'HOLD';
const isRefuse = (d: Decision): d is RefuseDecision => d.outcome === 'REFUSE';

const authorityOf = (d: RuledDecision): Authority =>
  ({ kind: d.authority ?? 'rm', ref: d.ref ?? null, ...(d.blocks ? { blocks: d.blocks } : {}), ...(d.delivered ? { delivered: d.delivered } : {}) });

function deliveredDecisions(now: Loaded, mirror: ReturnType<typeof readMirror>, claimed: RequestRow[], lookup?: (key: string) => number | undefined): Map<string, RuledDecision> {
  const out = new Map<string, RuledDecision>();
  for (const q of claimed) {
    const got = isPullRequest(q) ? null : deliveredDecision(now, mirror, q, lookup);
    if (got) out.set(q.req, got);
  }
  return out;
}

// Everything a ruling weighs, read from disk: a standing session kept nothing else that counts.
export interface JudgeInput {
  release: string;
  current: string;
  versions: string[];
  requests: RequestRow[];
  records: ReleaseState['records'];
  operator: OperatorRow[];
  rulings: RulingRow[];
  issues: IssueSnap[];
  ruled_at?: Record<string, string>;
  required_parent?: Record<string, string>;
}

export type Judge = (input: JudgeInput, opts?: { signal?: AbortSignal }) => Promise<Decision[]>;

// A judge reply the decision check refused; raw is kept so the run doc can show what the model said.
export class JudgeReplyError extends Error {
  constructor(message: string, readonly raw: string) {
    super(message);
    this.name = 'JudgeReplyError';
  }
}

function unfinishedRulings(rulings: Chain<RulingRow>): string[] {
  const last = new Map<string, RulingRow>();
  for (const r of rulings.verified) last.set(r.id, r);
  return [...last.values()].filter((r) => r.phase === 'intent' || r.phase === 'applied').map((r) => r.id);
}

export const LIVE_LOOKUP_MS = 15_000;
export const LIVE_POOL_MS = 60_000;
export const LIVE_READS = 8;

function overlay(mirrored: IssueSnap | undefined, live: IssueSnap): IssueSnap {
  if (!mirrored) return live;
  const out: Record<string, unknown> = { ...mirrored };
  for (const [k, v] of Object.entries(live)) if (v !== null && v !== undefined && v !== '') out[k] = v;
  return out as unknown as IssueSnap;
}

async function liveIssues(ctx: Ctx, keys: string[], mirrored: Map<string, IssueSnap> | null): Promise<{ issues: IssueSnap[]; fallback: Set<string> }> {
  const jira = ctx.jira as DoorJiraPort;
  const fallback = new Set<string>();
  let open = 0;
  let first: number | undefined;
  const waiters: Array<() => void> = [];
  const left = () => (first === undefined ? LIVE_POOL_MS : LIVE_POOL_MS - (Date.now() - first));
  const slot = async (): Promise<boolean> => {
    for (;;) {
      if (open < LIVE_READS) break;
      if (left() <= 0) return false;
      const freed = await new Promise<boolean>((resolve) => {
        const wake = () => { clearTimeout(timer); resolve(true); };
        const timer = setTimeout(() => { waiters.splice(waiters.indexOf(wake), 1); resolve(false); }, left());
        waiters.push(wake);
      });
      if (!freed) return false;
    }
    if (left() <= 0) return false;
    first ??= Date.now();
    open++;
    return true;
  };
  const one = async (key: string): Promise<IssueSnap | undefined> => {
    const m = mirrored?.get(key);
    if (!jira.issue) return m;
    if (!(await slot())) { fallback.add(key); return m; }
    const stop = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const read = Promise.resolve().then(() => jira.issue!(key, { signal: stop.signal })).finally(() => { open--; waiters.shift()?.(); });
    try {
      const live = await Promise.race([read, new Promise<undefined>((resolve) => { timer = setTimeout(() => { stop.abort(); resolve(undefined); }, LIVE_LOOKUP_MS); })]);
      if (live === undefined) { fallback.add(key); return m; }
      return live ? overlay(m, live) : m;
    } catch {
      fallback.add(key);
      return m;
    } finally {
      clearTimeout(timer);
      read.catch(() => undefined);
    }
  };
  const got = await Promise.all(keys.map(one));
  return { issues: got.flatMap((i) => i ?? []), fallback };
}

// Takes the lease, finishes older unreceipted rulings, claims, asks the judge once, rules and
// applies through the engine, and releases the lease. Decisions come only from
// the judge, never from the caller.

// Puts a claimed request back to open so the next run claims it again.
function unclaim(ctx: Ctx, req: string): void {
  locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const r = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(req);
    if (!r || r.state !== `claimed:${lease.epoch}`) return;
    const { prev: _p, mac: _m, ...rest } = r;
    appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: 'open' });
  });
}

// A version-repair request the judge held leaves the queue until a repair run withdraws it; claim() skips `held`.
function hold(ctx: Ctx, req: string, reason: string): void {
  locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const r = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(req);
    if (!r || r.state !== `claimed:${lease.epoch}`) return;
    const { prev: _p, mac: _m, ...rest } = r;
    appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: 'held', reason });
  });
}

// Closes a claimed request the engine refused, so a re-filed request opens a new qid.
function refuse(ctx: Ctx, req: string, reason: string): void {
  locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const r = latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).get(req);
    if (!r || r.state !== `claimed:${lease.epoch}`) return;
    const { prev: _p, mac: _m, ...rest } = r;
    appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: `refused:${lease.epoch}`, reason });
  });
}

function returnClaims(ctx: Ctx): number {
  return locked(ctx, (l) => {
    const lease = rmFence(ctx, l);
    const mine = [...latestRequests(readChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k)).values()].filter((r) => r.state === `claimed:${lease.epoch}`);
    for (const r of mine) {
      const { prev: _p, mac: _m, ...rest } = r;
      appendChain<RequestRow>(f(ctx, 'requests.jsonl'), l.k, { ...rest, ts: ts(ctx), state: 'open' });
    }
    return mine.length;
  });
}

const stopReason = (signal: AbortSignal): Error => (signal.reason instanceof Error ? signal.reason : new Error(String(signal.reason)));

function linkStop(signal?: AbortSignal): { stop: AbortController; unlink: () => void } {
  const stop = new AbortController();
  const onStop = () => stop.abort(signal?.reason);
  if (signal?.aborted) onStop();
  else signal?.addEventListener('abort', onStop, { once: true });
  return { stop, unlink: () => signal?.removeEventListener('abort', onStop) };
}

function reclaimNote(prior: RunLease): string[] {
  if (!prior.owner_doc || prior.released || !ownerGone(prior)) return [];
  return [`RECLAIMED lease epoch ${prior.epoch}: rm-run pid ${prior.owner_pid} on ${prior.owner_host} is gone`];
}

function failNote(ctx: Ctx, failed: Error, lines: string[]): void {
  lines.push(`FAILED: ${failed.message}`);
  try {
    const n = returnClaims(ctx);
    if (n) lines.push(`RETURNED ${n} claimed requests to open`);
  } catch (e) {
    lines.push(`PENDING claims: ${(e as Error).message}`);
  }
}

export const JUDGE_SETTLE_MS = 6000;

function startDeadline(stop: AbortController, ms: number | undefined): () => void {
  if (ms === undefined) return () => undefined;
  const timer = setTimeout(() => stop.abort(new Error(`rm-run: the judge did not answer within ${ms / 1000}s; nothing ruled`)), ms);
  return () => clearTimeout(timer);
}

async function settleWithin(answer: Promise<unknown>, ms: number): Promise<void> {
  let grace: ReturnType<typeof setTimeout> | undefined;
  await Promise.race([answer.then(() => undefined, () => undefined), new Promise((r) => { grace = setTimeout(r, ms); })]);
  clearTimeout(grace);
}

function answerBeforeStop<T>(answer: Promise<T>, stop: AbortSignal): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const stopped = () => void settleWithin(answer, JUDGE_SETTLE_MS).then(() => reject(stopReason(stop)));
    if (stop.aborted) return stopped();
    stop.addEventListener('abort', stopped, { once: true });
    answer.then((v) => { if (!stop.aborted) resolve(v); }, (e) => { if (!stop.aborted) reject(e); });
  });
}

async function judged<T>(answer: Promise<T>, stop: AbortController, ms: number | undefined): Promise<T> {
  const clearDeadline = startDeadline(stop, ms);
  try {
    return await answerBeforeStop(answer, stop.signal);
  } finally {
    clearDeadline();
  }
}

export interface RmRunOptions {
  doc?: string;
  session?: string;
  /** The caller's stop (the CLI wires SIGTERM, SIGINT and SIGHUP to it): the run fails cleanly at the next step. */
  signal?: AbortSignal;
  /** How long the judge may take before the run fails (default: no deadline of the run's own). */
  judgeTimeoutMs?: number;
  /** The process the lease names (default this one), so the next run can free the lease if it dies. */
  pid?: number;
  /** Called once the judge answers or fails: how many requests it was asked and how long it took (decision 815). */
  onJudge?: (requests: number, ms: number) => void;
}

// The last line of an rm-run that refused anything: how many requests the engine refused, so a refusal is not
// only buried in the lines above. A run with no refusal prints none and keeps its output.
export function rmRunSummary(release: string, lines: string[]): string | null {
  const n = lines.filter((x) => /^REFUSED /.test(x)).length;
  return n ? `RM-RUN ${release} summary: ${n} refused` : null;
}

function queueRequest(ctx: Ctx, q: RequestRow, queue: QueuedRequest): string {
  return locked(ctx, (l) => {
    rmFence(ctx, l);
    return fileRequest(ctx, l, {
      from: 'rm', verb: queue.verb, key: q.key, from_v: queue.from_v, to_v: queue.to_v,
      why: `the operator's ${queue.operator_record} still owes this ${queue.verb}`, evidence: { operator_record: queue.operator_record },
    }).req;
  });
}

export async function rmRun(ctx: Ctx, judge: Judge, o: RmRunOptions = {}): Promise<string[]> {
  const l = loadOrThrow(ctx);
  const pending = [...latestRequests(l.requests).values()].filter((r) => r.state === 'open' || r.state.startsWith('claimed:'));
  if (!pending.length && !unfinishedRulings(l.rulings).length) return [`RM-RUN ${ctx.release}: nothing pending`];

  const doc = o.doc ?? join(ctx.dir, 'rm-runs', `run-${ts(ctx).replace(/[:.]/g, '-')}.md`);
  const rctx: Ctx = { ...ctx, env: { ...ctx.env, HIMMEL_RELEASE_MANAGER: '1', HIMMEL_RM_DOC: doc, HIMMEL_RM_RELEASE: ctx.release } };
  const prior: RunLease = readLease(ctx, l.k);
  const lease = leaseAcquire(rctx, { expectEpoch: prior.epoch, doc, session: o.session ?? 'rm-run', pid: o.pid ?? process.pid, reclaim: true });
  const lines: string[] = reclaimNote(prior);
  const { stop, unlink } = linkStop(o.signal);
  const halt = () => { if (stop.signal.aborted) throw stopReason(stop.signal); };
  let failed: Error | undefined;
  let refused: JudgeReplyError | undefined;
  const queue = (q: RequestRow, d: { queue?: QueuedRequest }) => {
    if (!d.queue) return;
    try {
      lines.push(`QUEUED ${queueRequest(rctx, q, d.queue)}: ${d.queue.verb} ${q.key} for ${d.queue.operator_record}`);
    } catch (e) {
      lines.push(`PENDING queue ${q.req}: ${(e as Error).message}`);
    }
  };
  try {
    halt();
    for (const id of unfinishedRulings(loadOrThrow(ctx).rulings)) {
      halt();
      try {
        const got = await apply(rctx, id);
        lines.push(got.line);
        if (got.note) lines.push(`PENDING ${id}: ${got.note}`);
      } catch (e) {
        lines.push(`PENDING ${id}: ${(e as Error).message}`);
      }
    }
    const seen = new Set<string>();
    const claimed: RequestRow[] = [];
    for (const q of claim(rctx)) {
      if (seen.has(q.key)) unclaim(rctx, q.req);
      else { seen.add(q.key); claimed.push(q); }
    }
    if (claimed.length) {
      const now = loadOrThrow(ctx);
      const mirror = readMirror(ctx.mirrorRoot);
      const delivered = deliveredDecisions(now, mirror, claimed, ctx.deliveredPr);
      const asked = claimed.filter((q) => !isPullRequest(q) && !delivered.has(q.req));
      const history = now.requests.verified;
      const required_parent = requiredParentOf(history);
      const keys = new Set(asked.map((r) => r.key));
      const parents = [...keys].flatMap((k) => required_parent[k] ? [required_parent[k]] : []);
      const ruled_at: Record<string, string> = {};
      const newest = new Map<string, RulingRow>();
      for (const r of now.rulings.verified) {
        ruled_at[r.id] ??= r.ts;
        newest.set(r.id, r);
      }
      const settled = [...newest.values()].filter((r) => r.phase === 'applied' || r.phase === 'receipted');
      const receipted = settled.filter((r) => r.phase === 'receipted');
      const live = await liveIssues(ctx, [...new Set([...keys, ...parents])], mirror.issues);
      const issues = live.issues;
      halt();
      let decisions: Decision[];
      const judgeStart = Date.now();
      try {
        decisions = !asked.length ? [] : await judged(judge({
          release: ctx.release, current: now.decl.current, versions: now.decl.versions, requests: asked,
          records: reduceLoaded(now, mirror).records.filter((r) => keys.has(r.key)),
          operator: judgeOperatorRows(ctx.release, now.operator.verified, asked, issues, receipted),
          rulings: [...new Set([...settled.filter((r) => keys.has(r.key)), ...receipted.slice(-40)])],
          issues, ruled_at, required_parent,
        }, { signal: stop.signal }), stop, o.judgeTimeoutMs);
      } catch (e) {
        if (e instanceof JudgeReplyError) {
          refused = e;
          lines.push(`JUDGE-REFUSED: ${e.message}`);
        }
        throw e;
      } finally {
        if (asked.length) o.onJudge?.(asked.length, Date.now() - judgeStart);
      }
      for (const q of claimed) {
        halt();
        let id: string;
        let d = delivered.get(q.req) ?? decisions.find((x) => x?.req === q.req);
        const pulled = isPullRequest(q);
        const facts = live.fallback.has(q.key) ? ' (mirror facts)' : '';
        try {
          if (pulled) {
            const got = pullDecision(now, mirror, q);
            if ('noop' in got) {
              lines.push(`NOOP ${q.req}: ${got.noop}`);
              refuse(rctx, q.req, got.noop);
              continue;
            }
            d = got;
          }
          if (!d) throw new Error('the judge returned no decision');
          if (isRefuse(d)) {
            lines.push(`REFUSED ${q.req}: ${d.ground}: ${d.reason}${facts}`);
            refuse(rctx, q.req, `${d.ground}: ${d.reason}${facts}`);
            queue(q, d);
            continue;
          }
          if (isHold(d)) {
            lines.push(`HELD ${q.req}: ${d.reason}`);
            if (isRepair(q)) hold(rctx, q.req, d.reason);
            continue;
          }
          id = rule(rctx, {
            req: q.req, outcome: d.outcome, op: { kind: d.op, from_v: d.from ?? null, to_v: d.to ?? null }, sector: d.sector ?? '',
            ground: d.ground ?? '', reason: `${d.reason ?? ''}${facts}`, supersedes: d.supersedes ?? [],
            authority: authorityOf(d),
          }).id;
        } catch (e) {
          lines.push(`REFUSED ${q.req}: ${(e as Error).message}`);
          if (d || pulled) refuse(rctx, q.req, (e as Error).message);
          continue;
        }
        queue(q, d);
        try {
          const got = await apply(rctx, id);
          lines.push(got.line);
          if (got.note) lines.push(`PENDING ${id}: ${got.note}`);
        } catch (e) {
          lines.push(`PENDING ${id}: ${(e as Error).message}`);
        }
      }
    }
  } catch (e) {
    failed = e as Error;
    throw e;
  } finally {
    // Cleanup never hides the rulings already made or the error that ended the run.
    unlink();
    if (failed) failNote(rctx, failed, lines);
    try {
      leaseRelease(rctx);
    } catch (e) {
      lines.push(`PENDING lease: ${(e as Error).message}`);
    }
    try {
      mkdirSync(dirname(doc), { recursive: true });
      const raw = refused ? `\n## Raw judge reply\n\n~~~~\n${refused.raw}\n~~~~\n` : '';
      writeFileSync(doc, `# rm-run ${ctx.release} epoch ${lease.epoch}\n\n${lines.map((x) => `- ${x}`).join('\n')}\n${raw}`);
    } catch (e) {
      lines.push(`PENDING run record: ${(e as Error).message}`);
    }
    if (failed) Object.assign(failed, { runLines: lines, runDoc: doc } satisfies RunRecord);
  }
  return lines;
}

/** What a failed rmRun's error carries: the lines it wrote and its run doc, so the caller can print them. */
export interface RunRecord { runLines: string[]; runDoc: string }
