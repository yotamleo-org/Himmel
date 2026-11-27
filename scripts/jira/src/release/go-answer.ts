import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { closeSync, constants, existsSync, fstatSync, mkdtempSync, openSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadOrThrow, lockedAcross, operatorFence, readMirror, type Ctx } from './engine-core.js';
import { AGENT_COMMANDS, AGENT_MARKERS, walk, type WalkOpts } from './fence-ancestry.js';
import { loadKey, readChain } from './ledger.js';
import { recordDecision, releaseForProject } from './operator-acts.js';
import { releaseKeyPath, releaseRoot } from './paths.js';
import { pinnedEnv, type VerifiedLine } from './operator-words-spawn.js';
import type { OperatorRow } from './types.js';

export interface GoAnswerArgs {
  request: string;
  requestSha256: string;
  check?: boolean;
  lookup?: boolean;
  update?: number;
  code?: string;
  asked?: number;
  ttl?: number;
}

export interface GoAnswerDeps {
  env: Record<string, string | undefined>;
  now: () => Date;
  platform: NodeJS.Platform;
  walk?: Pick<WalkOpts, 'procRoot' | 'hostNsPath' | 'execArgv' | 'env'>;
  ctxFor: (release: string, mirrorRoot: string) => Ctx;
  mirrorRoot: (project: string) => string;
  verify: (update: number) => VerifiedLine;
  gitleaks: (file: string) => number | null;
}

export interface GoRecord { o: string; key: string; from: string; words: string }

export type GoAnswerOut =
  | { mode: 'check'; key: string; from: string; ask: string }
  | { mode: 'record'; record: GoRecord }
  | { mode: 'none' };

interface Request { key: string; from: string; sha: string }

const CODE = /^[A-MO-Z2-9]{6}$/;

const LINES: Record<string, RegExp> = {
  kind: /^move-out$/,
  key: /^[A-Z][A-Z0-9]+-[1-9][0-9]*$/,
  from: /^v[0-9]+(\.[0-9]+)*$/,
  chief: /^.*$/,
};

const askLine = (code: string, key: string, from: string): string =>
  `go ${code} <why> → take key=${key} out of from=${from} to backlog · no ${code} → keep it`;

export function bucketGitleaks(file: string, env: Record<string, string | undefined>): number | null {
  const script = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'handover', 'chief-kit', 'bucket-gitleaks.sh');
  return spawnSync('bash', [script, file], { env: pinnedEnv(env), stdio: 'ignore', timeout: 60_000 }).status;
}

function gates(d: GoAnswerDeps): void {
  if (d.platform !== 'linux') throw new Error(`no ancestry read on ${d.platform}; the phone route is Linux only`);
  operatorFence({ env: d.env, procRoot: d.walk?.procRoot, hostNsPath: d.walk?.hostNsPath } as Ctx);
  if (d.env.CLAUDECODE === '1') throw new Error('refused in an agent session: CLAUDECODE=1');
  const w = walk({ ...d.walk, platform: d.platform, markers: AGENT_MARKERS, commands: AGENT_COMMANDS });
  if (w.stop !== 'allow') throw new Error(`refused by the agent session check: ${w.why}`);
}

const positive = (n: number | undefined): boolean => Number.isSafeInteger(n) && (n as number) > 0;

function checkArgs(a: GoAnswerArgs): void {
  const writeOnly = a.asked !== undefined || a.ttl !== undefined;
  if (a.check && a.lookup) throw new Error('takes one mode: --check, --lookup or the write');
  if (a.check && (a.code === undefined || a.update !== undefined || writeOnly)) throw new Error('--check takes --code and no other mode argument');
  if (a.lookup && (!positive(a.update) || a.code !== undefined || writeOnly)) throw new Error('--lookup takes --update and no other mode argument');
  if (!a.check && !a.lookup && !(positive(a.update) && a.code !== undefined && positive(a.asked) && positive(a.ttl))) {
    throw new Error('the write takes --update, --code, --asked and --ttl, each a positive number but the code');
  }
  if (a.code !== undefined && !CODE.test(a.code)) throw new Error('--code is six characters of A-Z and 2-9, with no N');
}

function readRegularFile(path: string): Buffer {
  let fd: number;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (e) {
    throw new Error(`--request is not a regular file that can be read: ${(e as Error).message}`);
  }
  try {
    if (!fstatSync(fd).isFile()) throw new Error('--request is not a regular file');
    return readFileSync(fd);
  } finally {
    closeSync(fd);
  }
}

function readRequest(a: GoAnswerArgs): Request {
  if (!a.request.endsWith('.answer.pending')) throw new Error('--request must name a .answer.pending file');
  if (basename(dirname(a.request)) !== 'bypass-queue') throw new Error('--request must sit in a bypass-queue directory');
  const bytes = readRegularFile(a.request);
  const sha = createHash('sha256').update(bytes).digest('hex');
  if (sha !== a.requestSha256) throw new Error('the request sha256 is not --request-sha256');
  const lines = bytes.toString('utf8').split('\n');
  if (lines.at(-1) === '') lines.pop();
  const got = new Map<string, string>();
  for (const line of lines) {
    const at = line.indexOf('=');
    const name = line.slice(0, at);
    const value = line.slice(at + 1);
    if (at < 0 || !Object.hasOwn(LINES, name) || got.has(name) || !LINES[name].test(value)) {
      throw new Error(`the request line '${line}' is not accepted`);
    }
    got.set(name, value);
  }
  const missing = Object.keys(LINES).find((name) => !got.has(name));
  if (missing) throw new Error(`the request has no ${missing}= line`);
  return { key: got.get('key') as string, from: got.get('from') as string, sha };
}

function usedBy(update: number, q: Request, env: GoAnswerDeps['env']): GoRecord | null {
  const root = releaseRoot(env);
  for (const release of existsSync(root) ? readdirSync(root).sort() : []) {
    if (!existsSync(join(root, release, 'release.json'))) continue;
    const chain = readChain<OperatorRow>(join(root, release, 'operator.jsonl'), loadKey(releaseKeyPath(release, env)));
    if (chain.bad.length) throw new Error(`release ${release}: operator.jsonl does not verify (${chain.bad[0]})`);
    const row = chain.verified.find((r) => r.go?.update === update);
    if (!row) continue;
    const key = (row.keys ?? []).join(',');
    if (key !== q.key || row.from_v !== q.from || row.go?.request_sha256 !== q.sha) {
      throw new Error(`update ${update} was already used by ${row.id} for ${key} out of ${row.from_v}`);
    }
    return { o: row.id, key, from: q.from, words: row.verbatim as string };
  }
  return null;
}

function releasedVersions(path: string): Set<string> {
  return new Set(readFileSync(path, 'utf8').split('\n').map((l) => l.split('\t')).filter((p) => p.length >= 2 && p[1].trim() === 'true').map((p) => p[0]));
}

function releaseFacts(q: Request, d: GoAnswerDeps): Ctx {
  const project = q.key.slice(0, q.key.lastIndexOf('-'));
  const decls = releaseForProject(d.env, project);
  if (decls === 'unreadable') throw new Error(`the declared releases of ${project} cannot be read`);
  const holders = decls.filter((x) => x.versions.includes(q.from));
  if (holders.length !== 1) throw new Error(`exactly one declared release must hold ${q.from}; ${holders.length} do`);
  const mirrorRoot = d.mirrorRoot(project);
  const released = releasedVersions(`${mirrorRoot}.versions.tsv`);
  if (released.has(q.from)) throw new Error(`${q.from} is released`);
  const snap = readMirror(mirrorRoot).issues?.get(q.key);
  if (!snap?.fixVersions.includes(q.from)) throw new Error(`the mirror does not hold ${q.key} in ${q.from}`);
  const other = snap.fixVersions.find((v) => v !== q.from && !released.has(v) && decls.some((x) => x.versions.includes(v)));
  if (other !== undefined) throw new Error(`${q.key} also holds the open declared version ${other}, so a record taking it out of ${q.from} could not be applied`);
  return d.ctxFor(holders[0].release, mirrorRoot);
}

function scan(text: string, d: GoAnswerDeps): number | null {
  const dir = mkdtempSync(join(tmpdir(), 'go-answer-scan-'));
  try {
    const file = join(dir, 'words.txt');
    writeFileSync(file, text, { mode: 0o600 });
    return d.gitleaks(file);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function checkEnvironment(ctx: Ctx, d: GoAnswerDeps): void {
  loadOrThrow(ctx);
  const rc = scan('', d);
  if (rc !== 0) throw new Error(`the secret check does not run (exit ${rc})`);
  let floor = 'it accepted update 0';
  try {
    d.verify(0);
  } catch (e) {
    floor = (e as Error).message;
  }
  if (!floor.includes('below the update-id floor')) throw new Error(`the words verifier did not refuse update 0 with its floor reason: ${floor}`);
}

function bind(line: VerifiedLine, a: GoAnswerArgs, q: Request, now: Date): string {
  const said = /^(\S+)(?:\s+(\S+))?(?:\s+([\s\S]*))?$/.exec(line.text.trim());
  if (said?.[1].toLowerCase() !== 'go') throw new Error('the reply is not a go');
  if (said[2]?.toUpperCase() !== a.code) throw new Error('the reply\'s code is not this ask\'s code');
  const words = (said[3] ?? '').trim();
  if (!words) throw new Error('the reply has no words after the code');
  if (words.includes('`')) throw new Error('the words hold a backtick');
  if (line.reply_to_text !== askLine(a.code as string, q.key, q.from)) throw new Error('the reply is not a reply to this ask');
  const asked = a.asked as number;
  if (!(line.ts >= asked - 30 && line.ts <= asked + (a.ttl as number))) throw new Error('the reply is outside the ask window');
  const clock = now.getTime() / 1000;
  if (!(line.ts >= clock - 15 * 60 && line.ts <= clock + 60)) throw new Error('the reply is outside the 15 minute window of this clock');
  return words;
}

export function goAnswer(a: GoAnswerArgs, d: GoAnswerDeps): GoAnswerOut {
  gates(d);
  checkArgs(a);
  const q = readRequest(a);
  if (!a.check) {
    const done = usedBy(a.update as number, q, d.env);
    if (done) return { mode: 'record', record: done };
    if (a.lookup) return { mode: 'none' };
  }
  const ctx = releaseFacts(q, d);
  checkEnvironment(ctx, d);
  if (a.check) return { mode: 'check', key: q.key, from: q.from, ask: askLine(a.code as string, q.key, q.from) };
  const update = a.update as number;
  const line = d.verify(update);
  const words = bind(line, a, q, d.now());
  const rc = scan(words, d);
  if (rc !== 0) throw new Error(`the secret check refused the words (exit ${rc})`);
  return lockedAcross(ctx, (l) => {
    const done = usedBy(update, q, d.env);
    if (done) return { mode: 'record', record: done };
    if (releaseFacts(q, d).release !== ctx.release) throw new Error(`the release holding ${q.from} changed during this run`);
    const row = recordDecision(ctx, l, { decision: `tg-${update}`, keys: [q.key], op: 'remove', from_v: q.from, to_v: null, verbatim: words }, {
      answer: 'move-out', update, message_id: line.message_id, ts: new Date(line.ts * 1000).toISOString(),
      asked: new Date((a.asked as number) * 1000).toISOString(), code: a.code as string, request_sha256: q.sha,
    });
    return { mode: 'record', record: { o: row.id, key: q.key, from: q.from, words } };
  });
}
