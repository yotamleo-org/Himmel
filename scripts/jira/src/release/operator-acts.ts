import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync } from 'node:fs';
import { basename, dirname, isAbsolute, join } from 'node:path';
import { releaseKeyPath, releaseRoot } from './paths.js';
import { type Getter } from './version-writes.js';
import { appendChain, contentSha, loadKey, mintKey, readChain, readSigned, withLock, writeSigned } from './ledger.js';
import { baselineId, effectOn, terminalOf } from './reducer.js';
import { checkWords, decisionsDirFor, resolveDecision } from './verbatim.js';
import type { Baseline, Declaration, EventRow, IssueSnap, OperatorRow, OutOfVersionRow, RequestRow } from './types.js';
import { appendOperator, type Ctx, f, latestRequests, type Loaded, locked, lockedAcross, operatorFence, readMirror, readOperatorRecords, type ReleaseRecord, ts } from './engine-core.js';
import { mirrorState, type MirrorState } from '../mirror-cursor.js';

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

export const DELIVERED_DECISION = '929';
const DELIVERED_VERBATIM = 'standing record: a ticket whose work merges while it sits in a later version moves to the version open at merge time ("471 standing it should move to 1.1.3")';

export const BLOCKER_PULL_DECISION = '385';
const BLOCKER_PULL_VERBATIM = 'standing record: a blocker of a ticket in the current version is placed in the current version as its related item';

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

export function placementOf(o: { op?: string; from_v?: string | null; to_v?: string | null }): string | null | undefined {
  if (o.op === 'keep' || o.op === 'discharge') return o.from_v ?? null;
  if (o.op === 'remove') return null;
  if (o.op === 'add' || o.op === 'move') return o.to_v ?? null;
  return undefined;
}

export const pending = (r: RequestRow) => r.state === 'open' || r.state.startsWith('claimed:');
const retirable = (r: RequestRow) => pending(r) || r.state === 'held';
export const isRepair = (r: RequestRow | undefined): boolean => (r?.evidence as { rule?: unknown } | null)?.rule === 'version-repair';

export function appendWithdrawal(ctx: Ctx, k: Buffer, r: RequestRow, by: string, reason: string): RequestRow {
  const { prev: _p, mac: _m, ...rest } = r;
  return appendChain<RequestRow>(f(ctx, 'requests.jsonl'), k, { ...rest, ts: ts(ctx), state: `withdrawn:${by}`, reason });
}

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

export interface DeclaredRelease { release: string; project: string; current: string; versions: string[] }

export function releaseForProject(env: Record<string, string | undefined>, project: string): DeclaredRelease[] | 'unreadable' {
  let root: string;
  try {
    root = releaseRoot(env);
  } catch {
    return 'unreadable';
  }
  if (!existsSync(root)) {
    process.stderr.write(`release: no release root at ${root}; no declaration names ${project}\n`);
    return [];
  }
  const out: DeclaredRelease[] = [];
  for (const d of declaredReleases(env)) {
    if (!unparsedOrNamesProject(d, project)) continue;
    if (!d.parsed) return 'unreadable';
    const release = basename(dirname(d.path));
    let k: Buffer;
    try {
      k = loadKey(releaseKeyPath(release, env));
    } catch {
      return 'unreadable';
    }
    const signed = readSigned<Declaration>(d.path, k);
    const v = signed.value;
    if (!signed.ok || !v || v.release !== release || !Array.isArray(v.versions) || typeof v.current !== 'string') return 'unreadable';
    out.push({ release, project, current: v.current, versions: [...v.versions] });
  }
  return out;
}

function withinDeadline<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`no answer within ${ms} ms`)), ms);
  });
  return Promise.race([p, deadline]).finally(() => clearTimeout(timer));
}

export interface BucketOptions { get: Getter; deadlineMs: number; now: Date; cli?: string }

const shellQuote = (s: string): string => (/^[A-Za-z0-9_./:@%+=-]+$/.test(s) ? s : `'${s.replace(/'/g, `'\\''`)}'`);

export async function bucketCheck(env: Record<string, string | undefined>, keys: string[], mirrorRoot: string, o: BucketOptions): Promise<string[]> {
  const { issues } = readMirror(mirrorRoot);
  const state = issues ? null : mirrorState(mirrorRoot);
  const versionsPath = `${mirrorRoot.replace(/\/+$/, '')}.versions.tsv`;
  const lines: string[] = [];
  for (const key of keys) lines.push(await bucketLine(env, key, mirrorRoot, versionsPath, issues, o, state));
  return lines;
}

async function bucketLine(env: Record<string, string | undefined>, key: string, mirrorRoot: string, versionsPath: string,
  issues: Map<string, IssueSnap> | null, o: BucketOptions, state: MirrorState | null): Promise<string> {
  const failed = (why: string) => `FAILED ${key} ${why.replace(/\s+/g, ' ')}`;
  if (!ISSUE_KEY.test(key)) return failed('is not a ticket key');
  const project = key.split('-')[0];
  if (!issues && state?.complete === 'no') {
    const heal = `JIRA_PROJECT_KEY=${project} ${o.cli ? `node ${shellQuote(o.cli)}` : 'jira'} mirror --root ${shellQuote(mirrorRoot)}`;
    return failed(`mirror sync incomplete since ${state.lastSync} at ${mirrorRoot} (cursor complete: false, repair: ${state.repair}); heal: ${heal}`);
  }
  if (!issues) return failed(`no readable mirror at ${mirrorRoot}`);
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

function coreKeys(verb: string, keys: string[]): string[] {
  if (!keys.length) throw new Error(`release operator ${verb}: no keys given`);
  const bad = keys.find((k) => !ISSUE_KEY.test(k));
  if (bad !== undefined) throw new Error(`release operator ${verb}: '${bad}' is not a ticket key`);
  return [...new Set(keys)].sort();
}

export function coreBypass(ctx: Ctx, o: { keys: string[]; decision: string; verbatim: string }): OperatorRow {
  operatorFence(ctx);
  const keys = coreKeys('core-bypass', o.keys);
  return locked(ctx, (l) => appendOperator(ctx, l.k, { kind: 'core-bypass', decision: o.decision, keys, verbatim: o.verbatim }));
}

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

export interface FoldItem { key: string; pr: number }
export interface FoldSkip { key: string; terminal: string; resolution: string }
export interface FoldOut { folded: EventRow[]; already: string[]; skipped: FoldSkip[] }

export const ISSUE_KEY = /^[A-Z][A-Z0-9]*-\d+$/;

const lastBookkeeping = (events: EventRow[], key: string) =>
  [...events].reverse().find((e) => e.key === key && (e.kind === 'fold' || e.kind === 'reopen'));

function foldVersion(ctx: Ctx, l: Loaded, v: string): void {
  if (!l.decl.versions.includes(v)) throw new Error(`release: ${v} is not a version of ${ctx.release}`);
  if (l.events.bad.length) throw new Error(`release: events.jsonl does not verify (${l.events.bad[0]})`);
}

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
