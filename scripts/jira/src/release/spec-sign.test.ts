import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { chmodSync, copyFileSync, cpSync, existsSync, mkdtempSync, mkdirSync, openSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, truncateSync, unlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { coreBypass, declare, fold, request, state, coreSnapshot, readOperatorRecords, pinnedSha, signSpec, specCheck, specReview, type Ctx, type JiraPort } from './engine.js';
import { execFileSync, spawnSync } from 'node:child_process';
import { Command } from 'commander';
import * as pinned from './pinned.js';
import { RESIDUAL_ROWS } from './test-residual-fixtures.js';
import { checkResiduals, checkRoundResiduals, headerTickets, lintSpec, SPEC_CHECK_VERBS, specSigner, type SignerAlert } from './spec-sign.js';
import { estimateLine, planOf } from './sign-lint.js';
import { readSignerState } from './engine-core.js';
import * as ledger from './ledger.js';
import type { IssueSnap, OperatorRow } from './types.js';
import { appendChain, loadKey, readChain } from './ledger.js';
import { withLock } from './ledger.js';

const afterMinerva = vi.hoisted(() => ({ fn: null as null | (() => void) }));

const sourceFixture = vi.hoisted(() => ({ primary: null as string | null }));

const signingLock = vi.hoisted(() => ({ fn: null as null | (() => void) }));

vi.mock('node:fs', async (orig) => {
  const m = await orig<typeof import('node:fs')>();
  return { ...m, openSync: ((...a: Parameters<typeof m.openSync>) => {
    const fd = m.openSync(...a);
    if (String(a[0]).endsWith('/release/R1/.lock')) {
      const fn = signingLock.fn;
      signingLock.fn = null;
      fn?.();
    }
    return fd;
  }) as typeof m.openSync };
});

const cappedCalls = vi.hoisted(() => [] as string[][]);

const cappedSpawn = vi.hoisted(() => ({ fn: null as null | ((args: string[], options: unknown) => string), options: [] as unknown[], attempts: [] as string[][] }));

vi.mock('node:child_process', async (orig) => {
  const m = await orig<typeof import('node:child_process')>();
  const execFileSync = ((...a: Parameters<typeof m.execFileSync>) => {
    const args = a[1] as string[] | undefined;
    if (sourceFixture.primary && a[0] === 'git' && args?.[0] === '-C'
      && args[1] === dirname(fileURLToPath(import.meta.url)) && args.at(-1) === '--git-common-dir') {
      return m.execFileSync('git', ['-C', sourceFixture.primary, ...args.slice(2)], a[2]);
    }
    if (args?.[1] === 'capped-fold') cappedSpawn.attempts.push([...args]);
    if (cappedSpawn.fn && args?.[1] === 'capped-fold' && args.includes('--keys')) { cappedSpawn.options.push(a[2]); cappedCalls.push([...args]); return cappedSpawn.fn([...args], a[2]) as never; }
    const r = m.execFileSync(...a);
    if ((a[1] as string[] | undefined)?.[1] === 'capped-fold') cappedCalls.push([...(a[1] as string[])]);
    if (String((a[1] as string[] | undefined)?.[0] ?? '').endsWith('minerva-trace-lint.sh')) afterMinerva.fn?.();
    return r;
  }) as typeof m.execFileSync;
  return { ...m, execFileSync };
});

class FakeJira implements JiraPort {
  fv = new Map<string, string[]>();
  live = new Map<string, IssueSnap>();
  async issue(key: string) { return this.live.get(key) ?? null; }
  comments = new Map<string, Array<{ id: string; body: string }>>();
  posted = 0;
  entries = new Map<string, string>();
  entryCalls = 0;
  entryFails = false;
  async newestFixVersionEntry(key: string) {
    this.entryCalls++;
    if (this.entryFails) throw new Error('entry read down');
    return { id: this.entries.get(key) ?? 'create', ts: '' };
  }
  writes = 0;
  lbl = new Map<string, string[]>();
  labelPuts: Array<{ key: string; labels: string[] }> = [];
  stuck = new Set<string>();
  async labels(key: string) { return [...(this.lbl.get(key) ?? [])]; }
  async removeLabels(key: string, labels: string[]) {
    this.labelPuts.push({ key, labels: [...labels] });
    this.lbl.set(key, (this.lbl.get(key) ?? []).filter((x) => !labels.includes(x) || this.stuck.has(x)));
  }
  async fixVersions(key: string) { return [...(this.fv.get(key) ?? [])]; }
  async setFixVersion(key: string, op: 'add' | 'remove', v: string) {
    this.writes++;
    const cur = this.fv.get(key) ?? [];
    this.fv.set(key, op === 'add' ? [...new Set([...cur, v])] : cur.filter((x) => x !== v));
  }
  async findComment(key: string, marker: string) {
    return this.comments.get(key)?.find((c) => c.body.includes(marker))?.id ?? null;
  }
  async addComment(key: string, body: string) {
    this.posted++;
    const id = String(1000 + this.posted);
    this.comments.set(key, [...(this.comments.get(key) ?? []), { id, body }]);
    return id;
  }
}

let root: string;

let jira: FakeJira;

const consoleEnv = {};

function ctx(env: Record<string, string> = consoleEnv): Ctx {
  return {
    release: 'R1', dir: join(root, 'release', 'R1'), keyPath: join(root, 'keys', 'R1.key'),
    env, now: () => new Date('2026-10-21T10:00:00.000Z'), jira, mirrorRoot: join(root, 'mirror'),
  };
}

function fakeProc(marker: Record<string, string> = {}): { procRoot: string; hostNsPath: string } {
  const procRoot = mkdtempSync(join(tmpdir(), 'engine-proc-'));
  for (const [pid, ppid, uid, env] of [[300, 200, 1000, {}], [200, 100, 1000, marker], [100, 1, 1000, {}], [1, 0, 0, null]] as const) {
    mkdirSync(join(procRoot, String(pid)));
    writeFileSync(join(procRoot, String(pid), 'status'), `Name:\tp\nPPid:\t${ppid}\nUid:\t${uid}\t${uid}\t${uid}\t${uid}\nNSpid:\t${pid}\n`);
    if (env) writeFileSync(join(procRoot, String(pid), 'environ'), Object.entries({ PATH: '/usr/bin', ...env }).map(([k, v]) => `${k}=${v}\0`).join(''));
  }
  mkdirSync(join(procRoot, '300', 'ns'));
  symlinkSync('pid:[4026531836]', join(procRoot, '300', 'ns', 'pid'));
  symlinkSync('user:[4026531837]', join(procRoot, '300', 'ns', 'user'));
  writeFileSync(join(procRoot, '300', 'cmdline'), 'node\0vitest\0');
  symlinkSync('300', join(procRoot, 'self'));
  const hostNsPath = join(procRoot, 'host-ns-ref');
  writeFileSync(hostNsPath, 'pid:[4026531836] user:[4026531837]\n');
  return { procRoot, hostNsPath };
}

const savedLedger = process.env.HIMMEL_ADMISSIONS_LEDGER;

const RUNS_AS_ROOT = process.getuid?.() === 0;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'release-engine-'));
  jira = new FakeJira();
  process.env.HIMMEL_ADMISSIONS_LEDGER = join(root, 'admissions-ledger.jsonl');
});

afterEach(() => {
  vi.unstubAllEnvs();
  if (savedLedger === undefined) delete process.env.HIMMEL_ADMISSIONS_LEDGER;
  else process.env.HIMMEL_ADMISSIONS_LEDGER = savedLedger;
});

describe('signed minerva specs', () => {
  const specEnv = () => ({ HIMMEL_RELEASE_STATE_DIR: join(root, 'release'), HIMMEL_RELEASE_KEY_DIR: join(root, 'keys') });
  const sctx = (env: Record<string, string> = specEnv()) => ctx(env);
  const r2 = (): Ctx => ({ ...sctx(), release: 'R2', dir: join(root, 'release', 'R2'), keyPath: join(root, 'keys', 'R2.key') });
  const declared = (c: Ctx = sctx()) => declare(c, { project: 'HIMMEL', versions: ['v1'], decision: '106', verbatim: 'R', mode: 'observe' });

  function spec(name = 'K-1-fixture-2026-10-31.md', dir = join(root, 'specs'), body: string[] = []): string {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'est.json'), JSON.stringify({ median_seq: 1, sigma: 0.1, dod: { passed: true } }));
    const p = join(dir, name);
    writeFileSync(p, [
      body[0] ?? '# K-1: a fixture design', '', 'Estimate record: est.json', '',
      '## Alternatives considered', '', '- none better.', '', '## Definition of done', '', '- the fixture signs.', '',
      '## Invariants', '', 'none', '', ...body.slice(1), '',
    ].join('\n'));
    return p;
  }
  function verdict(specPath: string, kind: 'spec' | 'plan', last: string): string {
    const p = `${specPath}.critic-${kind}-r1.md`;
    writeFileSync(p, `the critic's return\n\n${last}\n`);
    return p;
  }
  const sign = (c: Ctx, keys: string[], p: string, extra: Partial<Parameters<typeof signSpec>[1]> = {}) => signSpec(c, {
    keys, spec: p, decision: '387', verbatim: 'approve', ...extra,
    verdicts: extra.verdicts ?? [verdict(p, 'spec', 'SPEC CLEAN'), verdict(p, 'plan', 'PLAN CLEAN')],
  });
  const check = (keys: string[], mirrorRoot: string | null = null) => specCheck(specEnv(), keys, mirrorRoot).lines;

  async function cli(...args: string[]) {
    const { registerRelease } = await import('../commands/release.js');
    const p = new Command();
    p.exitOverride();
    registerRelease(p);
    await p.parseAsync(['node', 'jira', 'release', ...args]);
  }

  it('spec-check K-1 gives SPEC ok K-1 after a spec record over a fixture spec and two CLEAN verdicts', async () => {
    declared();
    for (const [k, v] of Object.entries(specEnv())) vi.stubEnv(k, v);
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
    vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
    const p = spec();
    writeFileSync(join(root, 'verbatim.txt'), 'approve 1-5\n');
    const out: string[] = [];
    const log = vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
    try {
      await cli('operator', 'spec', 'R1', '--keys', 'K-1', '--spec', p, '--verdict', verdict(p, 'spec', 'SPEC CLEAN'),
        '--verdict', verdict(p, 'plan', 'PLAN CLEAN'), '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'));
      await cli('spec-check', 'K-1');
    } finally {
      log.mockRestore();
    }
    expect(out.at(-1)).toBe(`SPEC ok K-1 ${p} O-R1-0002`);
  });

  it('a spec edited while the minerva checks run refuses to sign', () => {
    declared();
    const p = spec();
    afterMinerva.fn = () => writeFileSync(p, readFileSync(p, 'utf8').replace('fixture', 'fixturE'));
    try {
      expect(() => sign(sctx(), ['K-1'], p)).toThrow(/changed while it was checked/);
    } finally {
      afterMinerva.fn = null;
    }
    expect(check(['K-1'])).toEqual(['NO-SPEC K-1']);
  });

  it('a plan edited while the minerva checks run refuses to sign', () => {
    declared();
    const { spec: p, plan } = bucketSpec('docs/handover/running-a-chief.md');
    afterMinerva.fn = () => writeFileSync(plan, `${readFileSync(plan, 'utf8')}\n- Task 2: added mid-sign.\n`);
    try {
      expect(() => sign(sctx(), ['K-1'], p, { plan })).toThrow(/changed while it was checked/);
    } finally {
      afterMinerva.fn = null;
    }
    expect(check(['K-1'])).toEqual(['NO-SPEC K-1']);
  });

  it('a --supersedes re-sign that drops a key of the record it replaces is refused', () => {
    declared();
    const p = spec();
    const r = sign(sctx(), ['K-1', 'K-2'], p);
    expect(() => sign(sctx(), ['K-1'], p, { supersedes: r.id })).toThrow(/K-2/);
    expect(check(['K-1', 'K-2'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`, `SPEC ok K-2 ${p} ${r.id}`]);
  });

  it('one changed byte of the signed spec gives SPEC-STALE', () => {
    declared();
    const p = spec();
    const r = sign(sctx(), ['K-1'], p);
    writeFileSync(p, readFileSync(p, 'utf8').replace('fixture', 'fixturE'));
    expect(check(['K-1'])).toEqual([`SPEC-STALE K-1 ${p} ${r.id}`]);
    expect(specCheck(specEnv(), ['K-1'], null).ok).toBe(false);
  });

  it('a --supersedes re-sign clears SPEC-STALE with the new id', () => {
    declared();
    const p = spec();
    const old = sign(sctx(), ['K-1'], p);
    writeFileSync(p, `${readFileSync(p, 'utf8')}\n## Notes\n\nedited after review\n`);
    const fresh = sign(sctx(), ['K-1'], p, { supersedes: old.id });
    expect(fresh.supersedes).toBe(old.id);
    expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${fresh.id}`]);
    expect(() => sign(sctx(), ['K-1'], p, { supersedes: 'O-R1-0999' })).toThrow(/O-R1-0999 is no verified spec record/);
  });

  it('a re-sign of an already-signed key without --supersedes is refused, naming the record to supersede', () => {
    declared();
    const a = spec('K-1-a.md');
    const b = spec('K-1-b.md', join(root, 'specs-b'));
    const first = sign(sctx(), ['K-1'], a);
    expect(() => sign(sctx(), ['K-2', 'K-1'], b)).toThrow(/K-1 is already signed in O-R1-0002; re-sign with --supersedes O-R1-0002/);
    expect(check(['K-1', 'K-2'])).toEqual([`SPEC ok K-1 ${a} ${first.id}`, 'NO-SPEC K-2']);
    const later = sign({ ...sctx(), now: () => new Date('2026-10-22T10:00:00.000Z') }, ['K-1', 'K-2'], b, { supersedes: first.id });
    expect(check(['K-1', 'K-2'])).toEqual([`SPEC ok K-1 ${b} ${later.id}`, `SPEC ok K-2 ${b} ${later.id}`]);
  });

  it('signing a spec and writing the core snapshot wait on the release root lock, not only the release lock', () => {
    declared();
    const p = spec();
    const rootLock = join(root, 'release', '.lock');
    writeFileSync(rootLock, 'another writer');
    let t = Date.now();
    const clock = vi.spyOn(Date, 'now').mockImplementation(() => (t += 4000));
    try {
      expect(() => sign(sctx(), ['K-1'], p)).toThrow(/release\/\.lock is held/);
      expect(() => coreSnapshot(sctx(), { keys: ['K-1'] })).toThrow(/release\/\.lock is held/);
    } finally {
      clock.mockRestore();
      unlinkSync(rootLock);
    }
    expect(readOperatorRecords('spec', specEnv())).toEqual([]);
  });

  describe('latest-round verdicts beside the spec', () => {
    const put = (path: string, last: string): string => {
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, `the critic's return\n\n${last}\n`);
      return path;
    };
    const named = (p: string, kind: 'spec' | 'plan', n: number, dir = dirname(p)) => join(dir, `${basename(p)}.critic-${kind}-r${n}.md`);
    const pair = (p: string, n: number) => [put(named(p, 'spec', n), 'SPEC CLEAN'), put(named(p, 'plan', n), 'PLAN CLEAN')];
    const none = () => expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    const V = 'release operator spec:';

    it('S1-R1 an r1 spec verdict is refused while critic-spec-r2.md sits beside the spec, naming r2', () => {
      declared();
      const p = spec();
      const r1 = pair(p, 1);
      const r2 = put(named(p, 'spec', 2), 'SPEC FINDINGS 1');
      expect(() => sign(sctx(), ['K-1'], p, { verdicts: r1 })).toThrow(
        `${V} ${realpathSync(r1[0])} is round 1, but ${realpathSync(r2)} is round 2; sign with the latest round`);
      none();
    });

    it('S1-R2 a verdict file not beside the spec is refused', () => {
      declared();
      const p = spec();
      const dir = join(root, 'elsewhere');
      const copies = [put(named(p, 'spec', 1, dir), 'SPEC CLEAN'), put(named(p, 'plan', 1, dir), 'PLAN CLEAN')];
      expect(() => sign(sctx(), ['K-1'], p, { verdicts: copies })).toThrow(
        `${V} ${realpathSync(copies[0])} is not beside the spec as ${basename(p)}.critic-spec-r1.md`);
      none();
    });

    it('S1-R3 a verdict whose name kind differs from its verdict line is refused', () => {
      declared();
      const p = spec();
      const wrong = put(named(p, 'spec', 2), 'PLAN CLEAN');
      expect(() => sign(sctx(), ['K-1'], p, { verdicts: [verdict(p, 'spec', 'SPEC CLEAN'), wrong] })).toThrow(
        `${V} ${realpathSync(wrong)} is not beside the spec as ${basename(p)}.critic-plan-r2.md`);
      none();
    });

    it('S1-R4 (control) a plan verdict in the plans folder beside the specs root signs', () => {
      declared();
      const p = spec();
      const plan = put(named(p, 'plan', 1, join(root, 'specs', 'plans')), 'PLAN CLEAN');
      const r = sign(sctx(), ['K-1'], p, { verdicts: [put(named(p, 'spec', 1), 'SPEC CLEAN'), plan] });
      expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    });

    it('S1-R5 a later plan round in the plans folder refuses the r1 plan verdict, naming it', () => {
      declared();
      const p = spec();
      const r1 = pair(p, 1);
      const later = put(named(p, 'plan', 2, join(root, 'specs', 'plans')), 'PLAN CLEAN');
      expect(() => sign(sctx(), ['K-1'], p, { verdicts: r1 })).toThrow(
        `${V} ${realpathSync(r1[1])} is round 1, but ${realpathSync(later)} is round 2; sign with the latest round`);
      none();
    });

    it('S1-R5b a tie with a plans-folder file of the same round is refused, naming it', () => {
      declared();
      const p = spec();
      const r1 = pair(p, 1);
      const tie = put(named(p, 'plan', 1, join(root, 'specs', 'plans')), 'PLAN CLEAN');
      expect(() => sign(sctx(), ['K-1'], p, { verdicts: r1 })).toThrow(
        `${V} ${realpathSync(r1[1])} is round 1, but ${realpathSync(tie)} is round 1; sign with the latest round`);
      none();
    });

    it('S1-R6 (control) the highest-round spec and plan verdicts beside the spec sign', () => {
      declared();
      const p = spec();
      pair(p, 1);
      const r = sign(sctx(), ['K-1'], p, { verdicts: pair(p, 2) });
      expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    });

    it('S1-R7 (control) another spec of the same key with a higher round does not block', () => {
      declared();
      const p = spec();
      const r1 = pair(p, 1);
      put(join(dirname(p), 'K-1-other.md.critic-spec-r5.md'), 'SPEC CLEAN');
      const r = sign(sctx(), ['K-1'], p, { verdicts: r1 });
      expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    });

    it('S1-R8 a series-named symlink that points elsewhere is refused with the real path', () => {
      declared();
      const p = spec();
      const target = put(named(p, 'spec', 1, join(root, 'elsewhere')), 'SPEC CLEAN');
      const link = named(p, 'spec', 1);
      symlinkSync(target, link);
      expect(() => sign(sctx(), ['K-1'], p, { verdicts: [link, put(named(p, 'plan', 1), 'PLAN CLEAN')] })).toThrow(
        `${V} ${realpathSync(target)} is not beside the spec as ${basename(p)}.critic-spec-r1.md`);
      none();
    });

    it.skipIf(RUNS_AS_ROOT)('S1-R9 a plans folder that cannot be read refuses, naming the folder', () => {
      declared();
      const p = spec();
      const r1 = pair(p, 1);
      const plans = join(root, 'specs', 'plans');
      mkdirSync(plans);
      const dir = realpathSync(plans);
      chmodSync(plans, 0);
      try {
        expect(() => sign(sctx(), ['K-1'], p, { verdicts: r1 })).toThrow(
          `${V} ${dir}: cannot read the folder (EACCES: permission denied, scandir '${dir}')`);
      } finally { chmodSync(plans, 0o700); }
      none();
    });

    it('S1-R10 (control) a later round written after signing leaves the record SPEC ok', () => {
      declared();
      const p = spec();
      const r = sign(sctx(), ['K-1'], p, { verdicts: pair(p, 1) });
      put(named(p, 'spec', 2), 'SPEC FINDINGS 1');
      expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    });

    it('S1-R11 (control) spec-review takes a verdict that signing would refuse', () => {
      declared();
      const f = rspec();
      const loose = join(root, 'elsewhere', 'loose-return.md');
      mkdirSync(dirname(loose), { recursive: true });
      copyFileSync(critic(f.spec, 'SPEC CLEAN'), loose);
      put(`${f.spec}.critic-spec-r2.md`, 'SPEC FINDINGS 1');
      const r = review(sctx(), f, [loose]);
      expect(readOperatorRecords('spec-review', specEnv()).map(x => x.id)).toEqual([r.id]);
    });
  });

  function bucketSpec(cited: string): { spec: string; plan: string } {
    const p = spec('K-1-bucket-2026-11-02.md', join(root, 'bucket', 'designs'));
    writeFileSync(p, [
      '# K-1: a status feed', '', 'Estimate record: est.json', '',
      '## Alternatives considered', '', '- none better.', '', '## Definition of done', '', '- the fixture signs.', '',
      '## Fact ownership', '',
      '| Fact | Existing surfaces | Owner after | Non-owners |', '|---|---|---|---|',
      `| item status | \`${cited}\` (\`--held\`, \`ROW_REGISTRIES\`) | the feed | n/a |`, '',
      '## Invariants', '', '- I1 — one fact is one row.', '',
    ].join('\n'));
    const plan = join(root, 'bucket', 'plans', 'K-1-bucket-plan-2026-11-02.md');
    mkdirSync(join(root, 'bucket', 'plans'), { recursive: true });
    writeFileSync(plan, 'plan\n\n- Task 1: I1 — Test: `scripts/test-feed.sh` feeds a fact from two real sources.\n');
    return { spec: p, plan };
  }

  describe('explicit source-root normal signing', () => {
    let primary: string;
    let linked: string;
    const git = (cwd: string, ...args: string[]) => execFileSync('git', ['-C', cwd,
      '-c', 'user.name=test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false',
      '-c', 'core.hooksPath=/dev/null', ...args], { encoding: 'utf8' }).trim();
    beforeEach(() => {
      const common = git(dirname(fileURLToPath(import.meta.url)), 'rev-parse', '--path-format=absolute', '--git-common-dir');
      primary = join(root, 'primary');
      linked = join(root, 'linked');
      mkdirSync(primary);
      git(primary, 'init', '-q');
      git(primary, 'commit', '-q', '--allow-empty', '-m', 'fixture');
      const scripts = 'marketplace/plugins/himmel-ops/scripts';
      mkdirSync(join(primary, scripts), { recursive: true });
      for (const name of ['minerva-spec-gate.sh', 'minerva-trace-lint.sh']) {
        copyFileSync(join(dirname(common), scripts, name), join(primary, scripts, name));
      }
      git(primary, 'worktree', 'add', '-q', '--detach', linked);
      mkdirSync(join(linked, 'branch-only'));
      writeFileSync(join(linked, 'branch-only', 'source.ts'), 'export const source = true;\n');
      git(linked, 'add', '.');
      git(linked, 'commit', '-q', '-m', 'branch-only source');
      sourceFixture.primary = primary;
      declared();
      for (const [k, v] of Object.entries(specEnv())) vi.stubEnv(k, v);
      vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
      vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
      writeFileSync(join(root, 'verbatim.txt'), 'fixture approval');
    });
    afterEach(() => { sourceFixture.primary = null; afterMinerva.fn = null; signingLock.fn = null; });

    async function normalSign(sourceRoot?: string, citation = 'branch-only/source.ts') {
      const { spec: p, plan } = bucketSpec(citation);
      await cli('operator', 'spec', 'R1', '--keys', 'K-1', '--spec', p, '--plan', plan,
        '--verdict', verdict(p, 'spec', 'SPEC CLEAN'), '--verdict', verdict(p, 'plan', 'PLAN CLEAN'),
        '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'),
        ...(sourceRoot === undefined ? [] : ['--source-root', sourceRoot]));
      return readOperatorRecords('spec', specEnv())[0];
    }

    async function normalCappedSign(f: CappedFixture, sourceRoot: string) {
      await cli('operator', 'spec', 'R1', '--keys', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan,
        '--verdict', f.verdicts[0], '--verdict', f.verdicts[1], '--source-root', sourceRoot,
        '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'));
      return readOperatorRecords('spec', specEnv())[0];
    }

    it('combines capped carry and source provenance through normal signing and spec-check', async () => {
      const f = cappedFixture(undefined, false, 5, 'branch-only/source.ts');
      const frozen = fixtureHashes(f.specsRoot);
      const row = await normalCappedSign(f, linked);
      expect(row).toMatchObject({ source_root: realpathSync(linked), source_head: git(linked, 'rev-parse', 'HEAD'),
        residuals: 2, capped_carry: { mode: 'capped-carry', key: 'HIMMEL-10205', carried: [
          expect.objectContaining({ kind: 'spec', finding_id: 'F1' }),
          expect.objectContaining({ kind: 'plan', finding_id: 'F1' }),
        ] } });
      expect(fixtureHashes(f.specsRoot)).toEqual(frozen);
      const out = vi.spyOn(console, 'log').mockImplementation(() => {});
      try {
        await cli('spec-check', 'HIMMEL-10205');
        expect(out).toHaveBeenCalledWith(`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`);
      } finally { out.mockRestore(); }
      writeFileSync(f.ledgerPath, `${readFileSync(f.ledgerPath, 'utf8')}\n`);
      expect(specCheck(specEnv(), ['HIMMEL-10205'], null).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
    });

    it('refuses capped signing when the verified source root lacks the branch citation', async () => {
      const f = cappedFixture(undefined, false, 5, 'branch-only/source.ts');
      await expect(normalCappedSign(f, primary)).rejects.toThrow(/cites branch-only\/source.ts, which does not exist/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it('rechecks capped proof before append with a verified source root', async () => {
      const f = cappedFixture(undefined, false, 5, 'branch-only/source.ts');
      signingLock.fn = () => writeFileSync(f.ledgerPath, `${readFileSync(f.ledgerPath, 'utf8')}\n`);
      await expect(normalCappedSign(f, linked)).rejects.toThrow(/capped evidence changed/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it('signs branch-only citations in a live same-repo linked root with canonical root/head provenance', async () => {
      const alias = join(root, 'alias');
      symlinkSync(linked, alias);
      const scripts = join(linked, 'marketplace/plugins/himmel-ops/scripts');
      mkdirSync(scripts, { recursive: true });
      writeFileSync(join(scripts, 'minerva-spec-gate.sh'), 'exit 99\n');
      writeFileSync(join(scripts, 'minerva-trace-lint.sh'), 'exit 99\n');
      const row = await normalSign(alias);
      expect(row).toMatchObject({ source_root: realpathSync(linked), source_head: git(linked, 'rev-parse', 'HEAD') });
      expect(check(['K-1'])).toEqual([expect.stringMatching(/^SPEC ok K-1 /)]);
      git(linked, 'commit', '-q', '--allow-empty', '-m', 'later source');
      expect(check(['K-1'])).toEqual([expect.stringMatching(/^SPEC ok K-1 /)]);
    });

    it('keeps default primary citation behavior and old records without provenance', async () => {
      await expect(normalSign()).rejects.toThrow(/cites branch-only\/source.ts, which does not exist/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
      const row = await normalSign(undefined, 'marketplace/plugins/himmel-ops/scripts/minerva-trace-lint.sh');
      expect(row).not.toHaveProperty('source_root');
      expect(row).not.toHaveProperty('source_head');
      expect(check(['K-1'])).toEqual([expect.stringMatching(/^SPEC ok K-1 /)]);
    });

    it('accepts explicit primary and preserves the state repository as alternate citation root', async () => {
      const stateRepo = join(root, 'bucket');
      mkdirSync(stateRepo);
      git(stateRepo, 'init', '-q');
      mkdirSync(join(stateRepo, 'notes'));
      writeFileSync(join(stateRepo, 'notes', 'state.md'), 'state');
      const row = await normalSign(primary, 'notes/state.md');
      expect(row).toMatchObject({ source_root: realpathSync(primary), source_head: git(primary, 'rev-parse', 'HEAD') });
    });

    it.each(['missing', 'foreign', 'unregistered', 'subdir'])('refuses %s roots before appending any spec record', async (kind) => {
      let candidate = join(root, kind);
      if (kind === 'foreign') {
        mkdirSync(candidate);
        git(candidate, 'init', '-q');
        git(candidate, 'commit', '-q', '--allow-empty', '-m', 'foreign');
      } else if (kind === 'unregistered') {
        mkdirSync(candidate);
        copyFileSync(join(linked, '.git'), join(candidate, '.git'));
      } else if (kind === 'subdir') candidate = join(linked, 'branch-only');
      await expect(normalSign(candidate, 'marketplace/plugins/himmel-ops/scripts/minerva-trace-lint.sh')).rejects.toThrow(/source.root/i);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it.each(['HEAD', 'symlink', 'directory', 'registration'])('refuses a %s swap during validation before appending', async (kind) => {
      const alias = join(root, 'alias');
      symlinkSync(linked, alias);
      afterMinerva.fn = () => {
        if (kind === 'HEAD') git(linked, 'commit', '-q', '--allow-empty', '-m', 'changed');
        if (kind === 'symlink') { unlinkSync(alias); symlinkSync(primary, alias); }
        if (kind === 'directory') {
          renameSync(linked, `${linked}-old`);
          mkdirSync(linked);
          copyFileSync(join(`${linked}-old`, '.git'), join(linked, '.git'));
        }
        if (kind === 'registration') rmSync(git(linked, 'rev-parse', '--absolute-git-dir'), { recursive: true });
      };
      await expect(normalSign(alias)).rejects.toThrow(/source.root/i);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it.each(['spec', 'plan', 'verdict'])('keeps the %s hash-race refusal with an explicit root', async (kind) => {
      afterMinerva.fn = () => {
        const p = join(root, 'bucket/designs/K-1-bucket-2026-11-02.md');
        const target = kind === 'spec' ? p : kind === 'plan'
          ? join(root, 'bucket/plans/K-1-bucket-plan-2026-11-02.md') : `${p}.critic-spec-r1.md`;
        writeFileSync(target, `${readFileSync(target, 'utf8')}\nchanged\n`);
      };
      await expect(normalSign(linked)).rejects.toThrow(/changed while it was checked/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it.each(['source', 'document'])('rechecks %s after acquiring the append lock', async (kind) => {
      signingLock.fn = () => {
        if (kind === 'source') git(linked, 'commit', '-q', '--allow-empty', '-m', 'changed before append');
        else writeFileSync(join(root, 'bucket/designs/K-1-bucket-2026-11-02.md'), 'changed before append');
      };
      await expect(normalSign(linked)).rejects.toThrow(/changed while it was checked/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    it('keeps normal operator fencing with an explicit root', async () => {
      vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
      await expect(normalSign(linked)).rejects.toThrow(/chief-spawned worker/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    });

    async function normalGroupSign(f: V2Fixture, sourceRoot?: string) {
      await cli('operator', 'spec', 'R1', '--keys', f.keys!.join(','), '--spec', f.spec, '--plan', f.plan,
        '--verdict', f.verdicts[0], '--verdict', f.verdicts[1], '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'),
        ...(sourceRoot === undefined ? [] : ['--source-root', sourceRoot]));
      return readOperatorRecords('spec', specEnv())[0];
    }

    it('capped carry v2 group signing takes a citation only from the root it names: a candidate-only citation signs with --source-root and not by default, and the candidate scripts never run (E23)', async () => {
      spawnReset();
      const scripts = join(linked, 'marketplace/plugins/himmel-ops/scripts');
      mkdirSync(scripts, { recursive: true });
      writeFileSync(join(scripts, 'minerva-spec-gate.sh'), 'exit 99\n');
      writeFileSync(join(scripts, 'minerva-trace-lint.sh'), 'exit 99\n');
      const f = v2Build({ builder: 'group', citation: 'branch-only/source.ts' });
      const before = fixtureHashes(f.specsRoot);
      await expect(normalGroupSign(f)).rejects.toThrow(/cites branch-only\/source.ts, which does not exist/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
      const row = await normalGroupSign(f, linked);
      expect(row).toMatchObject({ source_root: realpathSync(linked), source_head: git(linked, 'rev-parse', 'HEAD'), capped_carry: { schema: 2, mode: 'capped-carry-ledger' } });
      expect(check(f.keys!)).toEqual(f.keys!.map(k => `SPEC ok ${k} ${f.spec} ${row.id}`));
      expect(fixtureHashes(f.specsRoot)).toEqual(before);
      expect(cappedSpawn.attempts.map(a => a[2])).toEqual(['--keys', '--keys']);
      spawnReset();
    });

    it('capped carry v2 group signing: a primary-only citation signs by default and is refused through --source-root (E23)', async () => {
      spawnReset();
      mkdirSync(join(primary, 'primary-only'));
      writeFileSync(join(primary, 'primary-only', 'source.ts'), 'export const only = true;\n');
      const f = v2Build({ builder: 'group', citation: 'primary-only/source.ts' });
      await expect(normalGroupSign(f, linked)).rejects.toThrow(/cites primary-only\/source.ts, which does not exist/);
      expect(readOperatorRecords('spec', specEnv())).toEqual([]);
      const row = await normalGroupSign(f);
      expect(row).not.toHaveProperty('source_root');
      expect(row.capped_carry).toMatchObject({ schema: 2, mode: 'capped-carry-ledger' });
      expect(check(f.keys!)).toEqual(f.keys!.map(k => `SPEC ok ${k} ${f.spec} ${row.id}`));
      spawnReset();
    });

    it('capped carry v2 docs: each chief doc holds exactly one signing-hash-check marker and the same fenced command after it; the command is silent on equal lint scripts and stops on a changed candidate copy (X1)', () => {
      const blocks = CHIEF_DOCS.map(rel => {
        const text = chiefDoc(rel);
        expect(occurrences(text, SIGNING_MARKER), `${rel}: exactly one marker`).toBe(1);
        const block = markedBlock(text);
        expect(block, `${rel}: a fenced block follows the marker`).not.toBeNull();
        return block as string;
      });
      expect(blocks[1], 'the two blocks are byte-equal').toBe(blocks[0]);
      const scripts = 'marketplace/plugins/himmel-ops/scripts'; const names = ['minerva-spec-gate.sh', 'minerva-trace-lint.sh'];
      mkdirSync(join(linked, scripts), { recursive: true });
      for (const name of names) copyFileSync(join(primary, scripts, name), join(linked, scripts, name));
      const run = (block: string, sentinel: string) => spawnSync('bash', ['-c', `${block}\n: > "$SENTINEL"`], {
        cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME, CAND: linked, SENTINEL: sentinel } });
      blocks.forEach((block, i) => {
        const equal = join(root, `sentinel-equal-${i}`); const changed = join(root, `sentinel-changed-${i}`);
        const ok = run(block, equal);
        expect([ok.status, ok.stdout, ok.stderr], 'equal copies: silent, exit 0').toEqual([0, '', '']);
        expect(existsSync(equal), 'equal copies: the sentinel step ran').toBe(true);
        writeFileSync(join(linked, scripts, names[1]), 'exit 99\n');
        const stop = run(block, changed);
        expect(stop.status, 'a changed candidate copy: non-zero exit').not.toBe(0);
        expect(stop.stderr, 'a changed candidate copy: STOP on stderr').toContain('STOP');
        expect(existsSync(changed), 'a changed candidate copy: the abort is proved, no sentinel').toBe(false);
        copyFileSync(join(primary, scripts, names[1]), join(linked, scripts, names[1]));
      });
    });

    it('capped carry v2 docs: both chief docs hold every finite token, each marker or sentence exactly once, and no other display-only or per-family filter text (X2)', () => {
      const tokens = ['--keys', '--source-root', 'tickets:', 'spec-review', 'jira release spec-check', 'jira roadmap get', 'next-dispatchable.sh', 'gen-briefs.py', 'brief-lint.sh',
        'roadmap.ts', 'tracker.py', 'board.ts', 'full pause', 'snapshot folder', 'manifest entry'];
      for (const rel of CHIEF_DOCS) {
        const text = chiefDoc(rel);
        for (const token of tokens) expect(occurrences(text, token), `${rel}: ${token}`).toBeGreaterThanOrEqual(1);
        expect(/--key\b/.test(text), `${rel}: the flag --key by itself`).toBe(true);
        for (const once of [SIGNING_MARKER, 'none is accepted as display-only', 'not a per-family filter']) expect(occurrences(text, once), `${rel}: ${once}`).toBe(1);
        expect(occurrences(text, 'display-only'), `${rel}: no other display-only`).toBe(1);
        expect(occurrences(text, 'per-family filter'), `${rel}: no other per-family filter`).toBe(1);
      }
    });

    it('capped carry v2 docs: a changed spec-gate copy on the candidate stops the marked command as well (X1, the spec-gate copy)', () => {
      const scripts = 'marketplace/plugins/himmel-ops/scripts'; const names = ['minerva-spec-gate.sh', 'minerva-trace-lint.sh'];
      mkdirSync(join(linked, scripts), { recursive: true });
      for (const name of names) copyFileSync(join(primary, scripts, name), join(linked, scripts, name));
      CHIEF_DOCS.forEach((rel, i) => {
        const block = markedBlock(chiefDoc(rel)) as string; const sentinel = join(root, `sentinel-spec-gate-${i}`);
        writeFileSync(join(linked, scripts, names[0]), 'exit 99\n');
        const stop = spawnSync('bash', ['-c', `${block}\n: > "$SENTINEL"`], { cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME, CAND: linked, SENTINEL: sentinel } });
        expect(stop.status, `${rel}: a changed spec-gate copy: non-zero exit`).not.toBe(0);
        expect(stop.stderr, `${rel}: a changed spec-gate copy: STOP on stderr`).toContain('STOP');
        expect(existsSync(sentinel), `${rel}: a changed spec-gate copy: no sentinel`).toBe(false);
        copyFileSync(join(primary, scripts, names[0]), join(linked, scripts, names[0]));
      });
    });

    it('capped carry v2 docs: the section of each chief doc exists once and the two sections are byte-equal (a driver-ruled row beyond the frozen matrix)', () => {
      const sections = CHIEF_DOCS.map(rel => {
        const text = chiefDoc(rel);
        expect(text.split('\n').filter(l => l === SECTION_HEADING), `${rel}: one section heading`).toHaveLength(1);
        return docSection(text) as string;
      });
      expect(sections[1], 'the two sections are byte-equal').toBe(sections[0]);
    });

    it('capped carry v2 docs: each chief doc section opens with the imperative not-yet sentence, in its first paragraph (a driver-ruled row beyond the frozen matrix)', () => {
      const notYet = '**Do not use this route for any real signing until the operator has approved live issuance (item 6); until then every command below is for fixtures only.**';
      for (const rel of CHIEF_DOCS) {
        const lines = (docSection(chiefDoc(rel)) as string).split('\n');
        const first = lines.slice(2, lines.findIndex((l, i) => i > 2 && l === '')).join(' ');
        expect(first.startsWith(notYet), `${rel}: the first paragraph of the section opens with the sentence`).toBe(true);
      }
    });
  });

  it('signs a bucket spec with invariants: the lint reads its paths from the checkout and its invariants from the plan', () => {
    declared();
    const { spec: p, plan } = bucketSpec('docs/handover/running-a-chief.md');
    const r = sign(sctx(), ['K-1'], p, { plan });
    expect(r.keys).toEqual(['K-1']);
    expect(readOperatorRecords('spec', specEnv())[0].plan_path).toBe(plan);
    expect(check(['K-1'])).toEqual([expect.stringMatching(/^SPEC ok K-1 /)]);
  });

  it('the signature binds the plan bytes: one changed byte of the signed plan gives SPEC-STALE', () => {
    declared();
    const { spec: p, plan } = bucketSpec('docs/handover/running-a-chief.md');
    const r = sign(sctx(), ['K-1'], p, { plan });
    expect(r.plan_sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    expect(specCheck(specEnv(), ['K-1'], null).warnings).toEqual([]);
    writeFileSync(plan, `${readFileSync(plan, 'utf8')}\n- Task 2: an unsigned addition.\n`);
    expect(check(['K-1'])).toEqual([`SPEC-STALE K-1 ${p} ${r.id}`]);
    expect(specCheck(specEnv(), ['K-1'], null).ok).toBe(false);
    unlinkSync(plan);
    expect(check(['K-1'])).toEqual([`SPEC-STALE K-1 ${p} ${r.id}`]);
  });

  it('a record signed before the plan hash existed still reads SPEC ok, with a plan-unbound warning', () => {
    declared();
    const { spec: p, plan } = bucketSpec('docs/handover/running-a-chief.md');
    const r = sign(sctx(), ['K-1'], p, { plan });
    const c = sctx();
    const k = loadKey(c.keyPath);
    const path = join(c.dir, 'operator.jsonl');
    const kept = readChain<OperatorRow>(path, k).verified.map(({ prev: _p, mac: _m, plan_sha256: _s, ...row }) => row);
    rmSync(path);
    for (const row of kept) appendChain(path, k, row);
    writeFileSync(plan, `${readFileSync(plan, 'utf8')}\n- Task 2: an addition after the old signature.\n`);
    const out = specCheck(specEnv(), ['K-1'], null);
    expect(out.lines).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    expect(out.ok).toBe(true);
    expect(out.warnings).toEqual([expect.stringMatching(/K-1.*plan unbound/)]);
  });

  it('spec-check prints the plan-unbound warning on stderr and still exits ok', async () => {
    declared();
    for (const [k, v] of Object.entries(specEnv())) vi.stubEnv(k, v);
    const { spec: p, plan } = bucketSpec('docs/handover/running-a-chief.md');
    const r = sign(sctx(), ['K-1'], p, { plan });
    const c = sctx();
    const k = loadKey(c.keyPath);
    const path = join(c.dir, 'operator.jsonl');
    const kept = readChain<OperatorRow>(path, k).verified.map(({ prev: _p, mac: _m, plan_sha256: _s, ...row }) => row);
    rmSync(path);
    for (const row of kept) appendChain(path, k, row);
    const out: string[] = [];
    const err: string[] = [];
    const log = vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
    const errSpy = vi.spyOn(console, 'error').mockImplementation((s: string) => { err.push(s); });
    const code = process.exitCode;
    try {
      await cli('spec-check', 'K-1');
    } finally {
      log.mockRestore();
      errSpy.mockRestore();
    }
    expect(out).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    expect(err).toEqual([expect.stringMatching(/^WARN K-1 plan unbound/)]);
    expect(process.exitCode).toBe(code);
  });

  it('a spec signed with no separate plan has no plan to bind and warns of nothing', () => {
    declared();
    const p = spec();
    const r = sign(sctx(), ['K-1'], p);
    expect(r.plan_sha256 ?? null).toBeNull();
    expect(specCheck(specEnv(), ['K-1'], null).warnings).toEqual([]);
  });

  it('a spec with invariants cannot be signed without its plan, nor with itself as the plan', () => {
    declared();
    const { spec: p } = bucketSpec('docs/handover/running-a-chief.md');
    expect(() => sign(sctx(), ['K-1'], p)).toThrow(/the plan is the spec/);
    expect(() => sign(sctx(), ['K-1'], p, { plan: p })).toThrow(/the plan is the spec/);
    expect(readOperatorRecords('spec', specEnv())).toEqual([]);
  });

  it('a bucket spec naming a truly missing path is still refused, and so is one whose plan names no test', () => {
    declared();
    const bad = bucketSpec('scripts/no-such-file.sh');
    expect(() => sign(sctx(), ['K-1'], bad.spec, { plan: bad.plan })).toThrow(/cites scripts\/no-such-file\.sh, which does not exist/);
    const ok = bucketSpec('docs/handover/running-a-chief.md');
    writeFileSync(ok.plan, 'plan\n\n- Task 1: I1 is covered somewhere.\n');
    expect(() => sign(sctx(), ['K-1'], ok.spec, { plan: ok.plan })).toThrow(/I1 has no plan line naming its acceptance test/);
    expect(readOperatorRecords('spec', specEnv())).toEqual([]);
  });

  it('a missing plan file is refused at signing', () => {
    declared();
    const { spec: p } = bucketSpec('docs/handover/running-a-chief.md');
    expect(() => sign(sctx(), ['K-1'], p, { plan: join(root, 'bucket', 'plans', 'absent.md') }))
      .toThrow(/release operator spec: plan not found: .*absent\.md/);
  });

  it('a missing spec file is refused at signing and reads SPEC-STALE once signed', () => {
    declared();
    expect(() => sign(sctx(), ['K-1'], join(root, 'specs', 'absent.md'), { verdicts: [] }))
      .toThrow(/release operator spec: spec not found: .*absent\.md/);
    const p = spec();
    const r = sign(sctx(), ['K-1'], p);
    unlinkSync(p);
    expect(check(['K-1'])).toEqual([`SPEC-STALE K-1 ${p} ${r.id}`]);
  });

  it('a missing verdict file is refused at signing and reads SPEC-STALE once signed', () => {
    declared();
    const p = spec();
    expect(() => sign(sctx(), ['K-1'], p, { verdicts: [verdict(p, 'spec', 'SPEC CLEAN'), `${p}.critic-plan-r9.md`] }))
      .toThrow(/release operator spec: verdict file not found: .*critic-plan-r9\.md/);
    const r = sign(sctx(), ['K-1'], p);
    unlinkSync(`${p}.critic-plan-r1.md`);
    expect(check(['K-1'])).toEqual([`SPEC-STALE K-1 ${p} ${r.id}`]);
  });

  it('an uncovered key gives NO-SPEC and a non-zero result', () => {
    declared();
    sign(sctx(), ['K-1'], spec());
    expect(check(['K-1', 'K-9'])).toEqual([expect.stringMatching(/^SPEC ok K-1 /), 'NO-SPEC K-9']);
    expect(specCheck(specEnv(), ['K-9'], null).ok).toBe(false);
  });

  it('a sub-task with no record of its own is covered by its parent\'s record, one hop', () => {
    declared();
    const p = spec();
    const r = sign(sctx(), ['K-1'], p);
    const m = join(root, 'mirror');
    mkdirSync(m, { recursive: true });
    writeFileSync(join(m, '.cursor.json'), JSON.stringify({ lastSync: '2026-10-21T09:00:00.000Z' }));
    writeFileSync(join(m, 'K-2.md'), ['---', 'key: "K-2"', 'type: "Subtask"', 'parent: "K-1"', '---', ''].join('\n'));
    writeFileSync(join(m, 'K-3.md'), ['---', 'key: "K-3"', 'type: "Subtask"', 'parent: "K-2"', '---', ''].join('\n'));
    writeFileSync(join(m, 'K-4.md'), ['---', 'key: "K-4"', 'type: "Task"', 'parent: "K-1"', '---', ''].join('\n'));
    expect(check(['K-2', 'K-3', 'K-4'], m)).toEqual([`SPEC ok K-2 ${p} ${r.id}`, 'NO-SPEC K-3', 'NO-SPEC K-4']);
    expect(check(['K-2'])).toEqual(['NO-SPEC K-2']);
  });

  it('a record in a second declared release is found', () => {
    declared();
    declared(r2());
    const p = spec();
    const r = sign(r2(), ['K-1'], p);
    expect(r.id).toMatch(/^O-R2-/);
    expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
    expect(readOperatorRecords('spec', specEnv()).map((o) => o.release)).toEqual(['R2']);
  });

  it('a tampered chain row gives NO-SPEC', () => {
    declared();
    sign(sctx(), ['K-1'], spec());
    const chain = join(root, 'release', 'R1', 'operator.jsonl');
    writeFileSync(chain, readFileSync(chain, 'utf8').replace('"keys":["K-1"]', '"keys":["K-1","K-2"]'));
    expect(check(['K-1', 'K-2'])).toEqual(['NO-SPEC K-1', 'NO-SPEC K-2']);
  });

  it('a worker context is refused by the fence', () => {
    declared();
    expect(() => sign(sctx({ ...specEnv(), HIMMEL_CONSOLE_LEG: '1' }), ['K-1'], spec())).toThrow(/chief-spawned worker/);
  });

  it('a spec failing minerva-spec-gate is refused and records nothing', () => {
    declared();
    const p = spec();
    writeFileSync(p, readFileSync(p, 'utf8').replace('Estimate record: est.json', ''));
    expect(() => sign(sctx(), ['K-1'], p)).toThrow(/minerva-spec-gate.*estimate record/s);
    expect(readOperatorRecords('spec', specEnv())).toEqual([]);
  });

  it('a SPEC FINDINGS 2 verdict signs only with a critic-rounds section dispositioning both residuals', () => {
    declared();
    const p = spec();
    const findings = () => [verdict(p, 'spec', 'SPEC FINDINGS 2'), verdict(p, 'plan', 'PLAN CLEAN')];
    expect(() => sign(sctx(), ['K-1'], p, { verdicts: findings() })).toThrow(/2 residual findings.*Critic rounds/s);
    writeFileSync(p, `${readFileSync(p, 'utf8')}\n## Critic rounds\n\n- R1: fixed in §1\n`);
    expect(() => sign(sctx(), ['K-1'], p, { verdicts: findings() })).toThrow(/2 residual findings.*1 dispositioned/s);
    writeFileSync(p, `${readFileSync(p, 'utf8')}- R2: deferred → HIMMEL-9000\n`);
    expect(sign(sctx(), ['K-1'], p, { verdicts: findings() }).residuals).toBe(2);
    expect(() => sign(sctx(), ['K-1'], p, { verdicts: [verdict(p, 'spec', 'looks fine'), verdict(p, 'plan', 'PLAN CLEAN')] }))
      .toThrow(/last line/);
  });

  it('a ceiling disposition signs a residual, the retired word still reads as its alias, and an unknown word is refused', () => {
    declared();
    const p = spec();
    const findings = () => [verdict(p, 'spec', 'SPEC FINDINGS 2'), verdict(p, 'plan', 'PLAN CLEAN')];
    writeFileSync(p, `${readFileSync(p, 'utf8')}\n## Critic rounds\n\n- R1: ceiling\n- R2: accepted\n`);
    expect(() => sign(sctx(), ['K-1'], p, { verdicts: findings() }))
      .toThrow(/2 residual findings.*1 dispositioned.*fixed\|ASSUMPTION\|ceiling\|deferred/s);
    writeFileSync(p, readFileSync(p, 'utf8').replace('- R2: accepted', '- R2: ponytail'));
    expect(sign(sctx(), ['K-1'], p, { verdicts: findings() }).residuals).toBe(2);
  });

  it('run from a non-himmel cwd, the verb finds the minerva scripts in the primary checkout and lints the spec in its own repository', () => {
    declared();
    const repo = join(root, 'state-repo');
    mkdirSync(join(repo, 'notes'), { recursive: true });
    execFileSync('git', ['init', '-q', repo]);
    writeFileSync(join(repo, 'notes', 'only-here.md'), 'x\n');
    const p = spec('K-1-check.md', join(repo, 'specs'), ['# K-1: a status check design',
      '## Fact ownership', '', '| fact | existing surfaces | owner |', '|---|---|---|', '| a | `notes/only-here.md` | `notes/only-here.md` |']);
    const away = mkdtempSync(join(tmpdir(), 'not-himmel-'));
    const was = process.cwd();
    process.chdir(away);
    try {
      expect(sign(sctx(), ['K-1'], p).spec_path).toBe(p);
    } finally {
      process.chdir(was);
    }
  });

  const sha = (p: string) => createHash('sha256').update(readFileSync(p)).digest('hex');
  const both = { kinds: ['spec', 'spec-review'] as OperatorRow['kind'][] };

  function rspec(dir = join(root, 'rs'), head = '- Ticket: K-2', title = '# K-2: a reviewed design'): { spec: string; plan: string } {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'est.json'), JSON.stringify({ median_seq: 1, sigma: 0.1, dod: { passed: true } }));
    const p = join(dir, 'K-2-review.md');
    writeFileSync(p, [
      title, '', head, '', 'Estimate record: est.json', '',
      '## Alternatives considered', '', '- none better.', '', '## Definition of done', '', '- the fixture records.', '',
      '## Invariants', '', 'none', '',
    ].join('\n'));
    const plan = join(dir, 'K-2-review-plan.md');
    writeFileSync(plan, 'plan\n\n- Task 1: build it.\n');
    return { spec: p, plan };
  }
  function critic(specPath: string, last: string, o: { kind?: 'spec' | 'plan'; round?: number; key?: string | null; reviewed?: string[]; body?: string[] } = {}): string {
    const kind = o.kind ?? 'spec';
    const p = `${specPath}.critic-${kind}-r${o.round ?? 1}.md`;
    const reviewed = o.reviewed ?? (kind === 'spec' ? [`Reviewed: spec ${sha(specPath)}`] : []);
    writeFileSync(p, [...(o.key === null ? [] : [`Key: ${o.key ?? 'K-2'}`]), ...reviewed, '', 'the critic\'s return', ...(o.body ?? []), '', last, ''].join('\n'));
    return p;
  }
  const review = (c: Ctx, f: { spec: string; plan?: string }, verdicts: string[], extra: Partial<Parameters<typeof specReview>[1]> = {}) => specReview(c, {
    keys: ['K-2'], spec: f.spec, plan: f.plan, verdicts, ...extra,
  });
  const candidateRoot = fileURLToPath(new URL('../../../../', import.meta.url));
  const expectedVerifier = join(candidateRoot, 'scripts/telegram/chief-route.ts');
  const bunLookup = spawnSync('which', ['bun'], { encoding: 'utf8' });
  const realBun = bunLookup.status === 0 ? bunLookup.stdout.trim() : '';
  type CappedFixture = { spec: string; plan: string; verdicts: string[]; ledgerPath: string; specsRoot: string };
  function cappedFixture(cleanKind?: 'spec' | 'plan', invalidLint = false, rounds = 5, citation?: string, criticLine?: string): CappedFixture {
    if (!realBun) throw new Error('capped fixture requires Bun on PATH; install the pinned .bun-version');
    const scratchRoot = mkdtempSync(join(root, 'capped-'));
    const specText = '---\ntickets: HIMMEL-10205\n---\n# HIMMEL-10205 fixture\n\nKey: HIMMEL-10205\n\nEstimate record: estimate.json\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n'
      + (citation ? `\n## Fact ownership\n\n| Fact | Existing surfaces | Owner after | Non-owners |\n|---|---|---|---|\n| source | \`${citation}\` | source | n/a |\n` : '')
      + (criticLine ? `\n## Critic rounds\n\n${criticLine}\n` : '');
    const request = { scratchRoot, key: 'HIMMEL-10205', specText: invalidLint ? specText.replace('Estimate record: estimate.json', '') : specText,
      planText: '---\ntickets: HIMMEL-10205\n---\n# HIMMEL-10205 plan\n\n- Ticket: HIMMEL-10205\n\n- Task 1: build the fixture.\n',
      returns: [1, 2, 3, 4, 5].slice(0, rounds).flatMap(round => (['spec', 'plan'] as const).map(kind => ({ kind, round,
        text: kind === cleanKind ? `${kind.toUpperCase()} CLEAN\n` : `- **F1** (${kind === 'spec' ? 'minor' : 'medium'}) residual\n${kind.toUpperCase()} FINDINGS 1\n`,
        reads: ['spec', 'plan', { path: 'specs/designs/estimate.json', text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' },
          { path: 'specs/designs/page.html', text: '<p>fixture</p>\n' }],
      }))),
    };
    const f = JSON.parse(execFileSync(realBun, [join(candidateRoot, 'scripts/telegram/testlib-capped-fold.ts')], {
      input: JSON.stringify(request), encoding: 'utf8', timeout: 15000,
    })) as CappedFixture;
    f.verdicts = f.verdicts.slice(-2);
    return f;
  }
  const cappedSign = (api: 'spec' | 'spec-review', f: CappedFixture, extra: Record<string, unknown> = {}) => {
    const o = { keys: ['HIMMEL-10205'], spec: f.spec, plan: f.plan, verdicts: f.verdicts, ...extra };
    return api === 'spec' ? signSpec(sctx(), { ...o, decision: '387', verbatim: 'approve' }) : specReview(sctx(), o);
  };
  const fixtureHashes = (dir: string): Record<string, string> => Object.fromEntries(readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    const p = join(dir, e.name);
    return e.isDirectory() ? Object.entries(fixtureHashes(p)) : [[p, sha(p)]];
  }));

  const cappedCheck = (api: 'spec' | 'spec-review', keys = ['HIMMEL-10205'], issues?: Map<string, IssueSnap>) =>
    specCheck(specEnv(), keys, null, { kinds: [api], ...(issues ? { issues } : {}) });

  function externalCappedFixture(location: string): CappedFixture {
    if (!['spec-return', 'plan-return', 'plan-document'].includes(location)) return cappedFixture();
    const f = cappedFixture(undefined, false, 4);
    const runner = join(dirname(f.specsRoot), 'external-fixture.ts');
    writeFileSync(runner, `
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { ledgerVerify, sealRound } from ${JSON.stringify(expectedVerifier)};
const f = ${JSON.stringify(f)}, location = ${JSON.stringify(location)};
const external = join(dirname(f.specsRoot), 'external'); mkdirSync(external);
const oldPlan = f.plan;
if (location === 'plan-document') { f.plan = join(external, basename(f.plan)); copyFileSync(oldPlan, f.plan); }
for (const [i, kind] of ['spec', 'plan'].entries()) {
  const previous = f.verdicts[i];
  const next = join(location === kind+'-return' ? external : dirname(previous), basename(previous).replace('r4.md', 'r5.md'));
  const text = readFileSync(previous, 'utf8').replace('Fixture: '+kind+' round 4', 'Fixture: '+kind+' round 5')
    .replace(/^((?:READ(?:-SHA256)?|CONTENT-SHA256) [0-9a-f]{64}) (.+)$/gm, (_line, prefix, rel) => {
      const path = resolve(dirname(previous), rel); return prefix+' '+(path === oldPlan ? f.plan : path);
    });
  writeFileSync(next, text);
  for (const m of text.matchAll(/^CONTENT-SHA256 [0-9a-f]{64} (.+)$/gm)) await sealRound(next, m[1]);
  await ledgerVerify(next, { spec: f.spec }); f.verdicts[i] = next;
}
console.log(JSON.stringify(f));
`);
    return JSON.parse(execFileSync(realBun, [runner], { encoding: 'utf8', timeout: 15000 })) as CappedFixture;
  }

  function returnDirectory(f: CappedFixture, location: string): string {
    if (location === 'spec-return') return dirname(f.verdicts[0]);
    if (location === 'plan-return') return dirname(f.verdicts[1]);
    if (location === 'plan-document') return dirname(f.plan);
    return join(f.specsRoot, location === 'key' ? 'HIMMEL-10205' : location);
  }

  function addUnaccountedReturn(f: CappedFixture, directory: string, round: number): void {
    mkdirSync(directory, { recursive: true });
    cpSync(f.verdicts[0], join(directory, basename(f.verdicts[0]).replace('r5.md', `r${round}a.md`)));
  }

  function unchangedProofFiles(proof: pinned.CappedFoldProof): void {
    for (const pin of proof.pins) if (pin.role !== 'decision-selection') expect(sha(pin.path)).toBe(pin.sha256);
  }

  it.each(['spec', 'spec-review'] as const)('capped carry return selection irrelevant files remain fresh: %s', api => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    expect(existsSync(join(f.specsRoot, 'design'))).toBe(false);
    expect(cappedCheck(api).ok).toBe(true);
    writeFileSync(join(f.specsRoot, 'design'), 'optional non-directory lookup');
    expect(cappedCheck(api).ok).toBe(true);
    unlinkSync(join(f.specsRoot, 'design'));
    for (const directory of ['design', 'spec', 'plan', 'HIMMEL-10205']) {
      const path = join(f.specsRoot, directory); mkdirSync(path);
      for (const name of ['HIMMEL-10205-other.md.critic-spec-r2.md', 'HIMMEL-10205-other.md.critic-r1-plan.md', 'HIMMEL-10205-other.md.critic-r2a.md',
        'unrelated.txt', ...(directory === 'HIMMEL-10205' ? [] : ['HIMMEL-99999-other.md.critic-plan-r99.md'])]) cpSync(f.verdicts[0], join(path, name));
    }
    unchangedProofFiles(row.capped_carry!);
    expect(cappedCheck(api).lines).toEqual([`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`]);
    const proof = JSON.parse(execFileSync(realBun, [expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan,
      '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]], { encoding: 'utf8', timeout: 15000 })) as pinned.CappedFoldProof;
    expect(proof.returns.map(r => r.round)).toEqual([5, 5]);
  });

  const directoryStale = (api: 'spec' | 'spec-review', fault: string) => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    expect(cappedCheck(api).ok).toBe(true);
    const directory = join(f.specsRoot, 'design');
    if (fault === 'alias') {
      const elsewhere = join(dirname(f.specsRoot), 'alias-target'); mkdirSync(elsewhere); symlinkSync(elsewhere, directory);
    }
    if (fault === 'overflow') { mkdirSync(directory); for (let i = 0; i < 4097; i++) writeFileSync(join(directory, `irrelevant-${i}`), ''); }
    if (fault === 'unreadable') { mkdirSync(directory); chmodSync(directory, 0); }
    try {
      unchangedProofFiles(row.capped_carry!);
      expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
    } finally { if (fault === 'unreadable') chmodSync(directory, 0o700); }
  };
  const directoryFaults = (faults: string[]) => (['spec', 'spec-review'] as const).flatMap(api => faults.map(fault => [api, fault] as const));
  it.each(directoryFaults(['alias', 'overflow']))('capped carry return selection directory stale: %s %s', directoryStale);
  it.skipIf(RUNS_AS_ROOT).each(directoryFaults(['unreadable']))('capped carry return selection directory stale: %s %s', directoryStale);

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['spec-return', 'plan-return', 'plan-document', 'design', 'designs', 'spec', 'plan', 'plans', 'key'].flatMap(location =>
      [5, 6].map(round => [api, location, round] as const))))('capped carry return selection later stale: %s %s r%s', (api, location, round) => {
    declared();
    const f = externalCappedFixture(location);
    if (api === 'spec' && (location === 'spec-return' || location === 'plan-return')) {
      const kind = location === 'spec-return' ? 'spec' : 'plan';
      const external = f.verdicts[kind === 'spec' ? 0 : 1];
      expect(() => cappedSign(api, f)).toThrow(
        `release operator spec: ${realpathSync(external)} is not beside the spec as ${basename(f.spec)}.critic-${kind}-r5.md`);
      expect(readOperatorRecords(api, specEnv())).toEqual([]);
      return;
    }
    const row = cappedSign(api, f);
    expect(readOperatorRecords(api, specEnv()).map(r => r.id)).toEqual([row.id]);
    expect(cappedCheck(api).lines).toEqual([`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`]);
    addUnaccountedReturn(f, returnDirectory(f, location), round);
    unchangedProofFiles(row.capped_carry!);
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
  });

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    [5, 6].map(round => [api, round] as const)))('capped carry return selection preappend: %s r%s', (api, round) => {
    declared();
    const f = cappedFixture();
    const before = fixtureHashes(f.specsRoot);
    const actual = ledger.withLock;
    let changed = false;
    cappedCalls.length = 0;
    const spy = vi.spyOn(ledger, 'withLock').mockImplementation((dir, fn, ...rest) => actual(dir, () => {
      if (dir === sctx().dir && !changed) {
        expect(cappedCalls).toHaveLength(1);
        expect(existsSync(join(sctx().dir, '.lock')) && existsSync(join(root, 'release', '.lock'))).toBe(true);
        changed = true;
        addUnaccountedReturn(f, join(f.specsRoot, 'spec'), round);
        for (const [path, hash] of Object.entries(before)) expect(sha(path)).toBe(hash);
      }
      return fn();
    }, ...rest));
    try {
      expect(() => cappedSign(api, f)).toThrow(/unaccounted latest return/);
      expect(changed).toBe(true);
      noCappedRows();
    } finally { spy.mockRestore(); }
  });

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    [5, 6].map(round => [api, round] as const)))('capped carry return selection persisted stale: %s r%s', (api, round) => {
    declared();
    const f = cappedFixture();
    const actual = ledger.appendChain;
    let changed = false;
    const spy = vi.spyOn(ledger, 'appendChain').mockImplementation((path, key, fields) => {
      const persisted = actual(path, key, fields);
      if (!changed && path === join(sctx().dir, 'operator.jsonl') && (fields as OperatorRow).kind === api) {
        changed = true;
        addUnaccountedReturn(f, join(f.specsRoot, 'HIMMEL-10205'), round);
      }
      return persisted;
    });
    let error = '';
    try { cappedSign(api, f); } catch (e) { error = (e as Error).message; }
    finally { spy.mockRestore(); }
    const rows = readOperatorRecords(api, specEnv());
    expect(rows).toHaveLength(1);
    expect(changed).toBe(true);
    unchangedProofFiles(rows[0].capped_carry!);
    expect(error).toBe(`persisted-but-stale ${rows[0].id}: capped-fold: ambiguous or unaccounted latest return: ${join(f.specsRoot, 'HIMMEL-10205', basename(f.verdicts[0]).replace('r5.md', `r${round}a.md`))}; inspect this record before retrying`);
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${rows[0].id}`]);
  });

  function resetFixture(f: CappedFixture, reseal = true): CappedFixture & { decision: string } {
    const runner = join(dirname(f.specsRoot), 'reset-fixture.ts');
    writeFileSync(runner, `
import { mkdirSync, readFileSync, readdirSync, utimesSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { roundReset, sealRound } from ${JSON.stringify(expectedVerifier)};
const f = ${JSON.stringify(f)};
const decision = join(f.specsRoot, 'decisions', 'verbatim-decision-990-fixture.txt');
mkdirSync(dirname(decision));
const quote = 'start this ticket over from scratch';
writeFileSync(decision, 'HIMMEL-10205 '+quote+'\\n');
const seconds = Math.floor(Date.now()/1000)+2.140625;
utimesSync(decision, seconds, seconds);
process.env.HIMMEL_CONSOLE='1';
await roundReset(f.specsRoot, 'HIMMEL-10205', { decision:'990', quote });
for (const name of ${reseal} ? readdirSync(dirname(f.spec)).filter(n => /critic-(spec|plan)-r[1-5]\\.md$/.test(n)).sort() : []) {
  const p=join(dirname(f.spec), name);
  writeFileSync(p, readFileSync(p,'utf8').replace('Fixture:', 'New epoch Fixture:'));
  for (const m of readFileSync(p,'utf8').matchAll(/^CONTENT-SHA256 [0-9a-f]{64} (.+)$/gm)) await sealRound(p, join(dirname(p),m[1]));
}
`);
    execFileSync(realBun, [runner], { timeout: 15000, stdio: ['ignore', 'pipe', 'pipe'] });
    return { ...f, decision: join(f.specsRoot, 'decisions', 'verbatim-decision-990-fixture.txt') };
  }
  const decisionFixture = () => resetFixture(cappedFixture());
  const keepMtime = (path: string, mtime: number) => {
    utimesSync(path, mtime / 1000, mtime / 1000);
    expect(statSync(path).mtimeMs, 'the bytes fault keeps the pinned mtime').toBe(mtime);
  };

  function evidencePath(f: CappedFixture, role: string): string {
    const paths: Record<string, string> = { spec: f.spec, plan: f.plan, page: join(dirname(f.spec), 'page.html'),
      estimate: join(dirname(f.spec), 'estimate.json'), return: f.verdicts[0], ledger: f.ledgerPath,
      manifest: join(dirname(f.ledgerPath), 'manifest.json'), snapshot: join(dirname(f.ledgerPath), 'HIMMEL-10205', sha(f.spec)),
      decision: join(f.specsRoot, 'decisions', 'verbatim-decision-990-fixture.txt') };
    return paths[role];
  }

  it('capped fixture requires bun', () => {
    const bin = join(root, 'ordinary-tools');
    mkdirSync(bin);
    for (const name of ['which', 'git', 'bash', 'dirname', 'cat', 'sed', 'awk', 'rg', 'head', 'tr', 'grep', 'sort', 'tail', 'wc', 'date']) {
      const found = spawnSync('which', [name], { encoding: 'utf8' });
      if (found.status === 0) symlinkSync(found.stdout.trim(), join(bin, name));
    }
    symlinkSync(process.execPath, join(bin, 'node'));
    const result = spawnSync(process.execPath, [join(candidateRoot, 'scripts/jira/node_modules/vitest/vitest.mjs'), 'run',
      'src/release/spec-sign.test.ts', '-t', '^signed minerva specs > capped carry signs frozen findings:'], {
      cwd: join(candidateRoot, 'scripts/jira'), env: { ...process.env, PATH: bin }, timeout: 15000, encoding: 'utf8',
    });
    expect(result.signal).toBeNull();
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain('capped fixture requires Bun on PATH');
    expect(`${result.stdout}${result.stderr}`).toMatch(/2 failed/);
  }, 20000);

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['spec', 'plan', 'page', 'estimate', 'snapshot', 'return', 'ledger', 'manifest'].map(role => [api, role] as const)))('capped carry extra pins stale: %s %s', (api, role) => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    expect(cappedCheck(api).lines).toEqual([`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`]);
    const path = evidencePath(f, role);
    writeFileSync(path, `${readFileSync(path, 'utf8')}\n`);
    const out = cappedCheck(api);
    expect(out.lines, role).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
    const ordinary: Record<string, string> = { spec: 'spec', plan: 'plan', return: 'verdict' };
    expect(out.answer.get('HIMMEL-10205'), role).toEqual({ missing: role in ordinary
      ? `${ordinary[role]} ${path} changed since ${row.id}`
      : `capped proof stale since ${row.id}: capped evidence changed or unreadable: ${path}` });
  });

  it.each(['spec', 'spec-review'] as const)('capped carry later ledger append stale: %s', api => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    const paths = [f.spec, f.plan, ...f.verdicts];
    const hashes = paths.map(sha);
    const ledgerBefore = readFileSync(f.ledgerPath, 'utf8');
    expect(cappedCheck(api).ok).toBe(true);
    resetFixture(f, false);
    expect(readFileSync(f.ledgerPath, 'utf8').startsWith(ledgerBefore)).toBe(true);
    expect(JSON.parse(readFileSync(f.ledgerPath, 'utf8').trim().split('\n').at(-1)!)).toMatchObject({ row: 'reset', epoch: 1 });
    expect(paths.map(sha)).toEqual(hashes);
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
  });

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['bytes', 'selection', 'mtime', 'file-alias', 'directory-alias'].map(fault => [api, fault] as const)))('capped carry decision selection/mtime/alias stale: %s %s', (api, fault) => {
    declared();
    const f = decisionFixture();
    const row = cappedSign(api, f);
    const proof = row.capped_carry!;
    expect(proof.epoch).toBe(1);
    const mtime = statSync(f.decision).mtimeMs;
    expect(mtime % 1).not.toBe(0);
    expect(proof.pins.find(p => p.role === 'decision')).toMatchObject({ path: f.decision, mtime_ms: mtime });
    expect(cappedCheck(api).lines).toEqual([`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`]);
    const bytes = readFileSync(f.decision);
    if (fault === 'bytes') { writeFileSync(f.decision, `${bytes.toString()}changed\n`); keepMtime(f.decision, mtime); }
    if (fault === 'selection') writeFileSync(join(dirname(f.decision), 'verbatim-decision-990-second.txt'), bytes);
    if (fault === 'mtime') { utimesSync(f.decision, mtime / 1000 + 10, mtime / 1000 + 10); expect(readFileSync(f.decision)).toEqual(bytes); }
    if (fault === 'file-alias') { const moved = join(dirname(f.specsRoot), 'same-decision'); renameSync(f.decision, moved); symlinkSync(moved, f.decision); }
    if (fault === 'directory-alias') { const moved = join(dirname(f.specsRoot), 'same-decisions'); renameSync(dirname(f.decision), moved); symlinkSync(moved, dirname(f.decision)); }
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry recording checkout removed: %s', api => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    expect(cappedCheck(api).ok).toBe(true);
    const elsewhere = join(root, 'retained-copy');
    cpSync(f.specsRoot, elsewhere, { recursive: true });
    expect(sha(join(elsewhere, 'designs', basename(f.spec)))).toBe(sha(f.spec));
    rmSync(dirname(f.specsRoot), { recursive: true });
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
  });

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['null', 'unknown-field', 'schema', 'reader-version', 'missing-pin', 'key', 'proof-key', 'spec', 'plan', 'returns', 'count'].map(fault => [api, fault] as const)))('capped carry persisted malformed or unbound proof stale: %s %s', (api, fault) => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    expect(cappedCheck(api).ok).toBe(true);
    const proof = JSON.parse(JSON.stringify(row.capped_carry));
    const copy = { ...row, id: 'O-R1-9000', supersedes: row.id, capped_carry: proof };
    if (fault === 'null') copy.capped_carry = null;
    if (fault === 'unknown-field') proof.unknown = true;
    if (fault === 'schema') proof.schema = 2;
    if (fault === 'reader-version') proof.reader_version = 2;
    if (fault === 'missing-pin') proof.pins = proof.pins.filter((p: { role: string }) => p.role !== 'ledger');
    if (fault === 'key') copy.keys = ['HIMMEL-10205', 'HIMMEL-8888'];
    if (fault === 'proof-key') { proof.key = 'HIMMEL-8888'; for (const c of proof.carried) c.key = proof.key; }
    if (fault === 'spec') { copy.spec_path = join(root, 'same-spec.md'); cpSync(f.spec, copy.spec_path); }
    if (fault === 'plan') { copy.plan_path = join(root, 'same-plan.md'); cpSync(f.plan, copy.plan_path); }
    if (fault === 'returns') { const path = join(root, 'same-return.md'); cpSync(f.verdicts[0], path); copy.verdicts = [{ path, sha256: sha(path) }, row.verdicts![1]]; }
    if (fault === 'count') copy.residuals = 0;
    appendChain(join(sctx().dir, 'operator.jsonl'), loadKey(sctx().keyPath), copy);
    expect(readOperatorRecords(api, specEnv()).at(-1)?.id).toBe(copy.id);
    expect(cappedCheck(api).lines).toEqual([`SPEC-STALE HIMMEL-10205 ${copy.spec_path} ${copy.id}`]);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry parent proof remains fresh for an inheriting child: %s', api => {
    declared();
    const f = cappedFixture();
    const row = cappedSign(api, f);
    const issues = new Map([['HIMMEL-8888', { type: 'Sub-task', parent: 'HIMMEL-10205' } as IssueSnap]]);
    expect(cappedCheck(api, ['HIMMEL-8888'], issues).lines).toEqual([`SPEC ok HIMMEL-8888 ${f.spec} ${row.id}`]);
    writeFileSync(f.ledgerPath, `${readFileSync(f.ledgerPath, 'utf8')}\n`);
    expect(cappedCheck(api, ['HIMMEL-8888'], issues).lines).toEqual([`SPEC-STALE HIMMEL-8888 ${f.spec} ${row.id}`]);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry signs frozen findings: %s', api => {
    declared();
    const f = cappedFixture();
    const before = fixtureHashes(f.specsRoot);
    const row = cappedSign(api, f);
    expect(row.residuals).toBe(2);
    expect(row.capped_carry).toMatchObject({ schema: 1, mode: 'capped-carry', key: 'HIMMEL-10205' });
    expect(row.capped_carry?.carried.map(c => [c.kind, c.finding_id, c.status])).toEqual([
      ['spec', 'F1', 'open-carried'], ['plan', 'F1', 'open-carried'],
    ]);
    expect(readOperatorRecords(api, specEnv()).find(r => r.id === row.id)?.capped_carry).toEqual(row.capped_carry);
    expect(fixtureHashes(f.specsRoot)).toEqual(before);
  });

  it.each([['spec', 'plan'], ['spec-review', 'plan'], ['spec', 'spec'], ['spec-review', 'spec']] as const)('capped carry preserves scoped IDs and CLEAN companion: %s %s', (api, cleanKind) => {
    declared();
    const f = cappedFixture(cleanKind);
    const before = fixtureHashes(f.specsRoot);
    const row = cappedSign(api, f);
    expect(row.residuals).toBe(1);
    expect(row.capped_carry?.returns.map(r => [r.kind, r.residuals])).toEqual(cleanKind === 'plan' ? [['spec', 1], ['plan', 0]] : [['spec', 0], ['plan', 1]]);
    expect(row.capped_carry?.carried.map(c => [c.kind, c.finding_id])).toEqual([[cleanKind === 'plan' ? 'spec' : 'plan', 'F1']]);
    expect(fixtureHashes(f.specsRoot)).toEqual(before);
  });

  function rejectingBun(mode: string, run: (log: string) => void): void {
    const bin = mkdtempSync(join(root, 'bun-bin-'));
    const log = join(bin, 'real-success.jsonl');
    const path = join(bin, 'bun');
    writeFileSync(path, `#!${process.execPath}
const {execFileSync} = require('node:child_process');
const fs = require('node:fs');
const {createHash} = require('node:crypto');
const args = process.argv.slice(2), mode = ${JSON.stringify(mode)};
if(args[0] !== ${JSON.stringify(expectedVerifier)} || args[1] !== 'capped-fold') throw Error('unexpected verifier argv');
if(mode === 'missing-verifier') args[0] += '.missing';
if(mode === 'unknown-verb') args[1] = 'unknown-capped-fold';
let output;
try { output = execFileSync(${JSON.stringify(realBun)}, args, {encoding:'utf8', stdio:['ignore','pipe','pipe']}); }
catch(e) { process.stderr.write(String(e.stderr || e.message)); process.exit(e.status || 1); }
const p = JSON.parse(output);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({args, digest:createHash('sha256').update(output).digest('hex')})+'\\n');
const h = 'f'.repeat(64);
function changeHash(pin) { const old=pin.sha256; pin.sha256=h; for(const x of p.pins) if(x.path===pin.path && x.sha256===old) x.sha256=h; }
if(mode==='key') { p.key='HIMMEL-99999'; for(const c of p.carried)c.key=p.key; }
if(mode==='spec-hash') changeHash(p.spec);
if(mode==='plan-hash') changeHash(p.plan);
if(mode==='return-full') changeHash(p.returns[1]);
if(mode==='return-normalized') { p.returns[1].return_sha=h; for(const c of p.carried)if(c.kind==='plan')c.return_sha=h; }
if(mode==='count') { p.returns[1].residuals++; p.carried.push({...p.carried.find(c=>c.kind==='plan'), finding_id:'F2'}); }
if(mode==='reader-version')p.reader_version=2;
if(mode==='schema')p.schema=2;
if(mode==='malformed') { process.stdout.write('not JSON'); process.exit(0); }
if(mode==='nonzero') { process.stderr.write('rejecting verifier exit'); process.exit(7); }
if(mode==='returned-drift') { const path=p.returns[1].path; fs.writeFileSync(path,fs.readFileSync(path,'utf8').replace(/Reviewed: spec [0-9a-f]{64}/,'Reviewed: spec '+h)); }
if(mode.startsWith('latest-return-')) {
  const path=p.returns[0].path; fs.copyFileSync(path,path.replace('r5.md','r'+mode.slice('latest-return-'.length)+'a.md'));
  for(const pin of p.pins) if(pin.role!=='decision-selection' && createHash('sha256').update(fs.readFileSync(pin.path)).digest('hex')!==pin.sha256) throw Error('original pin changed');
}
if(mode==='timeout') Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,32000);
process.stdout.write(JSON.stringify(p));
if(mode==='output')process.stdout.write(' '.repeat(4*1024*1024+1));
`);
    chmodSync(path, 0o755);
    const old = process.env.PATH;
    process.env.PATH = `${bin}:${old}`;
    try { run(log); } finally { process.env.PATH = old; rmSync(bin, { recursive: true, force: true }); }
  }

  function noCappedRows(): void {
    expect(readOperatorRecords('spec', specEnv())).toEqual([]);
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);
  }

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    [5, 6].map(round => [api, round] as const)))('capped carry return selection initial consumption: %s r%s', (api, round) => {
    declared();
    const f = cappedFixture();
    rejectingBun(`latest-return-${round}`, log => {
      expect(() => cappedSign(api, f)).toThrow(/residual findings.*capped verifier unavailable\/refused:.*unaccounted latest return/);
      expect(readFileSync(log, 'utf8').trim().split('\n')).toHaveLength(1);
      noCappedRows();
    });
  });

  it.each(['key', 'spec-hash', 'plan-hash', 'return-full', 'return-normalized', 'count'])('capped carry rejects mismatched proof binding: %s', mode => {
    declared();
    const f = cappedFixture();
    rejectingBun(mode, log => {
      for (const api of ['spec', 'spec-review'] as const) {
        expect(() => cappedSign(api, f)).toThrow(/residual findings.*capped verifier unavailable\/refused: capped proof .*binding disagrees/);
        noCappedRows();
      }
      expect(readFileSync(log, 'utf8').trim().split('\n')).toHaveLength(2);
    });
  });

  it('capped carry rejects returned-byte drift', () => {
    declared();
    const f = cappedFixture();
    rejectingBun('returned-drift', log => {
      expect(() => cappedSign('spec-review', f)).toThrow(/residual findings.*capped evidence changed/);
      expect(readFileSync(log, 'utf8')).toContain('digest');
      noCappedRows();
    });
  });

  it.each(['reader-version', 'schema', 'malformed', 'nonzero', 'missing-verifier', 'unknown-verb'])('capped carry verifier refuses unavailable or incompatible evidence: %s', mode => {
    declared();
    const f = cappedFixture();
    rejectingBun(mode, log => {
      expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:/);
      if (!['missing-verifier', 'unknown-verb'].includes(mode)) expect(readFileSync(log, 'utf8')).toContain('digest');
      noCappedRows();
    });
  });

  it('capped carry refuses absent Bun', () => {
    declared();
    const f = cappedFixture();
    const old = process.env.PATH;
    process.env.PATH = join(root, 'absent-bun');
    try { expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:.*ENOENT/); }
    finally { process.env.PATH = old; }
    noCappedRows();
  });

  it('capped carry bounds verifier output', () => {
    declared();
    const f = cappedFixture();
    rejectingBun('output', log => {
      expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:.*ENOBUFS/);
      expect(readFileSync(log, 'utf8')).toContain('digest');
      noCappedRows();
    });
  });

  it('capped carry bounds verifier time', () => {
    declared();
    const f = cappedFixture();
    rejectingBun('timeout', log => {
      const start = Date.now();
      expect(() => cappedSign('spec-review', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:.*ETIMEDOUT/);
      expect(Date.now() - start).toBeGreaterThanOrEqual(29000);
      expect(Date.now() - start).toBeLessThan(40000);
      expect(readFileSync(log, 'utf8')).toContain('digest');
      noCappedRows();
    });
  }, 45000);

  it('capped carry Node Reviewed crosscheck', () => {
    declared();
    const f = cappedFixture();
    const actual = pinned.reviewedSpecHashes;
    let planAfterVerifier = false;
    cappedCalls.length = 0;
    const spy = vi.spyOn(pinned, 'reviewedSpecHashes').mockImplementation(text => {
      const hashes = actual(text);
      if (text.includes('Fixture: plan round 5')) {
        planAfterVerifier = cappedCalls.length > 0;
        return ['a'.repeat(64)];
      }
      return hashes;
    });
    try {
      expect(() => cappedSign('spec-review', f)).toThrow(/residual findings.*capped plan Reviewed binding disagrees/);
      expect(planAfterVerifier).toBe(true);
      noCappedRows();
    } finally { spy.mockRestore(); }
    expect(cappedSign('spec-review', f).capped_carry?.carried).toHaveLength(2);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry uses candidate verifier source: %s', api => {
    declared();
    const f = cappedFixture();
    cappedCalls.length = 0;
    const old = process.cwd();
    process.chdir(root);
    try { expect(cappedSign(api, f).capped_carry?.carried).toHaveLength(2); }
    finally { process.chdir(old); }
    expect(cappedCalls).toEqual([[expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan,
      '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]]);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry uses candidate verifier built-dist: %s', api => {
    declared();
    const f = cappedFixture();
    const log = join(root, 'child-calls.jsonl');
    const observe = `import cp from 'node:child_process'; import {syncBuiltinESMExports} from 'node:module'; import {appendFileSync} from 'node:fs';
const actual=cp.execFileSync; cp.execFileSync=(...a)=>{if(a[1]?.[1]==='capped-fold')appendFileSync(${JSON.stringify(log)},JSON.stringify(a[1])+'\\n');return actual(...a);}; syncBuiltinESMExports();
`;
    const engine = new URL('../../dist/release/engine.js', import.meta.url).href;
    const c = sctx();
    Object.assign(c, fakeProc());
    const input = { engine, api, ctx: { release: c.release, dir: c.dir, keyPath: c.keyPath, env: c.env, procRoot: c.procRoot, hostNsPath: c.hostNsPath },
      args: { keys: ['HIMMEL-10205'], spec: f.spec, plan: f.plan, verdicts: f.verdicts, decision: '387', verbatim: 'approve' } };
    const script = `${observe}const i=JSON.parse(process.argv[1]); const m=await import(i.engine); const row=m[i.api==='spec'?'signSpec':'specReview']({...i.ctx,now:()=>new Date('2026-10-21T10:00:00.000Z'),jira:{},mirrorRoot:null},i.args); console.log(JSON.stringify({engine:i.engine,row}));`;
    const child = spawnSync(process.execPath, ['--input-type=module', '-e', script, JSON.stringify(input)], { cwd: root, encoding: 'utf8', timeout: 15000 });
    expect(child.status, child.stderr).toBe(0);
    const result = JSON.parse(child.stdout);
    expect(result.row.capped_carry.carried).toHaveLength(2);
    expect(readFileSync(log, 'utf8').trim().split('\n'), 'one attempt, logged before it ran').toHaveLength(1);
    expect(JSON.parse(readFileSync(log, 'utf8').trim())).toEqual([expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan,
      '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]);
    const beforeRows = readFileSync(join(c.dir, 'operator.jsonl'), 'utf8');
    const beforeCalls = readFileSync(log, 'utf8');
    const wrongNs = fakeProc();
    writeFileSync(wrongNs.hostNsPath, 'pid:[999] user:[999]\n');
    for (const [ancestry, reason] of [
      [fakeProc({ HIMMEL_BRIDGE_SESSION: '1' }), /HIMMEL_BRIDGE_SESSION=1/],
      [wrongNs, /other namespaces/],
    ] as const) {
      const deniedInput = { ...input, ctx: { ...input.ctx, ...ancestry } };
      const denied = spawnSync(process.execPath, ['--input-type=module', '-e', script, JSON.stringify(deniedInput)], { cwd: root, encoding: 'utf8', timeout: 15000 });
      expect(denied.status).toBe(1);
      expect(denied.stderr).toMatch(reason);
      expect(readFileSync(join(c.dir, 'operator.jsonl'), 'utf8')).toBe(beforeRows);
      expect(readFileSync(log, 'utf8')).toBe(beforeCalls);
    }
  });

  it('shared return hash preserves normalization compatibility', () => {
    const hash = (text: string) => createHash('sha256').update(text).digest('hex');
    expect(pinned.returnSha('line  \nCONTENT-SHA256 dead ignored\nnext\t\n\n')).toBe(hash('line\nnext\n'));
    expect(pinned.returnSha('\n\t\n')).toBe(hash(''));
    expect(pinned.returnSha(' CONTENT-SHA256 retained\r\n\n')).toBe(hash(' CONTENT-SHA256 retained\n'));
  });

  it.each(['spec', 'spec-review'] as const)('capped carry does not bypass gates: %s', api => {
    declared();
    const f = cappedFixture();
    expect(() => cappedSign(api, f, { plan: undefined })).toThrow(api === 'spec' ? /residual findings.*explicit distinct plan/ : /--plan names the plan/);
    expect(() => cappedSign(api, f, { plan: f.spec })).toThrow(api === 'spec' ? /residual findings.*explicit distinct plan/ : /--plan is the spec/);
    const alias = join(root, 'plan-alias.md');
    symlinkSync(f.spec, alias);
    expect(() => cappedSign(api, f, { plan: alias })).toThrow(api === 'spec' ? /residual findings.*capped verifier unavailable\/refused/ : /--plan is the spec/);
    expect(() => cappedSign(api, f, { keys: ['HIMMEL-10205', 'HIMMEL-10206'] })).toThrow(api === 'spec' ? /residual findings.*one key/ : /names HIMMEL-10205, not --keys/);
    expect(() => cappedSign(api, f, { verdicts: [f.verdicts[0]] })).toThrow(api === 'spec' ? /exactly two --verdict/ : /residual findings.*paired SPEC\/PLAN/);
    expect(() => cappedSign(api, f, { supersedes: 'O-R1-9999' })).toThrow(api === 'spec' ? /no verified spec record/ : /no live spec-review record/);
    noCappedRows();
    const gated = cappedFixture(undefined, true);
    cappedCalls.length = 0;
    expect(() => cappedSign(api, gated)).toThrow(/minerva-spec-gate.sh refused/);
    expect(cappedCalls).toHaveLength(1);
    noCappedRows();
    const o = { keys: ['HIMMEL-10205'], spec: f.spec, plan: f.plan, verdicts: f.verdicts };
    const fenced = sctx({ ...specEnv(), HIMMEL_CONSOLE_LEG: '1' });
    cappedCalls.length = 0;
    expect(() => api === 'spec' ? signSpec(fenced, { ...o, decision: '387', verbatim: 'approve' }) : specReview(fenced, o)).toThrow(/chief-spawned worker/);
    expect(cappedCalls).toEqual([]);
    noCappedRows();
  });

  it('T-R12: signSpec refuses an id-list line on the capped route through lintSpec with the gate line', () => {
    declared();
    vi.stubEnv('HIMMEL_REPO', candidateRoot);
    const scripts = 'marketplace/plugins/himmel-ops/scripts';
    const signerRoot = mkdtempSync(join(root, 'signer-root-'));
    execFileSync('git', ['init', '-q', signerRoot]);
    mkdirSync(join(signerRoot, scripts), { recursive: true });
    for (const name of ['minerva-spec-gate.sh', 'minerva-trace-lint.sh']) copyFileSync(join(candidateRoot, scripts, name), join(signerRoot, scripts, name));
    sourceFixture.primary = signerRoot;
    try {
      const f = cappedFixture(undefined, false, 5, undefined, '- R1: F1, F2 fixed');
      expect(() => cappedSign('spec', f)).toThrow(/minerva-spec-gate\.sh refused the spec:[\s\S]*SIGN-SHAPE REFUSED: .*R1: F1, F2 fixed/);
      noCappedRows();
      const clean = cappedFixture(undefined, false, 5, undefined, '- R1-F1: fixed');
      expect(spawnSync('bash', [join(signerRoot, scripts, 'minerva-spec-gate.sh'), clean.spec], { cwd: dirname(clean.spec), encoding: 'utf8' }).status,
        'control: the gate passes the qualified line').toBe(0);
    } finally { sourceFixture.primary = null; }
  });

  it.each(['spec', 'spec-review'] as const)('capped carry requires normal declared authority: %s', api => {
    const f = cappedFixture();
    expect(() => cappedSign(api, f)).toThrow(/release R1 is UNKNOWN/);
    expect(existsSync(join(sctx().dir, 'operator.jsonl'))).toBe(false);
  });

  it.each(['spec', 'spec-review'] as const)('capped carry does not bypass key or Reviewed bindings: %s', api => {
    declared();
    const f = cappedFixture();
    for (const path of f.verdicts) {
      const original = readFileSync(path, 'utf8');
      for (const changed of [original.replace(/^Reviewed:.*\n/m, ''), original.replace(/Reviewed: spec [0-9a-f]{64}/, `Reviewed: spec ${'a'.repeat(64)}`),
        original.replace('Key: HIMMEL-10205', 'Key: HIMMEL-10206')]) {
        writeFileSync(path, changed);
        expect(() => cappedSign(api, f)).toThrow(/Reviewed|review|latest|Key:|names|header|return must declare/);
        noCappedRows();
      }
      writeFileSync(path, original);
    }
    expect(cappedSign(api, f).capped_carry?.carried).toHaveLength(2);
  });

  it('legacy inline and CLEAN success never requests capped fallback', () => {
    declared();
    cappedCalls.length = 0;
    cappedSpawn.attempts.length = 0;
    const clean = spec();
    expect(sign(sctx(), ['K-1'], clean).capped_carry).toBeUndefined();
    const inline = spec('K-3.md', join(root, 'inline'), ['# K-3: inline', '## Critic rounds', '- R1: fixed in the spec']);
    expect(sign(sctx(), ['K-3'], inline, { verdicts: [verdict(inline, 'spec', 'SPEC FINDINGS 1'), verdict(inline, 'plan', 'PLAN CLEAN')] }).capped_carry).toBeUndefined();
    const f = rspec();
    expect(review(sctx(), f, [critic(f.spec, 'SPEC CLEAN')]).capped_carry).toBeUndefined();
    const v = critic(f.spec, 'SPEC FINDINGS 1', { reviewed: [`Reviewed: spec ${'a'.repeat(64)}`] });
    writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\n## Critic rounds\n\n- Round 1: file ${basename(v)}\n  - R1: fixed in §1\n`);
    expect(review(sctx(), f, [v]).capped_carry).toBeUndefined();
    expect(cappedCalls).toEqual([]);
    expect(cappedSpawn.attempts, 'no capped-fold spawn was attempted, a failed one included').toEqual([]);
  });

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['spec', 'plan', 'page', 'estimate', 'return', 'ledger', 'manifest', 'snapshot', 'decision', 'selection', 'mtime'].map(role => [api, role] as const)))('capped carry preappend drift: %s %s', (api, role) => {
    declared();
    const f = ['decision', 'selection', 'mtime'].includes(role) ? decisionFixture() : cappedFixture();
    const actual = ledger.withLock;
    let changedUnderLocks = 0;
    cappedCalls.length = 0;
    const spy = vi.spyOn(ledger, 'withLock').mockImplementation((dir, fn, ...rest) => {
      return actual(dir, () => {
        if (dir === sctx().dir && !changedUnderLocks) {
          expect(cappedCalls).toHaveLength(1);
          expect(existsSync(join(sctx().dir, '.lock')) && existsSync(join(root, 'release', '.lock'))).toBe(true);
          changedUnderLocks++;
          const path = evidencePath(f, ['selection', 'mtime'].includes(role) ? 'decision' : role);
          if (role === 'selection') writeFileSync(join(dirname(path), 'verbatim-decision-990-second.txt'), readFileSync(path));
          else if (role === 'mtime') { const seconds = statSync(path).mtimeMs / 1000 + 10; utimesSync(path, seconds, seconds); }
          else writeFileSync(path, `${readFileSync(path, 'utf8')}\n`);
        }
        return fn();
      }, ...rest);
    });
    try {
      const refusal = api === 'spec' && ['spec', 'plan', 'return'].includes(role)
        ? /the spec, plan or a verdict file changed while it was checked/
        : /capped evidence (changed|selection changed)/;
      expect(() => cappedSign(api, f)).toThrow(refusal);
      expect(changedUnderLocks).toBe(1);
      noCappedRows();
    } finally { spy.mockRestore(); }
  });

  it.each(['spec', 'spec-review'] as const)('capped carry persisted stale on postappend drift: %s', api => {
    declared();
    const f = cappedFixture();
    const actual = ledger.appendChain;
    const authorityPath = join(sctx().dir, 'operator.jsonl');
    let changedAfterPersistence = false;
    const spy = vi.spyOn(ledger, 'appendChain').mockImplementation((path, key, fields) => {
      const persisted = actual(path, key, fields);
      if (!changedAfterPersistence && path === authorityPath && (fields as OperatorRow).kind === api) {
        changedAfterPersistence = true;
        writeFileSync(f.ledgerPath, `${readFileSync(f.ledgerPath, 'utf8')}\n`);
      }
      return persisted;
    });
    let error = '';
    try { cappedSign(api, f); } catch (e) { error = (e as Error).message; }
    finally { spy.mockRestore(); }
    const rows = readOperatorRecords(api, specEnv());
    expect(rows).toHaveLength(1);
    expect(changedAfterPersistence).toBe(true);
    expect(error).toMatch(new RegExp(`persisted-but-stale ${rows[0].id}:.*inspect this record before retrying`));
  });

  it.each(['spec', 'spec-review'] as const)('capped carry reports exact persisted row when verified readback fails: %s', api => {
    declared();
    const f = cappedFixture();
    const actual = ledger.appendChain;
    const path = join(sctx().dir, 'operator.jsonl');
    const saved = `${path}.saved`;
    let refusedReadback = false;
    const spy = vi.spyOn(ledger, 'appendChain').mockImplementation((target, key, fields) => {
      const persisted = actual(target, key, fields);
      if (!refusedReadback && target === path && (fields as OperatorRow).kind === api) {
        refusedReadback = true;
        renameSync(path, saved);
      }
      return persisted;
    });
    let error = '';
    try { cappedSign(api, f); } catch (e) { error = (e as Error).message; }
    finally { spy.mockRestore(); if (existsSync(saved)) renameSync(saved, path); }
    const rows = readOperatorRecords(api, specEnv());
    expect(rows).toHaveLength(1);
    expect(refusedReadback).toBe(true);
    expect(error).toBe(`persisted-but-stale ${rows[0].id}: signed row did not verify on readback; inspect this record before retrying`);
  });

  const CHILD = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'pinned-read-child.mjs');
  const child = (mode: 'check' | 'review', input: Record<string, unknown>) => {
    const r = spawnSync(process.execPath, [CHILD, JSON.stringify({ env: specEnv(), ...input }), mode], { timeout: 5000, encoding: 'utf8' });
    return { status: r.status, signal: r.signal, out: r.stdout ? JSON.parse(r.stdout) as Record<string, unknown> : null };
  };

  it.each((['spec', 'spec-review'] as const).flatMap(api =>
    ['spec', 'plan', 'page', 'estimate', 'return', 'ledger', 'manifest', 'snapshot', 'decision'].flatMap(role =>
      ['fifo', 'directory', 'oversized', 'missing', 'device'].map(fault => [api, role, fault] as const))))('capped carry stale unreadable pin: %s %s %s', (api, role, fault) => {
    declared();
    const f = role === 'decision' ? decisionFixture() : cappedFixture();
    const row = cappedSign(api, f);
    expect(cappedCheck(api).ok).toBe(true);
    const path = evidencePath(f, role);
    unlinkSync(path);
    if (fault === 'fifo') execFileSync('mkfifo', [path]);
    if (fault === 'directory') mkdirSync(path);
    if (fault === 'oversized') { writeFileSync(path, ''); truncateSync(path, 16 * 1024 * 1024 + 1); }
    if (fault === 'device') symlinkSync('/dev/null', path);
    const out = child('check', { keys: ['HIMMEL-10205'], kinds: [api] });
    expect(out.signal).toBeNull();
    expect(out.status).toBe(0);
    expect(out.out?.lines).toEqual([`SPEC-STALE HIMMEL-10205 ${f.spec} ${row.id}`]);
  });
  function signedPair(): { p: string; id: string; good: string; goodId: string } {
    declared();
    const p = spec();
    const r = sign(sctx(), ['K-1'], p);
    const good = spec('K-3-good.md', join(root, 'specs3'));
    const g = sign(sctx(), ['K-3'], good);
    return { p, id: r.id, good, goodId: g.id };
  }

  it('spec-check never accepts a spec-review record', () => {
    declared();
    const f = rspec();
    const r = review(sctx(), f, [critic(f.spec, 'SPEC CLEAN')]);
    expect(r.kind).toBe('spec-review');
    expect(check(['K-2'])).toEqual(['NO-SPEC K-2']);
    expect(specCheck(specEnv(), ['K-2'], null).answer.get('K-2')).toEqual({ missing: 'no spec-review record for K-2' });
    const out = specCheck(specEnv(), ['K-2'], null, both);
    expect(out.lines).toEqual([`SPEC ok K-2 ${f.spec} ${r.id}`]);
    expect(out.answer.get('K-2')).toEqual({ ok: true });
  });

  it('spec-check --kinds reads spec-review records for the chief', async () => {
    declared();
    for (const [k, v] of Object.entries(specEnv())) vi.stubEnv(k, v);
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
    vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
    const f = rspec();
    const out: string[] = [];
    const log = vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
    const code = process.exitCode;
    const codes: Array<typeof code> = [];
    try {
      await cli('operator', 'spec-review', 'R1', '--keys', 'K-2', '--spec', f.spec, '--plan', f.plan, '--verdict', critic(f.spec, 'SPEC CLEAN'));
      await cli('spec-check', 'K-2');
      codes.push(process.exitCode);
      process.exitCode = code;
      await cli('spec-check', '--kinds', 'spec,spec-review', 'K-2');
      codes.push(process.exitCode);
    } finally {
      log.mockRestore();
      process.exitCode = code;
    }
    expect(out).toEqual([`O-R1-0002 spec-review ${f.spec} for K-2`, 'NO-SPEC K-2', `SPEC ok K-2 ${f.spec} O-R1-0002`]);
    expect(codes).toEqual([1, code]);
    const row = readOperatorRecords('spec-review', specEnv())[0];
    expect([row.spec_sha256, row.plan_sha256, ...(row.verdicts ?? []).map((v) => v.sha256)]).toHaveLength(3);
    const four = review(sctx(), f, [critic(f.spec, 'SPEC CLEAN'), critic(f.spec, 'PLAN CLEAN', { kind: 'plan' })]);
    expect([four.spec_sha256, four.plan_sha256, ...(four.verdicts ?? []).map((v) => v.sha256)]).toHaveLength(4);
  });

  it('a FIFO at a pinned path names that key only and does not block', () => {
    const { p, id, good, goodId } = signedPair();
    const pinned = `${p}.critic-spec-r1.md`;
    unlinkSync(pinned);
    execFileSync('mkfifo', [pinned]);
    const r = child('check', { keys: ['K-1', 'K-3'] });
    expect(r.signal).toBeNull();
    expect(r.status).toBe(0);
    expect(r.out).toEqual({
      lines: [`SPEC-STALE K-1 ${p} ${id}`, `SPEC ok K-3 ${good} ${goodId}`],
      answer: { 'K-1': { missing: `${pinned} is unreadable (${id})` }, 'K-3': { ok: true } },
    });
  });

  it('a FIFO at a spec-review row\'s pinned path is unreadable too', () => {
    declared();
    const f = rspec();
    const r = review(sctx(), f, [critic(f.spec, 'SPEC CLEAN')]);
    const pinned = `${f.spec}.critic-spec-r1.md`;
    unlinkSync(pinned);
    execFileSync('mkfifo', [pinned]);
    const out = child('check', { keys: ['K-2'], kinds: ['spec', 'spec-review'] });
    expect(out.signal).toBeNull();
    expect(out.out).toEqual({ lines: [`SPEC-STALE K-2 ${f.spec} ${r.id}`], answer: { 'K-2': { missing: `${pinned} is unreadable (${r.id})` } } });
  });

  it('a device at a pinned path is unreadable', () => {
    const { p, id, good, goodId } = signedPair();
    unlinkSync(p);
    symlinkSync('/dev/zero', p);
    const r = child('check', { keys: ['K-1', 'K-3'] });
    expect(r.signal).toBeNull();
    expect(r.status).toBe(0);
    expect(r.out).toEqual({
      lines: [`SPEC-STALE K-1 ${p} ${id}`, `SPEC ok K-3 ${good} ${goodId}`],
      answer: { 'K-1': { missing: `${p} is unreadable (${id})` }, 'K-3': { ok: true } },
    });
  });

  it('a directory at a pinned path names that key only', () => {
    const { p, id, good, goodId } = signedPair();
    const pinned = `${p}.critic-plan-r1.md`;
    unlinkSync(pinned);
    mkdirSync(pinned);
    const out = specCheck(specEnv(), ['K-1', 'K-3'], null);
    expect(out.lines).toEqual([`SPEC-STALE K-1 ${p} ${id}`, `SPEC ok K-3 ${good} ${goodId}`]);
    expect(out.answer.get('K-1')).toEqual({ missing: `${pinned} is unreadable (${id})` });
  });

  it('a pinned file over 16 MiB is unreadable', () => {
    const { p, id, good, goodId } = signedPair();
    const pinned = `${p}.critic-spec-r1.md`;
    truncateSync(pinned, 17 * 1024 * 1024);
    const out = specCheck(specEnv(), ['K-1', 'K-3'], null);
    expect(out.lines).toEqual([`SPEC-STALE K-1 ${p} ${id}`, `SPEC ok K-3 ${good} ${goodId}`]);
    expect(out.answer.get('K-1')).toEqual({ missing: `${pinned} is unreadable (${id})` });
    expect(out.answer.get('K-3')).toEqual({ ok: true });
  });

  it.skipIf(process.platform !== 'linux')('a pinned file that yields more bytes than fstat reported is unreadable', () => {
    expect(pinnedSha('/proc/self/status')).toEqual({ unreadable: true });
  });

  it('the bounded reader refuses a device by its file type: /dev/null is canonical and empty, so neither the alias check nor a digest is the cause', () => {
    expect(realpathSync('/dev/null')).toBe('/dev/null');
    expect(pinned.pinnedRead('/dev/null')).toEqual({ unreadable: true });
  });

  it('a missing or changed pinned file names its path in the answer', () => {
    const { p, id } = signedPair();
    writeFileSync(p, `${readFileSync(p, 'utf8')}\nedited\n`);
    expect(specCheck(specEnv(), ['K-1'], null).answer.get('K-1')).toEqual({ missing: `spec ${p} changed since ${id}` });
    unlinkSync(p);
    expect(specCheck(specEnv(), ['K-1'], null).answer.get('K-1')).toEqual({ missing: `${p} is missing (${id})` });
  });

  it('a newer row of another kind never hides a spec-review row', () => {
    declared();
    const f = rspec();
    const r = review(sctx(), f, [critic(f.spec, 'SPEC CLEAN')]);
    coreBypass({ ...sctx(), now: () => new Date('2026-10-22T10:00:00.000Z') }, { keys: ['K-2'], decision: '804', verbatim: 'bypass' });
    const records = readOperatorRecords(['spec-review', 'core-bypass'], specEnv());
    expect(records.map((x) => x.kind)).toEqual(['spec-review', 'core-bypass']);
    const out = specCheck(specEnv(), ['K-2'], null, { ...both, records, issues: null });
    expect(out.answer.get('K-2')).toEqual({ ok: true });
    expect(out.lines).toEqual([`SPEC ok K-2 ${f.spec} ${r.id}`]);
  });

  it('a stale spec-review row never hides a fresh signed spec', () => {
    declared();
    const p = spec();
    const signed = sign(sctx(), ['K-2'], p);
    const f = rspec();
    review({ ...sctx(), now: () => new Date('2026-10-22T10:00:00.000Z') }, f, [critic(f.spec, 'SPEC CLEAN')]);
    writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\nedited\n`);
    const out = specCheck(specEnv(), ['K-2'], null, both);
    expect(out.answer.get('K-2')).toEqual({ ok: true });
    expect(out.lines).toEqual([`SPEC ok K-2 ${p} ${signed.id}`]);
  });

  it('spec-review refuses a missing or self plan, a wrong verdict set, a refused spec, a worker and a spec-row supersede', () => {
    declared();
    const f = rspec();
    const clean = () => critic(f.spec, 'SPEC CLEAN');
    expect(() => review(sctx(), { spec: f.spec }, [clean()])).toThrow(/release operator spec-review: --plan names the plan/);
    expect(() => review(sctx(), { spec: f.spec, plan: f.spec }, [clean()])).toThrow(/--plan is the spec/);
    expect(() => review(sctx(), f, [critic(f.spec, 'PLAN CLEAN', { kind: 'plan' })])).toThrow(/exactly one SPEC verdict/);
    expect(() => review(sctx(), f, [clean(), critic(f.spec, 'SPEC CLEAN', { round: 2 })])).toThrow(/exactly one SPEC verdict/);
    expect(() => review(sctx({ ...specEnv(), HIMMEL_CONSOLE_LEG: '1' }), f, [clean()])).toThrow(/chief-spawned worker/);
    const signed = sign(sctx(), ['K-2'], spec());
    expect(() => review(sctx(), f, [clean()], { supersedes: signed.id })).toThrow(new RegExp(`${signed.id} is no live spec-review record`));
    writeFileSync(f.spec, readFileSync(f.spec, 'utf8').replace('Estimate record: est.json', ''));
    expect(() => review(sctx(), f, [clean()])).toThrow(/minerva-spec-gate/);
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);
  });

  it('spec-review refuses a FIFO --spec as unreadable within the deadline', () => {
    declared();
    const f = rspec();
    const v = critic(f.spec, 'SPEC CLEAN');
    unlinkSync(f.spec);
    execFileSync('mkfifo', [f.spec]);
    const c = sctx();
    const r = child('review', {
      ctx: { release: c.release, dir: c.dir, keyPath: c.keyPath, now: '2026-10-21T10:00:00.000Z', ...fakeProc() },
      review: { keys: ['K-2'], spec: f.spec, plan: f.plan, verdicts: [v] },
    });
    expect(r.signal).toBeNull();
    expect(r.out).toEqual({ error: `release operator spec-review: spec ${f.spec} is unreadable` });
  });

  it('shared Reviewed extractor preserves legacy specReview', () => {
    declared();
    const f = rspec();
    const s = sha(f.spec);
    const other = 'a'.repeat(64);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { reviewed: [] })])).toThrow(/one 'Reviewed: spec <sha256>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { reviewed: [`Reviewed: spec ${s}`, `Reviewed: spec ${s}`] })]))
      .toThrow(/one 'Reviewed: spec <sha256>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { reviewed: [`Reviewed: design ${s}`] })])).toThrow(/one 'Reviewed: spec <sha256>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { reviewed: [`Reviewed: spec ${other}`] })]))
      .toThrow(new RegExp(`SPEC CLEAN reviewed ${other}, not the spec's bytes ${s}`));
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC FINDINGS 0', { reviewed: [`Reviewed: spec ${other}`] })]))
      .toThrow(new RegExp(`SPEC FINDINGS 0 reviewed ${other}, not the spec's bytes ${s}`));
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);

    const v = critic(f.spec, 'SPEC FINDINGS 1', { reviewed: [`Reviewed: spec ${other}`] });
    writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\n## Critic rounds\n\n- Round 1: one finding, file ${basename(v)}\n  - R1: fixed in §1\n`);
    const r = review(sctx(), f, [v]);
    expect(r.reviewed_sha256).toBe(other);
    expect(r.spec_sha256).toBe(sha(f.spec));
    expect(r.spec_sha256).not.toBe(other);
    expect(r.residuals).toBe(1);
  });

  it('spec-review refuses a Key: line that is missing, empty of keys, another key set or only in the body, and an unnamed spec', () => {
    declared();
    const f = rspec();
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { key: null })])).toThrow(/one 'Key: <keys>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { key: 'see the spec' })])).toThrow(/one 'Key: <keys>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { key: 'K-2, K-3' })])).toThrow(/names K-2, K-3, not --keys K-2/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { key: null, body: ['this reviews K-2'] })])).toThrow(/one 'Key: <keys>' line/);
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN'), critic(f.spec, 'PLAN CLEAN', { kind: 'plan', key: null })]))
      .toThrow(/critic-plan-r1\.md needs exactly one 'Key: <keys>' line/);
    const unnamed = rspec(join(root, 'rs-unnamed'), '- Ticket: K-7');
    expect(() => review(sctx(), unnamed, [critic(unnamed.spec, 'SPEC CLEAN')])).toThrow(/the spec's header does not name K-2/);
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);
  });

  it('spec-review refuses a key that is a prefix of the reviewed key, and a cross-ticket record', () => {
    declared();
    const h = rspec(join(root, 'rs-h'), '- Ticket: HIMMEL-9564', '# HIMMEL-9564: a reviewed design');
    expect(() => review(sctx(), h, [critic(h.spec, 'SPEC CLEAN', { key: 'HIMMEL-9564' })], { keys: ['HIMMEL-956'] }))
      .toThrow(/names HIMMEL-9564, not --keys HIMMEL-956/);
    const f = rspec();
    expect(() => review(sctx(), f, [critic(f.spec, 'SPEC CLEAN')], { keys: ['K-9'] })).toThrow(/names K-2, not --keys K-9/);
    writeFileSync(`${h.spec}.critic-spec-r1.md`, readFileSync(`${h.spec}.critic-spec-r1.md`, 'utf8').replace('Key: HIMMEL-9564', 'Key: HIMMEL-956'));
    expect(() => review(sctx(), h, [`${h.spec}.critic-spec-r1.md`], { keys: ['HIMMEL-956'] })).toThrow(/the spec's header does not name HIMMEL-956/);
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);
  });

  it('spec-review reads the keys on a Key: line with trailing prose', () => {
    declared();
    const f = rspec();
    const r = review(sctx(), f, [critic(f.spec, 'SPEC CLEAN', { key: 'K-2 (spec)' })]);
    expect(r.keys).toEqual(['K-2']);
  });

  it('spec-review refuses a FINDINGS fold whose own round block lacks its dispositions', () => {
    declared();
    const f = rspec();
    const v = critic(f.spec, 'SPEC FINDINGS 2');
    writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\n## Critic rounds\n\n- Round 1: two findings, file ${basename(v)}\n  - R1: fixed in §1\n`);
    expect(() => review(sctx(), f, [v])).toThrow(/2 residual findings and their round blocks hold 1 dispositioned/);
    const g = rspec(join(root, 'rs-r2'));
    const v1 = critic(g.spec, 'SPEC FINDINGS 5');
    writeFileSync(g.spec, `${readFileSync(g.spec, 'utf8')}\n## Critic rounds\n\n- Round 1: five findings, file ${basename(v1)}\n`
      + [1, 2, 3, 4, 5].map((n) => `  - R${n}: fixed\n`).join('')
      + `- Round 2: three findings, file ${basename(`${g.spec}.critic-spec-r2.md`)}\n`);
    const v2 = critic(g.spec, 'SPEC FINDINGS 3', { round: 2 });
    expect(() => review(sctx(), g, [v2])).toThrow(/3 residual findings and their round blocks hold 0 dispositioned/);
    expect(readOperatorRecords('spec-review', specEnv())).toEqual([]);
  });

  it('spec-review pins the reviewed and the folded spec hash', () => {
    declared();
    const f = rspec();
    const reviewedSha = sha(f.spec);
    const v = critic(f.spec, 'SPEC FINDINGS 3');
    writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\n## Critic rounds\n\n- Round 1: three findings, file ${basename(v)}\n`
      + '  - R1: fixed in §1\n  - R2: ASSUMPTION A1\n  - R3: deferred → HIMMEL-9000\n');
    const r = review(sctx(), f, [v]);
    expect(r.reviewed_sha256).toBe(reviewedSha);
    expect(r.spec_sha256).toBe(sha(f.spec));
    expect(r.spec_sha256).not.toBe(reviewedSha);
    expect(r.residuals).toBe(3);
  });

  type V2Fixture = CappedFixture & { keys?: string[]; anchor?: string; members?: string[]; earlier?: string[]; decision?: string | null; all: string[] };
  const v2Build = (request: Record<string, unknown>): V2Fixture => {
    if (!realBun) throw new Error('capped fixture requires Bun on PATH; install the pinned .bun-version');
    const f = JSON.parse(execFileSync(realBun, [join(candidateRoot, 'scripts/telegram/testlib-capped-fold.ts')], {
      input: JSON.stringify({ scratchRoot: mkdtempSync(join(root, 'v2-')), ...request }), encoding: 'utf8', timeout: 15000,
    })) as V2Fixture;
    f.all = f.verdicts;
    f.verdicts = (['spec', 'plan'] as const).map(kind => f.all.filter(p => p.includes(`.critic-${kind}-r`)).at(-1) as string);
    return f;
  };
  const v2Keys = (f: V2Fixture) => f.keys ?? [/(HIMMEL-\d+)/.exec(basename(f.spec))![1]];
  const v2Sign = (f: V2Fixture, extra: Record<string, unknown> = {}, c: Ctx = sctx()) => signSpec(c, {
    keys: v2Keys(f), spec: f.spec, plan: f.plan, verdicts: f.verdicts, decision: '387', verbatim: 'approve', ...extra,
  });
  const spawnReset = () => { cappedSpawn.fn = null; cappedSpawn.options.length = 0; cappedSpawn.attempts.length = 0; };
  const attemptFlags = () => cappedSpawn.attempts.map(a => a[2]);
  const releaseRows = () => existsSync(join(sctx().dir, 'operator.jsonl')) ? readFileSync(join(sctx().dir, 'operator.jsonl'), 'utf8').trim().split('\n').filter(Boolean).length : 0;
  const v2Tree = (f: V2Fixture) => {
    const decisions: Record<string, number> = {};
    const dir = join(f.specsRoot, 'decisions');
    if (existsSync(dir)) for (const name of readdirSync(dir)) decisions[name] = statSync(join(dir, name)).mtimeMs;
    return { files: fixtureHashes(f.specsRoot), decisions, rows: readFileSync(f.ledgerPath, 'utf8').trim().split('\n').map(l => (JSON.parse(l) as { row: string }).row) };
  };
  const within = (path: string, dir: string) => path === dir || path.startsWith(`${dir}/`);
  function v2Hermetic(f: V2Fixture): () => void {
    const home = process.env.HOME as string;
    const listing = () => readdirSync(home, { recursive: true }).map(String).filter(p => !p.startsWith('.bun/install/cache/')).sort();
    const before = listing();
    return () => {
      const env = specEnv();
      expect(within(env.HIMMEL_RELEASE_STATE_DIR, root) && within(env.HIMMEL_RELEASE_KEY_DIR, root), 'the release root and the key are inside the temporary root').toBe(true);
      expect(within(home, root) && within(f.specsRoot, root), 'HOME and the fixture are scratch directories inside the temporary root').toBe(true);
      expect(within(f.specsRoot, env.HIMMEL_RELEASE_STATE_DIR) || within(env.HIMMEL_RELEASE_STATE_DIR, f.specsRoot), 'the release root and the artifact tree share no path').toBe(false);
      expect(listing(), 'nothing under HOME changed').toEqual(before);
    };
  }
  function v2OnlyFixture(): V2Fixture {
    return v2Build({ key: 'HIMMEL-10205',
      specText: '---\ntickets: HIMMEL-10205\n---\n# HIMMEL-10205 fixture\n\nKey: HIMMEL-10205\n\nEstimate record: estimate.json\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n',
      planText: '---\ntickets: HIMMEL-10205\n---\n# HIMMEL-10205 plan\n\n- Ticket: HIMMEL-10205\n\n- Task 1: build the fixture.\n',
      returns: [1, 2, 3, 4, 5].flatMap(round => (['spec', 'plan'] as const).map(kind => ({ kind, round,
        text: `- **F1** (${kind === 'spec' ? 'medium; Fact overlap' : 'minor'}) residual\n${kind.toUpperCase()} FINDINGS 1\n`,
        reads: ['spec', 'plan', { path: 'specs/designs/estimate.json', text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' }, { path: 'specs/designs/page.html', text: '<p>fixture</p>\n' }] }))) });
  }
  const armProof = (mutate: (proof: any, args: string[]) => void, argv: (args: string[]) => string[] = args => args) => {
    cappedSpawn.fn = args => {
      const run = spawnSync(realBun, argv(args), { encoding: 'utf8', timeout: 15000 });
      if (run.status !== 0) throw Object.assign(new Error(run.stderr), { status: run.status, stderr: run.stderr });
      const proof = JSON.parse(run.stdout);
      mutate(proof, args);
      return JSON.stringify(proof);
    };
  };
  const OTHER = 'f'.repeat(64);

  const CHIEF_DOCS = ['docs/handover/chief-sections/telegram-files.md', 'docs/handover/running-a-chief.md'] as const;
  const SIGNING_MARKER = '<!-- signing-hash-check -->';
  const chiefDoc = (rel: string) => readFileSync(join(candidateRoot, rel), 'utf8');
  const occurrences = (text: string, needle: string) => text.split(needle).length - 1;
  function markedBlock(text: string): string | null {
    const lines = text.split('\n'); const marker = lines.indexOf(SIGNING_MARKER);
    const open = marker < 0 ? -1 : lines.findIndex((l, i) => i > marker && l.startsWith('```'));
    const close = open < 0 ? -1 : lines.findIndex((l, i) => i > open && l.startsWith('```'));
    return close < 0 ? null : lines.slice(open + 1, close).join('\n');
  }
  const SECTION_HEADING = '## Ledger-bound capped carry (proof v2)';
  function docSection(text: string): string | null {
    const lines = text.split('\n'); const start = lines.indexOf(SECTION_HEADING);
    if (start < 0) return null;
    const next = lines.findIndex((l, i) => i > start && /^## /.test(l));
    return lines.slice(start, next < 0 ? lines.length : next).join('\n').trimEnd();
  }

  describe('capped carry v2 producer route', () => {
    beforeEach(() => {
      spawnReset();
      for (const [k, v] of Object.entries(specEnv())) vi.stubEnv(k, v);
      vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
      vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
      vi.stubEnv('HOME', mkdtempSync(join(root, 'home-')));
      declared();
    });
    afterEach(() => spawnReset());

    async function cliSign(f: V2Fixture, keys = v2Keys(f)) {
      writeFileSync(join(root, 'verbatim.txt'), 'approve 1-5\n');
      const out: string[] = [];
      const log = vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
      try {
        await cli('operator', 'spec', 'R1', '--keys', keys.join(','), '--spec', f.spec, '--plan', f.plan, '--verdict', f.verdicts[0], '--verdict', f.verdicts[1],
          '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'));
      } finally { log.mockRestore(); }
      return out;
    }
    const okLines = (keys: string[], f: V2Fixture, id: string) => keys.map(k => `SPEC ok ${k} ${f.spec} ${id}`);
    const staleLines = (keys: string[], f: V2Fixture, id: string) => keys.map(k => `SPEC-STALE ${k} ${f.spec} ${id}`);
    const GROUP_REFUSAL = /residual findings.*capped verifier unavailable\/refused: v1 route: capped carry requires one key, an explicit distinct plan and paired SPEC\/PLAN returns; v2: /;

    it('capped carry v2 signs a seven-key group through the real release operator spec: one schema-2 record, seven SPEC ok, the artifact tree unchanged (E1, R1, R2, E19)', async () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!;
      const done = v2Hermetic(f); const before = v2Tree(f); const rowsBefore = releaseRows();
      const releaseDir = sctx().dir;
      const releaseFiles = () => existsSync(releaseDir) ? Object.fromEntries(readdirSync(releaseDir, { recursive: true }).map(String).sort()
        .filter(n => statSync(join(releaseDir, n)).isFile()).map(n => [n, sha(join(releaseDir, n))])) : {};
      const releaseBefore = releaseFiles();
      await cliSign(f);
      const rows = readOperatorRecords('spec', specEnv());
      expect(rows).toHaveLength(1);
      const row = rows[0];
      const releaseAfter = releaseFiles();
      expect(Object.keys(releaseAfter).filter(n => releaseAfter[n] !== releaseBefore[n]), 'E19: the release directory changes in operator.jsonl only').toEqual(['operator.jsonl']);
      expect(Object.keys(releaseBefore).filter(n => !(n in releaseAfter)), 'E19: no release file is removed').toEqual([]);
      expect(row.capped_carry).toMatchObject({ schema: 2, reader_version: 2, mode: 'capped-carry-ledger', anchor: f.anchor, keys: [...keys].sort(), epoch: 1 });
      expect([...(row.keys ?? [])].sort()).toEqual([...keys].sort());
      expect(row.residuals).toBe(2);
      expect(row.capped_carry!.carried.map(c => [c.kind, c.finding_id, c.status]), 'R2: every carried entry is open-carried').toEqual([['spec', 'F1', 'open-carried'], ['plan', 'P1', 'open-carried']]);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      expect(v2Tree(f), 'R1: the artifact tree, every decision mtime and the ledger rows are unchanged').toEqual(before);
      expect(releaseRows(), 'the release root gains exactly one signed row').toBe(rowsBefore + 1);
      expect(cappedSpawn.attempts).toEqual([[expectedVerifier, 'capped-fold', '--keys', [...keys].sort().join(','), '--spec', f.spec, '--plan', f.plan, '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]]);
      done();
    }, 60000);

    it('capped carry v2 refuses six of the seven keys and eight keys: no record (E2)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const done = v2Hermetic(f);
      expect(() => v2Sign(f, { keys: keys.slice(0, 6) })).toThrow(new RegExp(`${GROUP_REFUSAL.source}capped-fold: capped-fold: tickets must declare only ${keys.slice(0, 6).join(', ')}`));
      expect(() => v2Sign(f, { keys: [...keys, 'HIMMEL-9808'] })).toThrow(new RegExp(`${GROUP_REFUSAL.source}capped-fold: capped-fold: tickets must declare only ${[...keys, 'HIMMEL-9808'].join(', ')}`));
      noCappedRows();
      expect(attemptFlags(), 'a group goes to the v2 route only').toEqual(['--keys', '--keys']);
      done();
    });

    it('capped carry v2 group record is stale after each pinned file edit, a ledger append, a history file edited or removed and an unsealed or foreign file (E3)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f);
      const ok = okLines(keys, f, row.id); const stale = staleLines(keys, f, row.id);
      expect(check(keys)).toEqual(ok);
      const files = row.capped_carry!.pins.filter((p): p is pinned.EvidenceFilePin | pinned.HistoryPin => 'path' in p);
      expect(new Set(files.map(p => p.role))).toEqual(new Set(['ledger', 'manifest', 'return', 'artifact', 'snapshot', 'decision', 'history']));
      expect(files.filter(p => p.role === 'history').map(p => p.path).sort()).toEqual([...f.earlier!].sort());
      for (const pin of files.filter(p => p.role !== 'decision')) {
        const kept = readFileSync(pin.path);
        writeFileSync(pin.path, `${kept.toString()}\n`);
        expect(check(keys), `${pin.role} ${pin.path} edited`).toEqual(stale);
        writeFileSync(pin.path, kept);
        expect(check(keys), `${pin.role} ${pin.path} restored`).toEqual(ok);
      }
      const ledger = readFileSync(f.ledgerPath, 'utf8');
      writeFileSync(f.ledgerPath, `${ledger}${ledger.trim().split('\n').at(-1)}\n`);
      expect(check(keys), 'a ledger row appended').toEqual(stale);
      writeFileSync(f.ledgerPath, ledger);
      const history = f.earlier![0]; const kept = readFileSync(history);
      unlinkSync(history);
      expect(check(keys), 'a history file removed').toEqual(stale);
      writeFileSync(history, kept);
      expect(check(keys)).toEqual(ok);
      const unsealed = f.verdicts[0].replace('r5.md', 'r6.md');
      cpSync(f.verdicts[0], unsealed);
      expect(check(keys), 'a new unsealed return').toEqual(stale);
      unlinkSync(unsealed);
      const foreign = join(dirname(f.spec), 'HIMMEL-9801-foreign.md.critic-spec-r5.md');
      writeFileSync(foreign, 'a foreign return of the same key');
      expect(check(keys), 'a foreign file of the key at the signed round').toEqual(stale);
      unlinkSync(foreign);
      expect(check(keys)).toEqual(ok);
    }, 60000);

    it.each(['bytes', 'selection', 'mtime', 'file-alias', 'directory-alias'])('capped carry v2 group decision selection, mtime and alias fault is the only cause of the stale read: %s (E3)', fault => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!;
      const decisionTime = Math.floor(Date.now() / 1000) + 2.140625;
      utimesSync(f.decision!, decisionTime, decisionTime);
      const row = v2Sign(f);
      const proof = row.capped_carry!; const mtime = statSync(f.decision!).mtimeMs;
      expect(proof.pins.find(p => p.role === 'decision')).toMatchObject({ path: f.decision, mtime_ms: mtime });
      expect(proof.pins.some(p => p.role === 'decision-selection')).toBe(true);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      const ledger = readFileSync(f.ledgerPath, 'utf8'); const bytes = readFileSync(f.decision!);
      if (fault === 'bytes') { writeFileSync(f.decision!, `${bytes.toString()}changed\n`); keepMtime(f.decision!, mtime); }
      if (fault === 'selection') writeFileSync(join(dirname(f.decision!), 'verbatim-decision-990-second.txt'), bytes);
      if (fault === 'mtime') { utimesSync(f.decision!, mtime / 1000 + 10, mtime / 1000 + 10); expect(readFileSync(f.decision!)).toEqual(bytes); }
      if (fault === 'file-alias') { const moved = join(dirname(f.specsRoot), 'same-decision'); renameSync(f.decision!, moved); symlinkSync(moved, f.decision!); }
      if (fault === 'directory-alias') { const moved = join(dirname(f.specsRoot), 'same-decisions'); renameSync(dirname(f.decision!), moved); symlinkSync(moved, dirname(f.decision!)); }
      for (const pin of proof.pins) if ('path' in pin && pin.role !== 'decision') expect(sha(pin.path), `${pin.role} unchanged`).toBe(pin.sha256);
      expect(readFileSync(f.ledgerPath, 'utf8')).toBe(ledger);
      expect(check(keys)).toEqual(staleLines(keys, f, row.id));
    });

    it('capped carry v2 re-signs a schema-2 group record only by superseding it and keeping every key (E4)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const first = v2Sign(f);
      expect(() => v2Sign(f)).toThrow(new RegExp(`${keys[0]} is already signed in ${first.id}; re-sign with --supersedes ${first.id}`));
      expect(() => v2Sign(f, { keys: keys.slice(0, 6), supersedes: first.id }), 'the verifier refuses six of the seven before the engine reaches its own check').toThrow(GROUP_REFUSAL);
      expect(() => sign(sctx(), keys.slice(0, 6), spec('HIMMEL-9801-clean.md'), { supersedes: first.id }), 'an ordinary signing that drops a key').toThrow(new RegExp(`--keys must keep every key of ${first.id}; missing ${keys[6]}`));
      expect(check(keys)).toEqual(okLines(keys, f, first.id));
      const later = v2Sign(f, { supersedes: first.id }, { ...sctx(), now: () => new Date('2026-10-22T10:00:00.000Z') });
      expect(later.capped_carry).toMatchObject({ schema: 2 });
      expect(check(keys)).toEqual(okLines(keys, f, later.id));
    });

    it('capped carry v2 refuses a group-shaped spec without its Estimate record line through the real release operator spec: no record (E5)', async () => {
      const keys = ['HIMMEL-9801', 'HIMMEL-9802'];
      const f = v2Build({ key: keys[0], declarations: false,
        specText: `---\ntickets: [${keys.join(', ')}]\n---\n# HIMMEL-9801 group\n\nThe contract names every member.\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n`,
        planText: '# HIMMEL-9801 plan\n\n- Task 1: build the fixture.\n',
        returns: [1, 2, 3, 4, 5].flatMap(round => (['spec', 'plan'] as const).map(kind => ({ kind, round,
          text: `- **F1** (${kind === 'spec' ? 'medium; Fact overlap' : 'minor'}) residual\n${kind.toUpperCase()} FINDINGS 1\n`, reads: ['spec', 'plan'] }))) });
      await expect(cliSign(f, keys)).rejects.toThrow(/release operator spec: minerva-spec-gate.sh refused the spec:/);
      expect(attemptFlags(), 'the artifact reached the verifier and the lint refused after it').toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 proof fails the unchanged v1 shape validator and passes the v2 one, and the pinned reader version is still 1 (E8: the validator contract)', () => {
      const f = v2Build({ builder: 'group' }); const row = v2Sign(f);
      expect(() => pinned.validateCappedFoldProofShape(row.capped_carry)).toThrow('invalid capped-fold proof');
      expect(pinned.validateCappedProofShape(row.capped_carry)).toEqual(row.capped_carry);
      expect(pinned.PINNED_READ_VERSION).toBe(1);
    });

    it('capped carry v2 group refusal names the v1 route before the v2 reason: the verifier refuses a member that holds a ledger, and a mocked v2 spawn throws its timeout (E9; a real child timeout is pinned for v1 only)', () => {
      const f = v2Build({ builder: 'group', reset: 'none' }); const keys = f.keys!;
      writeFileSync(join(pinned.ledgerDirOf(f.specsRoot), `${f.members![0]}.jsonl`), '');
      expect(() => v2Sign(f)).toThrow(new RegExp(`${GROUP_REFUSAL.source}capped-fold: capped-fold: group member holds ledger state: ${f.members![0]}`));
      expect(() => v2Sign(f)).toThrow(/residual findings.*one key/);
      noCappedRows();
      expect(attemptFlags()).toEqual(['--keys', '--keys']);
      spawnReset();
      cappedSpawn.fn = () => { throw Object.assign(new Error('spawnSync bun ETIMEDOUT'), { code: 'ETIMEDOUT' }); };
      expect(() => v2Sign(f)).toThrow(new RegExp(`${GROUP_REFUSAL.source}spawnSync bun ETIMEDOUT$`));
      expect(cappedSpawn.options).toEqual([expect.objectContaining({ timeout: 30000, maxBuffer: 4194304 })]);
      expect(cappedSpawn.attempts).toEqual([[expectedVerifier, 'capped-fold', '--keys', [...keys].sort().join(','), '--spec', f.spec, '--plan', f.plan, '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]]);
      noCappedRows();
    });

    it('capped carry v2 one key a v1 verifier accepts is stored as schema 1, byte for byte what the verifier printed, with one --key attempt and no --keys (E11, E15)', () => {
      const f = cappedFixture(); const done = v2Hermetic(f as V2Fixture);
      const row = cappedSign('spec', f);
      const attempts = cappedSpawn.attempts.map(a => [...a]);
      expect(attempts, 'the whole attempt list of the signing, before the comparison child runs').toEqual([[expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan, '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]]);
      expect(row.capped_carry).toMatchObject({ schema: 1, mode: 'capped-carry', key: 'HIMMEL-10205' });
      const printed = execFileSync(realBun, [expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan, '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]], { encoding: 'utf8', timeout: 15000 });
      expect(JSON.stringify(row.capped_carry)).toBe(printed.trim());
      expect(cappedSpawn.attempts.slice(0, 1)).toEqual([[expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', f.spec, '--plan', f.plan, '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]]]);
      expect(attemptFlags().slice(0, 1)).toEqual(['--key']);
      expect(attemptFlags().includes('--keys')).toBe(false);
      expect(check(['HIMMEL-10205'])).toEqual([`SPEC ok HIMMEL-10205 ${f.spec} ${row.id}`]);
      done();
    });

    it('capped carry v2 known-single refusedCap: v1 refuses, v2 accepts, one schema-2 record, SPEC ok, the artifact tree unchanged (E12, R1, R2)', () => {
      const f = v2Build({ builder: 'known-single', variant: 'refusedCap' }); const key = v2Keys(f)[0];
      const done = v2Hermetic(f); const before = v2Tree(f); const rowsBefore = releaseRows();
      const row = v2Sign(f);
      expect(row.capped_carry).toMatchObject({ schema: 2, mode: 'capped-carry-ledger', anchor: key, keys: [key], epoch: 0 });
      expect(attemptFlags(), 'the shipped route first, then v2 with the one key').toEqual(['--key', '--keys']);
      expect(cappedSpawn.attempts[1].slice(2, 4)).toEqual(['--keys', key]);
      expect(row.capped_carry!.carried.map(c => [c.kind, c.finding_id, c.status]), 'R2').toEqual([['plan', 'P6', 'open-carried'], ['plan', 'P7', 'open-carried']]);
      expect(readOperatorRecords('spec', specEnv()).find(r => r.id === row.id)?.capped_carry).toEqual(row.capped_carry);
      expect(check([key])).toEqual([`SPEC ok ${key} ${f.spec} ${row.id}`]);
      expect(v2Tree(f), 'R1').toEqual(before);
      expect(releaseRows()).toBe(rowsBefore + 1);
      done();
    });

    it('capped carry v2 admittedNextRound: both routes refuse and the message holds the first route reason, then the v2 reason (E13)', () => {
      const f = v2Build({ builder: 'known-single', variant: 'admittedNextRound' }); const key = v2Keys(f)[0];
      expect(() => v2Sign(f)).toThrow(new RegExp(`residual findings.*capped verifier unavailable/refused: capped-fold: capped-fold: header must declare only ${key}; v2: capped-fold: capped-fold: findings have not reached the refused round cap$`));
      expect(attemptFlags()).toEqual(['--key', '--keys']);
      noCappedRows();
    });

    it('capped carry v2 never runs for spec-review: a v2-only artifact is refused by the v1 route alone and signs through release operator spec (E14)', () => {
      const f = v2OnlyFixture();
      let refusal = '';
      try { cappedSign('spec-review', f); } catch (e) { refusal = (e as Error).message; }
      expect(refusal).toMatch(/residual findings.*capped verifier unavailable\/refused: capped-fold: capped-fold: ineligible finding heading/);
      expect(refusal, 'the shipped refusal alone, no v2 reason').not.toContain('; v2:');
      expect(attemptFlags(), 'no --keys spawn from spec-review').toEqual(['--key']);
      noCappedRows();
      spawnReset();
      const row = cappedSign('spec', f);
      expect(row.capped_carry).toMatchObject({ schema: 2, anchor: 'HIMMEL-10205' });
      expect(attemptFlags()).toEqual(['--key', '--keys']);
    });

    it.each(['malformed', 'output', 'reader-version', 'schema', 'key', 'returned-drift', 'latest-return-5'])('capped carry v2 never retries a final failure of the v1 route on v2: %s (P3-2)', mode => {
      const f = cappedFixture();
      rejectingBun(mode, () => {
        expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:/);
        expect(attemptFlags(), 'exactly one --key attempt and no --keys').toEqual(['--key']);
        noCappedRows();
      });
    }, 60000);

    it('capped carry v2 never retries after an absent Bun, and goes to v2 only after a non-zero exit of the v1 verifier (P3-2)', () => {
      const f = cappedFixture();
      const old = process.env.PATH;
      process.env.PATH = join(root, 'absent-bun');
      try { expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused:.*ENOENT/); } finally { process.env.PATH = old; }
      expect(attemptFlags()).toEqual(['--key']);
      spawnReset();
      rejectingBun('nonzero', () => {
        expect(() => cappedSign('spec', f)).toThrow(/residual findings.*capped verifier unavailable\/refused: rejecting verifier exit; v2: rejecting verifier exit$/);
        expect(attemptFlags()).toEqual(['--key', '--keys']);
        spawnReset();
        expect(() => cappedSign('spec-review', f)).toThrow(/capped verifier unavailable\/refused: rejecting verifier exit$/);
        expect(attemptFlags(), 'spec-review stops after the one --key attempt').toEqual(['--key']);
      });
      noCappedRows();
    });

    const FORGED = ['anchor', 'keys', 'spec-hash', 'plan-hash', 'return-full', 'return-normalized', 'residuals', 'declared-tickets'] as const;
    it.each(FORGED)('capped carry v2 binds the proof to the signing input: %s', fault => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!;
      const message = {
        anchor: /capped proof anchor disagrees$/, keys: /capped proof input binding disagrees$/, 'spec-hash': /capped proof input binding disagrees$/, 'plan-hash': /capped proof input binding disagrees$/,
        'return-full': /capped proof plan return binding disagrees$/, 'return-normalized': /capped proof plan return binding disagrees$/, residuals: /capped proof plan return binding disagrees$/,
        'declared-tickets': /capped proof declared tickets disagree$/,
      }[fault];
      const requested = fault === 'declared-tickets' ? keys.slice(0, 6) : keys;
      armProof(p => {
        const absence = (members: string[]) => { for (const pin of p.pins) if (pin.role === 'member-absence') pin.keys = members; };
        const rehash = (artifact: { path: string; sha256: string }) => { artifact.sha256 = OTHER; for (const pin of p.pins) if (pin.path === artifact.path) pin.sha256 = OTHER; };
        if (fault === 'anchor') { p.anchor = p.keys[1]; for (const c of p.carried) c.key = p.keys[1]; absence(p.keys.filter((k: string) => k !== p.keys[1])); }
        if (fault === 'keys') { p.keys = p.keys.slice(0, 6); absence(p.keys.slice(1)); }
        if (fault === 'declared-tickets') { p.keys = p.keys.slice(0, 6); absence(p.keys.slice(1)); }
        if (fault === 'spec-hash') rehash(p.spec);
        if (fault === 'plan-hash') rehash(p.plan);
        if (fault === 'return-full') rehash(p.returns[1]);
        if (fault === 'return-normalized') { p.returns[1].return_sha = OTHER; for (const c of p.carried) if (c.kind === 'plan') c.return_sha = OTHER; }
        if (fault === 'residuals') { p.returns[1].residuals++; p.carried.push({ ...p.carried.find((c: any) => c.kind === 'plan'), finding_id: 'P2' }); }
      }, args => args.map((a, i) => i === 3 ? keys.join(',') : a));
      expect(() => v2Sign(f, { keys: requested })).toThrow(message);
      expect(attemptFlags(), 'the v2 spawn is made once').toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 refuses an answer that is not a schema-2 proof, and never asks again: schema 1, unparseable, an invalid shape (P3-2)', () => {
      const f = v2Build({ builder: 'known-single', variant: 'refusedCap' }); const other = cappedFixture();
      const v1 = execFileSync(realBun, [expectedVerifier, 'capped-fold', '--key', 'HIMMEL-10205', '--spec', other.spec, '--plan', other.plan, '--spec-return', other.verdicts[0], '--plan-return', other.verdicts[1]], { encoding: 'utf8', timeout: 15000 });
      spawnReset();
      cappedSpawn.fn = () => v1;
      expect(() => v2Sign(f)).toThrow(/; v2: capped proof schema disagrees: a --keys call was answered with schema 1$/);
      expect(attemptFlags()).toEqual(['--key', '--keys']);
      spawnReset();
      cappedSpawn.fn = () => 'not JSON';
      expect(() => v2Sign(f)).toThrow(/; v2: Unexpected token/);
      expect(attemptFlags()).toEqual(['--key', '--keys']);
      spawnReset();
      armProof(p => { p.reader_version = 1; });
      expect(() => v2Sign(f)).toThrow(/; v2: invalid capped-fold proof$/);
      expect(attemptFlags()).toEqual(['--key', '--keys']);
      noCappedRows();
    });

    it.each(['history-edit', 'history-removed', 'return-edit', 'unaccounted-return'])('capped carry v2 checks every pin of the proof before it is stored: %s', fault => {
      const f = v2Build({ builder: 'group' });
      armProof(p => {
        const history = p.pins.find((pin: any) => pin.role === 'history').path;
        if (fault === 'history-edit') writeFileSync(history, `${readFileSync(history, 'utf8')}\n`);
        if (fault === 'history-removed') unlinkSync(history);
        if (fault === 'return-edit') writeFileSync(p.returns[0].path, `${readFileSync(p.returns[0].path, 'utf8')}\n`);
        if (fault === 'unaccounted-return') cpSync(p.returns[0].path, p.returns[0].path.replace('r5.md', 'r6.md'));
      });
      const expected = fault === 'unaccounted-return' ? /; v2: capped-fold: ambiguous or unaccounted latest return: .*r6\.md$/ : /; v2: capped evidence changed or unreadable: /;
      expect(() => v2Sign(f)).toThrow(expected);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 reads schema-1 and schema-2 records by their own code, and an unknown schema reads stale (E16)', () => {
      const single = cappedFixture(); const v1Row = cappedSign('spec', single);
      const g = v2Build({ builder: 'group' }); const keys = g.keys!; const v2Row = v2Sign(g);
      expect([v1Row.capped_carry!.schema, v2Row.capped_carry!.schema]).toEqual([1, 2]);
      const lines = () => check(['HIMMEL-10205', ...keys]);
      expect(lines()).toEqual([`SPEC ok HIMMEL-10205 ${single.spec} ${v1Row.id}`, ...okLines(keys, g, v2Row.id)]);
      const copy = (row: typeof v2Row, id: string, schema: number) => ({ ...row, id, supersedes: row.id, capped_carry: { ...JSON.parse(JSON.stringify(row.capped_carry)), schema } });
      appendChain(join(sctx().dir, 'operator.jsonl'), loadKey(sctx().keyPath), copy(v2Row, 'O-R1-9001', 3));
      expect(lines()).toEqual([`SPEC ok HIMMEL-10205 ${single.spec} ${v1Row.id}`, ...staleLines(keys, g, 'O-R1-9001')]);
      appendChain(join(sctx().dir, 'operator.jsonl'), loadKey(sctx().keyPath), copy(v1Row, 'O-R1-9002', 3));
      expect(lines()).toEqual([`SPEC-STALE HIMMEL-10205 ${single.spec} O-R1-9002`, ...staleLines(keys, g, 'O-R1-9001')]);
    });

    it('capped carry v2 CLEAN spec and CLEAN plan sign ordinarily: no verifier is spawned and no capped proof is stored (E18)', () => {
      const p = spec();
      const row = sign(sctx(), ['K-1'], p);
      expect(row).not.toHaveProperty('capped_carry');
      expect(cappedSpawn.attempts).toEqual([]);
      expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${row.id}`]);
    });

    it.each(['null', 'unknown-field', 'schema-1', 'reader-version', 'missing-pin', 'keys', 'anchor', 'spec', 'plan', 'returns', 'count', 'declared-tickets'])('capped carry v2 persisted malformed or unbound proof stale: %s', fault => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      const proof = JSON.parse(JSON.stringify(row.capped_carry));
      const copy: any = { ...row, id: 'O-R1-9000', supersedes: row.id, capped_carry: proof };
      if (fault === 'null') copy.capped_carry = null;
      if (fault === 'unknown-field') proof.unknown = true;
      if (fault === 'schema-1') proof.schema = 1;
      if (fault === 'reader-version') proof.reader_version = 1;
      if (fault === 'missing-pin') proof.pins = proof.pins.filter((p: { role: string }) => p.role !== 'ledger');
      if (fault === 'keys') copy.keys = [...keys, 'HIMMEL-8888'];
      if (fault === 'anchor') { proof.anchor = keys[1]; for (const c of proof.carried) c.key = keys[1]; for (const pin of proof.pins) if (pin.role === 'member-absence') pin.keys = keys.filter(k => k !== keys[1]); }
      if (fault === 'spec') { copy.spec_path = join(root, 'same-spec.md'); cpSync(f.spec, copy.spec_path); }
      if (fault === 'plan') { copy.plan_path = join(root, 'same-plan.md'); cpSync(f.plan, copy.plan_path); }
      if (fault === 'returns') { const path = join(root, 'same-return.md'); cpSync(f.verdicts[0], path); copy.verdicts = [{ path, sha256: sha(path) }, row.verdicts![1]]; }
      if (fault === 'count') copy.residuals = 0;
      if (fault === 'declared-tickets') { copy.keys = keys.slice(0, 6); proof.keys = keys.slice(0, 6); for (const pin of proof.pins) if (pin.role === 'member-absence') pin.keys = keys.slice(1, 6); }
      appendChain(join(sctx().dir, 'operator.jsonl'), loadKey(sctx().keyPath), copy);
      expect(readOperatorRecords('spec', specEnv()).at(-1)?.id).toBe(copy.id);
      expect(check([keys[0]])).toEqual([`SPEC-STALE ${keys[0]} ${copy.spec_path} ${copy.id}`]);
    });

    it('capped carry v2 stored member-absence pin on another folder reads stale: a scratch folder, another specs root, other keys (E26)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f);
      const withAbsence = (id: string, supersedes: string, change: (pin: any) => void) => {
        const proof = JSON.parse(JSON.stringify(row.capped_carry));
        for (const pin of proof.pins) if (pin.role === 'member-absence') change(pin);
        appendChain(join(sctx().dir, 'operator.jsonl'), loadKey(sctx().keyPath), { ...row, id, supersedes, capped_carry: proof });
      };
      withAbsence('O-R1-9001', row.id, () => {});
      expect(check(keys), 'control: an unchanged copy reads fresh').toEqual(okLines(keys, f, 'O-R1-9001'));
      withAbsence('O-R1-9002', 'O-R1-9001', pin => { pin.directory = join(root, 'scratch-ledgers'); });
      expect(check(keys)).toEqual(staleLines(keys, f, 'O-R1-9002'));
      withAbsence('O-R1-9003', 'O-R1-9002', pin => { pin.directory = join(mkdtempSync(join(root, 'other-specs-')), 'specs', 'ledgers', 'spec-rounds'); });
      expect(check(keys)).toEqual(staleLines(keys, f, 'O-R1-9003'));
      withAbsence('O-R1-9004', 'O-R1-9003', pin => { pin.keys = pin.keys.slice(1); });
      expect(check(keys)).toEqual(staleLines(keys, f, 'O-R1-9004'));
    });

    it('capped carry v2 a guard that refuses before any spawn refuses once with its shipped words, for a group too (P3-2)', () => {
      const f = v2Build({ builder: 'group' });
      const guard = /residual findings.*capped verifier unavailable\/refused: capped carry requires one key, an explicit distinct plan and paired SPEC\/PLAN returns$/;
      expect(() => v2Sign(f, { plan: undefined })).toThrow(guard);
      expect(() => v2Sign(f, { plan: f.spec })).toThrow(guard);
      expect(cappedSpawn.attempts, 'no spawn and no v2 reason').toEqual([]);
      noCappedRows();
    });

    it('capped carry v2 refuses a spec edited after the verifier answered, at the bind, before any pin is read', () => {
      const f = v2Build({ builder: 'group' });
      armProof(() => { writeFileSync(f.spec, `${readFileSync(f.spec, 'utf8')}\n`); });
      expect(() => v2Sign(f)).toThrow(/; v2: capped proof input binding disagrees$/);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 spawns with the keys sorted whatever order they were requested in, and keeps the requested order on the record (E1)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const reversed = [...keys].reverse();
      const row = v2Sign(f, { keys: reversed });
      expect(cappedSpawn.attempts[0].slice(2, 4)).toEqual(['--keys', [...keys].sort().join(',')]);
      expect(row.keys).toEqual(reversed);
      expect(row.capped_carry).toMatchObject({ keys: [...keys].sort() });
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
    });

    const ANCHORS = [['last', 'HIMMEL-9899', ['HIMMEL-9801', 'HIMMEL-9802', 'HIMMEL-9803', 'HIMMEL-9899']], ['in the middle', 'HIMMEL-9830', ['HIMMEL-9801', 'HIMMEL-9830', 'HIMMEL-9899']]] as const;
    function v2AnchorFixture(anchor: string, keys: readonly string[]): V2Fixture {
      const estimate = { path: 'specs/designs/estimate.json', text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' };
      const f = v2Build({ key: anchor, declarations: false,
        specText: `---\ntickets: [${keys.join(', ')}]\n---\n# ${anchor} group\n\nEstimate record: estimate.json\n\nThe contract names every member.\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n`,
        planText: `# ${anchor} plan\n\n- Task 1: build the fixture.\n`,
        returns: [1, 2, 3, 4, 5].flatMap(round => (['spec', 'plan'] as const).map(kind => ({ kind, round,
          text: `- **${kind === 'spec' ? 'F1' : 'P1'}** (${kind === 'spec' ? 'medium; Fact overlap' : 'minor'}) residual\n${kind.toUpperCase()} FINDINGS 1\n`,
          reads: kind === 'spec' ? ['spec', estimate] : ['spec', 'plan', estimate] }))) });
      f.keys = [...keys];
      f.anchor = anchor;
      return f;
    }

    it.each(ANCHORS)('capped carry v2 uses the anchor and not the first key in a group whose anchor sorts %s: signing, the stored record and the readback', (_where, anchor, keys) => {
      const f = v2AnchorFixture(anchor, keys); const sorted = [...keys].sort(); const done = v2Hermetic(f);
      expect(sorted[0], 'the anchor is not the first key').not.toBe(anchor);
      const unsealed = f.verdicts[0].replace('r5.md', 'r6.md');
      armProof(p => { cpSync(p.returns[0].path, unsealed); });
      expect(() => v2Sign(f, { keys }), 'signing: an unaccounted return of the anchor that appears after the verifier answered').toThrow(/; v2: capped-fold: ambiguous or unaccounted latest return: .*r6\.md$/);
      noCappedRows();
      unlinkSync(unsealed);
      spawnReset();
      const row = v2Sign(f, { keys });
      expect(row.capped_carry).toMatchObject({ schema: 2, anchor, keys: sorted });
      expect(row.capped_carry!.carried.every(c => c.key === anchor), 'every carried finding belongs to the anchor').toBe(true);
      expect(readOperatorRecords('spec', specEnv()).find(r => r.id === row.id)?.capped_carry, 'the stored record').toEqual(row.capped_carry);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      cpSync(f.verdicts[0], unsealed);
      expect(check(keys), 'the readback: a return of the anchor above the signed round copied in later').toEqual(staleLines(keys, f, row.id));
      unlinkSync(unsealed);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      done();
    });

    const realKeys = (keys: string[]) => (args: string[]) => args.map((a, i) => i === 3 ? keys.join(',') : a);
    it('capped carry v2 refuses a proof whose keys are a strict superset of the signing input, the input being a prefix of them', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!;
      armProof(() => {}, realKeys(keys));
      expect(() => v2Sign(f, { keys: keys.slice(0, 6) })).toThrow(/; v2: capped proof input binding disagrees$/);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 refuses a proof whose keys have the signing input\'s count and one different key', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!;
      armProof(() => {}, realKeys(keys));
      expect(() => v2Sign(f, { keys: [...keys.slice(0, 6), 'HIMMEL-9808'] })).toThrow(/; v2: capped proof input binding disagrees$/);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    function signalBun(signal: string, run: () => void): void {
      const bin = mkdtempSync(join(root, 'bun-bin-'));
      writeFileSync(join(bin, 'bun'), `#!${process.execPath}\nprocess.kill(process.pid, ${JSON.stringify(signal)});\nsetTimeout(() => {}, 5000);\n`);
      chmodSync(join(bin, 'bun'), 0o755);
      const old = process.env.PATH;
      process.env.PATH = `${bin}:${old}`;
      try { run(); } finally { process.env.PATH = old; rmSync(bin, { recursive: true, force: true }); }
    }
    it.each(['SIGKILL', 'SIGTERM'])('capped carry v2 a v1 child killed by %s is final: one --key attempt, no --keys, the shipped refusal words', signal => {
      const f = cappedFixture();
      signalBun(signal, () => {
        let refusal = '';
        try { cappedSign('spec', f); } catch (e) { refusal = (e as Error).message; }
        expect(refusal).toMatch(/residual findings.*capped verifier unavailable\/refused: Command failed: bun /);
        expect(refusal, 'no v2 reason').not.toContain('; v2:');
      });
      expect(attemptFlags()).toEqual(['--key']);
      noCappedRows();
    });

    const signedOnly = (row: { id: string }) => expect(readOperatorRecords('spec', specEnv()).map(r => r.id)).toEqual([row.id]);

    it.each(['ledger-file', 'snapshot-folder', 'manifest-entry'])('capped carry v2 group record is stale for every key once a member gains a %s after signing, and a fresh signing of the same group then refuses (E17)', kind => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const member = f.members![1]; const row = v2Sign(f);
      const dir = pinned.ledgerDirOf(f.specsRoot); const manifest = join(dir, 'manifest.json'); const kept = readFileSync(manifest);
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
      if (kind === 'ledger-file') writeFileSync(join(dir, `${member}.jsonl`), '');
      if (kind === 'snapshot-folder') mkdirSync(join(dir, member));
      if (kind === 'manifest-entry') { const m = JSON.parse(kept.toString()); m.keys[member] = { spec: 1, plan: 1 }; writeFileSync(manifest, JSON.stringify(m)); }
      expect(check(keys), 'every key, the anchor included').toEqual(staleLines(keys, f, row.id));
      expect(specCheck(specEnv(), keys, null).answer.get(f.anchor!), 'the reason').toEqual({ missing: expect.stringContaining(kind === 'manifest-entry'
        ? 'capped evidence changed or unreadable' : `capped evidence selection changed: ${dir}`) });
      spawnReset();
      expect(() => v2Sign(f, { supersedes: row.id })).toThrow(new RegExp(`${GROUP_REFUSAL.source}capped-fold: capped-fold: group member holds ledger state: ${member}`));
      expect(attemptFlags()).toEqual(['--keys']);
      signedOnly(row);
      if (kind === 'ledger-file') unlinkSync(join(dir, `${member}.jsonl`));
      if (kind === 'snapshot-folder') rmSync(join(dir, member), { recursive: true });
      if (kind === 'manifest-entry') writeFileSync(manifest, kept);
      expect(check(keys), 'the fault was the only cause').toEqual(okLines(keys, f, row.id));
    });

    it.each(['ledger-file', 'snapshot-folder'])('capped carry v2 a member %s created after the verifier answered and before the append refuses at the signing recheck under the lock, naming the shared ledger folder, and writes no record (E25)', kind => {
      const f = v2Build({ builder: 'group' }); const dir = pinned.ledgerDirOf(f.specsRoot);
      const made = join(dir, kind === 'ledger-file' ? `${f.members![0]}.jsonl` : f.members![0]);
      signingLock.fn = () => { if (kind === 'ledger-file') writeFileSync(made, ''); else mkdirSync(made); };
      try { expect(() => v2Sign(f)).toThrow(new Error(`capped evidence selection changed: ${dir}`)); } finally { signingLock.fn = null; }
      expect(existsSync(made), 'the lock seam ran').toBe(true);
      expect(attemptFlags(), 'the verifier answered once, before the member existed').toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 a listing over the bound is stale for the group and is never read as absence (E17)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const dir = pinned.ledgerDirOf(f.specsRoot);
      for (let i = 0; i < 4097; i++) writeFileSync(join(dir, `junk-${i}`), '');
      expect(check(keys)).toEqual(staleLines(keys, f, row.id));
      expect(specCheck(specEnv(), keys, null).answer.get(keys[0])).toEqual({ missing: expect.stringContaining(`capped evidence selection changed: ${dir}`) });
      for (let i = 0; i < 4097; i++) unlinkSync(join(dir, `junk-${i}`));
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
    }, 60000);

    it('capped carry v2 a member lock file and an unrelated name are no ledger state, a dangling link under a member name is (E17)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const member = f.members![0]; const row = v2Sign(f); const dir = pinned.ledgerDirOf(f.specsRoot);
      writeFileSync(join(dir, `${member}.jsonl.lock`), '');
      writeFileSync(join(dir, 'notes.txt'), '');
      expect(check(keys), 'a lock file and an unrelated name').toEqual(okLines(keys, f, row.id));
      symlinkSync(join(dir, 'gone'), join(dir, `${member}.jsonl`));
      expect(check(keys), 'a dangling link is present, never absent').toEqual(staleLines(keys, f, row.id));
    });

    it.each(['names-a-member', 'is-malformed'])('capped carry v2 the member check reads the manifest bytes the record pins: a manifest that %s is stale by the member words, not by a hash (E17)', fault => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const dir = pinned.ledgerDirOf(f.specsRoot); const manifest = join(dir, 'manifest.json');
      const original = JSON.parse(readFileSync(manifest, 'utf8'));
      const record = (bytes: string | null) => {
        const proof = JSON.parse(JSON.stringify(row.capped_carry));
        if (bytes !== null) { writeFileSync(manifest, bytes); for (const pin of proof.pins) if (pin.role === 'manifest') pin.sha256 = sha(manifest); }
        return { ...row, release: 'R1', capped_carry: proof };
      };
      expect(specCheck(specEnv(), keys, null, { records: [record(null)] }).lines, 'control: the record as signed').toEqual(okLines(keys, f, row.id));
      const out = specCheck(specEnv(), keys, null, { records: [record(fault === 'is-malformed' ? '{ not json' : JSON.stringify({ ...original, keys: { ...original.keys, [f.members![2]]: { spec: 1, plan: 1 } } }))] });
      expect(out.lines).toEqual(staleLines(keys, f, row.id));
      expect(out.answer.get(keys[0])).toEqual({ missing: expect.stringContaining(`capped evidence selection changed: ${dir}`) });
    });

    it('capped carry v2 the member check needs the pinned ledger folder itself: an alias of it is stale although every pinned file still reads (E17)', () => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const dir = pinned.ledgerDirOf(f.specsRoot); const moved = join(dirname(f.specsRoot), 'moved-ledgers');
      const proof = JSON.parse(JSON.stringify(row.capped_carry));
      for (const pin of proof.pins) if (typeof pin.path === 'string' && pin.path.startsWith(`${dir}/`)) pin.path = join(moved, pin.path.slice(dir.length + 1));
      renameSync(dir, moved);
      symlinkSync(moved, dir);
      const out = specCheck(specEnv(), keys, null, { records: [{ ...row, release: 'R1', capped_carry: proof }] });
      expect(out.lines).toEqual(staleLines(keys, f, row.id));
      expect(out.answer.get(keys[0])).toEqual({ missing: expect.stringContaining(`capped evidence selection changed: ${dir}`) });
    });

    const REVIEWED_WORDS = 'capped return Reviewed declaration disagrees with the current spec';
    const KEYS_WORDS = 'capped return Keys? declaration disagrees with the declared keys';
    const AGREEMENT = [['reviewed-wrong', REVIEWED_WORDS], ['keys-other', KEYS_WORDS], ['reviewed-doubled', REVIEWED_WORDS], ['keys-doubled', KEYS_WORDS]] as const;
    const AGREEMENT_CASES = (['spec', 'plan'] as const).flatMap(which => AGREEMENT.map(([fault, words]) => [which, fault, words] as const));
    const agreementLines = (fault: string, keys: string[], specSha: string): string[] => {
      const list = [...keys].sort().join(', ');
      return ({ 'reviewed-wrong': [`Reviewed: spec ${'e'.repeat(64)}`], 'keys-other': [`Keys: ${keys[0]}, HIMMEL-9999`], 'reviewed-doubled': [`Reviewed: spec ${specSha}`, `Reviewed: spec ${specSha}`],
        'keys-doubled': [`Keys: ${list}`, `Keys: ${list}`], control: [`Keys: ${list}`, `Reviewed: spec ${specSha}`] } as Record<string, string[]>)[fault];
    };
    const realProof = (f: V2Fixture) => JSON.parse(spawnSync(realBun, [expectedVerifier, 'capped-fold', '--keys', [...f.keys!].sort().join(','), '--spec', f.spec, '--plan', f.plan,
      '--spec-return', f.verdicts[0], '--plan-return', f.verdicts[1]], { encoding: 'utf8', timeout: 15000 }).stdout);
    function editReturn(f: V2Fixture, which: 'spec' | 'plan', lines: string[], proof: any): string {
      const i = which === 'spec' ? 0 : 1; const path = f.verdicts[i];
      writeFileSync(path, `${lines.join('\n')}\n${readFileSync(path, 'utf8')}`);
      proof.returns[i].sha256 = sha(path);
      proof.returns[i].return_sha = pinned.returnSha(readFileSync(path, 'utf8'));
      for (const pin of proof.pins) if (pin.path === path) pin.sha256 = sha(path);
      for (const c of proof.carried) if (c.kind === which) c.return_sha = proof.returns[i].return_sha;
      return path;
    }
    const refusalMessage = (run: () => unknown) => { try { run(); } catch (e) { return (e as Error).message; } return ''; };

    it.each(AGREEMENT_CASES)('capped carry v2 the bind refuses a %s return that disagrees with the declared keys or the spec at signing, with the agreement reason: %s (E10)', (which, fault, words) => {
      const f = v2Build({ builder: 'group' }); const proof = realProof(f);
      editReturn(f, which, agreementLines(fault, f.keys!, sha(f.spec)), proof);
      cappedSpawn.fn = () => JSON.stringify(proof);
      const message = refusalMessage(() => v2Sign(f));
      expect(message.endsWith(`; v2: ${words}`), message).toBe(true);
      expect(message, 'not a hash reason').not.toMatch(/binding disagrees|changed or unreadable/);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    it.each(['spec', 'plan'] as const)('capped carry v2 the bind signs a %s return whose Keys? and Reviewed lines agree, the control of E10', which => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const proof = realProof(f);
      editReturn(f, which, agreementLines('control', keys, sha(f.spec)), proof);
      cappedSpawn.fn = () => JSON.stringify(proof);
      const row = v2Sign(f);
      expect(row.capped_carry).toMatchObject({ schema: 2, anchor: f.anchor });
      expect(check(keys)).toEqual(okLines(keys, f, row.id));
    });

    it.each(AGREEMENT_CASES)('capped carry v2 the readback reads a %s return that disagrees with the declared keys or the spec stale, with the agreement reason: %s (E22)', (which, fault, words) => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const proof = JSON.parse(JSON.stringify(row.capped_carry));
      const path = editReturn(f, which, agreementLines(fault, keys, sha(f.spec)), proof);
      const record = { ...row, release: 'R1', verdicts: row.verdicts!.map(v => v.path === path ? { path, sha256: sha(path) } : v), capped_carry: proof };
      const out = specCheck(specEnv(), keys, null, { records: [record] });
      expect(out.lines).toEqual(staleLines(keys, f, row.id));
      const why = (out.answer.get(keys[0]) as { missing: string }).missing;
      expect(why.endsWith(words), why).toBe(true);
      expect(why, 'not a hash reason').not.toMatch(/binding disagrees|changed or unreadable/);
    });

    it.each(['spec', 'plan'] as const)('capped carry v2 the readback reads a %s return whose Keys? and Reviewed lines agree as fresh, the control of E22', which => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const proof = JSON.parse(JSON.stringify(row.capped_carry));
      const path = editReturn(f, which, agreementLines('control', keys, sha(f.spec)), proof);
      const record = { ...row, release: 'R1', verdicts: row.verdicts!.map(v => v.path === path ? { path, sha256: sha(path) } : v), capped_carry: proof };
      expect(specCheck(specEnv(), keys, null, { records: [record] }).lines).toEqual(okLines(keys, f, row.id));
    });

    const memberFolder = (shape: string) => {
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const dir = pinned.ledgerDirOf(f.specsRoot); const moved = join(dirname(f.specsRoot), 'moved-ledgers');
      const proof = JSON.parse(JSON.stringify(row.capped_carry));
      for (const pin of proof.pins) if (typeof pin.path === 'string' && pin.path.startsWith(`${dir}/`)) pin.path = join(moved, pin.path.slice(dir.length + 1));
      renameSync(dir, moved);
      writeFileSync(join(moved, `${f.members![0]}.jsonl`), '');
      if (shape === 'a plain file') writeFileSync(dir, '');
      if (shape === 'a symlink to a file') { const target = join(dirname(f.specsRoot), 'a-file'); writeFileSync(target, ''); symlinkSync(target, dir); }
      if (shape === 'a dangling symlink') symlinkSync(join(dirname(f.specsRoot), 'nowhere'), dir);
      if (shape === 'a directory that cannot be listed') { mkdirSync(dir); chmodSync(dir, 0o311); }
      try {
        const out = specCheck(specEnv(), keys, null, { records: [{ ...row, release: 'R1', capped_carry: proof }] });
        expect(out.lines).toEqual(staleLines(keys, f, row.id));
        expect(out.answer.get(keys[0])).toEqual({ missing: expect.stringContaining(`capped evidence selection changed: ${dir}`) });
      } finally { if (shape === 'a directory that cannot be listed') chmodSync(dir, 0o755); }
    };
    const memberTitle = 'capped carry v2 the member check refuses a pinned ledger folder that is %s, although every pinned file lives elsewhere and reads (E17)';
    it.each(['a plain file', 'a symlink to a file', 'a dangling symlink'])(memberTitle, memberFolder);
    it.skipIf(RUNS_AS_ROOT).each(['a directory that cannot be listed'])(memberTitle, memberFolder);

    it('capped carry v2 a doctored verifier answer whose pinned files moved with the ledger folder, now a plain file, is refused when the answer is checked, naming the folder (E17, the signing side)', () => {
      const f = v2Build({ builder: 'group' }); const dir = pinned.ledgerDirOf(f.specsRoot); const moved = join(dirname(f.specsRoot), 'moved-ledgers');
      armProof(p => {
        cpSync(dir, moved, { recursive: true });
        for (const pin of p.pins) if (typeof pin.path === 'string' && pin.path.startsWith(`${dir}/`)) pin.path = join(moved, pin.path.slice(dir.length + 1));
        rmSync(dir, { recursive: true });
        writeFileSync(dir, '');
        writeFileSync(join(moved, `${f.members![0]}.jsonl`), '');
      });
      expect(() => v2Sign(f)).toThrow(new RegExp(`; v2: capped evidence selection changed: ${dir}$`));
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });

    it('capped carry v2 a member ledger for the last key of the group makes the record stale and refuses at the signing recheck under the lock (E17, E25)', () => {
      const lock = v2Build({ builder: 'group' }); const last = lock.members!.at(-1) as string; const dir = pinned.ledgerDirOf(lock.specsRoot);
      expect(last, 'the last member sorts last').toBe([...lock.keys!].sort().at(-1));
      signingLock.fn = () => writeFileSync(join(dir, `${last}.jsonl`), '');
      try { expect(() => v2Sign(lock)).toThrow(new Error(`capped evidence selection changed: ${dir}`)); } finally { signingLock.fn = null; }
      noCappedRows();
      const f = v2Build({ builder: 'group' }); const keys = f.keys!; const row = v2Sign(f); const ledgers = pinned.ledgerDirOf(f.specsRoot);
      writeFileSync(join(ledgers, `${last}.jsonl`), '');
      expect(check(keys)).toEqual(staleLines(keys, f, row.id));
      expect(specCheck(specEnv(), keys, null).answer.get(keys[0])).toEqual({ missing: expect.stringContaining(`capped evidence selection changed: ${ledgers}`) });
    });

    it('capped carry v2 a member that exists when the verifier answer is checked is refused there, before the signing lock is taken (E17)', () => {
      const f = v2Build({ builder: 'group' }); const dir = pinned.ledgerDirOf(f.specsRoot); let locked = false;
      armProof(() => { writeFileSync(join(dir, `${f.members![0]}.jsonl`), ''); });
      signingLock.fn = () => { locked = true; };
      try { expect(() => v2Sign(f)).toThrow(new RegExp(`; v2: capped evidence selection changed: ${dir}$`)); } finally { signingLock.fn = null; }
      expect(locked, 'the signing lock was never taken').toBe(false);
      expect(attemptFlags()).toEqual(['--keys']);
      noCappedRows();
    });
  });

  describe('who signs each spec: the read side', () => {
    const LATER = '2026-10-22T10:00:00.000Z';
    const at = (iso: string, c: Ctx = sctx()): Ctx => ({ ...c, now: () => new Date(iso) });
    function put(row: Omit<OperatorRow, 'id'>, c: Ctx = sctx()): OperatorRow {
      const k = loadKey(c.keyPath);
      const path = join(c.dir, 'operator.jsonl');
      const n = readChain<OperatorRow>(path, k).rows.length + 1;
      return appendChain<OperatorRow>(path, k, { id: `O-${c.release}-${String(n).padStart(4, '0')}`, ...row });
    }
    const signer = (keys: string[] | undefined, who: 'chief' | 'operator', decision: string, ts = LATER, c: Ctx = sctx()) => put({
      kind: 'spec-signer', ts, decision, signer: who, ...(keys ? { keys } : {}), verbatim: `the operator's words, decision ${decision}`,
    }, c);
    const pinsOf = (r: OperatorRow) => {
      const { id: _i, prev: _p, mac: _m, ...rest } = r as OperatorRow & { release?: string };
      return rest;
    };
    const opSign = (from: OperatorRow, keys: string[], operatorKeys: string[], o: Partial<OperatorRow> = {}) => put({
      ...pinsOf(from), ts: LATER, keys, signer: 'operator', operator_keys: operatorKeys, decision: '1300', supersedes: from.id, ...o,
    });
    let mirrors = 0;
    function mirror(entries: Array<[string, string, string?]>, cursor?: object): string {
      const m = join(root, `mirror-${++mirrors}`);
      mkdirSync(m, { recursive: true });
      writeFileSync(join(m, '.cursor.json'), JSON.stringify(cursor ?? { lastSync: '2026-10-21T09:00:00.000Z' }));
      for (const [key, type, parent] of entries) {
        writeFileSync(join(m, `${key}.md`), ['---', `key: "${key}"`, `type: "${type}"`, ...(parent ? [`parent: "${parent}"`] : []), '---', ''].join('\n'));
      }
      return m;
    }
    const headed = (name: string, ticket: string | null, dir = join(root, 'specs')) => spec(name, dir,
      [`# ${ticket ?? 'K-4'}: a sliced design${ticket ? `\n\n- Ticket: ${ticket}` : ''}`]);

    it('R2 read half: a chief row and a later mark on K: spec-check prints SPEC-NEEDS-OPERATOR K with the chief row\'s id and the mark\'s id (I1)', () => {
      declared();
      const p = spec();
      const r = sign(sctx(), ['K-1'], p);
      expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
      const m = signer(['K-1'], 'operator', '1170');
      const out = specCheck(specEnv(), ['K-1'], null);
      expect(out.lines).toEqual([`SPEC-NEEDS-OPERATOR K-1 ${p} ${r.id} ${m.id}`]);
      expect(out.ok).toBe(false);
      expect(out.answer.get('K-1')).toEqual({ missing: `K-1 needs the operator's own signature (${m.id}); the chief's signature ${r.id} does not count` });
    });

    it('a chief-signed parent row read by its sub-task, with a mark on the parent: the sub-task reads SPEC-NEEDS-OPERATOR naming that mark (I1)', () => {
      declared();
      const p = spec();
      const r = sign(sctx(), ['K-1'], p);
      const m = mirror([['K-1', 'Task'], ['K-2', 'Subtask', 'K-1']]);
      expect(check(['K-2'], m)).toEqual([`SPEC ok K-2 ${p} ${r.id}`]);
      const mark = signer(['K-1'], 'operator', '1170');
      expect(check(['K-1', 'K-2'], m)).toEqual([
        `SPEC-NEEDS-OPERATOR K-1 ${p} ${r.id} ${mark.id}`, `SPEC-NEEDS-OPERATOR K-2 ${p} ${r.id} ${mark.id}`,
      ]);
    });

    it('a chief-signed parent row read by its sub-task, with a mark on the sub-task only: the sub-task reads SPEC-NEEDS-OPERATOR naming that mark (I1)', () => {
      declared();
      const p = spec();
      const r = sign(sctx(), ['K-1'], p);
      const m = mirror([['K-1', 'Task'], ['K-2', 'Subtask', 'K-1']]);
      const mark = signer(['K-2'], 'operator', '1170');
      expect(check(['K-1', 'K-2'], m)).toEqual([`SPEC ok K-1 ${p} ${r.id}`, `SPEC-NEEDS-OPERATOR K-2 ${p} ${r.id} ${mark.id}`]);
    });

    function sliced() {
      declared();
      const p = headed('V-1-sliced.md', 'V-1');
      const q = headed('K-4-other.md', null, join(root, 'specs-other'));
      const r1 = sign(sctx(), ['V-1', 'K-1', 'K-2'], p);
      const r2 = sign(sctx(), ['K-3'], p);
      const r3 = sign(sctx(), ['K-4'], q);
      const m = mirror(['V-1', 'K-1', 'K-2', 'K-3', 'K-4'].map((k) => [k, 'Task'] as [string, string]));
      const mark = signer(['V-1'], 'operator', '1170');
      return { p, q, r1, r2, r3, m, mark };
    }

    it('R5 read half: chief rows for V, K1, K2 and for K3 alone on a spec whose header names V, then a mark on V: all four read SPEC-NEEDS-OPERATOR naming the mark; a spec whose header does not name V keeps SPEC ok (I18 b)', () => {
      const { p, q, r1, r2, r3, m, mark } = sliced();
      const out = specCheck(specEnv(), ['V-1', 'K-1', 'K-2', 'K-3', 'K-4'], m);
      expect(out.lines).toEqual([
        `SPEC-NEEDS-OPERATOR V-1 ${p} ${r1.id} ${mark.id}`,
        `SPEC-NEEDS-OPERATOR K-1 ${p} ${r1.id} ${mark.id}`,
        `SPEC-NEEDS-OPERATOR K-2 ${p} ${r1.id} ${mark.id}`,
        `SPEC-NEEDS-OPERATOR K-3 ${p} ${r2.id} ${mark.id}`,
        `SPEC ok K-4 ${q} ${r3.id}`,
      ]);
      expect(out.answer.get('K-3')).toEqual({
        missing: `K-3 needs the operator's own signature: V-1 is marked (${mark.id}) and ${r2.id} covers it; the chief's signature ${r2.id} does not count`,
      });
    });

    it('R6 read half: an operator row for V, K1, K2 superseding the first row, operator_keys [V], reads SPEC ok for V, K1, K2, and for K3 because it signs V on the same spec bytes (I18 b)', () => {
      const { p, r1, r2, m } = sliced();
      const op = opSign(r1, ['V-1', 'K-1', 'K-2'], ['V-1']);
      expect(check(['V-1', 'K-1', 'K-2', 'K-3'], m)).toEqual([
        `SPEC ok V-1 ${p} ${op.id}`, `SPEC ok K-1 ${p} ${op.id}`, `SPEC ok K-2 ${p} ${op.id}`, `SPEC ok K-3 ${p} ${r2.id}`,
      ]);
    });

    it('R6 read half: with the operator row on different spec bytes, K3 reads SPEC-NEEDS-OPERATOR (I18 b)', () => {
      const { r1, r2, p, m, mark } = sliced();
      const other = spec('V-1-resliced.md', join(root, 'specs-re'), ['# V-1: a resliced design\n\n- Ticket: V-1']);
      const op = opSign(r1, ['V-1', 'K-1', 'K-2'], ['V-1'], { spec_path: other, spec_sha256: pinnedSha(other).sha256 });
      expect(check(['V-1', 'K-3'], m)).toEqual([`SPEC ok V-1 ${other} ${op.id}`, `SPEC-NEEDS-OPERATOR K-3 ${p} ${r2.id} ${mark.id}`]);
    });

    it('headerTickets reads the front matter tickets line and the - Ticket: and Key: lines before the first ## heading, and no line after it (I18)', () => {
      const text = [
        '---', 'tickets: HIMMEL-10477, HIMMEL-10478', 'date: 2026-11-21', '---', '# HIMMEL-10641: a slice', '',
        '- Ticket: HIMMEL-10641', '- Tickets: HIMMEL-1 and PR 5749', 'Key: SALUS-3', 'Keys: HIMMEL-2', 'tickets: HIMMEL-77',
        'See HIMMEL-55 in passing.', '', '## Section', '- Ticket: HIMMEL-99', 'Key: HIMMEL-98', '',
      ].join('\n');
      expect(headerTickets(text)).toEqual(['HIMMEL-10477', 'HIMMEL-10478', 'HIMMEL-10641', 'HIMMEL-1', 'SALUS-3', 'HIMMEL-2']);
      expect(headerTickets('# no header\n\n## Body\n- Ticket: HIMMEL-9\n')).toEqual([]);
    });

    it('station flip on real chain rows: a chief row, then a station operator record, reads SPEC ok; a chief row written after it reads SPEC-NEEDS-OPERATOR naming the station record (I11)', () => {
      declared();
      const a = spec('K-1-a.md');
      const b = spec('K-2-b.md', join(root, 'specs-b'));
      const r1 = sign(sctx(), ['K-1'], a);
      const r2 = sign(at('2026-10-23T10:00:00.000Z'), ['K-2'], b);
      const station = signer(undefined, 'operator', '1171');
      expect(check(['K-1', 'K-2'])).toEqual([`SPEC ok K-1 ${a} ${r1.id}`, `SPEC-NEEDS-OPERATOR K-2 ${b} ${r2.id} ${station.id}`]);
    });

    it('a marked parent signed by the operator gives SPEC ok for its sub-task that reads the parent\'s row (I17)', () => {
      declared();
      const p = spec();
      const r = sign(sctx(), ['K-1'], p);
      const m = mirror([['K-1', 'Task'], ['K-2', 'Subtask', 'K-1']]);
      signer(['K-1'], 'operator', '1170');
      const op = opSign(r, ['K-1'], ['K-1']);
      expect(check(['K-1', 'K-2'], m)).toEqual([`SPEC ok K-1 ${p} ${op.id}`, `SPEC ok K-2 ${p} ${op.id}`]);
      signer(['K-2'], 'operator', '1171');
      expect(check(['K-2'], m)).toEqual([`SPEC ok K-2 ${p} ${op.id}`]);
    });

    it('a broken chain or an unloadable key in any declared release: a chief row reads SPEC-SIGNER-UNKNOWN naming why; an operator row still reads SPEC ok (I1, I15)', () => {
      declared();
      declared(r2());
      const p = spec();
      const r = sign(sctx(), ['K-1'], p);
      const q = spec('K-2-op.md', join(root, 'specs-op'));
      const chief2 = sign(sctx(), ['K-2'], q);
      const op = opSign(chief2, ['K-2'], ['K-2']);
      const chain = join(root, 'release', 'R2', 'operator.jsonl');
      const good = readFileSync(chain, 'utf8');
      writeFileSync(chain, `${good}not json\n`);
      const out = specCheck(specEnv(), ['K-1', 'K-2'], null);
      expect(out.lines).toEqual([
        expect.stringMatching(new RegExp(`^SPEC-SIGNER-UNKNOWN K-1 ${r.id} release R2: operator\\.jsonl does not verify \\(line \\d+: unparseable\\)$`)),
        `SPEC ok K-2 ${q} ${op.id}`,
      ]);
      expect(out.answer.get('K-1')).toEqual({ missing: expect.stringMatching(/^signer records unreadable: release R2: /) });
      writeFileSync(chain, good);
      expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
      rmSync(join(root, 'keys', 'R2.key'));
      expect(check(['K-1', 'K-2'])).toEqual([
        expect.stringMatching(new RegExp(`^SPEC-SIGNER-UNKNOWN K-1 ${r.id} release R2: its key does not load`)),
        `SPEC ok K-2 ${q} ${op.id}`,
      ]);
    });

    it('a mirror whose cursor reads complete false changes no answer with no record, a station-only record or a key with its own record; with a parent mark only a key missing from the mirror and holding no record of its own reads SPEC-SIGNER-UNKNOWN (I15, P2)', () => {
      declared();
      const a = spec('K-1-a.md');
      const b = spec('K-5-b.md', join(root, 'specs-b'));
      const c = spec('K-6-c.md', join(root, 'specs-c'));
      const r1 = sign(sctx(), ['K-1'], a);
      const r5 = sign(sctx(), ['K-5'], b);
      const r6 = sign(sctx(), ['K-6'], c);
      const m = mirror([['K-1', 'Task'], ['P-9', 'Task']], { lastSync: '2026-10-21T09:00:00.000Z', complete: false });
      const kept = [`SPEC ok K-1 ${a} ${r1.id}`, `SPEC ok K-5 ${b} ${r5.id}`, `SPEC ok K-6 ${c} ${r6.id}`];
      expect(check(['K-1', 'K-5', 'K-6'], m)).toEqual(kept);
      signer(undefined, 'chief', '1160', '2026-10-01T00:00:00.000Z');
      expect(check(['K-1', 'K-5', 'K-6'], m)).toEqual(kept);
      expect(check(['K-1', 'K-5', 'K-6'], null)).toEqual(kept);
      signer(['K-5'], 'chief', '1161');
      expect(check(['K-5'], m)).toEqual([kept[1]]);
      signer(['P-9'], 'operator', '1170');
      expect(check(['K-1', 'K-5', 'K-6'], m)).toEqual([
        kept[0], kept[1], expect.stringMatching(new RegExp(`^SPEC-SIGNER-UNKNOWN K-6 ${r6.id} K-6 is not in the Jira mirror`)),
      ]);
    });

    it('with --kinds spec-review, a marked key\'s fresh spec-review row reads SPEC ok (P5)', () => {
      declared();
      const p = spec();
      const rv = put({ kind: 'spec-review', ts: LATER, decision: null, keys: ['K-1'], spec_path: p, spec_sha256: pinnedSha(p).sha256, verdicts: [] });
      signer(['K-1'], 'operator', '1170');
      expect(specCheck(specEnv(), ['K-1'], null, { kinds: ['spec-review'] }).lines).toEqual([`SPEC ok K-1 ${p} ${rv.id}`]);
    });

    it('with no spec-signer record, every fixture spec row keeps its spec-check line, legacy rows with no signer included (I9)', () => {
      declared();
      declared(r2());
      const a = spec('K-1-a.md');
      const b = spec('K-2-b.md', join(root, 'specs-b'));
      const c = spec('K-3-c.md', join(root, 'specs-c'));
      const legacy = sign(sctx(), ['K-1'], a);
      const stale = sign(r2(), ['K-2'], b);
      writeFileSync(b, `${readFileSync(b, 'utf8')}\nedited\n`);
      const chief = put({ ...pinsOf(sign(sctx(), ['K-3'], c)), ts: LATER, keys: ['K-3'], signer: 'chief', supersedes: 'O-R1-0003' });
      const m = mirror([['K-1', 'Task'], ['K-4', 'Subtask', 'K-1']]);
      const want = [`SPEC ok K-1 ${a} ${legacy.id}`, `SPEC-STALE K-2 ${b} ${stale.id}`, `SPEC ok K-3 ${c} ${chief.id}`, `SPEC ok K-4 ${a} ${legacy.id}`, 'NO-SPEC K-9'];
      expect(check(['K-1', 'K-2', 'K-3', 'K-4', 'K-9'], m)).toEqual(want);
      expect(specCheck(specEnv(), ['K-1', 'K-2', 'K-3', 'K-4', 'K-9'], m, { signer: readSignerState(specEnv(), m) }).lines).toEqual(want);
      expect(readSignerState(specEnv(), m)).toEqual({ records: [], unreadable: null, issues: null });
    });

    it('printer shape: specCheck driven into each verb prints a line that matches the fixture\'s full line for that verb field for field, ids normalised, a voided key\'s line included; the fixture holds every verb of SPEC_CHECK_VERBS (I14)', () => {
      const fixture = readFileSync(join(fileURLToPath(new URL('../../../../', import.meta.url)), 'scripts/handover/chief-kit/fixtures/spec-check-lines.txt'), 'utf8')
        .split('\n').filter(Boolean).map((l) => l.split('\t'));
      const verbOf = (line: string) => [...SPEC_CHECK_VERBS].sort((x, y) => y.length - x.length).find((v) => line === v || line.startsWith(`${v} `));
      const shape = (line: string, path: string | null) => {
        const verb = verbOf(line) as string;
        const t = (path ? line.slice(verb.length).replace(path, '<path>') : line.slice(verb.length)).trim().split(' ');
        if (verb === 'SPEC-SIGNER-UNKNOWN') return [verb, '<K>', '<id>', '<why>'];
        return [verb, '<K>', ...t.slice(1).map((x) => (x === '<path>' ? x : '<id>'))];
      };
      const fullLine = (verb: string) => fixture.find(([want, line]) => want !== 'none' && verbOf(line) === verb)?.[1];
      for (const v of SPEC_CHECK_VERBS) expect(fullLine(v), `fixture line for ${v}`).toBeDefined();
      const { p, r1 } = sliced();
      const m2 = mirror(['V-1', 'K-1', 'K-7', 'K-8', 'K-9'].map((k) => [k, 'Task'] as [string, string]));
      const s = spec('K-7-stale.md', join(root, 'specs-stale'));
      sign({ ...sctx(), mirrorRoot: m2 }, ['K-7'], s);
      writeFileSync(s, `${readFileSync(s, 'utf8')}\nedited\n`);
      const ok = spec('K-8-ok.md', join(root, 'specs-ok'));
      sign({ ...sctx(), mirrorRoot: m2 }, ['K-8'], ok);
      const got = specCheck(specEnv(), ['K-8', 'K-7', 'K-9', 'V-1', 'K-1'], m2).lines;
      const paths = [ok, s, null, p, p];
      expect(got.map(verbOf)).toEqual(['SPEC ok', 'SPEC-STALE', 'NO-SPEC', 'SPEC-NEEDS-OPERATOR', 'SPEC-NEEDS-OPERATOR']);
      expect(got[4]).toContain(r1.id);
      const fixturePath = (line: string) => /\/state\/specs\/\S+/.exec(line)?.[0] ?? null;
      got.forEach((line, i) => {
        const want = fullLine(verbOf(line) as string) as string;
        expect(shape(line, paths[i])).toEqual(shape(want, fixturePath(want)));
      });
      writeFileSync(join(root, 'release', 'R1', 'operator.jsonl'), `${readFileSync(join(root, 'release', 'R1', 'operator.jsonl'), 'utf8')}not json\n`);
      const [unknown] = specCheck(specEnv(), ['K-8'], m2).lines;
      expect(verbOf(unknown)).toBe('SPEC-SIGNER-UNKNOWN');
      const want = fullLine('SPEC-SIGNER-UNKNOWN') as string;
      expect(shape(unknown, null)).toEqual(shape(want, null));
    });

    describe('the write side: the record, --signer and the alert', () => {
      let alerts: SignerAlert[];
      beforeEach(() => { alerts = []; });
      const ok = (a: SignerAlert) => { alerts.push(a); return 0; };
      const exits = (rc: number) => (a: SignerAlert) => { alerts.push(a); return rc; };
      function decide(n: string, ...paras: string[]) {
        const d = join(root, 'specs', 'decisions');
        mkdirSync(d, { recursive: true });
        writeFileSync(join(d, `verbatim-decision-${n}-operator-10-21.txt`), [`Decision ${n}, operator, 2026-10-21.`, ...paras].join('\n\n') + '\n');
      }
      const rowsOf = (kind: string, c: Ctx = sctx()) => readChain<OperatorRow>(join(c.dir, 'operator.jsonl'), loadKey(c.keyPath)).verified.filter((r) => r.kind === kind);
      const withMirror = (m: string, c: Ctx = sctx()): Ctx => ({ ...c, mirrorRoot: m });
      const record = (c: Ctx, o: Partial<Parameters<typeof specSigner>[1]> & { decision: string; words: string }) => specSigner(c, { signer: 'operator', alert: ok, ...o });
      const opSignSpec = (c: Ctx, keys: string[], p: string, decision: string, words: string, extra: Partial<Parameters<typeof signSpec>[1]> = {}) =>
        sign(c, keys, p, { signer: 'operator', decision, words, verbatim: undefined, alert: ok, ...extra });
      const MARK_K1 = 'K-1 is the operator\'s own to sign, every spec of it';
      const markK1 = (c: Ctx = sctx()) => { decide('1170', MARK_K1); return record(c, { keys: ['K-1'], decision: '1170', words: MARK_K1 }).row; };

      it('R1 chief-signed passes: no spec-signer record, signer chief, spec-check SPEC ok, the row stores signer chief', () => {
        declared();
        const p = spec();
        const r = sign(sctx(), ['K-1'], p);
        expect(r.signer).toBe('chief');
        expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${r.id}`]);
      });

      it('R2 write half: a mark on K: signSpec with signer chief throws the mark text naming the mark (I2)', () => {
        declared();
        const mark = markK1();
        expect(mark).toMatchObject({ kind: 'spec-signer', keys: ['K-1'], signer: 'operator', decision: '1170', verbatim: MARK_K1, words: 1 });
        expect(() => sign(sctx(), ['K-1'], spec())).toThrow(`release operator spec: K-1 is marked for the operator's own signature (${mark.id}, decision 1170); a chief signature is refused. The operator signs it: jira release operator spec R1 --keys K-1 ... --signer operator --decision <n> --words "<his words naming K-1>" [--supersedes <live spec row>]; or he lifts the mark: jira release operator spec-signer R1 --signer chief --keys K-1 --decision <n> --words "<his words>"`);
        expect(rowsOf('spec')).toEqual([]);
      });

      it('R3 operator-marked passes his own signature: superseding the chief row, words name the key from a newer decision, alert queued, operator_keys holds the key, SPEC ok (I7)', () => {
        declared();
        const p = spec();
        const r = sign(sctx(), ['K-1'], p);
        markK1();
        const words = 'the operator signs K-1 himself, spec and plan';
        decide('1180', words);
        alerts = [];
        const op = opSignSpec(withMirror(mirror([['K-1', 'Task']])), ['K-1'], p, '1180', words, { supersedes: r.id });
        expect(op).toMatchObject({ signer: 'operator', operator_keys: ['K-1'], decision: '1180', verbatim: words, words: 1, supersedes: r.id });
        expect(alerts).toEqual([{ kind: 'signature', scope: 'K-1', signer: 'operator', decision: '1180', words, notes: [], chiefSigned: [] }]);
        expect(check(['K-1'])).toEqual([`SPEC ok K-1 ${p} ${op.id}`]);
      });

      it('R4 slice-only signing refused: a mark on V; signSpec with signer chief and --keys K1,K2 on a spec whose header names V throws the header text naming V and the mark, writes no row and calls no alert; the same spec signed while V is unmarked writes its row (I18 a)', () => {
        declared();
        const p = headed('V-1-sliced.md', 'V-1');
        const before = sign(sctx(), ['K-1', 'K-2'], p);
        expect(before.keys).toEqual(['K-1', 'K-2']);
        const words = 'V-1 is the operator\'s to sign, slices and all';
        decide('1170', words);
        const m = mirror(['V-1', 'K-1', 'K-2', 'K-3'].map((k) => [k, 'Task'] as [string, string]));
        const mark = record(withMirror(m), { keys: ['V-1'], decision: '1170', words }).row;
        alerts = [];
        expect(() => sign(withMirror(m), ['K-3'], p)).toThrow(`release operator spec: the spec names V-1 in its header, and V-1 is marked for the operator's own signature (${mark.id}, decision 1170); a chief signature for K-3 on this spec is refused. The operator signs it with V-1 among the keys: jira release operator spec R1 --keys V-1,K-3 ... --signer operator --decision <n> --words "<his words naming V-1>" [--supersedes <live spec row of V-1>]; or he lifts the mark: jira release operator spec-signer R1 --signer chief --keys V-1 --decision <n> --words "<his words>"`);
        expect(rowsOf('spec').map((r) => r.id)).toEqual([before.id]);
        expect(alerts).toEqual([]);
      });

      function slicedRows() {
        declared();
        const p = headed('V-1-sliced.md', 'V-1');
        const q = headed('K-4-other.md', null, join(root, 'specs-other'));
        const r1 = sign(sctx(), ['V-1', 'K-1', 'K-2'], p);
        const r2 = sign(sctx(), ['K-3'], p);
        const r3 = sign(sctx(), ['K-4'], q);
        const m = mirror(['V-1', 'K-1', 'K-2', 'K-3', 'K-4', 'K-5', 'K-9'].map((k) => [k, 'Task'] as [string, string]));
        return { p, q, r1, r2, r3, m, c: withMirror(m) };
      }
      const MARK_V1 = 'V-1 is the operator\'s to sign, slices and all';

      it('R5 write half: a mark on V after the R5 rows: the alert argument and stdout name both rows with the keys the chief signed in each; a mark on a ticket no row covers says voids no signature (I18 c)', () => {
        const { r1, r2, c } = slicedRows();
        decide('1170', MARK_V1);
        const out = record(c, { keys: ['V-1'], decision: '1170', words: MARK_V1 });
        const voids = [`V-1 mark voids ${r1.id} for V-1, K-1, K-2`, `V-1 mark voids ${r2.id} for K-3`];
        expect(out.notes).toEqual(voids);
        expect(alerts).toEqual([{ kind: 'record', scope: 'V-1', signer: 'operator', decision: '1170', words: MARK_V1, notes: voids, chiefSigned: [] }]);
        const nine = 'K-9 is the operator\'s to sign from now on';
        decide('1171', nine);
        expect(record(c, { keys: ['K-9'], decision: '1171', words: nine }).notes).toEqual(['K-9 mark voids no signature']);
      });

      it('R6 write half: the operator signs --keys V,K1,K2 --supersedes R with words naming V only; an operator row leaving a key to the chief while the header names V outside operator_keys is refused; one signing every key himself is written (I7, I18 a, b)', () => {
        const { p, r1, r2, c } = slicedRows();
        decide('1170', MARK_V1);
        const mark = record(c, { keys: ['V-1'], decision: '1170', words: MARK_V1 }).row;
        const words = 'the operator signs V-1 on this spec himself';
        const half = 'the operator signs K-3 on this spec himself';
        const both = 'the operator signs K-3 and K-5 on this spec himself';
        decide('1180', words, half, both);
        alerts = [];
        const op = opSignSpec(c, ['V-1', 'K-1', 'K-2'], p, '1180', words, { supersedes: r1.id });
        expect(op.operator_keys).toEqual(['V-1']);
        expect(alerts).toEqual([{ kind: 'signature', scope: 'V-1', signer: 'operator', decision: '1180', words, notes: [], chiefSigned: ['K-1', 'K-2'] }]);
        expect(specCheck(specEnv(), ['V-1', 'K-1', 'K-2', 'K-3'], c.mirrorRoot).lines).toEqual([
          `SPEC ok V-1 ${p} ${op.id}`, `SPEC ok K-1 ${p} ${op.id}`, `SPEC ok K-2 ${p} ${op.id}`, `SPEC ok K-3 ${p} ${r2.id}`,
        ]);
        alerts = [];
        expect(() => opSignSpec(c, ['K-3', 'K-5'], p, '1180', half, { supersedes: r2.id }))
          .toThrow(`release operator spec: the spec names V-1 in its header, and V-1 is marked for the operator's own signature (${mark.id}, decision 1170); a chief signature for K-5 on this spec is refused.`);
        expect(alerts).toEqual([]);
        const all = opSignSpec(c, ['K-3', 'K-5'], p, '1180', both, { supersedes: r2.id });
        expect(all.operator_keys).toEqual(['K-3', 'K-5']);
      });

      it('a station operator default: signSpec with signer chief throws the station text naming the station record (I2)', () => {
        declared();
        const words = 'the operator signs every core spec himself from now on';
        decide('1171', words);
        const station = record(sctx(), { decision: '1171', words }).row;
        expect(station.keys).toBeUndefined();
        expect(() => sign(at(LATER), ['K-1'], spec())).toThrow(`release operator spec: the station default (${station.id}, decision 1171) is the operator's own signature; a chief signature is refused. The operator signs it: jira release operator spec R1 --keys K-1 ... --signer operator --decision <n> --words "<his words naming K-1>" [--supersedes <live spec row>]; or he sets the default back: jira release operator spec-signer R1 --signer chief --decision <n> --words "<his words>"`);
      });

      it('a mark on a parent names the chief-signed row of its sub-task that the mark voids', () => {
        declared();
        const c = withMirror(mirror([['K-1', 'Task'], ['K-2', 'Subtask', 'K-1']]));
        const r = sign(c, ['K-2'], spec());
        decide('1170', MARK_K1);
        expect(record(c, { keys: ['K-1'], decision: '1170', words: MARK_K1 }).notes).toEqual([`K-1 mark voids ${r.id} for K-2`]);
      });

      it('a marked parent: signSpec with signer chief for its sub-task throws naming the parent\'s mark (I2)', () => {
        declared();
        const c = withMirror(mirror([['K-1', 'Task'], ['K-2', 'Subtask', 'K-1']]));
        const mark = markK1(c);
        expect(() => sign(c, ['K-2'], spec())).toThrow(`release operator spec: K-2 is marked for the operator's own signature (${mark.id}, decision 1170)`);
      });

      it('a spec-signer record from a chief-spawned worker is refused by the fence and writes no row (I3)', () => {
        declared();
        decide('1170', MARK_K1);
        expect(() => record(sctx({ ...specEnv(), HIMMEL_CONSOLE_LEG: '1' }), { keys: ['K-1'], decision: '1170', words: MARK_K1 })).toThrow(/chief-spawned worker/);
        expect(rowsOf('spec-signer')).toEqual([]);
        expect(alerts).toEqual([]);
      });

      it('spec-signer words not in the decision file, in a chief gloss, or not naming a key are refused; station chief words without chief and sign are refused (I4)', () => {
        declared();
        decide('1170', MARK_K1, 'Reading: K-1 is the operator\'s own to sign now', 'the operator lets go of this whole station rule', 'the chief signs every spec again, as before');
        const refused = (o: { keys?: string[]; signer?: 'chief' | 'operator'; words: string }, want: RegExp) =>
          expect(() => record(sctx(), { decision: '1170', ...o })).toThrow(want);
        refused({ keys: ['K-1'], words: 'K-1 is mine, the operator said so' }, /is not in the decision file/);
        refused({ keys: ['K-1'], words: 'Reading: K-1 is the operator\'s own to sign now' }, /the chief's gloss/);
        refused({ keys: ['K-1', 'K-2'], words: MARK_K1 }, /release operator spec-signer: the words do not name K-2/);
        refused({ signer: 'chief', words: 'the operator lets go of this whole station rule' }, /a station default of chief needs words holding both "chief" and "sign"/);
        expect(rowsOf('spec-signer')).toEqual([]);
        expect(alerts).toEqual([]);
        expect(record(sctx(), { signer: 'chief', decision: '1170', words: 'the chief signs every spec again, as before' }).row.signer).toBe('chief');
      });

      it('I5: a lift that does not outrank K\'s own and parent\'s key records is refused; a station chief record that does not outrank the newest station record is refused; a mark older than the station record is written and binds; an exact repeat returns the existing row, runs no outranks and calls no second alert', () => {
        declared();
        const c = withMirror(mirror([['K-1', 'Task'], ['K-2', 'Subtask', 'K-1']]));
        markK1(c);
        decide('1160', 'K-2 goes back to the chief to sign', 'the chief signs every spec at this station');
        decide('1171', 'the operator signs every core spec himself from now on');
        decide('1150', 'K-2 is the operator\'s own to sign as well');
        expect(() => record(c, { signer: 'chief', keys: ['K-2'], decision: '1160', words: 'K-2 goes back to the chief to sign' }))
          .toThrow(/release operator spec-signer: decision 1160 does not outrank the signer records of K-2/);
        record(c, { decision: '1171', words: 'the operator signs every core spec himself from now on' });
        expect(() => record(c, { signer: 'chief', decision: '1160', words: 'the chief signs every spec at this station' }))
          .toThrow(/release operator spec-signer: decision 1160 does not outrank the station records/);
        const old = record(c, { keys: ['K-2'], decision: '1150', words: 'K-2 is the operator\'s own to sign as well' }).row;
        expect(() => sign(at(LATER, c), ['K-2'], spec())).toThrow(`K-2 is marked for the operator's own signature (${old.id}, decision 1150)`);
        decide('1190', 'K-2 goes back to the chief, the operator said');
        const lift = record(c, { signer: 'chief', keys: ['K-2'], decision: '1190', words: 'K-2 goes back to the chief, the operator said' });
        const n = alerts.length;
        const again = record(c, { signer: 'chief', keys: ['K-2'], decision: '1190', words: 'K-2 goes back to the chief, the operator said' });
        expect(again.row.id).toBe(lift.row.id);
        expect(alerts).toHaveLength(n);
        expect(rowsOf('spec-signer')).toHaveLength(4);
      });

      it('I6: a failing alert writes no chief record and no operator signature; no callback, a held key or a changed verdict refuses before any alert; a failing mark alert still writes with a WARN; an emergency key carries the bypass note', () => {
        declared();
        const m = mirror([['K-1', 'Task'], ['K-7', 'Task'], ['K-8', 'Task']]);
        writeFileSync(join(m, 'K-8.md'), '---\nkey: "K-8"\ntype: "Bug"\npriority: "Highest"\n---\n');
        const c = withMirror(m);
        decide('1160', 'the chief signs every spec at this station');
        for (const rc of [1, 77]) {
          expect(() => record(c, { signer: 'chief', decision: '1160', words: 'the chief signs every spec at this station', alert: exits(rc) }))
            .toThrow(`release operator spec-signer: the operator alert exited ${rc}${rc === 77 ? ' (the send was refused)' : ''}; no record written`);
        }
        expect(rowsOf('spec-signer')).toEqual([]);
        const p = spec();
        const r = sign(c, ['K-1'], p);
        const mark = markK1(c);
        const words = 'the operator signs K-1 himself, spec and plan';
        decide('1180', words);
        alerts = [];
        expect(() => opSignSpec(c, ['K-1'], p, '1180', words, { supersedes: r.id, alert: exits(1) })).toThrow('release operator spec: the operator alert exited 1; no record written');
        expect(() => opSignSpec(c, ['K-1'], p, '1180', words, { supersedes: r.id, alert: undefined })).toThrow(/--signer operator needs the operator alert/);
        expect(alerts).toHaveLength(1);
        expect(() => opSignSpec(c, ['K-1'], p, '1180', words)).toThrow(`K-1 is already signed in ${r.id}`);
        const v = [verdict(p, 'spec', 'SPEC CLEAN'), verdict(p, 'plan', 'PLAN CLEAN')];
        signingLock.fn = () => writeFileSync(v[0], 'the critic\'s return\n\nSPEC CLEAN\nedited\n');
        expect(() => opSignSpec(c, ['K-1'], p, '1180', words, { supersedes: r.id, verdicts: v })).toThrow(/changed while it was checked/);
        expect(alerts).toHaveLength(1);
        expect(rowsOf('spec').map((x) => x.id)).toEqual([r.id]);
        const seven = 'K-7 is the operator\'s own to sign now';
        const eight = 'K-8 is the operator\'s own to sign now';
        decide('1181', seven, eight);
        const warned = record(c, { keys: ['K-7'], decision: '1181', words: seven, alert: exits(1) });
        expect(warned.warn).toBe('WARN release operator spec-signer: the operator alert exited 1; the mark is written anyway');
        expect(rowsOf('spec-signer').map((x) => x.id)).toEqual([mark.id, warned.row.id]);
        alerts = [];
        const bug = record(c, { keys: ['K-8'], decision: '1181', words: eight });
        expect(bug.notes).toEqual(['K-8 bypassed (emergency Bug at Highest): the mark does not bind while it is', 'K-8 mark voids no signature']);
        expect(alerts[0].notes).toEqual(bug.notes);
      });

      it('I7: operator words from the mark\'s own decision or an older one are refused; words not naming a marked key are refused; an unmarked key the words do not name is signed as chief and voided by a later mark', () => {
        declared();
        const c = withMirror(mirror([['K-1', 'Task'], ['K-6', 'Task']]));
        const p = spec();
        const r = sign(c, ['K-1', 'K-6'], p);
        const mark = markK1(c);
        decide('1100', 'the operator signs K-1 himself, an old word');
        expect(() => opSignSpec(c, ['K-1', 'K-6'], p, '1170', MARK_K1, { supersedes: r.id })).toThrow(/decision 1170 does not outrank the signer records of K-1/);
        expect(() => opSignSpec(c, ['K-1', 'K-6'], p, '1100', 'the operator signs K-1 himself, an old word', { supersedes: r.id })).toThrow(/decision 1100 does not outrank/);
        decide('1180', 'the operator signs K-6 himself, not the other', 'the operator signs K-1 himself, spec and plan');
        expect(() => opSignSpec(c, ['K-1', 'K-6'], p, '1180', 'the operator signs K-6 himself, not the other', { supersedes: r.id }))
          .toThrow(`release operator spec: K-1 is marked for the operator's own signature (${mark.id}, decision 1170); a chief signature is refused.`);
        expect(alerts).toHaveLength(1);
        const op = opSignSpec(c, ['K-1', 'K-6'], p, '1180', 'the operator signs K-1 himself, spec and plan', { supersedes: r.id });
        expect(op.operator_keys).toEqual(['K-1']);
        expect(specCheck(specEnv(), ['K-1', 'K-6'], c.mirrorRoot).lines).toEqual([`SPEC ok K-1 ${p} ${op.id}`, `SPEC ok K-6 ${p} ${op.id}`]);
        decide('1190', 'K-6 is the operator\'s own to sign now');
        const six = record(c, { keys: ['K-6'], decision: '1190', words: 'K-6 is the operator\'s own to sign now' });
        expect(six.notes).toEqual([`K-6 mark voids ${op.id} for K-6`]);
        expect(specCheck(specEnv(), ['K-6'], c.mirrorRoot).lines).toEqual([`SPEC-NEEDS-OPERATOR K-6 ${p} ${op.id} ${six.row.id}`]);
      });

      it('while the state is unreadable, signSpec refuses every signature and the spec-signer verb refuses a mark and a lift, and no alert callback is called (I2, I15)', () => {
        declared();
        declared(r2());
        const p = spec();
        const r = sign(sctx(), ['K-1'], p);
        decide('1170', MARK_K1, 'K-1 goes back to the chief to sign');
        decide('1180', 'the operator signs K-1 himself, spec and plan');
        const chain = join(root, 'release', 'R2', 'operator.jsonl');
        writeFileSync(chain, `${readFileSync(chain, 'utf8')}not json\n`);
        const unreadable = /the signer records are unreadable \(release R2: operator\.jsonl does not verify/;
        expect(() => sign(sctx(), ['K-2'], spec('K-2-b.md', join(root, 'specs-b')))).toThrow(unreadable);
        expect(() => opSignSpec(sctx(), ['K-1'], p, '1180', 'the operator signs K-1 himself, spec and plan', { supersedes: r.id })).toThrow(unreadable);
        expect(() => record(sctx(), { keys: ['K-1'], decision: '1170', words: MARK_K1 })).toThrow(unreadable);
        expect(() => record(sctx(), { signer: 'chief', keys: ['K-1'], decision: '1170', words: 'K-1 goes back to the chief to sign' })).toThrow(unreadable);
        expect(alerts).toEqual([]);
        expect(rowsOf('spec-signer')).toEqual([]);
      });
    });
  });

  describe('sign-check', () => {
    const OK_LINE = /^SIGN-CHECK OK spec-sha=[0-9a-f]{64} plan-sha=([0-9a-f]{64}|none)$/;

    beforeEach(() => {
      declared();
      for (const [k, v] of Object.entries(specEnv())) vi.stubEnv(k, v);
      vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
      vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
      writeFileSync(join(root, 'verbatim.txt'), 'approve 1-5\n');
    });

    async function signCheckRun(...args: string[]): Promise<{ code: number; out: string[] }> {
      const out: string[] = [];
      const log = vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
      const err = vi.spyOn(console, 'error').mockImplementation(() => {});
      try {
        await cli('sign-check', ...args);
        return { code: Number(process.exitCode ?? 0), out };
      } finally {
        process.exitCode = undefined;
        log.mockRestore();
        err.mockRestore();
      }
    }

    async function signingRefusal(route: 'spec' | 'spec-review', args: string[]): Promise<string | null> {
      const log = vi.spyOn(console, 'log').mockImplementation(() => {});
      try {
        await cli('operator', route, 'R1', ...args,
          ...(route === 'spec' ? ['--decision', '387', '--verbatim-file', join(root, 'verbatim.txt')] : []));
        return null;
      } catch (e) {
        return (e as Error).message;
      } finally {
        log.mockRestore();
      }
    }

    const fileArgs = (keys: string, p: string, verdicts: string[], plan?: string) =>
      ['--keys', keys, '--spec', p, ...(plan ? ['--plan', plan] : []), ...verdicts.flatMap((v) => ['--verdict', v])];

    async function sameRefusal(route: 'spec' | 'spec-review', args: string[], expected: RegExp): Promise<void> {
      const checked = await signCheckRun(...args, ...(route === 'spec' ? [] : ['--route', route]));
      const signed = await signingRefusal(route, args);
      expect(signed).toMatch(expected);
      expect(checked).toEqual({ code: 1, out: [`SIGN-CHECK REFUSED: ${signed}`] });
    }

    it('(a) a plan return with undispositioned findings and a refusing capped verifier gets the signing message', async () => {
      const f = cappedFixture(undefined, false, 4);
      await sameRefusal('spec', fileArgs('HIMMEL-10205', f.spec, f.verdicts, f.plan), /residual findings[\s\S]*capped verifier unavailable\/refused/);
    });

    it('(b) a path:line Fact ownership cell gets the signing lint refusal, with this checkout\'s new message', async () => {
      const scripts = 'marketplace/plugins/himmel-ops/scripts';
      const signerRoot = mkdtempSync(join(root, 'signer-root-'));
      execFileSync('git', ['init', '-q', signerRoot]);
      mkdirSync(join(signerRoot, scripts), { recursive: true });
      for (const name of ['minerva-spec-gate.sh', 'minerva-trace-lint.sh']) copyFileSync(join(candidateRoot, scripts, name), join(signerRoot, scripts, name));
      vi.stubEnv('HIMMEL_REPO', candidateRoot);
      sourceFixture.primary = signerRoot;
      try {
        const { spec: p, plan } = bucketSpec(`${scripts}/minerva-spec-gate.sh:12`);
        await sameRefusal('spec', fileArgs('K-1', p, [verdict(p, 'spec', 'SPEC CLEAN'), verdict(p, 'plan', 'PLAN CLEAN')], plan),
          /minerva-trace-lint\.sh refused the spec:[\s\S]*minerva-spec-gate\.sh:12; cite the file in backticks and name its function bare/);
      } finally { sourceFixture.primary = null; }
    });

    it('(c) a spec-review SPEC CLEAN that reviewed other bytes gets the signing message', async () => {
      const f = rspec();
      await sameRefusal('spec-review', fileArgs('K-2', f.spec, [critic(f.spec, 'SPEC CLEAN', { reviewed: [`Reviewed: spec ${'a'.repeat(64)}`] })], f.plan),
        /SPEC CLEAN reviewed a{64}, not the spec's bytes/);
    });

    it('(d) a missing spec gets the signing message', async () => {
      const p = spec();
      await sameRefusal('spec', fileArgs('K-1', join(root, 'absent.md'), [verdict(p, 'spec', 'SPEC CLEAN'), verdict(p, 'plan', 'PLAN CLEAN')]), /spec not found/);
    });

    it('(e) no --plan on a signable fixture is accepted by both, with plan-sha=none', async () => {
      const p = spec();
      const args = fileArgs('K-1', p, [verdict(p, 'spec', 'SPEC CLEAN'), verdict(p, 'plan', 'PLAN CLEAN')]);
      const checked = await signCheckRun(...args);
      expect(await signingRefusal('spec', args)).toBeNull();
      expect(checked).toEqual({ code: 0, out: [expect.stringMatching(/ plan-sha=none$/)] });
    });

    it('a spec-review record spec-review accepts is accepted with --route spec-review, naming the plan sha', async () => {
      const f = rspec();
      const args = fileArgs('K-2', f.spec, [critic(f.spec, 'SPEC CLEAN')], f.plan);
      const checked = await signCheckRun(...args, '--route', 'spec-review');
      expect(await signingRefusal('spec-review', args)).toBeNull();
      expect(checked).toEqual({ code: 0, out: [`SIGN-CHECK OK spec-sha=${sha(f.spec)} plan-sha=${sha(f.plan)}`] });
    });

    it('prints one OK line on accepted bytes, reads no signer or release record and leaves every file as it was', async () => {
      const p = spec();
      const args = fileArgs('K-1', p, [verdict(p, 'spec', 'SPEC CLEAN'), verdict(p, 'plan', 'PLAN CLEAN')]);
      writeFileSync(join(sctx().dir, 'operator.jsonl'), 'not a record chain\n');
      const before = fixtureHashes(root);
      const checked = await signCheckRun(...args);
      expect(checked).toEqual({ code: 0, out: [expect.stringMatching(OK_LINE)] });
      expect(checked.out[0]).toContain(`spec-sha=${sha(p)} `);
      expect(fixtureHashes(root)).toEqual(before);
    });

    it('runs in a worker context and makes no network call', async () => {
      const p = spec();
      vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
      vi.stubEnv('HIMMEL_BRIDGE_SESSION', '1');
      const net = vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('no network'));
      try {
        const checked = await signCheckRun(...fileArgs('K-1', p, [verdict(p, 'spec', 'SPEC CLEAN'), verdict(p, 'plan', 'PLAN CLEAN')]));
        expect(checked.code).toBe(0);
        expect(net).not.toHaveBeenCalled();
      } finally {
        net.mockRestore();
      }
    });

    it('a usage error exits 2 with no verdict line', async () => {
      const p = spec();
      const verdicts = [verdict(p, 'spec', 'SPEC CLEAN'), verdict(p, 'plan', 'PLAN CLEAN')];
      for (const args of [
        ['--keys', 'K-1', '--verdict', verdicts[0], '--verdict', verdicts[1]],
        [...fileArgs('K-1', p, verdicts), '--route', 'other'],
        [...fileArgs('K-1', p, verdicts), '--route', 'spec-review', '--source-root', root],
      ]) expect(await signCheckRun(...args), args.join(' ')).toEqual({ code: 2, out: [] });
    });
  });

  describe('sign-lint', () => {
    function shim(name: string, body: string): string {
      const bin = mkdtempSync(join(root, `${name}-bin-`));
      writeFileSync(join(bin, name), body);
      chmodSync(join(bin, name), 0o755);
      return bin;
    }
    function gate(p: string): { args: string[]; stderr: string } {
      const log = join(mkdtempSync(join(root, 'gate-log-')), 'argv');
      const bin = shim('bun', `#!/bin/sh\nprintf '%s\\n' "$@" >> '${log}'\n`);
      const r = spawnSync('bash', [join(candidateRoot, 'marketplace/plugins/himmel-ops/scripts/minerva-spec-gate.sh'), p], {
        cwd: dirname(p), encoding: 'utf8', env: { ...process.env, HIMMEL_REPO: join(root, 'no-checkout'), PATH: `${bin}:${process.env.PATH}` },
      });
      return { args: existsSync(log) ? readFileSync(log, 'utf8').split('\n') : [], stderr: r.stderr };
    }

    it('planOf resolves the plan the spec gate hands sign-shape, on each front-matter form', () => {
      const designs = join(root, 'bucket', 'specs', 'designs');
      const plan = join(root, 'bucket', 'specs', 'plans', 'p.md');
      mkdirSync(designs, { recursive: true });
      mkdirSync(dirname(plan), { recursive: true });
      writeFileSync(plan, 'plan\n');
      const forms = [
        `---\nplan: ${plan}\n---\n`,
        '---\nplan: ../plans/p.md\n---\n',
        '---\nplan: specs/plans/p.md\n---\n',
        '---\nplan: `../plans/p.md` (r3)\n---\n',
        '# title\n---\nplan: ../plans/p.md\n---\n',
        '---\nplan: ../plans/absent.md\n---\n',
        '---\ntickets: K-1\n---\nplan: ../plans/p.md\n',
      ];
      const found = forms.map((head, i) => {
        const p = join(designs, `s${i}.md`);
        writeFileSync(p, `${head}\nbody\n`);
        const { args } = gate(p);
        expect(args, `form ${i}: the gate reached sign-shape`).toContain('sign-shape');
        const given = args.includes('--plan') ? args[args.indexOf('--plan') + 1] : null;
        expect(planOf(p), `form ${i}`).toBe(given);
        return given !== null;
      });
      expect(found).toEqual([true, true, true, true, false, false, false]);
    });

    it('estimateLine agrees with the spec gate on each estimate-line form', () => {
      const forms = ['Estimate record: x', '  estimate RECORD: x', 'Estimates: x', 'Estimate record:', 'Estimate record:   ', 'Estimate record: ``',
        'Estimate record:\nEstimate record: x'];
      const answers = forms.map((line, i) => {
        const p = join(root, `estimate-${i}.md`);
        writeFileSync(p, `# title\n\n${line}\n`);
        const present = !gate(p).stderr.includes("no 'Estimate record:");
        expect(estimateLine(readFileSync(p, 'utf8')), line).toBe(present);
        return present;
      });
      expect(answers).toEqual([true, true, false, false, false, false, false]);
    });

    it('one lintSpec call runs the shell lint once while the gate really calls sign-shape', () => {
      const p = spec();
      writeFileSync(join(dirname(p), 'p.md'), 'plan\n\n- Task 1: build it.\n');
      writeFileSync(p, `---\ntickets: K-1\nplan: p.md\n---\n${readFileSync(p, 'utf8')}`);
      const log = join(root, 'lint-runs');
      const realBash = spawnSync('which', ['bash'], { encoding: 'utf8' }).stdout.trim();
      const bin = shim('bash', `#!/bin/sh\ncase "$*" in *minerva-trace-lint.sh*) printf '%s\\n' "$*" >> '${log}';; esac\nexec '${realBash}' "$@"\n`);
      const bunLog = join(root, 'bun-runs');
      writeFileSync(join(bin, 'bun'), `#!/bin/sh\nprintf '%s\\n' "$*" >> '${bunLog}'\nexec '${realBun}' "$@"\n`);
      chmodSync(join(bin, 'bun'), 0o755);
      vi.stubEnv('HIMMEL_REPO', candidateRoot);
      vi.stubEnv('PATH', `${bin}:${process.env.PATH}`);
      lintSpec(p, join(dirname(p), 'p.md'));
      expect(readFileSync(bunLog, 'utf8')).toMatch(/chief-route\.ts sign-shape .* --plan /);
      expect(readFileSync(log, 'utf8').trim().split('\n')).toHaveLength(1);
    });
  });
});

it('spec-sign.ts and engine-core.ts never import engine.ts, and engine-core.ts never imports spec-sign.ts', () => {
  const dir = dirname(fileURLToPath(import.meta.url));
  const wrong: string[] = [];
  const reads = (file: string, forbidden: string[]): void => {
    const code = readFileSync(join(dir, file), 'utf8');
    const specifiers: string[] = [];
    for (const m of code.matchAll(/\bfrom\s*(['"`])([^'"`\n]*)\1/g)) specifiers.push(m[2]);
    for (const m of code.matchAll(/\bimport\s*\(?\s*(['"`])([^'"`\n]*)\1/g)) specifiers.push(m[2]);
    for (const m of code.matchAll(/\brequire\s*\(\s*(['"`])([^'"`\n]*)\1/g)) specifiers.push(m[2]);
    for (const m of code.matchAll(/\b(?:import|require)\s*\(\s*(.)/g)) if (!/['"`]/.test(m[1])) wrong.push(`${file}: a module specifier that is not a plain string literal`);
    for (const s of specifiers) {
      if (s.includes('${')) wrong.push(`${file}: ${s}`);
      else if (s.startsWith('.') && forbidden.includes(join(dir, s).replace(/\.(js|ts)$/, ''))) wrong.push(`${file}: ${s}`);
    }
  };
  reads('spec-sign.ts', [join(dir, 'engine')]);
  reads('engine-core.ts', [join(dir, 'engine'), join(dir, 'spec-sign')]);
  expect(wrong, 'see HIMMEL-10654 R8: new code a moved function calls goes in spec-sign.ts or engine-core.ts; a declaration that stays in engine.ts and is now needed by moved code moves to engine-core.ts').toEqual([]);
});

describe('residual lines: one grammar', () => {
  const classOf = (rows: string[], line: string): string => {
    const parsed = pinned.parseResidualLines([...rows, line]);
    if (parsed.qualified.some(q => q.line === line && !rows.includes(line))) return 'qualified';
    if (parsed.idList.includes(line)) return 'idList';
    if (parsed.nearMiss.includes(line)) return 'nearMiss';
    return parsed.legacy.size > pinned.parseResidualLines(rows).legacy.size ? 'legacy' : 'prose';
  };

  it('T-R7a: parseResidualLines classifies the shared table', () => {
    expect(RESIDUAL_ROWS.map(r => [r.line, classOf(r.context, r.line)])).toEqual(RESIDUAL_ROWS.map(r => [r.line, r.cls]));
    const q = pinned.parseResidualLines(['  - R3-F27: deferred → HIMMEL-1', '- P3-P17: fixed']).qualified;
    expect(q.map(({ kind, round, id }) => [kind, round, id])).toEqual([['spec', 3, 'F27'], ['plan', 3, 'P17']]);
  });

  it('T-R11: findingIds refuses a duplicate id and reads no id from a non-finding heading', () => {
    expect(() => pinned.findingIds('- **F1** (minor) one\n- **F1** (minor) two\n')).toThrow(/duplicate F1/);
    expect(pinned.findingIds('- **X1** (note) not a finding\n- **F2** (major; regression) one\n')).toEqual(['F2']);
  });
});

describe('the signer matches qualified residual lines (R2)', () => {
  const sec = (...l: string[]) => ['# S', '', '## Critic rounds', '', ...l, '', '## Next'].join('\n');
  const ret = (name: string, ...body: string[]) => ({ path: `/b/specs/designs/${name}`, text: ['Reviewed: spec 0', '', ...body].join('\n') });
  const specR3 = ret('S.md.critic-spec-r3.md', '- **F2** (minor) one', '', 'SPEC FINDINGS 1');
  const planClean = ret('S.md.critic-plan-r1.md', 'PLAN CLEAN');
  const r1 = ['- Round 3 (spec critic)', '  - R3-F2: fixed'];
  const sign = (text: string, n: number, returns: { path: string; text: string }[]) => () => checkResiduals(text, n, returns);

  it('T-R1: a nested R3-F2 line answers F2 of the round-3 spec return', () => {
    expect(sign(sec(...r1), 1, [specR3, planClean])).not.toThrow();
  });
  it('T-R3: a line for another id leaves F2 undisposed', () => {
    expect(sign(sec('- Round 3', '  - R3-F7: fixed'), 1, [specR3, planClean])).toThrow(/F2/);
  });
  it('T-R2: a round-3 line naming an id the return lacks refuses', () => {
    expect(sign(sec(...r1, '- R3-F9: fixed'), 1, [specR3, planClean])).toThrow(/F9/);
  });
  it('T-R4: a plan finding needs a P<round> line, not an R line', () => {
    const plan2 = ret('S.md.critic-plan-r2.md', '- **P1** (minor) one', '', 'PLAN FINDINGS 1');
    const spec = ret('S.md.critic-spec-r1.md', 'SPEC CLEAN');
    expect(sign(sec('- R2-P1: fixed'), 1, [spec, plan2])).toThrow(/P1/);
    expect(sign(sec('- P2-P1: fixed'), 1, [spec, plan2])).not.toThrow();
  });
  it('T-R9: a return whose FINDINGS count differs from its headings refuses', () => {
    const bad = ret('S.md.critic-spec-r3.md', '- **F2** (minor) one', '', 'SPEC FINDINGS 2');
    expect(sign(sec(...r1), 2, [bad, planClean])).toThrow(/return ids do not parse/);
  });
  it('T-R10: a qualified line later than the given round refuses', () => {
    expect(sign(sec(...r1, '- R4-F2: fixed'), 1, [specR3, planClean])).toThrow(/R4-F2/);
  });
  it('T-R5: legacy lines against SPEC FINDINGS 2 still pass (control)', () => {
    expect(sign(sec('- R1: fixed', '- R2: ceiling'), 2, [])).not.toThrow();
  });
  it('T-R6: one legacy line short refuses (control)', () => {
    expect(sign(sec('- R1: fixed'), 2, [])).toThrow(/2 residual findings/);
  });
  it('T-R8: the bucket prose bullets keep the base verdict (control)', () => {
    const prose = ['- R4: superseded by round 2 R6', '- R1: spec critic, SPEC CLEAN', '  - R1: accepted for the build', '- R1-1: fixed'];
    expect(sign(sec('- R1: fixed', '- R2: ceiling', ...prose), 2, [])).not.toThrow();
    expect(sign(sec('- R1: fixed', ...prose), 2, [])).toThrow(/2 residual findings/);
  });
  it('T-R7: spec-review matches inside the block naming the verdict file', () => {
    const names = ['S.md.critic-spec-r3.md'];
    const review = (l: string[]) => () => checkRoundResiduals(sec(`- Round 3: ${names[0]}`, ...l), names, 1, 'spec-review', [specR3]);
    expect(review(['  - R3-F2: fixed'])).not.toThrow();
    expect(review(['  - R3-F7: fixed'])).toThrow(/F2/);
  });
  it('T-R13: a return outside CRITIC_FILE, or whose name kind disagrees with its verdict, refuses naming it', () => {
    expect(sign(sec(...r1), 1, [ret('x.critic-r3.md', '- **F2** (minor) one', '', 'SPEC FINDINGS 1'), planClean])).toThrow(/x\.critic-r3\.md/);
    expect(sign(sec(...r1), 1, [ret('S.md.critic-spec-r3.md', '- **F2** (minor) one', '', 'PLAN FINDINGS 1')])).toThrow(/S\.md\.critic-spec-r3\.md/);
  });
  it('T-R14: prose and a near-miss below the highest qualified round are history', () => {
    expect(sign(sec(...r1, '- R1 F6: reopened in R2', '- R2-F9: deferred → the chief files'), 1, [specR3, planClean])).not.toThrow();
  });
  it('T-R15: an id-list line refuses on the normal route, even at 0 residuals', () => {
    expect(sign(sec('- R1: F1, F2 fixed'), 2, [])).toThrow(/R1: F1, F2 fixed/);
    expect(sign(sec('- R1: F1, F2 fixed'), 0, [])).toThrow(/R1: F1, F2 fixed/);
  });
  it('T-R16: a near-miss at the highest qualified round refuses', () => {
    expect(sign(sec(...r1, '- R3-F2x: deferred → later'), 1, [specR3, planClean])).toThrow(/R3-F2x/);
  });
  it('T-R17: a duplicate finding id is a refusal, not a crash', () => {
    const dup = ret('S.md.critic-spec-r3.md', '- **F2** (minor) one', '- **F2** (minor) two', '', 'SPEC FINDINGS 2');
    expect(sign(sec(...r1), 2, [dup, planClean])).toThrow(/return ids do not parse: duplicate F2/);
  });
});
