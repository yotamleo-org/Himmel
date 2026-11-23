import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pinnedSha, pinnedRead, boundedDirectoryNames, selectDecisionNames, reviewedSpecHashes, returnSha, canonicalDirectoryNames, returnDirectories, checkLatestReturns, declaredTickets, keyOf, CRITIC_FILE, criticRounds, findingIds, parseResidualLines, type Kind, memberLedgerState, optionalReturnAgreement, parseManifest, validateCappedFoldProofShape, validateCappedProofShape, type AnyCappedProof, type CappedFoldProof, type CappedLedgerProof, type FilePin, type MemberAbsencePin } from './pinned.js';
import { contentSha, readChain } from './ledger.js';
import { namesKey } from './verbatim.js';
import { KEY_IN } from './judge-input.js';
import type { IssueSnap, OperatorKind, OperatorRow } from './types.js';
import { type Ctx, f, operatorFence, lockedAcross, readMirror, readMirrorFilesUnverified, appendOperator, type ReleaseRecord, readOperatorRecords, readSignerState } from './engine-core.js';
import { effectiveSigner, outranks, parentOf, signerOf, voidingTicket, type SignerState } from './signer.js';
import { pathIndependentBypass } from './core.js';
import { decisionWords } from './operator-acts.js';

const fileSha = (p: string) => createHash('sha256').update(readFileSync(p)).digest('hex');

function pinRead(path: string, role: string, verb: string): { bytes: Buffer; sha256: string } {
  const got = pinnedSha(path);
  if ('missing' in got) throw new Error(`${verb}: ${role} not found: ${path}`);
  if ('unreadable' in got) throw new Error(`${verb}: ${role} ${path} is unreadable`);
  return got;
}

function checkoutRoot(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  const common = execFileSync('git', ['-C', here, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim();
  return dirname(common);
}

function sourceIdentity(raw: string): { root: string; head: string; identity: string } {
  const verb = 'release operator spec: source-root';
  try {
    const root = realpathSync(raw);
    const stamp = (path: string) => {
      const st = lstatSync(path, { bigint: true });
      return `${st.dev}:${st.ino}`;
    };
    const before = [stamp(root), stamp(join(root, '.git'))];
    if (!statSync(root).isDirectory()) throw new Error('not a directory');
    const git = (...args: string[]) => execFileSync('git', ['-C', root, ...args], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
    const common = realpathSync(git('rev-parse', '--path-format=absolute', '--git-common-dir'));
    const primary = realpathSync(checkoutRoot());
    const primaryCommon = realpathSync(execFileSync('git', ['-C', primary, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim());
    if (common !== primaryCommon || realpathSync(git('rev-parse', '--show-toplevel')) !== root) {
      throw new Error('must be a root of the same repository as primary');
    }
    const gitDir = realpathSync(git('rev-parse', '--absolute-git-dir'));
    const head = git('rev-parse', '--verify', 'HEAD^{commit}');
    const registered = git('worktree', 'list', '--porcelain', '-z').split('\0\0').some((record) => {
      const fields = record.split('\0');
      if (!fields[0].startsWith('worktree ') || fields.some((v) => v === 'bare' || v.startsWith('prunable'))) return false;
      try { return realpathSync(fields[0].slice(9)) === root && fields.includes(`HEAD ${head}`); } catch { return false; }
    });
    if (!registered) throw new Error('not a registered live worktree');
    if (root === primary ? gitDir !== common
      : dirname(gitDir) !== realpathSync(join(common, 'worktrees'))
        || realpathSync(readFileSync(join(gitDir, 'gitdir'), 'utf8').trim()) !== realpathSync(join(root, '.git'))) {
      throw new Error('worktree Git identity does not match its registration');
    }
    const identity = JSON.stringify([root, common, gitDir, ...before, stamp(common), stamp(gitDir)]);
    if (realpathSync(raw) !== root || before[0] !== stamp(root) || before[1] !== stamp(join(root, '.git'))
      || git('rev-parse', '--verify', 'HEAD^{commit}') !== head) throw new Error('identity or HEAD changed while it was checked');
    return { root, head, identity };
  } catch (e) {
    throw new Error(`${verb} ${raw} refused: ${(e as Error).message}`);
  }
}

const minervaScript = (name: string): string => join(checkoutRoot(), 'marketplace', 'plugins', 'himmel-ops', 'scripts', name);

function runMinerva(name: string, args: string[], cwd: string, verb = 'release operator spec'): void {
  try {
    execFileSync('bash', [minervaScript(name), ...args], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    const err = e as { stderr?: string; stdout?: string; message: string };
    throw new Error(`${verb}: ${name} refused the spec:\n${(err.stderr || err.stdout || err.message).trim()}`);
  }
}

function lintSpec(spec: string, plan: string, verb?: string, sourceRoot = checkoutRoot()): void {
  runMinerva('minerva-spec-gate.sh', [spec], dirname(spec), verb);
  let own: string[] = [];
  try {
    own = [execFileSync('git', ['-C', dirname(spec), 'rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()];
  } catch { }
  runMinerva('minerva-trace-lint.sh', [spec, plan, ...own], sourceRoot, verb);
}

const VERDICT = /^(SPEC|PLAN) (CLEAN|FINDINGS (\d+))$/;

type VerdictKind = 'SPEC' | 'PLAN';

interface VerdictFile { path: string; sha256: string; kind: VerdictKind; last: string; residuals: number; text: string }

function readVerdicts(paths: string[], verb: string, need: { required: VerdictKind[]; allowed: VerdictKind[] }, refusal: string)
  : { verdicts: Array<{ path: string; sha256: string }>; residuals: number; files: VerdictFile[] } {
  const files = paths.map((raw): VerdictFile => {
    const path = resolve(raw);
    const got = pinnedSha(path);
    if ('missing' in got) throw new Error(`${verb}: verdict file not found: ${path}`);
    if ('unreadable' in got) throw new Error(`${verb}: verdict file ${path} is unreadable`);
    const text = got.bytes.toString('utf8');
    const last = text.split('\n').map((l) => l.trim()).filter(Boolean).at(-1) ?? '';
    const m = VERDICT.exec(last);
    if (!m) throw new Error(`${verb}: ${path} last line is '${last}', not SPEC|PLAN CLEAN or SPEC|PLAN FINDINGS <n>`);
    return { path, sha256: got.sha256, kind: m[1] as VerdictKind, last, residuals: Number(m[3] ?? 0), text };
  });
  const count = (k: VerdictKind) => files.filter((x) => x.kind === k).length;
  const fits = need.required.every((k) => count(k) === 1) && need.allowed.every((k) => count(k) <= 1)
    && files.every((x) => need.required.includes(x.kind) || need.allowed.includes(x.kind));
  if (!fits) throw new Error(refusal);
  return {
    verdicts: files.map(({ path, sha256 }) => ({ path, sha256 })),
    residuals: files.reduce((n, x) => n + x.residuals, 0),
    files,
  };
}

type GivenReturn = { path: string; text: string };

function matchResiduals(lines: string[], residuals: number, returns: GivenReturn[], verb: string, countRefusal: (done: number) => string): void {
  const parsed = parseResidualLines(lines);
  if (parsed.idList.length) {
    throw new Error(`${verb}: a residual line names several findings at once; write one 'R<round>-<id>: <disposition>' line each: `
      + parsed.idList.map((l) => l.trim()).join(' | '));
  }
  if (!parsed.qualified.length) {
    if (residuals && parsed.legacy.size < residuals) throw new Error(countRefusal(parsed.legacy.size));
    return;
  }
  if (parsed.nearMiss.length) {
    throw new Error(`${verb}: a residual line at the highest round does not parse as '<R|P><round>-<id>: <disposition>': `
      + parsed.nearMiss.map((l) => l.trim()).join(' | '));
  }
  const problems: string[] = [];
  const given = new Map<Kind, number>();
  for (const r of returns) {
    const name = basename(r.path);
    const last = r.text.split('\n').map((l) => l.trim()).filter(Boolean).at(-1) ?? '';
    const verdict = VERDICT.exec(last);
    const m = CRITIC_FILE.exec(name);
    if (!m || !verdict) { problems.push(`${name} is not a critic return name with a SPEC|PLAN verdict line`); continue; }
    const kind = (m[2] ?? m[5]) as Kind;
    const round = Number(m[3] ?? m[4]);
    if (kind.toUpperCase() !== verdict[1]) { problems.push(`${name} is a ${kind} return by name but its verdict line is '${last}'`); continue; }
    let ids: string[];
    try { ids = findingIds(r.text); } catch (e) { problems.push(`return ids do not parse: ${(e as Error).message}`); continue; }
    const count = Number(verdict[3] ?? 0);
    if (ids.length !== count) { problems.push(`return ids do not parse: ${name} has ${ids.length} finding headings for '${last}'`); continue; }
    given.set(kind, round);
    const tag = `${kind === 'spec' ? 'R' : 'P'}${round}`;
    const at = parsed.qualified.filter((q) => q.kind === kind && q.round === round);
    const missing = ids.filter((id) => !at.some((q) => q.id === id));
    if (missing.length) problems.push(`no '${tag}-<id>' line for ${missing.join(', ')} of ${name}`);
    for (const q of at) if (!ids.includes(q.id)) problems.push(`${tag}-${q.id} names no finding of ${name}`);
  }
  for (const q of parsed.qualified) {
    const round = given.get(q.kind);
    if (round !== undefined && q.round > round) problems.push(`'${q.line.trim()}' is later than the given ${q.kind} return, round ${round}`);
  }
  if (problems.length) throw new Error(`${verb}: ${problems.join('; ')}`);
}

export function checkResiduals(specText: string, residuals: number, returns: GivenReturn[]): void {
  matchResiduals(criticRounds(specText), residuals, returns, 'release operator spec', (done) =>
    `release operator spec: the verdicts carry ${residuals} residual findings and the spec's ## Critic rounds section has `
      + `${done} dispositioned (one '- R<n>: fixed|ASSUMPTION|ceiling|deferred → HIMMEL-<n>' line each)`);
}

export function checkRoundResiduals(specText: string, names: string[], residuals: number, verb: string, returns: GivenReturn[]): void {
  const inBlocks: string[] = [];
  let inBlock = false;
  for (const l of criticRounds(specText)) {
    if (/^-?\s*Round \d+:/.test(l)) {
      inBlock = names.some((n) => l.includes(n));
      continue;
    }
    if (inBlock) inBlocks.push(l);
  }
  matchResiduals(inBlocks, residuals, returns, verb, (done) =>
    `${verb}: the verdicts carry ${residuals} residual findings and their round blocks hold ${done} dispositioned `
      + `(one '- R<n>: fixed|ASSUMPTION|ceiling|deferred → HIMMEL-<n>' line each, under the '- Round <n>: … <verdict file>' line)`);
}

interface CappedInputs {
  keys: string[]; spec: FilePin; plan?: FilePin; files: VerdictFile[]; residuals: number;
}

function cappedVerifier(): string {
  return fileURLToPath(new URL('../../../telegram/chief-route.ts', import.meta.url));
}

function canonical(path: string): boolean {
  try { return realpathSync(path) === path; } catch { return false; }
}

function memberAbsent(pin: MemberAbsencePin, manifest: Buffer | undefined): boolean {
  try {
    const parsed = manifest && parseManifest(manifest.toString('utf8'));
    return !!parsed && canonical(pin.directory) && statSync(pin.directory).isDirectory() && memberLedgerState(boundedDirectoryNames(pin.directory), Object.keys(parsed.keys), pin.keys).present.length === 0;
  } catch { return false; }
}

function checkCappedPins(proof: AnyCappedProof): void {
  const key = proof.schema === 2 ? proof.anchor : proof.key;
  const history = proof.schema === 2 ? new Set(proof.pins.flatMap(pin => pin.role === 'history' ? [pin.path] : [])) : undefined;
  for (const directory of returnDirectories(key, proof.spec.path, proof.plan.path, proof.returns)) {
    checkLatestReturns(directory, canonicalDirectoryNames(directory).names, key, proof.returns, history);
  }
  let members: MemberAbsencePin | undefined;
  let manifest: Buffer | undefined;
  for (const pin of proof.pins) {
    if (pin.role === 'decision-selection') {
      if (!canonical(pin.directory) || JSON.stringify(selectDecisionNames(boundedDirectoryNames(pin.directory), pin.decision)) !== JSON.stringify(pin.names)) {
        throw new Error(`capped evidence selection changed: ${pin.directory}`);
      }
    } else if (pin.role === 'member-absence') {
      members = pin;
    } else {
      const got = pinnedRead(pin.path);
      if (!canonical(pin.path) || !('bytes' in got) || got.sha256 !== pin.sha256
        || (pin.role === 'decision' && got.mtime_ms !== pin.mtime_ms)) throw new Error(`capped evidence changed or unreadable: ${pin.path}`);
      if (pin.role === 'manifest') manifest = got.bytes;
    }
  }
  if (members && !memberAbsent(members, manifest)) throw new Error(`capped evidence selection changed: ${members.directory}`);
}

function bindCappedProof(proof: CappedFoldProof, input: CappedInputs): void {
  if (proof.key !== input.keys[0] || proof.spec.path !== input.spec.path || proof.spec.sha256 !== input.spec.sha256
    || proof.plan.path !== input.plan?.path || proof.plan.sha256 !== input.plan.sha256
    || proof.carried.length !== input.residuals) throw new Error('capped proof input binding disagrees');
  for (const r of proof.returns) {
    const file = input.files.find(f => f.kind.toLowerCase() === r.kind);
    if (!file || file.path !== r.path || file.sha256 !== r.sha256 || file.residuals !== r.residuals
      || returnSha(file.text) !== r.return_sha) throw new Error(`capped proof ${r.kind} return binding disagrees`);
    const reviewed = reviewedSpecHashes(file.text);
    if (reviewed.length !== 1 || reviewed[0] !== input.spec.sha256) throw new Error(`capped ${r.kind} Reviewed binding disagrees`);
  }
}

function bindCappedLedgerProof(proof: CappedLedgerProof, input: CappedInputs): void {
  const keys = [...input.keys].sort();
  if (keys.length !== proof.keys.length || keys.some((k, i) => k !== proof.keys[i]) || proof.spec.path !== input.spec.path || proof.spec.sha256 !== input.spec.sha256
    || proof.plan.path !== input.plan?.path || proof.plan.sha256 !== input.plan.sha256) throw new Error('capped proof input binding disagrees');
  for (const r of proof.returns) {
    const file = input.files.find(f => f.kind.toLowerCase() === r.kind);
    if (!file || file.path !== r.path || file.sha256 !== r.sha256 || file.residuals !== r.residuals
      || returnSha(file.text) !== r.return_sha) throw new Error(`capped proof ${r.kind} return binding disagrees`);
    optionalReturnAgreement(file.text, { keys: proof.keys, specSha: input.spec.sha256 });
  }
  if (proof.carried.length !== input.residuals) throw new Error('capped proof input binding disagrees');
  const spec = pinnedRead(input.spec.path);
  if (!('bytes' in spec) || spec.sha256 !== input.spec.sha256) throw new Error('capped proof input binding disagrees');
  const declared = declaredTickets(spec.bytes.toString('utf8'));
  if (!declared || JSON.stringify([...declared].sort()) !== JSON.stringify(proof.keys)) throw new Error('capped proof declared tickets disagree');
  if (proof.anchor !== keyOf(proof.spec.path)) throw new Error('capped proof anchor disagrees');
}

const CAPPED_GUARD = 'capped carry requires one key, an explicit distinct plan and paired SPEC/PLAN returns';

function cappedReason(e: unknown): string {
  const detail = e as { stderr?: string | Buffer; message?: string };
  return String(detail.stderr || detail.message || e).trim().slice(0, 500);
}

function spawnCappedFold(input: CappedInputs, flag: '--key' | '--keys', value: string): { output: string } | { reason: string; refused: boolean } {
  const args = [cappedVerifier(), 'capped-fold', flag, value, '--spec', input.spec.path, '--plan', input.plan!.path,
    '--spec-return', input.files.find(f => f.kind === 'SPEC')!.path, '--plan-return', input.files.find(f => f.kind === 'PLAN')!.path];
  try {
    return { output: execFileSync('bun', args, { encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }) };
  } catch (e) {
    const detail = e as { status?: number | null; code?: string };
    return { reason: cappedReason(e), refused: typeof detail.status === 'number' && detail.status !== 0 && detail.code === undefined };
  }
}

function cappedFallback(check: () => void, input: CappedInputs, ledgerBound = false): AnyCappedProof | undefined {
  let refusal: unknown;
  try { check(); return undefined; } catch (e) { refusal = e; }
  const refuse = (reason: string) => new Error(`${refusal instanceof Error ? refusal.message : refusal}; capped verifier unavailable/refused: ${reason}`);
  if ((input.keys.length !== 1 && !ledgerBound) || !input.plan || input.plan.path === input.spec.path || input.files.length !== 2) throw refuse(CAPPED_GUARD);
  let first: string;
  if (input.keys.length === 1) {
    const ran = spawnCappedFold(input, '--key', input.keys[0]);
    if ('output' in ran) {
      try {
        const proof = validateCappedFoldProofShape(JSON.parse(ran.output));
        bindCappedProof(proof, input);
        checkCappedPins(proof);
        return proof;
      } catch (e) { throw refuse(cappedReason(e)); }
    }
    if (!ledgerBound || !ran.refused) throw refuse(ran.reason);
    first = ran.reason;
  } else first = `v1 route: ${CAPPED_GUARD}`;
  const ran = spawnCappedFold(input, '--keys', [...input.keys].sort().join(','));
  if (!('output' in ran)) throw refuse(`${first}; v2: ${ran.reason}`);
  try {
    const proof = validateCappedProofShape(JSON.parse(ran.output));
    if (proof.schema !== 2) throw new Error(`capped proof schema disagrees: a --keys call was answered with schema ${proof.schema}`);
    bindCappedLedgerProof(proof, input);
    checkCappedPins(proof);
    return proof;
  } catch (e) { throw refuse(`${first}; v2: ${cappedReason(e)}`); }
}

function appendSpec(ctx: Ctx, k: Buffer, row: Omit<OperatorRow, 'id' | 'ts'>): OperatorRow {
  if (!row.capped_carry) return appendOperator(ctx, k, row);
  checkCappedPins(row.capped_carry);
  const persisted = appendOperator(ctx, k, row);
  try {
    const chain = readChain<OperatorRow>(f(ctx, 'operator.jsonl'), k);
    const verified = chain.verified.find(r => r.id === persisted.id);
    if (chain.bad.length || !verified || contentSha(verified) !== contentSha(persisted)) throw new Error('signed row did not verify on readback');
    checkCappedPins(row.capped_carry);
    return verified;
  } catch (e) {
    throw new Error(`persisted-but-stale ${persisted.id}: ${e instanceof Error ? e.message : e}; inspect this record before retrying`);
  }
}

/** The operator's Telegram line for a spec-signer record or an operator signature; `notes` carries a mark's bypass and voids clauses. */
export interface SignerAlert {
  kind: 'record' | 'signature';
  scope: string;
  signer: 'chief' | 'operator';
  decision: string;
  words: string;
  notes: string[];
  chiefSigned: string[];
}

const alertFailed = (rc: number) => `the operator alert exited ${rc}${rc === 77 ? ' (the send was refused)' : ''}`;

function chiefRefusal(release: string, keys: string[], chiefKeys: string[], t: string, g: OperatorRow): string {
  const verb = 'release operator spec';
  const lift = (k: string) => `jira release operator spec-signer ${release} --signer chief --keys ${k} --decision <n> --words "<his words>"`;
  if (!g.keys?.length) {
    return `${verb}: the station default (${g.id}, decision ${g.decision}) is the operator's own signature; a chief signature is refused. `
      + `The operator signs it: jira release operator spec ${release} --keys ${keys.join(',')} ... --signer operator --decision <n> --words "<his words naming ${keys.join(', ')}>" [--supersedes <live spec row>]; `
      + `or he sets the default back: jira release operator spec-signer ${release} --signer chief --decision <n> --words "<his words>"`;
  }
  const marked = `${t} is marked for the operator's own signature (${g.id}, decision ${g.decision})`;
  if (keys.includes(t)) {
    return `${verb}: ${marked}; a chief signature is refused. The operator signs it: jira release operator spec ${release} --keys ${t} ... --signer operator --decision <n> --words "<his words naming ${t}>" [--supersedes <live spec row>]; or he lifts the mark: ${lift(t)}`;
  }
  return `${verb}: the spec names ${t} in its header, and ${marked}; a chief signature for ${chiefKeys.join(', ')} on this spec is refused. `
    + `The operator signs it with ${t} among the keys: jira release operator spec ${release} --keys ${[t, ...keys].join(',')} ... --signer operator --decision <n> --words "<his words naming ${t}>" [--supersedes <live spec row of ${t}>]; or he lifts the mark: ${lift(t)}`;
}

export function signSpec(ctx: Ctx, o: {
  keys: string[]; spec: string; verdicts: string[]; decision: string; verbatim?: string; supersedes?: string; plan?: string; sourceRoot?: string;
  signer?: 'chief' | 'operator'; words?: string; alert?: (a: SignerAlert) => number;
}): OperatorRow {
  operatorFence(ctx);
  const signer = o.signer ?? 'chief';
  if (signer === 'operator' && !o.alert) throw new Error('release operator spec: --signer operator needs the operator alert; no record written');
  if (signer === 'operator' && o.words === undefined) throw new Error('release operator spec: --signer operator needs --words, the operator\'s exact words');
  if (signer === 'chief' && o.verbatim === undefined) throw new Error('release operator spec: a chief signature needs --decision and --verbatim-file');
  if (!o.keys.length) throw new Error('release operator spec: --keys names the keys the spec covers');
  const spec = resolve(o.spec);
  if (!existsSync(spec)) throw new Error(`release operator spec: spec not found: ${spec}`);
  const plan = o.plan ? resolve(o.plan) : spec;
  if (!existsSync(plan)) throw new Error(`release operator spec: plan not found: ${plan}`);
  const { verdicts, residuals, files } = readVerdicts(o.verdicts, 'release operator spec', { required: ['SPEC', 'PLAN'], allowed: [] },
    'release operator spec: give exactly two --verdict files, the spec critic\'s and the plan critic\'s');
  const bytes = readFileSync(spec);
  const specSha = createHash('sha256').update(bytes).digest('hex');
  const planSha = o.plan ? fileSha(plan) : null;
  const capped = cappedFallback(() => checkResiduals(bytes.toString('utf8'), residuals, files), {
    keys: [...new Set(o.keys)], spec: { path: spec, sha256: specSha }, plan: o.plan ? { path: plan, sha256: planSha! } : undefined, files, residuals,
  }, true);
  const source = o.sourceRoot === undefined ? undefined : sourceIdentity(o.sourceRoot);
  const checkSource = () => {
    if (!source) return;
    const current = sourceIdentity(o.sourceRoot as string);
    if (current.identity !== source.identity || current.head !== source.head) {
      throw new Error('release operator spec: source-root identity or HEAD changed while it was checked; sign again');
    }
  };
  lintSpec(spec, plan, undefined, source?.root);
  checkSource();
  const checkInputs = () => {
    if (fileSha(spec) !== specSha || verdicts.some((v) => fileSha(v.path) !== v.sha256)
      || (o.plan && (!existsSync(plan) || fileSha(plan) !== planSha))) {
      throw new Error('release operator spec: the spec, plan or a verdict file changed while it was checked; sign again');
    }
  };
  checkInputs();
  return lockedAcross(ctx, (l) => {
    const records = readOperatorRecords('spec', ctx.env);
    if (o.supersedes) {
      const old = records.find((r) => r.id === o.supersedes);
      if (!old) throw new Error(`release operator spec: ${o.supersedes} is no verified spec record in a declared release`);
      const dropped = (old.keys ?? []).filter((k) => !o.keys.includes(k));
      if (dropped.length) throw new Error(`release operator spec: --keys must keep every key of ${o.supersedes}; missing ${dropped.join(', ')}`);
    }
    const superseded = new Set(records.flatMap((r) => r.supersedes ?? []));
    const held = records.find((r) => !superseded.has(r.id) && r.id !== o.supersedes && r.keys?.some((k) => o.keys.includes(k)));
    if (held) {
      const k = held.keys?.find((x) => o.keys.includes(x));
      throw new Error(`release operator spec: ${k} is already signed in ${held.id}; re-sign with --supersedes ${held.id}`);
    }
    const s = readSignerState(ctx.env, ctx.mirrorRoot);
    if (s.unreadable) throw new Error(`release operator spec: the signer records are unreadable (${s.unreadable}); repair the chain first; no record written`);
    const keys = [...new Set(o.keys)];
    const operatorKeys = signer === 'operator' ? keys.filter((k) => namesKey(o.words as string, k, { bare: true })) : [];
    const chiefKeys = keys.filter((k) => !operatorKeys.includes(k));
    const now = ctx.now().toISOString();
    const atOperator = new Map<string, OperatorRow>();
    for (const t of new Set([...keys, ...headerTickets(bytes.toString('utf8'))])) {
      const e = effectiveSigner(t, now, s);
      if ('unreadable' in e) throw new Error(`release operator spec: the signer records are unreadable for ${t} (${e.unreadable}); no record written`);
      if (e.signer === 'operator' && e.governing !== 'default') atOperator.set(t, e.governing);
    }
    const voided = chiefKeys.length ? [...atOperator.keys()].find((t) => !operatorKeys.includes(t)) : undefined;
    if (voided) throw new Error(chiefRefusal(ctx.release, keys, chiefKeys, voided, atOperator.get(voided) as OperatorRow));
    const words = signer === 'operator' ? decisionWords(ctx, o.decision, o.words as string) : null;
    for (const k of signer === 'operator' ? keys.filter((x) => atOperator.has(x)) : []) {
      if (!outranks(o.decision, 'signature', k, now, s)) {
        throw new Error(`release operator spec: decision ${o.decision} does not outrank the signer records of ${k}; the words that set its signer cannot sign under it`);
      }
    }
    checkInputs();
    checkSource();
    if (o.alert && signer === 'operator') {
      const rc = o.alert({ kind: 'signature', scope: operatorKeys.join(', '), signer, decision: o.decision, words: o.words as string, notes: [], chiefSigned: chiefKeys });
      if (rc !== 0) throw new Error(`release operator spec: ${alertFailed(rc)}; no record written`);
    }
    return appendSpec(ctx, l.k, {
      kind: 'spec', decision: o.decision, keys: [...new Set(o.keys)], spec_path: spec, spec_sha256: specSha,
      plan_path: o.plan ? plan : null, plan_sha256: planSha, verdicts,
      ...(source ? { source_root: source.root, source_head: source.head } : {}),
      supersedes: o.supersedes ?? null, residuals, ...(capped ? { capped_carry: capped } : {}), signer,
      ...(words ? { operator_keys: operatorKeys, verbatim: o.words, ...words } : { verbatim: o.verbatim }),
    });
  });
}

const sameKeys = (a: string[], b: string[]) => a.length === b.length && a.every((k) => b.includes(k));

/**
 * `release operator spec-signer`: the operator's words set who signs, for the station (no keys) or per key:
 * a key record with signer operator marks the key, one with signer chief lifts the mark.
 */
export function specSigner(ctx: Ctx, o: { signer: 'chief' | 'operator'; keys?: string[]; decision: string; words: string; alert: (a: SignerAlert) => number }):
  { row: OperatorRow; notes: string[]; warn: string | null } {
  const verb = 'release operator spec-signer';
  operatorFence(ctx);
  if (o.signer !== 'chief' && o.signer !== 'operator') throw new Error(`${verb}: --signer is chief or operator, not '${String(o.signer)}'`);
  const keys = [...new Set(o.keys ?? [])];
  const words = decisionWords(ctx, o.decision, o.words);
  const unnamed = keys.find((k) => !namesKey(o.words, k, { bare: true }));
  if (unnamed) throw new Error(`${verb}: the words do not name ${unnamed}; a key record needs the operator's words naming each key`);
  if (!keys.length && o.signer === 'chief' && !(/chief/i.test(o.words) && /sign/i.test(o.words))) {
    throw new Error(`${verb}: a station default of chief needs words holding both "chief" and "sign"; these words do not`);
  }
  return lockedAcross(ctx, (l) => {
    const s = readSignerState(ctx.env, ctx.mirrorRoot);
    if (s.unreadable) throw new Error(`${verb}: the signer records are unreadable (${s.unreadable}); repair the chain first; no alert sent, no record written`);
    const newest = s.records.filter((r) => sameKeys(r.keys ?? [], keys)).at(-1);
    if (newest && newest.signer === o.signer && newest.decision === o.decision && newest.verbatim === o.words) return { row: newest, notes: [], warn: null };
    const now = ctx.now().toISOString();
    if (o.signer === 'chief' && !keys.length && !outranks(o.decision, 'station', null, now, s)) {
      throw new Error(`${verb}: decision ${o.decision} does not outrank the station records; a station default of chief needs newer words`);
    }
    for (const k of o.signer === 'chief' ? keys : []) {
      if (!s.issues?.get(k) && s.records.some((r) => r.keys?.length)) throw new Error(`${verb}: ${k} is not in the Jira mirror, so its parent's records cannot be read; no record written`);
      if (!outranks(o.decision, 'lift', k, now, s)) throw new Error(`${verb}: decision ${o.decision} does not outrank the signer records of ${k}; a lift needs newer words`);
    }
    const notes = o.signer === 'operator' && keys.length ? markNotes(ctx, keys, s, now) : [];
    const rc = o.alert({ kind: 'record', scope: keys.length ? keys.join(', ') : 'the station default', signer: o.signer, decision: o.decision, words: o.words, notes, chiefSigned: [] });
    let warn: string | null = null;
    if (rc !== 0) {
      if (o.signer === 'chief') throw new Error(`${verb}: ${alertFailed(rc)}; no record written`);
      warn = `WARN ${verb}: ${alertFailed(rc)}; the ${keys.length ? 'mark' : 'record'} is written anyway`;
    }
    const row = appendOperator(ctx, l.k, { kind: 'spec-signer', decision: o.decision, ...(keys.length ? { keys } : {}), signer: o.signer, verbatim: o.words, ...words });
    return { row, notes, warn };
  });
}

function markNotes(ctx: Ctx, marked: string[], s: SignerState, now: string): string[] {
  const snaps = readMirrorFilesUnverified(ctx.mirrorRoot).issues;
  const snapshots = readOperatorRecords('core-snapshot', ctx.env);
  const notes: string[] = [];
  for (const k of marked) {
    const snap = snaps?.get(k);
    const by = snap ? pathIndependentBypass(k, snap, snapshots) : null;
    if (by) notes.push(`${k} bypassed (${by}): the mark does not bind while it is`);
  }
  const { live, newest } = liveOf(readOperatorRecords('spec', ctx.env));
  const withMark: SignerState = { ...s, issues: s.issues ?? snaps ?? null, records: [...s.records, { id: 'this mark', kind: 'spec-signer', ts: now, decision: null, keys: marked, signer: 'operator' }] };
  for (const m of marked) {
    const voids = live.filter((r) => staleReason(r) === null).flatMap((r) => {
      const hit = (coveredBy(r) ?? []).filter((t) => t === m || parentOf(snaps?.get(t)) === m);
      const v = hit.length ? voidingTicket(r, hit, r.ts, withMark, (t) => operatorSignedFor(r, t, newest)) : null;
      return v && 'ticket' in v ? [`${m} mark voids ${r.id} for ${(r.keys ?? []).filter((k) => signerOf(r, k) === 'chief').join(', ')}`] : [];
    });
    notes.push(...(voids.length ? voids : [`${m} mark voids no signature`]));
  }
  return notes;
}

const KEY_LINE = /^Keys?:\s*(.+)$/gm;

export function specReview(ctx: Ctx, o: { keys: string[]; spec: string; plan?: string; verdicts: string[]; supersedes?: string }): OperatorRow {
  const verb = 'release operator spec-review';
  operatorFence(ctx);
  const keys = [...new Set(o.keys)];
  if (!keys.length) throw new Error(`${verb}: --keys names the keys the spec covers`);
  if (!o.plan) throw new Error(`${verb}: --plan names the plan; a spec-review record always pins one`);
  const spec = resolve(o.spec);
  const plan = resolve(o.plan);
  if (plan === spec) throw new Error(`${verb}: --plan is the spec; give the plan file`);
  const specPin = pinRead(spec, 'spec', verb);
  const planPin = pinRead(plan, 'plan', verb);
  if (realpathSync(plan) === realpathSync(spec)) throw new Error(`${verb}: --plan is the spec; give the plan file`);
  const { verdicts, residuals, files } = readVerdicts(o.verdicts, verb, { required: ['SPEC'], allowed: ['PLAN'] },
    `${verb}: give exactly one SPEC verdict and at most one PLAN verdict`);
  const specVerdict = files.find((x) => x.kind === 'SPEC') as VerdictFile;
  const reviewed = reviewedSpecHashes(specVerdict.text);
  if (reviewed.length !== 1) throw new Error(`${verb}: ${specVerdict.path} needs exactly one 'Reviewed: spec <sha256>' line`);
  const reviewedSha = reviewed[0];
  for (const x of files) {
    const lines = [...x.text.matchAll(KEY_LINE)];
    const named = lines.length === 1 ? [...new Set(lines[0][1].match(KEY_IN) ?? [])] : [];
    if (!named.length) throw new Error(`${verb}: ${x.path} needs exactly one 'Key: <keys>' line naming its keys`);
    if (named.length !== keys.length || named.some((k) => !keys.includes(k))) {
      throw new Error(`${verb}: ${x.path} names ${named.join(', ')}, not --keys ${keys.join(', ')}`);
    }
  }
  const specText = specPin.bytes.toString('utf8');
  const lines = specText.split('\n');
  const headEnd = lines.findIndex((l) => /^## /.test(l));
  const header = (headEnd < 0 ? lines : lines.slice(0, headEnd)).filter((l) => /^(- Tickets?:|Keys?:)/.test(l));
  for (const k of keys) {
    if (!header.some((l) => namesKey(l, k, { bare: false }))) {
      throw new Error(`${verb}: the spec's header does not name ${k} (a '- Ticket:' or 'Key:' line before the first ## heading)`);
    }
  }
  const clean = specVerdict.last === 'SPEC CLEAN';
  if ((clean || specVerdict.residuals === 0) && reviewedSha !== specPin.sha256) {
    throw new Error(`${verb}: ${specVerdict.last} reviewed ${reviewedSha}, not the spec's bytes ${specPin.sha256}; run the spec critic on the final spec`);
  }
  const capped = cappedFallback(() => checkRoundResiduals(specText, files.map((x) => basename(x.path)), residuals, verb, files), {
    keys, spec: { path: spec, sha256: specPin.sha256 }, plan: { path: plan, sha256: planPin.sha256 }, files, residuals,
  });
  lintSpec(spec, plan, verb);
  const same = (p: string, sha256: string) => {
    const got = pinnedSha(p);
    return 'sha256' in got && got.sha256 === sha256;
  };
  if (!same(spec, specPin.sha256) || !same(plan, planPin.sha256) || verdicts.some((v) => !same(v.path, v.sha256))) {
    throw new Error(`${verb}: the spec, plan or a verdict file changed while it was checked; record again`);
  }
  return lockedAcross(ctx, (l) => {
    if (o.supersedes) {
      const rows = readOperatorRecords('spec-review', ctx.env);
      const superseded = new Set(rows.flatMap((r) => r.supersedes ?? []));
      if (!rows.some((r) => r.id === o.supersedes && !superseded.has(r.id))) {
        throw new Error(`${verb}: ${o.supersedes} is no live spec-review record in a declared release`);
      }
    }
    return appendSpec(ctx, l.k, {
      kind: 'spec-review', decision: null, keys, spec_path: spec, spec_sha256: specPin.sha256,
      plan_path: plan, plan_sha256: planPin.sha256, ...(clean ? {} : { reviewed_sha256: reviewedSha }), verdicts,
      supersedes: o.supersedes ?? null, residuals, ...(capped ? { capped_carry: capped } : {}),
    });
  });
}

export type SpecAnswer = { ok: true } | { missing: string };

function liveOf(rows: ReleaseRecord[]): { live: ReleaseRecord[]; newest: (k: string) => ReleaseRecord | undefined } {
  const superseded = new Set(rows.flatMap((r) => r.supersedes ?? []));
  const live = rows.map((r, i) => ({ r, i })).filter(({ r }) => !superseded.has(r.id))
    .sort((a, b) => a.r.ts.localeCompare(b.r.ts) || a.i - b.i).map(({ r }) => r);
  return { live, newest: (k: string) => live.filter((r) => r.keys?.includes(k)).at(-1) };
}

function coveredBy(r: OperatorRow): string[] | null {
  const pin = r.spec_path ? pinnedSha(r.spec_path) : null;
  if (!pin || !('bytes' in pin) || pin.sha256 !== r.spec_sha256) return null;
  return [...new Set([...(r.keys ?? []), ...headerTickets(pin.bytes.toString('utf8'))])];
}

function operatorSignedFor(r: OperatorRow, v: string, newest: ((k: string) => ReleaseRecord | undefined) | undefined): boolean {
  if (r.keys?.includes(v) || !newest) return false;
  const own = newest(v);
  return !!own && own.kind === 'spec' && staleReason(own) === null && signerOf(own, v) === 'operator' && own.spec_sha256 === r.spec_sha256;
}

function staleReason(r: ReleaseRecord): string | null {
  const pins = [
    { role: 'spec', path: r.spec_path ?? '', sha256: r.spec_sha256 },
    ...(typeof r.plan_sha256 === 'string' ? [{ role: 'plan', path: r.plan_path ?? '', sha256: r.plan_sha256 }] : []),
    ...(r.verdicts ?? []).map((v) => ({ role: 'verdict', path: v.path, sha256: v.sha256 })),
  ];
  for (const p of pins) {
    const got = pinnedSha(p.path);
    if ('missing' in got) return `${p.path} is missing (${r.id})`;
    if ('unreadable' in got) return `${p.path} is unreadable (${r.id})`;
    if (got.sha256 !== p.sha256) return `${p.role} ${p.path} changed since ${r.id}`;
  }
  if (Object.hasOwn(r, 'capped_carry')) {
    try {
      const proof = validateCappedProofShape(r.capped_carry);
      if ((proof.schema === 1 && r.keys?.length !== 1) || !r.keys?.length || !r.plan_path || r.plan_path === r.spec_path) throw new Error('capped proof record binding disagrees');
      const { files } = readVerdicts((r.verdicts ?? []).map(v => v.path), 'capped proof', { required: ['SPEC', 'PLAN'], allowed: [] }, 'capped proof needs paired returns');
      const input = { keys: r.keys, spec: { path: r.spec_path ?? '', sha256: r.spec_sha256 ?? '' },
        plan: { path: r.plan_path, sha256: r.plan_sha256 ?? '' }, files, residuals: r.residuals ?? -1 };
      if (proof.schema === 1) bindCappedProof(proof, input);
      else bindCappedLedgerProof(proof, input);
      checkCappedPins(proof);
    } catch (e) {
      return `capped proof stale since ${r.id}: ${e instanceof Error ? e.message : e}`;
    }
  }
  return null;
}

export const SPEC_CHECK_VERBS = ['SPEC ok', 'SPEC-STALE', 'NO-SPEC', 'SPEC-NEEDS-OPERATOR', 'SPEC-SIGNER-UNKNOWN'] as const;

export function headerTickets(specText: string): string[] {
  const lines = specText.split('\n');
  const named: string[] = [];
  let i = 0;
  if (lines[0]?.trim() === '---') {
    for (i = 1; i < lines.length && lines[i].trim() !== '---'; i++) {
      if (/^tickets\s*:/i.test(lines[i])) named.push(lines[i]);
    }
    i++;
  }
  for (; i < lines.length && !lines[i].startsWith('## '); i++) {
    if (/^\s*-\s*tickets?\s*:/i.test(lines[i]) || /^\s*(?:-\s*)?keys?\s*:/i.test(lines[i])) named.push(lines[i]);
  }
  const out: string[] = [];
  for (const line of named) {
    for (const k of line.match(KEY_IN) ?? []) if (namesKey(line, k, { bare: false }) && !out.includes(k)) out.push(k);
  }
  return out;
}

export function specCheck(env: Record<string, string | undefined>, keys: string[], mirrorRoot: string | null, opts: {
  kinds?: OperatorKind[]; issues?: Map<string, IssueSnap> | null; records?: ReleaseRecord[]; signer?: SignerState;
} = {}): { lines: string[]; ok: boolean; warnings: string[]; answer: Map<string, SpecAnswer> } {
  const kinds = opts.kinds ?? ['spec'];
  const records = (opts.records ?? readOperatorRecords(kinds, env)).filter((r) => kinds.includes(r.kind));
  const newestOf = kinds.map((kind) => liveOf(records.filter((r) => r.kind === kind)).newest);
  const issues = opts.issues !== undefined ? opts.issues : (mirrorRoot ? readMirror(mirrorRoot).issues : null);
  const warnings: string[] = [];
  const answer = new Map<string, SpecAnswer>();
  let signerState = opts.signer;
  const specNewest = newestOf[kinds.indexOf('spec')];
  const signerRefusal = (k: string, r: ReleaseRecord, parent: string | null): { line: string; missing: string } | null => {
    const signingKey = r.keys?.includes(k) || !parent ? k : parent;
    if (signerOf(r, signingKey) === 'operator') return null;
    const s = (signerState ??= readSignerState(env, mirrorRoot));
    if (!s.records.length && !s.unreadable) return null;
    const covered = coveredBy(r);
    const mine = effectiveSigner(k, r.ts, s);
    const voided = covered === null ? { unreadable: `${r.spec_path}: the spec bytes changed after the check` } : voidingTicket(r, covered, r.ts, s, (v) => operatorSignedFor(r, v, specNewest));
    const why = 'unreadable' in mine ? mine.unreadable : voided && 'unreadable' in voided ? voided.unreadable : null;
    if (why !== null) return { line: `SPEC-SIGNER-UNKNOWN ${k} ${r.id} ${why}`, missing: `signer records unreadable: ${why}` };
    const gov = (g: OperatorRow | 'default') => (typeof g === 'string' ? g : g.id);
    const needs = `SPEC-NEEDS-OPERATOR ${k} ${r.spec_path} ${r.id}`;
    if (!('unreadable' in mine) && mine.signer === 'operator') {
      return { line: `${needs} ${gov(mine.governing)}`, missing: `${k} needs the operator's own signature (${gov(mine.governing)}); the chief's signature ${r.id} does not count` };
    }
    if (voided && 'ticket' in voided) {
      const g = gov(voided.governing);
      return { line: `${needs} ${g}`, missing: `${k} needs the operator's own signature: ${voided.ticket} is marked (${g}) and ${r.id} covers it; the chief's signature ${r.id} does not count` };
    }
    return null;
  };
  const lines = keys.map((k) => {
    try {
      const parent = parentOf(issues?.get(k));
      const candidates = newestOf.map((newest) => newest(k) ?? (parent ? newest(parent) : undefined))
        .filter((r): r is ReleaseRecord => !!r?.spec_path);
      if (!candidates.length) {
        answer.set(k, { missing: `no spec-review record for ${k}` });
        return `NO-SPEC ${k}`;
      }
      for (const r of candidates) {
        if (r.plan_path && typeof r.plan_sha256 !== 'string') {
          warnings.push(`${k} plan unbound: the record ${r.id} signed plan ${r.plan_path} without its hash; re-sign with --supersedes ${r.id} to bind it`);
        }
      }
      const judged = candidates.map((r) => ({ r, why: staleReason(r) }));
      const fresh = judged.find((j) => j.why === null);
      if (fresh) {
        const refused = fresh.r.kind === 'spec' ? signerRefusal(k, fresh.r, parent) : null;
        if (refused) {
          answer.set(k, { missing: refused.missing });
          return refused.line;
        }
        answer.set(k, { ok: true });
        return `SPEC ok ${k} ${fresh.r.spec_path} ${fresh.r.id}`;
      }
      const last = judged.sort((a, b) => a.r.ts.localeCompare(b.r.ts)).at(-1) as { r: ReleaseRecord; why: string };
      answer.set(k, { missing: last.why });
      return `SPEC-STALE ${k} ${last.r.spec_path} ${last.r.id}`;
    } catch (e) {
      answer.set(k, { missing: `${k}: ${(e as Error).message}` });
      return `SPEC-STALE ${k}`;
    }
  });
  return { lines, ok: lines.every((l) => l.startsWith('SPEC ok ')), warnings, answer };
}

/**
 * `release signer-check`: per key, who must sign it now, and the marked ticket V that voids the chief for it,
 * through its newest live, fresh spec row or, with specText, a ticket the spec's header names.
 */
export function signerCheck(env: Record<string, string | undefined>, keys: string[], mirrorRoot: string | null, o: { specText?: string; now?: Date } = {}): string[] {
  const s = readSignerState(env, mirrorRoot);
  const now = (o.now ?? new Date()).toISOString();
  const { newest } = liveOf(readOperatorRecords('spec', env));
  const header = o.specText === undefined ? [] : headerTickets(o.specText);
  const gov = (g: OperatorRow | 'default') => (typeof g === 'string' ? g : g.id);
  return keys.map((k) => {
    const e = effectiveSigner(k, now, s);
    if ('unreadable' in e) return `UNKNOWN ${k} ${e.unreadable}`;
    if (e.signer === 'operator') return `SIGNER ${k} operator ${gov(e.governing)}`;
    const r = newest(k);
    if (r && staleReason(r) === null && signerOf(r, k) === 'chief') {
      const covered = coveredBy(r);
      const v = covered && voidingTicket(r, covered, r.ts, s, (t) => operatorSignedFor(r, t, newest));
      if (v && 'unreadable' in v) return `UNKNOWN ${k} ${v.unreadable}`;
      if (v) return `SIGNER ${k} operator ${gov(v.governing)} via ${v.ticket}`;
    }
    for (const t of header.filter((x) => x !== k)) {
      const h = effectiveSigner(t, now, s);
      if ('unreadable' in h) return `UNKNOWN ${k} ${h.unreadable}`;
      if (h.signer === 'operator') return `SIGNER ${k} operator ${gov(h.governing)} via ${t}`;
    }
    return `SIGNER ${k} chief ${gov(e.governing)}`;
  });
}
