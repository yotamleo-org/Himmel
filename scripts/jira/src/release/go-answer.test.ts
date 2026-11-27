import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyUpdate, type VerifiedLine } from './operator-words-spawn.js';
import { bucketGitleaks, goAnswer, type GoAnswerArgs, type GoAnswerDeps, type GoAnswerOut } from './go-answer.js';
import { declare, operatorDecision, request, type Ctx, type JiraPort } from './engine.js';
import { loadKey, readChain } from './ledger.js';
import type { OperatorRow, RequestRow } from './types.js';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..', '..', '..');
const ASK = readFileSync(join(here, 'fixtures', 'answer-ask.txt'), 'utf8').trimEnd();
const CODE = 'K7P2QX';
const KEY = 'HIMMEL-1234';
const OTHER = 'HIMMEL-1235';
const UPDATE = 900_000_200;
const WORDS = 'no time before the cut, it waits for 1.1.4';
const NOW = new Date('2026-11-26T12:00:00.000Z');
const nowS = NOW.getTime() / 1000;
const TTL = 21_600;

const temps: string[] = [];
const temp = (prefix: string): string => {
  const d = mkdtempSync(join(tmpdir(), prefix));
  temps.push(d);
  return d;
};
afterEach(() => {
  for (const d of temps.splice(0)) rmSync(d, { recursive: true, force: true });
});

function bridgeHome(lines: object[] = []): string {
  const home = temp('go-answer-home-');
  const bridge = join(home, '.claude', 'handover', 'bridge');
  const channel = join(home, '.claude', 'channels', 'telegram');
  mkdirSync(bridge, { recursive: true });
  mkdirSync(channel, { recursive: true });
  const fixtures = join(repo, 'scripts', 'telegram', 'fixtures', 'operator-words');
  copyFileSync(join(fixtures, 'access.json'), join(channel, 'access.json'));
  writeFileSync(join(bridge, 'inbound.jsonl'),
    readFileSync(join(fixtures, 'inbound.jsonl'), 'utf8') + lines.map((l) => `${JSON.stringify(l)}\n`).join(''));
  return home;
}

const realVerify = (line: object) => (id: number): VerifiedLine =>
  verifyUpdate(id, { env: { PATH: process.env.PATH, HOME: bridgeHome([line]) } });

type Over = Partial<Record<200, { env?: Record<string, string>; cmdline?: string[] }>>;

function tree(over: Over = {}) {
  const procRoot = temp('go-answer-proc-');
  for (const [pid, ppid, uid] of [[300, 200, 1000], [200, 100, 1000], [100, 1, 1000], [1, 0, 0]] as const) {
    mkdirSync(join(procRoot, String(pid), 'ns'), { recursive: true });
    writeFileSync(join(procRoot, String(pid), 'status'), `Name:\tp\nPPid:\t${ppid}\nUid:\t${uid}\t${uid}\t${uid}\t${uid}\nNSpid:\t${pid}\n`);
    const o = pid === 200 ? over[200] : undefined;
    if (pid !== 1) writeFileSync(join(procRoot, String(pid), 'environ'), Object.entries({ PATH: '/usr/bin', ...o?.env }).map(([k, v]) => `${k}=${v}\0`).join(''));
    writeFileSync(join(procRoot, String(pid), 'cmdline'), (o?.cmdline ?? ['bash']).map((a) => `${a}\0`).join(''));
  }
  symlinkSync('pid:[4026531836]', join(procRoot, '300', 'ns', 'pid'));
  symlinkSync('user:[4026531837]', join(procRoot, '300', 'ns', 'user'));
  symlinkSync('300', join(procRoot, 'self'));
  const hostNsPath = join(procRoot, 'host-ns-ref');
  writeFileSync(hostNsPath, 'pid:[4026531836] user:[4026531837]\n');
  return { procRoot, hostNsPath, execArgv: [] as string[], env: {} as Record<string, string> };
}

let root: string;
let env: Record<string, string>;
const mirrorRoot = () => join(root, 'mirror', 'HIMMEL');

function ctxAt(release: string): Ctx {
  const { procRoot, hostNsPath } = tree();
  return {
    release, dir: join(env.HIMMEL_RELEASE_STATE_DIR, release), keyPath: join(env.HIMMEL_RELEASE_KEY_DIR, `${release}.key`),
    env, now: () => NOW, jira: {} as JiraPort, mirrorRoot: mirrorRoot(), procRoot, hostNsPath,
  };
}

function mirror(issues: Record<string, string[]>): void {
  mkdirSync(mirrorRoot(), { recursive: true });
  writeFileSync(join(mirrorRoot(), '.cursor.json'), JSON.stringify({ lastSync: '2026-11-26T11:00:00.000Z', total: Object.keys(issues).length }));
  for (const [key, versions] of Object.entries(issues)) {
    writeFileSync(join(mirrorRoot(), `${key}.md`), `---\nkey: "${key}"\ntype: "Task"\nstatus: "To Do"\nfixVersions: ${JSON.stringify(versions)}\n---\n`);
  }
}

const versionsTsv = (released: string[] = []): void => writeFileSync(`${mirrorRoot()}.versions.tsv`,
  ['v1.1.3', 'v1.1.4'].map((v) => `${v}\t${released.includes(v)}\t\tfalse`).join('\n') + '\n');

const requestText = (over: Record<string, string> = {}): string =>
  Object.entries({ kind: 'move-out', key: KEY, from: 'v1.1.3', chief: 'HIMMEL-chief', ...over }).map(([k, v]) => `${k}=${v}\n`).join('');

function requestFile(text = requestText(), dir = 'bypass-queue', name = 'a.answer.pending'): { request: string; requestSha256: string } {
  const d = join(temp('go-answer-bucket-'), dir);
  mkdirSync(d, { recursive: true });
  const request = join(d, name);
  writeFileSync(request, text);
  return { request, requestSha256: createHash('sha256').update(text).digest('hex') };
}

const reply = (over: Partial<VerifiedLine> & Record<string, unknown> = {}): VerifiedLine & { forwarded: boolean; caption: boolean } => ({
  update_id: UPDATE, from: 111, chat_id: 111, ts: nowS - 60, message_id: 500, text: `go ${CODE} ${WORDS}`, reply_to_text: ASK,
  forwarded: false, caption: false, ...over,
});

let verifyCalls: number[];

const fakeVerify = (line: VerifiedLine) => (id: number): VerifiedLine => {
  verifyCalls.push(id);
  if (id === 0) throw new Error('the words verifier refused: update 0 is below the update-id floor');
  if (id !== line.update_id) throw new Error(`the words verifier refused: update ${id} is not in the poller's log`);
  return line;
};

const deps = (over: Partial<GoAnswerDeps> = {}): GoAnswerDeps => ({
  env, now: () => NOW, platform: 'linux', walk: tree(), ctxFor: (release) => ctxAt(release), mirrorRoot,
  verify: fakeVerify(reply()), gitleaks: () => 0, ...over,
});

const writeArgs = (req = requestFile(), over: Partial<GoAnswerArgs> = {}): GoAnswerArgs =>
  ({ ...req, update: UPDATE, code: CODE, asked: nowS - 120, ttl: TTL, ...over });
const checkArgs = (req = requestFile()): GoAnswerArgs => ({ ...req, check: true, code: CODE });
const lookupArgs = (req = requestFile()): GoAnswerArgs => ({ ...req, lookup: true, update: UPDATE });

const ledger = (): string => join(env.HIMMEL_RELEASE_STATE_DIR, 'v1.1.3', 'operator.jsonl');
const bytes = (): string => readFileSync(ledger(), 'utf8');
const rows = (): OperatorRow[] => readChain<OperatorRow>(ledger(), loadKey(ctxAt('v1.1.3').keyPath)).verified;
const decisions = (): OperatorRow[] => rows().filter((r) => r.kind === 'decision');

function refused(why: RegExp, args: GoAnswerArgs = writeArgs(), d: GoAnswerDeps = deps()): void {
  const before = bytes();
  expect(() => goAnswer(args, d)).toThrow(why);
  expect(bytes()).toBe(before);
}

const record = (out: GoAnswerOut) => {
  if (out.mode !== 'record') throw new Error(`expected a record, got ${out.mode}`);
  return out.record;
};

beforeEach(() => {
  root = temp('go-answer-');
  env = { HIMMEL_RELEASE_STATE_DIR: join(root, 'release'), HIMMEL_RELEASE_KEY_DIR: join(root, 'keys') };
  verifyCalls = [];
  declare(ctxAt('v1.1.3'), { project: 'HIMMEL', versions: ['v1.1.3', 'v1.1.4'], decision: '1', verbatim: 'R = v1.1.3 + v1.1.4', mode: 'observe' });
  mirror({ [KEY]: ['v1.1.3'], [OTHER]: ['v1.1.3'] });
  versionsTsv();
});

describe('V1: the real verifier through verifyUpdate', () => {
  it('carries text, ts, message_id and reply_to_text through', () => {
    const line = reply({ text: 'go K7P2QX because  of the cut', ts: 1762817400, message_id: 171, reply_to_text: 'the ask line' });
    const env = { PATH: process.env.PATH, HOME: bridgeHome([line]) };
    expect(verifyUpdate(UPDATE, { env })).toEqual({
      update_id: UPDATE, from: 111, chat_id: 111, ts: 1762817400, message_id: 171,
      text: 'go K7P2QX because  of the cut', reply_to_text: 'the ask line',
    });
    expect(() => verifyUpdate(0, { env })).toThrow(/update 0 is below the update-id floor/);
  });
});

describe('the verifier spawn', () => {
  const line = reply();
  const answer = (stdout: string, status: number | null = 0, stderr = '', error?: Error) => () => ({ status, stdout, stderr, error });

  it('spawns bun on the verifier by absolute path, with only PATH, HOME, LANG and TZ and a 15 s timeout', () => {
    const seen: unknown[] = [];
    verifyUpdate(UPDATE, {
      env: { PATH: '/p', HOME: '/h', LANG: 'C', TZ: 'UTC', BRIDGE_ROOT: '/forged', TELEGRAM_ACCESS_PATH: '/forged', NODE_OPTIONS: '--require x' },
      spawn: (cmd, args, o) => {
        seen.push(cmd, args, o);
        return answer(`${JSON.stringify(line)}\n`)();
      },
    });
    expect(seen).toEqual(['bun', [join(repo, 'scripts', 'telegram', 'operator-words.ts'), '--update', String(UPDATE)],
      { cwd: repo, env: { PATH: '/p', HOME: '/h', LANG: 'C', TZ: 'UTC' }, timeout: 15_000 }]);
  });

  it('refuses a failed spawn, quoting the verifier or the spawn error', () => {
    expect(() => verifyUpdate(UPDATE, { spawn: answer('', 1, 'update is forwarded\nmore\n') })).toThrow(/the words verifier refused: update is forwarded$/);
    expect(() => verifyUpdate(UPDATE, { spawn: answer('', null, '', new Error('spawnSync bun ETIMEDOUT')) })).toThrow(/ETIMEDOUT/);
  });

  it('refuses any output but one JSON line for this update', () => {
    const one = JSON.stringify(line);
    for (const stdout of ['', one, `${one}\n${one}\n`, 'not json\n', 'null\n', `${JSON.stringify({ ...line, update_id: UPDATE + 1 })}\n`, `${JSON.stringify({ ...line, ts: '1' })}\n`]) {
      expect(() => verifyUpdate(UPDATE, { spawn: answer(stdout) }), JSON.stringify(stdout)).toThrow(/exactly one JSON line/);
    }
  });
});

describe('the secret check child', () => {
  it('does not inherit BASH_ENV, so a startup hook cannot answer for the scan', () => {
    const dir = temp('go-answer-hook-');
    writeFileSync(join(dir, 'hook.sh'), 'exit 7\n');
    writeFileSync(join(dir, 'empty.txt'), '');
    expect(bucketGitleaks(join(dir, 'empty.txt'), { PATH: process.env.PATH, HOME: dir, BASH_ENV: join(dir, 'hook.sh') })).not.toBe(7);
  });
});

describe('go-answer: the record', () => {
  it('G0: a go-confirmed reply with no agent ancestor writes one decision row and returns its record', () => {
    const args = writeArgs();
    const out = record(goAnswer(args, deps()));
    expect(decisions()).toHaveLength(1);
    expect(decisions()[0]).toMatchObject({
      kind: 'decision', decision: `tg-${UPDATE}`, keys: [KEY], op: 'remove', from_v: 'v1.1.3', to_v: null, verbatim: WORDS,
      go: {
        answer: 'move-out', update: UPDATE, message_id: 500, ts: new Date((nowS - 60) * 1000).toISOString(),
        asked: new Date((nowS - 120) * 1000).toISOString(), code: CODE, request_sha256: args.requestSha256,
      },
    });
    expect(out).toEqual({ o: decisions()[0].id, key: KEY, from: 'v1.1.3', words: WORDS });
  });

  it('G0b: the code and go compare without case, and the words keep their inner bytes', () => {
    const words = 'a  b \\n $(touch /x) %s -n \\x41\nend';
    const out = record(goAnswer(writeArgs(), deps({ verify: fakeVerify(reply({ text: `  Go k7p2qx   ${words}  ` })) })));
    expect(out.words).toBe(words);
  });

  it('G1: an ancestor with CLAUDECODE=1, or CLAUDECODE=1 in the verb\'s own env, is refused', () => {
    refused(/agent session/, writeArgs(), deps({ walk: tree({ 200: { env: { CLAUDECODE: '1' } } }) }));
    refused(/agent session/, writeArgs(), deps({ env: { ...env, CLAUDECODE: '1' } }));
  });

  it('G1b: an ancestor whose argv[0] is claude, with no CLAUDECODE, is refused', () => {
    refused(/agent session.*runs claude/, writeArgs(), deps({ walk: tree({ 200: { cmdline: ['claude', '--bg'] } }) }));
  });

  it('G2: HIMMEL_BRIDGE_SESSION=1 on an ancestor is refused by the fence', () => {
    refused(/Telegram bridge session/, writeArgs(), deps({ walk: tree({ 200: { env: { HIMMEL_BRIDGE_SESSION: '1' } } }) }));
  });

  it('G3: a line from another id is refused by the real verifier', () => {
    refused(/is not the operator's DM/, writeArgs(), deps({ verify: realVerify(reply({ from: 222, chat_id: 222 })) }));
  });

  it('G4: a forwarded line, then a caption, are refused by the real verifier', () => {
    refused(/is forwarded/, writeArgs(), deps({ verify: realVerify(reply({ forwarded: true })) }));
    refused(/is a caption/, writeArgs(), deps({ verify: realVerify(reply({ caption: true })) }));
  });

  it('G5: a wrong code, a bare go, a no and words with a backtick are refused', () => {
    const said = (text: string) => deps({ verify: fakeVerify(reply({ text })) });
    refused(/the reply's code is not this ask's code/, writeArgs(), said('go AAAAAA because'));
    refused(/no words after the code/, writeArgs(), said(`go ${CODE}`));
    refused(/the reply is not a go/, writeArgs(), said(`no ${CODE}`));
    refused(/the reply is not a go/, writeArgs(), said(`no ${CODE} keep it`));
    refused(/backtick/, writeArgs(), said(`go ${CODE} because \`x\``));
  });

  it('G6: the same update twice is one row and the same record; G6b: another request on it is refused', () => {
    const req = requestFile();
    const first = record(goAnswer(writeArgs(req), deps()));
    expect(record(goAnswer(writeArgs(req), deps()))).toEqual(first);
    expect(decisions()).toHaveLength(1);
    const other = requestFile(requestText({ key: OTHER }));
    refused(new RegExp(`update ${UPDATE} was already used by ${first.o} for ${KEY} out of v1\\.1\\.3`), writeArgs(other));
    refused(/already used by/, lookupArgs(other));
  });

  it('G6c: an hour later, after the key left from in the mirror, the same record is returned', () => {
    const req = requestFile();
    const first = record(goAnswer(writeArgs(req), deps()));
    mirror({ [KEY]: [] });
    const later = new Date(NOW.getTime() + 3_600_000);
    expect(record(goAnswer(writeArgs(req), deps({ now: () => later })))).toEqual(first);
    expect(decisions()).toHaveLength(1);
  });

  it('G6d: a release whose operator chain does not verify refuses, since the update\'s single use cannot be read', () => {
    writeFileSync(ledger(), bytes().replace('R = v1.1.3', 'R = v9.9.9'));
    refused(/operator\.jsonl does not verify/);
  });

  it('G7: a reply outside the ask window or the verb\'s clock window is refused', () => {
    const at = (ts: number) => deps({ verify: fakeVerify(reply({ ts })) });
    refused(/outside the ask window/, writeArgs(), at(nowS - 151));
    refused(/outside the ask window/, writeArgs(requestFile(), { ttl: 30 }), at(nowS - 89));
    refused(/outside the 15 minute window/, writeArgs(requestFile(), { asked: nowS - 1000 }), at(nowS - 901));
    refused(/outside the 15 minute window/, writeArgs(requestFile(), { asked: nowS }), at(nowS + 61));
  });

  it('G7b: a reply 20 seconds before the ask epoch passes', () => {
    record(goAnswer(writeArgs(), deps({ verify: fakeVerify(reply({ ts: nowS - 140 })) })));
    expect(decisions()).toHaveLength(1);
  });

  it('G9: a secret check that does not exit 0 refuses, on a 0600 file outside the bucket that is removed', () => {
    for (const rc of [1, 2, null]) {
      const seen: Array<{ file: string; mode: number; text: string }> = [];
      const gitleaks = (file: string): number | null => {
        const text = readFileSync(file, 'utf8');
        seen.push({ file, mode: statSync(file).mode & 0o777, text });
        return text === '' ? 0 : rc;
      };
      refused(/the secret check refused the words/, writeArgs(), deps({ gitleaks }));
      expect(seen.at(-1)).toMatchObject({ mode: 0o600, text: WORDS });
      expect(seen.some((s) => existsSync(s.file))).toBe(false);
      expect(seen.at(-1)?.file.startsWith(env.HIMMEL_RELEASE_STATE_DIR)).toBe(false);
    }
  });

  it('G10: darwin is refused even with no marker anywhere', () => {
    refused(/Linux only/, writeArgs(), deps({ platform: 'darwin' }));
    refused(/Linux only/, checkArgs(), deps({ platform: 'darwin' }));
  });

  describe('G11: a pending INTAKE of the key into from', () => {
    const intake = () => request(ctxAt('v1.1.3'), { verb: 'INTAKE', key: KEY, from_v: null, to_v: 'v1.1.3', why: 'found work', evidence: {}, from: 'console' });
    const latest = (req: string) => readChain<RequestRow>(join(ctxAt('v1.1.3').dir, 'requests.jsonl'), loadKey(ctxAt('v1.1.3').keyPath)).verified.filter((r) => r.req === req).at(-1);

    it('is withdrawn by the verb, citing the new O-id', () => {
      const q = intake();
      const out = record(goAnswer(writeArgs(), deps()));
      expect(latest(q.req)?.state).toBe(`withdrawn:${out.o}`);
    });

    it('(control) is withdrawn the same way by the desk verb', () => {
      const q = intake();
      const row = operatorDecision(ctxAt('v1.1.3'), { decision: '2', keys: [KEY], op: 'remove', from_v: 'v1.1.3', to_v: null, verbatim: 'x' });
      expect(latest(q.req)?.state).toBe(`withdrawn:${row.id}`);
    });
  });

  it('G12: a reply that is not to this ask is refused', () => {
    for (const reply_to_text of [undefined, ASK.replace(KEY, OTHER), ASK.replace('from=v1.1.3', 'from=v1.1'), `${ASK} and more`]) {
      refused(/not a reply to this ask/, writeArgs(), deps({ verify: fakeVerify(reply({ reply_to_text })) }));
    }
  });

  it('G13: two processes behind a barrier, both past the outer lookup, write one row', async () => {
    const barrier = temp('go-answer-barrier-');
    const config = join(temp('go-answer-race-'), 'config.json');
    writeFileSync(config, JSON.stringify({
      args: writeArgs(), env, now: NOW.toISOString(), walk: tree(), mirrorRoot: mirrorRoot(), barrier, line: reply(),
    }));
    const child = () => new Promise<{ status: number | null; out: string; err: string }>((resolve, reject) => {
      const p = spawn('bun', [join(here, 'fixtures', 'go-answer-race.ts'), config], { stdio: ['ignore', 'pipe', 'pipe'] });
      let out = '';
      let err = '';
      p.stdout.on('data', (d) => { out += String(d); });
      p.stderr.on('data', (d) => { err += String(d); });
      p.on('error', reject);
      p.on('close', (status) => resolve({ status, out, err }));
    });
    const both = await Promise.all([child(), child()]);
    expect(both.map((r) => r.err)).toEqual(['', '']);
    expect(both.map((r) => r.status)).toEqual([0, 0]);
    expect(both[0].out).toBe(both[1].out);
    expect(decisions()).toHaveLength(1);
  });
});

describe('go-answer: --check', () => {
  it('G8 (control) and G15: prints the key, from and the exact ask line', () => {
    expect(goAnswer(checkArgs(), deps())).toEqual({ mode: 'check', key: KEY, from: 'v1.1.3', ask: ASK });
  });

  it('G14: writes nothing and never hands the verifier a real update', () => {
    const before = bytes();
    expect(goAnswer(checkArgs(), deps()).mode).toBe('check');
    expect(bytes()).toBe(before);
    expect(verifyCalls).toEqual([0]);
  });

  it('G8: a from that no declared release holds, or that is released, is refused', () => {
    refused(/exactly one declared release must hold v9/, checkArgs(requestFile(requestText({ from: 'v9' }))));
    versionsTsv(['v1.1.3']);
    refused(/v1\.1\.3 is released/, checkArgs());
  });

  it('G8: a key the mirror does not hold in from, or also holding another open declared version, is refused', () => {
    mirror({ [KEY]: ['v1.1.4'] });
    refused(/the mirror does not hold HIMMEL-1234 in v1\.1\.3/, checkArgs());
    mirror({ [KEY]: ['v1.1.3', 'v1.1.4'] });
    refused(/HIMMEL-1234 also holds the open declared version v1\.1\.4/, checkArgs());
    refused(/HIMMEL-1234 also holds the open declared version v1\.1\.4/, writeArgs());
  });

  it('G8: a request with another line, a bad value or a missing line is refused', () => {
    refused(/the request line 'words=x' is not accepted/, checkArgs(requestFile(`${requestText()}words=x\n`)));
    refused(/the request line '' is not accepted/, checkArgs(requestFile(`${requestText()}\n`)));
    refused(/the request line 'key=HIMMEL-1235' is not accepted/, checkArgs(requestFile(`${requestText()}key=HIMMEL-1235\n`)));
    refused(/the request line 'kind=close' is not accepted/, checkArgs(requestFile(requestText({ kind: 'close' }))));
    refused(/the request line 'key=HIMMEL-0' is not accepted/, checkArgs(requestFile(requestText({ key: 'HIMMEL-0' }))));
    refused(/the request line 'from=1\.1\.3' is not accepted/, checkArgs(requestFile(requestText({ from: '1.1.3' }))));
    refused(/the request has no chief= line/, checkArgs(requestFile(requestText().replace('chief=HIMMEL-chief\n', ''))));
  });

  it('G8: a request outside a bypass-queue dir, under another name, a link, or with another sha is refused', () => {
    refused(/bypass-queue/, checkArgs(requestFile(requestText(), 'elsewhere')));
    refused(/\.answer\.pending/, checkArgs(requestFile(requestText(), 'bypass-queue', 'a.answer')));
    const real = requestFile();
    const link = join(dirname(real.request), 'b.answer.pending');
    symlinkSync(real.request, link);
    refused(/not a regular file/, checkArgs({ ...real, request: link }));
    refused(/sha256/, checkArgs({ ...real, requestSha256: 'a'.repeat(64) }));
  });

  it('refuses a code outside the ask alphabet, and an environment that cannot finish the write', () => {
    for (const code of ['K7N2QX', 'K7P2Q', 'K7P2QX x', 'k7p2qx']) refused(/--code/, { ...checkArgs(), code });
    refused(/the secret check does not run/, checkArgs(), deps({ gitleaks: () => 2 }));
    refused(/did not refuse update 0/, checkArgs(), deps({ verify: () => reply({ update_id: 0 }) }));
    refused(/did not refuse update 0/, checkArgs(), deps({ verify: () => { throw new Error('bun: not found'); } }));
  });

  it('takes exactly one mode with its own arguments', () => {
    const req = requestFile();
    refused(/one mode/, { ...req, check: true, lookup: true, code: CODE });
    refused(/--check takes --code/, { ...req, check: true });
    refused(/--lookup takes --update/, { ...req, lookup: true });
    refused(/--update, --code, --asked and --ttl/, { ...req, update: UPDATE, code: CODE });
    refused(/--update, --code, --asked and --ttl/, writeArgs(req, { asked: Number.NaN }));
  });
});

describe('go-answer: --lookup', () => {
  it('G16: before any write it finds none and writes nothing; after the write it returns the record', () => {
    const req = requestFile();
    const before = bytes();
    expect(goAnswer(lookupArgs(req), deps())).toEqual({ mode: 'none' });
    expect(bytes()).toBe(before);
    expect(verifyCalls).toEqual([]);
    const first = record(goAnswer(writeArgs(req), deps()));
    expect(record(goAnswer(lookupArgs(req), deps()))).toEqual(first);
  });
});

describe('the desk verb', () => {
  it('G17 (pin): an extra go property on a desk decision writes a row with no go block', () => {
    const o = { decision: '3', keys: [KEY], op: 'remove', from_v: 'v1.1.3', to_v: null, verbatim: 'x', go: { answer: 'move-out', update: UPDATE } };
    const row = operatorDecision(ctxAt('v1.1.3'), o);
    expect(row).not.toHaveProperty('go');
    expect(rows().at(-1)).not.toHaveProperty('go');
  });
});
