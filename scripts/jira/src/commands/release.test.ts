import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Command } from 'commander';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// While a reply is set, the judge's subscription `claude` call returns it, the usage preflight prints `preflight`, and
// the API launcher is refused on policy as on the station since PR 4669; each is recorded. Every other child runs for real.
type Seen = { file: string; args: string[]; env: NodeJS.ProcessEnv };
const judgeReply = vi.hoisted(() => ({ out: null as string | null, preflight: 'PROCEED\n', calls: [] as Seen[], hang: false }));
vi.mock('node:child_process', async (orig) => {
  const m = await orig<typeof import('node:child_process')>();
  const execFileSync = ((...a: Parameters<typeof m.execFileSync>) => {
    if (judgeReply.out === null) return m.execFileSync(...a);
    const file = String(a[0]);
    const args = (a[1] as string[] | undefined) ?? [];
    const seen = { file, args, env: { ...((a[2] as { env?: NodeJS.ProcessEnv } | undefined)?.env ?? process.env) } };
    if (String(args[0] ?? '').endsWith('usage-preflight.sh')) { judgeReply.calls.push(seen); return judgeReply.preflight; }
    if (String(args[0] ?? '').endsWith('claude-api.sh')) {
      judgeReply.calls.push(seen);
      throw Object.assign(new Error('Command failed: claude-api.sh\nclaude-api: refused: auto routing is for the himmel graph pass only (kind judge, repo none)'), { status: 2 });
    }
    return m.execFileSync(...a);
  }) as typeof m.execFileSync;
  const execFile = ((...a: unknown[]) => {
    if (judgeReply.out === null || a[0] !== 'claude') return (m.execFile as (...x: unknown[]) => unknown)(...a);
    const args = (a[1] as string[] | undefined) ?? [];
    judgeReply.calls.push({ file: 'claude', args, env: { ...((a[2] as { env?: NodeJS.ProcessEnv } | undefined)?.env ?? process.env) } });
    const reply = judgeReply.out;
    const done = a[3] as (err: Error | null, out: string, errOut: string) => void;
    const signal = (a[2] as { signal?: AbortSignal } | undefined)?.signal;
    if (judgeReply.hang) signal?.addEventListener('abort', () => done(Object.assign(new Error('The operation was aborted'), { name: 'AbortError' }), '', ''), { once: true });
    else setImmediate(() => done(null, reply, ''));
    return { stdin: { on: () => undefined, end: () => undefined } };
  }) as typeof m.execFile;
  return { ...m, execFileSync, execFile };
});
const rmRunSeen = vi.hoisted(() => ({ opts: null as { judgeTimeoutMs?: number } | null }));
vi.mock('../release/engine.js', async (orig) => {
  const m = await orig<typeof import('../release/engine.js')>();
  return { ...m, rmRun: ((c, j, o) => { rmRunSeen.opts = o ?? null; return m.rmRun(c, j, o); }) as typeof m.rmRun };
});
// The run options the repair command hands to the repair, as the last call saw them.
const repairSeen = vi.hoisted(() => ({ opts: null as { apply?: boolean; refuse?: unknown } | null }));
vi.mock('../release/repair-run.js', async (orig) => {
  const m = await orig<typeof import('../release/repair-run.js')>();
  return { ...m, repairRun: ((c, o) => { repairSeen.opts = o; return m.repairRun(c, o); }) as typeof m.repairRun };
});
vi.mock('../client.js', () => ({
  request: vi.fn(), projectKey: vi.fn(() => 'HIMMEL'), baseUrl: vi.fn(() => 'http://127.0.0.1:9'), authHeader: vi.fn(() => 'Basic eA=='),
}));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { projectKey, request } from '../client.js';
import { admissionBudget } from '../release/leaks.js';
import { ctxFor, JUDGE_API_PASS_ENV, judgeApiEnv, judgeCall, judgeEnv, judgeFor, judgePrompt, JUDGE_SPAWN_TIMEOUT_MS, JUDGE_TIMEOUT_S, liveJira, liveJudge, makeRoutedJudge, parseDecisions, refuseRequest, registerRelease, renderState, routedJudge } from './release.js';
import type { Judge, JudgeInput } from '../release/engine.js';
import { defaultRoot } from './mirror.js';
import { appendChain, loadKey } from '../release/ledger.js';

let out: string[];
let root: string;

async function run(...args: string[]) {
  const p = new Command();
  p.exitOverride();
  registerRelease(p);
  await p.parseAsync(['node', 'jira', 'release', ...args]);
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'release-cli-'));
  vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(root, 'state'));
  vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(root, 'keys'));
  vi.stubEnv('HIMMEL_CONSOLE', '');
  vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
  vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
  writeFileSync(join(root, 'verbatim.txt'), 'R = v1 + v2\n');
  // The request gate's live read of a key the mirror lacks answers a plain open Medium ticket; every other call answers nothing.
  vi.mocked(request).mockReset();
  vi.mocked(request).mockImplementation((async (_m: string, path: string) => (path.endsWith('?fields=labels,priority,status')
    ? { fields: { labels: [], priority: { name: 'Medium' }, status: { statusCategory: { name: 'To Do' } } } }
    : undefined)) as never);
  out = [];
  repairSeen.opts = null;
  vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
});

afterEach(() => {
  vi.unstubAllEnvs();
  judgeReply.out = null;
  judgeReply.preflight = 'PROCEED\n';
  judgeReply.calls = [];
  judgeReply.hang = false;
});

describe.skipIf(process.platform !== 'linux')('jira release from a test on the station', () => {
  beforeEach(() => {
    vi.stubEnv('HIMMEL_REAL_STATE_ASSUME_STATION', '1');
    vi.stubEnv('HIMMEL_REAL_STATE_EXTRA_ROOTS', root);
  });

  it('refuses every write verb, reads still run', async () => {
    const vf = join(root, 'verbatim.txt');
    await expect(run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', vf)).rejects.toThrow(/refused/);
    await expect(run('request', 'R1', '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'x')).rejects.toThrow(/refused/);
    expect(existsSync(join(root, 'state', 'R1'))).toBe(false);
    await run('state', 'R1', '--json', '--mirror-root', join(root, 'no-mirror'));
    await run('bucket-check', '--mirror', join(root, 'no-mirror'), 'K-1');
  });

  it('refuses a key mint at the declare call site once the state dir clears the write door', async () => {
    vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', mkdtempSync(join(tmpdir(), 'release-cli-state-')));
    await expect(run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', join(root, 'verbatim.txt')))
      .rejects.toThrow('release operator declare: refused, nothing was written');
    expect(existsSync(join(root, 'keys'))).toBe(false);
  });

  it('refuses repair --apply before the repair runs, and lets the dry run past the door', async () => {
    await expect(run('repair', 'R1', '--repo', 'o/r', '--apply', '--mirror-root', join(root, 'no-mirror'))).rejects.toThrow(/release repair: refused, nothing was written/);
    expect(repairSeen.opts).toBeNull();
    expect(existsSync(join(root, 'state', 'R1'))).toBe(false);
    await run('repair', 'R1', '--repo', 'o/r', '--mirror-root', join(root, 'no-mirror')).catch((e: Error) => expect(e.message).not.toMatch(/refused/));
    process.exitCode = undefined;
    expect(repairSeen.opts).toMatchObject({ apply: undefined });
  });
});

describe('jira release', () => {
  it('repair --apply hands the request refusal check to the repair', async () => {
    await run('repair', 'R1', '--repo', 'o/r', '--apply', '--mirror-root', join(root, 'no-mirror')).catch(() => undefined);
    process.exitCode = undefined;
    expect(repairSeen.opts).toMatchObject({ apply: true, refuse: refuseRequest });
  });

  it('declares, freezes, queues a request and reports the state as JSON', async () => {
    const vf = join(root, 'verbatim.txt');
    await run('operator', 'declare', 'R1', '--versions', 'v1,v2', '--decision', '106', '--verbatim-file', vf);
    await run('operator', 'freeze', 'R1', '--version', 'v1', '--keys', 'K-1,K-3', '--decision', '104', '--verbatim-file', vf);
    await run('request', 'R1', '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'found work');
    await run('state', 'R1', '--json', '--mirror-root', join(root, 'no-mirror'));
    expect(out.slice(0, 3)).toEqual([
      'DECLARED R1 = v1 + v2 (current v1, observe)',
      'FROZEN baseline-v1-g1 (2 keys)',
      'REQ Q-R1-0001',
    ]);
    const s = JSON.parse(out[3]);
    expect(s).toMatchObject({ release: 'R1', mode: 'observe', versions: ['v1', 'v2'], requests: { open: ['Q-R1-0001'] } });
    expect(s.requests.oldest_open).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(s.inputs.mirror).toBe('UNKNOWN');
    expect(s.burndown.v1.baseline).toBe(2);
  });

  it('state prints unknown when the mirror is UNKNOWN', async () => {
    const vf = join(root, 'verbatim.txt');
    await run('operator', 'declare', 'R1', '--versions', 'v1,v2', '--decision', '106', '--verbatim-file', vf);
    out.length = 0;
    await run('state', 'R1', '--mirror-root', join(root, 'no-mirror'));
    // The mirror input reads UNKNOWN on the inputs line; the headline stays OK (only an unreadable ledger makes it UNKNOWN).
    expect(out.join('\n')).toMatch(/^inputs: .*\bmirror=UNKNOWN\b/m);
  });

  it('refuses request evidence that is not a JSON object', async () => {
    const vf = join(root, 'verbatim.txt');
    await run('operator', 'declare', 'R1', '--versions', 'v1,v2', '--decision', '106', '--verbatim-file', vf);
    for (const bad of ['[1]', 'null', '3']) {
      await expect(run('request', 'R1', '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'w', '--evidence', bad))
        .rejects.toThrow(/--evidence is a JSON object/);
    }
  });

  it('refuses a ruling authority outside rm, operator and import', async () => {
    await expect(run('rule', 'R1', '--req', 'Q-R1-0001', '--outcome', 'ADMIT', '--op', 'add', '--to', 'v1',
      '--sector', 's', '--ground', 'regression', '--authority', 'RM')).rejects.toThrow(/--authority is rm, operator or import/);
  });

  it('folds a batch file, prints every skipped key with its terminal and resolution, and reopens', async () => {
    const vf = join(root, 'verbatim.txt');
    await run('operator', 'declare', 'R1', '--versions', 'v1,v2', '--decision', '106', '--verbatim-file', vf);
    const mir = join(root, 'mirror');
    mkdirSync(mir);
    writeFileSync(join(mir, '.cursor.json'), JSON.stringify({ lastSync: '2026-10-21T09:00:00.000Z' }));
    const md = (key: string, status: string, resolution: string) => writeFileSync(join(mir, `${key}.md`), [
      '---', `key: "${key}"`, `status: "${status}"`, 'statusCategory: "Done"', 'fixVersions: ["v1"]', `resolution: "${resolution}"`, '---', '',
    ].join('\n'));
    md('K-1', 'Closed', 'Done');
    md('K-2', 'Closed', "Won't Do");
    md('K-3', 'Closed', 'Cannot Reproduce');
    writeFileSync(join(root, 'batch.txt'), '# delivered\nK-1 11\n\nK-2 12\nK-3 13\n');
    out = [];
    await run('fold', 'R1', '--to', 'v1', '--file', join(root, 'batch.txt'), '--mirror-root', mir);
    expect(out).toEqual([
      'FOLD K-1 → v1 (PR 11)',
      'SKIPPED K-2 terminal="Won\'t Do" resolution="Won\'t Do"',
      'SKIPPED K-3 terminal="Other" resolution="Cannot Reproduce"',
      'FOLDED 1, ALREADY 0, SKIPPED 2',
    ]);
    expect(process.exitCode).toBe(2);
    process.exitCode = 0;
    out = [];
    await run('reopen', 'R1', '--key', 'K-1', '--from', 'v1');
    expect(out).toEqual(['REOPEN K-1 ← v1']);
    await expect(run('fold', 'R1', '--to', 'v1', '--key', 'K-1', '--mirror-root', mir)).rejects.toThrow(/--key with --pr, or --file/);
    await expect(run('fold', 'R1', '--to', 'v1', '--file', join(root, 'batch.txt'), '--pr', '1', '--mirror-root', mir)).rejects.toThrow(/--key with --pr, or --file/);
    await expect(run('fold', 'R1', '--to', 'v1', '--key', 'K-1', '--pr', '0x10', '--mirror-root', mir)).rejects.toThrow(/decimal PR number/);
  });

  it('refuses an operator act from a chief-spawned worker', async () => {
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
    await expect(run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', join(root, 'verbatim.txt')))
      .rejects.toThrow(/chief-spawned worker/);
  });
});

describe('jira release rm-run', () => {
  beforeEach(() => {
    // rm-run posts to Jira; a loopback Jira is a stub, so the post door stays open.
    vi.stubEnv('JIRA_BASE_URL', 'http://127.0.0.1:9');
    // profile-settings.sh bare runs for real and writes its settings file here.
    vi.stubEnv('HIMMEL_PROFILE_SETTINGS_DIR', join(root, 'profiles'));
    // the judge run appends its launch row beside this path, never under the real HOME
    vi.stubEnv('HIMMEL_API_CREDIT_STATE', join(root, 'credit', 'ledger.json'));
  });

  async function oneRequest() {
    await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', join(root, 'verbatim.txt'));
    await run('request', 'R1', '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'found work');
    const d = { req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 's', ground: 'g', reason: 'r' };
    judgeReply.out = JSON.stringify({ is_error: false, result: JSON.stringify([d]) });
    out = [];
  }

  it('with no usable API account the judge rules the batch on the subscription', async () => {
    // the station since PR 4669: the API launcher refuses a judge's auto request on policy, with no fallback
    vi.stubEnv('HIMMEL_API_LANE', 'on');
    vi.stubEnv('HIMMEL_API_ACCOUNT', 'auto');
    vi.stubEnv('ANTHROPIC_API_KEY', 'dummy-api-key');
    vi.stubEnv('CLAUDE_CODE_OAUTH_TOKEN', 'dummy-oauth-token');
    vi.stubEnv('WORKER_SESSION_LANE', 'claudex');
    await oneRequest();
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    expect(out.some((l) => /R-R1-\d+/.test(l))).toBe(true);
    expect(judgeReply.calls.some((c) => String(c.args[0]).endsWith('claude-api.sh'))).toBe(false);
    const call = judgeReply.calls.find((c) => c.file === 'claude');
    expect(call?.args).toEqual(expect.arrayContaining(['--permission-mode', 'plan', '--output-format', 'json', '--max-turns', '1', '--strict-mcp-config']));
    expect(call?.args[call.args.indexOf('--tools') + 1]).toBe('');
    expect(call?.args[call.args.indexOf('--mcp-config') + 1]).toBe('{"mcpServers":{}}');
    expect(Object.keys(call?.env ?? {}).filter((k) => /^(ANTHROPIC_|HIMMEL_API_)/i.test(k))).toEqual([]);
    expect(call?.env.CLAUDE_CODE_OAUTH_TOKEN).toBe('dummy-oauth-token');
    const pre = judgeReply.calls.find((c) => String(c.args[0]).endsWith('usage-preflight.sh'));
    expect(pre?.env).toMatchObject({ CADENCE_USAGE_LANE: 'native', CADENCE_USAGE_WORKER: 'rm-judge' });
    for (const k of ['WORKER_SESSION_LANE', 'CADENCE_USAGE_LAUNCH', 'CADENCE_USAGE_CALLER_PID']) expect(pre?.env).not.toHaveProperty(k);
  });

  it('the judge run writes a launch record the digest reads back by the session id', async () => {
    const cache = join(root, 'cache');
    vi.stubEnv('HIMMELCTL_CACHE_DIR', cache);
    await oneRequest();
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    const call = judgeReply.calls.find((c) => c.file === 'claude');
    const sid = call?.args[(call?.args.indexOf('--session-id') ?? -2) + 1] ?? '';
    expect(sid).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
    const log = readFileSync(join(cache, 'launch-logs', `rm-judge-${sid.slice(0, 8)}.log`), 'utf8');
    expect(log).toMatch(new RegExp(`^headed-arm-worker: profile=bare lane=native model=opus role=release-manager session=rm-judge-${sid.slice(0, 8)} session_id=${sid} launched=\\S+\\n$`));
  });

  it('the judge run writes exactly one launches.jsonl row carrying its session id and its real cost', async () => {
    await oneRequest();
    const d = { req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 's', ground: 'g', reason: 'r' };
    judgeReply.out = JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 1.2345678, result: JSON.stringify([d]) });
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    const call = judgeReply.calls.find((c) => c.file === 'claude');
    const sid = call?.args[(call?.args.indexOf('--session-id') ?? -2) + 1] ?? '';
    const rows = readFileSync(join(root, 'credit', 'launches.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ kind: 'judge', lane: 'native', model: 'opus', session_id: sid, sub_cost_usd: '1.234568', cost_usd: '', outcome: 'native', rc: 0 });
    expect(rows[0].ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  });

  it.each(['SKIPPED-BANK', 'BANK-UNKNOWN'])('the judge stops on preflight %s and names the token', async (token) => {
    await oneRequest();
    judgeReply.preflight = `bank-preflight: note\n${token}\n`;
    await expect(run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'))).rejects.toThrow(`nothing ruled: preflight ${token}`);
    expect(judgeReply.calls.some((c) => c.file === 'claude')).toBe(false);
  });

  it.each(['SIGTERM', 'SIGINT', 'SIGHUP'] as const)('%s during the judge call stops the run: the call is killed, the lease freed, the claim open, the doc says why', async (sig) => {
    await oneRequest();
    judgeReply.hang = true;
    const before = process.listenerCount(sig);
    const run1 = run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    await vi.waitFor(() => expect(judgeReply.calls.some((c) => c.file === 'claude')).toBe(true));
    expect(process.listenerCount(sig)).toBe(before + 1);
    process.emit(sig, sig);
    await expect(run1).rejects.toThrow(`rm-run: stopped by ${sig}; nothing more ruled`);
    expect(process.listenerCount(sig)).toBe(before);
    const dir = join(root, 'state', 'R1');
    expect(JSON.parse(readFileSync(join(dir, 'lease.json'), 'utf8'))).toMatchObject({ epoch: 1, released: true });
    expect(JSON.parse(readFileSync(join(dir, 'requests.jsonl'), 'utf8').trim().split('\n').at(-1) ?? '{}')).toMatchObject({ req: 'Q-R1-0001', state: 'open' });
    const docs = readdirSync(join(dir, 'rm-runs'));
    expect(docs).toHaveLength(1);
    expect(readFileSync(join(dir, 'rm-runs', docs[0]), 'utf8')).toMatch(new RegExp(`^- FAILED: rm-run: stopped by ${sig}`, 'm'));
    expect(out).toEqual([
      `FAILED: rm-run: stopped by ${sig}; nothing more ruled`, 'RETURNED 1 claimed requests to open',
      expect.stringMatching(/^RM-RUN R1 judge: 1 requests, \d+ ms$/), `RM-RUN R1 run record: ${join(dir, 'rm-runs', docs[0])}`,
    ]);
  });

  it('the CLI gives the judge a deadline that outlasts one routed call', async () => {
    await oneRequest();
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    expect(rmRunSeen.opts?.judgeTimeoutMs).toBe(960_000);
    expect(rmRunSeen.opts?.judgeTimeoutMs).toBeGreaterThan(JUDGE_SPAWN_TIMEOUT_MS);
  });

  it('a stale bank reading still runs the judge', async () => {
    await oneRequest();
    judgeReply.preflight = 'BANK-STALE\n';
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    expect(judgeReply.calls.some((c) => c.file === 'claude')).toBe(true);
    expect(out.some((l) => /R-R1-\d+/.test(l))).toBe(true);
  });

  it('prints nothing pending on an empty queue and makes no judge call', async () => {
    await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', join(root, 'verbatim.txt'));
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    expect(out.at(-1)).toBe('RM-RUN R1: nothing pending');
    expect(out.some((l) => /summary/.test(l))).toBe(false);
  });

  it('a run that refused a request ends with the refusal count', async () => {
    await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', join(root, 'verbatim.txt'));
    await run('request', 'R1', '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'found work');
    const other = { req: 'Q-R1-0099', outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 's', ground: 'g', reason: 'r' };
    judgeReply.out = JSON.stringify({ is_error: false, result: JSON.stringify([other]) });
    out = [];
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    expect(out.at(-3)).toMatch(/^REFUSED Q-R1-0001: /);
    expect(out.at(-2)).toMatch(/^RM-RUN R1 judge: 1 requests, \d+ ms$/);
    expect(out.at(-1)).toBe('RM-RUN R1 summary: 1 refused');
    expect(process.exitCode).toBe(2);
    process.exitCode = 0;
  });

  it('rm-run takes --ruling and --chief-override; the override needs a reason and the console marker, and the old --console-override is an unknown option', async () => {
    vi.stubEnv('HIMMEL_ADMISSIONS_LEDGER', join(root, 'admissions-ledger.jsonl'));
    await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', join(root, 'verbatim.txt'));
    const mirror = join(root, 'no-mirror');
    await run('rm-run', 'R1', '--mirror-root', mirror, '--ruling', '98');
    expect(out.at(-1)).toBe('RM-RUN R1: nothing pending');
    await expect(run('rm-run', 'R1', '--mirror-root', mirror, '--chief-override', 'big pass')).rejects.toThrow(/HIMMEL_CONSOLE=1/);
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    await expect(run('rm-run', 'R1', '--mirror-root', mirror, '--chief-override', ' ')).rejects.toThrow(/needs a reason/);
    await expect(run('rm-run', 'R1', '--mirror-root', mirror, '--chief-override', 'big pass', '--ruling', '98')).rejects.toThrow(/not both/);
    vi.stubEnv('HIMMEL_LEGACY_NAMES', '1');
    await expect(run('rm-run', 'R1', '--mirror-root', mirror, '--console-override', 'big pass')).rejects.toThrow(/unknown option '--console-override'/);
  });

  it('reads the decisions out of the claude JSON envelope and refuses a failed call', () => {
    const d = { req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 's', ground: 'g', reason: 'r' };
    expect(parseDecisions(JSON.stringify({ is_error: false, result: '```json\n' + JSON.stringify([d]) + '\n```' }))).toEqual([d]);
    expect(() => parseDecisions(JSON.stringify({ is_error: true, result: 'overloaded' }))).toThrow(/nothing ruled/);
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result: '{"req":"x"}' }))).toThrow();
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result: '[null]' }))).toThrow(/nothing ruled/);
    for (const bad of [{ authority: 'foo' }, { op: 'grow' }, { sector: 3 }, { to: undefined }, { supersedes: 'R-1' }]) {
      expect(() => parseDecisions(JSON.stringify({ is_error: false, result: JSON.stringify([{ ...d, ...bad }]) }))).toThrow(/nothing ruled/);
    }
    expect(parseDecisions(JSON.stringify({ is_error: false, result: JSON.stringify([{ ...d, authority: 'operator', ref: 'O-1', supersedes: ['R-1'] }]) })))
      .toHaveLength(1);
  });

  it('names the decision index and field a refused reply fails on, and keeps the raw reply', () => {
    const d = { req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 's', ground: 'g', reason: 'r' };
    const result = JSON.stringify([d, { ...d, req: 'Q-R1-0002', sector: 3 }]);
    let err: unknown;
    try { parseDecisions(JSON.stringify({ is_error: false, result })); } catch (e) { err = e; }
    expect((err as Error).message).toMatch(/decision 1 field sector/);
    expect((err as { raw?: string }).raw).toBe(result);
  });

  it('accepts a null sector so the engine refuses that one request, not the whole batch', () => {
    const d = { req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: null, ground: 'g', reason: 'r' };
    expect(parseDecisions(JSON.stringify({ is_error: false, result: JSON.stringify([d]) }))).toEqual([d]);
  });

  it('accepts a HOLD decision that carries no ground, op or sector', () => {
    const hold = { req: 'Q-R1-0001', outcome: 'HOLD', ground: null, reason: 'no sector for K-2' };
    expect(parseDecisions(JSON.stringify({ is_error: false, result: '```json\n' + JSON.stringify([hold]) + '\n```' }))).toEqual([hold]);
    expect(parseDecisions(JSON.stringify({ is_error: false, result: JSON.stringify([{ req: 'Q-R1-0001', outcome: 'HOLD', reason: 'r' }]) }))).toHaveLength(1);
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result: JSON.stringify([{ req: 'Q-R1-0001', outcome: 'HOLD' }]) }))).toThrow(/field reason/);
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result: JSON.stringify([{ ...hold, outcome: 'REFUSED' }]) }))).toThrow(/field ground/);
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result: JSON.stringify([{ req: 'Q-R1-0001', outcome: 'HOLD', reason: '  ' }]) }))).toThrow(/field reason/);
  });

  it('tells the judge to answer HOLD, never a refused outcome or a null ground, when it cannot rule', () => {
    const input = { release: 'R1', current: 'v1', versions: ['v1'], requests: [], records: [], operator: [], rulings: [], issues: [] };
    expect(judgePrompt(input, 'skill')).toMatch(/"outcome":"HOLD"/);
  });

  it('never tells the judge to refuse a request with no sector, and ties the ground rule to rulings', () => {
    const input = { release: 'R1', current: 'v1', versions: ['v1'], requests: [], records: [], operator: [], rulings: [], issues: [] };
    const prompt = judgePrompt(input, 'skill');
    expect(prompt).not.toContain('refused alone');
    expect(prompt).toContain('its ground is always a non-empty string');
  });

  it('with a Sector field configured a request with no sector is a HOLD', () => {
    vi.stubEnv('JIRA_SECTOR_FIELD', 'customfield_10500');
    const input = { release: 'R1', current: 'v1', versions: ['v1'], requests: [], records: [], operator: [], rulings: [], issues: [] };
    const prompt = judgePrompt(input, 'skill');
    expect(prompt).toContain('that request is then a HOLD');
    expect(prompt).toContain('(no sector, or the input is missing');
  });

  it('with no Sector field configured a request with no sector is ruled, not held', () => {
    vi.stubEnv('JIRA_SECTOR_FIELD', 'none');
    const input = { release: 'R1', current: 'v1', versions: ['v1'], requests: [], records: [], operator: [], rulings: [], issues: [] };
    const prompt = judgePrompt(input, 'skill');
    expect(prompt).not.toContain('that request is then a HOLD');
    expect(prompt).not.toContain('(no sector, or');
    expect(prompt).toContain('No Sector field is configured');
    expect(prompt).toMatch(/"outcome":"HOLD"/);
  });

  it('tells the judge to take the sector from the issue snapshot first', () => {
    const input = { release: 'R1', current: 'v1', versions: ['v1'], requests: [], records: [], operator: [], rulings: [], issues: [] };
    expect(judgePrompt(input, 'skill')).toContain('issues[].sector');
  });

  it('parses a valid array wrapped in prose that holds brackets', () => {
    const d = { req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 's', ground: 'g', reason: 'r' };
    const result = `Ruling [see skill] for Q-R1-0001:\n${JSON.stringify([d])}\nDone [1].`;
    expect(parseDecisions(JSON.stringify({ is_error: false, result }))).toEqual([d]);
    expect(parseDecisions(JSON.stringify({ is_error: false, result: `Ruling []:\n${JSON.stringify([d])}` }))).toEqual([d]);
  });

  it('skips a prose example that is not a decision array and takes the later valid one', () => {
    const d = { req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 's', ground: 'g', reason: 'r' };
    const result = `Example: [{"note":"sample"}]\nRuling:\n${JSON.stringify([d])}`;
    expect(parseDecisions(JSON.stringify({ is_error: false, result }))).toEqual([d]);
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result: 'Example: [{"note":"sample"}]' }))).toThrow(/decision 0 field req/);
  });

  it('gives up on a bracket-heavy reply quickly instead of trying every slice', () => {
    const result = '['.repeat(4000) + 'not-json' + ']'.repeat(4000);
    const t0 = Date.now();
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result }))).toThrow(/nothing ruled/);
    expect(Date.now() - t0).toBeLessThan(2000);
  });

  it('keeps the raw stdout when it is not a JSON envelope', () => {
    let err: unknown;
    try { parseDecisions('Error: overloaded'); } catch (e) { err = e; }
    expect((err as { raw?: string }).raw).toBe('Error: overloaded');
    expect(() => parseDecisions('null')).toThrow(/nothing ruled/);
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result: `Ruling:\n${JSON.stringify([[{ req: 'x' }]])}` }))).toThrow(/decision 0/);
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result: JSON.stringify([[{ req: 'x' }]]) }))).toThrow(/decision 0/);
  });

  it('the judge call does not inherit the calling session markers', () => {
    expect(judgeEnv({
      PATH: '/bin', CLAUDECODE: '1', CLAUDE_CODE_ENTRYPOINT: 'cli', AI_AGENT: 'x', HOME: '/h', CLAUDE_PROJECT_DIR: '/repo',
      HIMMEL_CONSOLE_LEG: '1', HIMMEL_CONSOLE_DOC: '/d.md', HIMMEL_RELEASE_MANAGER: '1', HIMMEL_RM_DOC: '/r.md', HIMMEL_WORKER_SESSION_ID: 'N1',
      ANTHROPIC_API_KEY: 'k', anthropic_base_url: 'u', CLAUDE_CODE_USE_BEDROCK: '1', HIMMEL_RELEASE_STATE_DIR: '/s',
      CLAUDE_CODE_OAUTH_TOKEN: 't',
    })).toEqual({ PATH: '/bin', HOME: '/h', HIMMEL_RELEASE_STATE_DIR: '/s', CLAUDE_CODE_OAUTH_TOKEN: 't' });
  });

  it('the judge env carries nothing of the API lane (decision 525)', () => {
    expect(judgeEnv({ PATH: '/bin', HIMMEL_API_LANE: 'on', HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_TOOLS: 'Bash,Write' })).toEqual({ PATH: '/bin' });
  });
});

const FROZEN_DESC = 'frozen: 2026-10-20\nfrozen-keys: K-1';

function writeMirror(...issues: Array<{ key: string; fixVersions: string[]; status?: string }>): string {
  const dir = join(root, 'mirror');
  mkdirSync(dir);
  writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync: '2026-10-23T00:00:00Z' }));
  for (const i of issues) {
    writeFileSync(join(dir, `${i.key}.md`), `---\nkey: ${JSON.stringify(i.key)}\nstatus: ${JSON.stringify(i.status ?? 'In Progress')}\n` +
      `type: "Task"\npriority: "Medium"\nfixVersions: ${JSON.stringify(i.fixVersions)}\n---\n`);
  }
  return dir;
}

function jiraAnswers(versions: Array<{ name: string; description?: string }>, comments: unknown[] = []) {
  vi.mocked(request).mockImplementation((async (method: string, path: string) => {
    if (path.endsWith('/versions')) return versions;
    if (path.includes('/comment') && method === 'GET') return { comments, total: comments.length };
    if (method === 'POST') return { id: 'c-1' };
    return undefined;
  }) as never);
}

describe('jira release leaks', () => {
  beforeEach(() => {
    vi.mocked(request).mockReset();
    // The mock never connects; a loopback Jira is how the post door tells a local stub from the real one.
    vi.stubEnv('JIRA_BASE_URL', 'http://127.0.0.1:9');
    vi.stubEnv('HIMMEL_ADMISSIONS_LEDGER', join(root, 'ledger.jsonl'));
    writeFileSync(join(root, 'ledger.jsonl'), JSON.stringify({
      ts: '2026-10-23T00:00:00.000Z', version: 'v1', key: 'K-3', kind: 'override', actor: 'console',
    }) + '\n');
  });

  it('prints one line per open ticket outside the frozen set and the ledger', async () => {
    jiraAnswers([{ name: 'v1', description: FROZEN_DESC }]);
    const mirror = writeMirror(
      { key: 'K-1', fixVersions: ['v1'] }, { key: 'K-2', fixVersions: ['v1'] }, { key: 'K-3', fixVersions: ['v1'] },
      { key: 'K-4', fixVersions: ['v1'], status: 'Done' }, { key: 'K-5', fixVersions: ['v2'] },
    );
    await run('leaks', 'v1', '--mirror-root', mirror);
    expect(out).toEqual(['LEAK K-2@v1 — carries v1 (frozen 2026-10-20) with no frozen-set membership and no admissions-ledger row']);
    expect(vi.mocked(request).mock.calls.some(([m]) => m === 'POST')).toBe(false);
  });

  it('says none when the version has no leak', async () => {
    jiraAnswers([{ name: 'v1', description: FROZEN_DESC }]);
    await run('leaks', 'v1', '--mirror-root', writeMirror({ key: 'K-1', fixVersions: ['v1'] }));
    expect(out).toEqual(['leaks v1: none (mirror synced 2026-10-23T00:00:00Z)']);
  });

  it('--comment posts one comment on a leak and skips one already commented', async () => {
    jiraAnswers([{ name: 'v1', description: FROZEN_DESC }]);
    const mirror = writeMirror({ key: 'K-2', fixVersions: ['v1'] });
    await run('leaks', 'v1', '--mirror-root', mirror, '--comment');
    const posts = vi.mocked(request).mock.calls.filter(([m]) => m === 'POST');
    expect(posts).toHaveLength(1);
    expect(posts[0][1]).toBe('/issue/K-2/comment');

    vi.mocked(request).mockClear();
    jiraAnswers([{ name: 'v1', description: FROZEN_DESC }], [{ id: 'c-9', body: 'x [intake-leak v1] y' }]);
    await run('leaks', 'v1', '--mirror-root', mirror, '--comment');
    expect(vi.mocked(request).mock.calls.some(([m]) => m === 'POST')).toBe(false);
  });

  it('refuses an unfrozen version and a missing mirror instead of reporting clean', async () => {
    jiraAnswers([{ name: 'v1', description: 'no freeze lines' }, { name: 'v2', description: FROZEN_DESC }]);
    await expect(run('leaks', 'v1', '--mirror-root', writeMirror())).rejects.toThrow(/not frozen/);
    await expect(run('leaks', 'v3', '--mirror-root', join(root, 'mirror'))).rejects.toThrow(/no version named "v3"/);
    await expect(run('leaks', 'v2', '--mirror-root', join(root, 'no-mirror'))).rejects.toThrow(/mirror is missing or unreadable/);
  });
});

describe('jira release state admissions budget', () => {
  const stateOut = (n: number) => ({
    release: 'R1', status: 'OK', mode: 'observe', inputs: {}, burndown: {}, admissions_today: { v1: n },
    leaks: { unauthorized: [], ruled_in_non_member: [] }, requests: { open: [], claimed: [] }, integrity: [],
  }) as never;

  it('shows the count alone without a budget, and the budget with an over-budget marker', () => {
    expect(renderState(stateOut(3))).toContain('operator admissions today: v1 3');
    expect(renderState(stateOut(3))).not.toContain('of ');
    expect(renderState(stateOut(3), { v1: 5 })).toContain('operator admissions today: v1 3 of 5');
    expect(renderState(stateOut(3), { v1: 5 })).not.toContain('OVER BUDGET');
    expect(renderState(stateOut(6), { v1: 5 })).toContain('operator admissions today: v1 6 of 5 OVER BUDGET');
  });

  it('reads admission-budget:N from the version description into the JSON state', async () => {
    const vf = join(root, 'verbatim.txt');
    await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '106', '--verbatim-file', vf);
    vi.mocked(request).mockReset();
    jiraAnswers([{ name: 'v1', description: 'notes\nadmission-budget: 4\n' }]);
    out = [];
    await run('state', 'R1', '--json', '--mirror-root', join(root, 'no-mirror'));
    expect(JSON.parse(out[0]).admission_budget).toEqual({ v1: 4 });
  });

  it('keeps the required-project-key error instead of printing the count alone', async () => {
    const vf = join(root, 'verbatim.txt');
    await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '106', '--verbatim-file', vf);
    vi.mocked(projectKey).mockImplementationOnce(() => { throw new Error('JIRA_PROJECT_KEY is required'); });
    await expect(run('state', 'R1', '--json', '--mirror-root', join(root, 'no-mirror'))).rejects.toThrow(/JIRA_PROJECT_KEY is required/);
  });

  it('parses only a whole admission-budget line', () => {
    expect(admissionBudget('a\nadmission-budget: 12\nb')).toBe(12);
    expect(admissionBudget('admission-budget:x')).toBeUndefined();
    expect(admissionBudget('see admission-budget: 3 here')).toBeUndefined();
    expect(admissionBudget(undefined)).toBeUndefined();
  });
});

describe('jira release request refuses junk', () => {
  const vf = () => join(root, 'verbatim.txt');
  const declared = () => run('operator', 'declare', 'R1', '--versions', 'v1,v2', '--decision', '106', '--verbatim-file', vf());
  const ask = (mirror: string, ...a: string[]) => run('request', 'R1', '--mirror-root', mirror, ...a);

  it('refuses a placeholder why', async () => {
    await declared();
    const mir = writeMirror();
    for (const why of ['w', 'tbd', 'filed to the backlog: x', 'filed to the backlog: test']) {
      await expect(ask(mir, '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', why)).rejects.toThrow(/placeholder/);
    }
    await ask(mir, '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'filed to the backlog: the console loses a worker');
    expect(out.at(-1)).toBe('REQ Q-R1-0001');
  });

  it('refuses an INTAKE for a closed ticket outside the release', async () => {
    await declared();
    const mir = writeMirror({ key: 'K-77', fixVersions: ['v0.9'], status: 'Done' }, { key: 'K-1', fixVersions: [], status: 'Done' });
    await expect(ask(mir, '--verb', 'INTAKE', '--key', 'K-77', '--to', 'v1', '--why', 'filed to the backlog: found work'))
      .rejects.toThrow(/K-77 is closed .*outside R1/);
    await expect(ask(mir, '--verb', 'INTAKE', '--key', 'K-1', '--to', 'v1', '--why', 'filed to the backlog: found work'))
      .rejects.toThrow(/K-1 is closed/);
    await expect(ask(mir, '--verb', 'INTAKE', '--key', 'K-1', '--to', 'v1', '--why', 'merged in PR #12: Done folds into v1', '--evidence', '{"pr":true}'))
      .rejects.toThrow(/K-1 is closed/);
    await ask(mir, '--verb', 'INTAKE', '--key', 'K-1', '--to', 'v1', '--why', 'merged in PR #12: Done folds into v1', '--evidence', '{"pr":12}');
    expect(out.at(-1)).toBe('REQ Q-R1-0001');
  });

  it('refuses a REVERSION from a version the mirror does not hold the key in', async () => {
    await declared();
    const mir = writeMirror({ key: 'K-5', fixVersions: ['v2'] });
    await expect(ask(mir, '--verb', 'REVERSION', '--key', 'K-5', '--from', 'v1', '--why', 'moves out of the version'))
      .rejects.toThrow(/K-5 is in v2, not v1.*jira mirror/);
    await ask(mir, '--verb', 'REVERSION', '--key', 'K-5', '--from', 'v2', '--why', 'moves out of the version');
    expect(out.at(-1)).toBe('REQ Q-R1-0001');
  });

  function jiraLabels(held: string[], stuck: string[] = []) {
    const now = { labels: [...held] };
    vi.mocked(request).mockImplementation((async (method: string, _path: string, body?: { update: { labels: Array<{ remove: string }> } }) => {
      if (method === 'PUT') {
        const gone = body!.update.labels.map((l) => l.remove);
        now.labels = now.labels.filter((l) => !gone.includes(l) || stuck.includes(l));
        return {};
      }
      return { fields: { labels: [...now.labels] } };
    }) as never);
    return now;
  }
  const puts = () => vi.mocked(request).mock.calls.filter((c) => c[0] === 'PUT');

  it('withdraws a request from the CLI', async () => {
    await declared();
    const mir = writeMirror();
    await ask(mir, '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'filed to the backlog: found work');
    jiraLabels([]);
    await run('withdraw', 'R1', '--req', 'Q-R1-0001', '--reason', 'junk from a test run');
    expect(out.at(-1)).toBe('WITHDRAWN Q-R1-0001 (withdrawn:console): junk from a test run');
    expect(puts()).toHaveLength(0);
  });

  it('a withdrawn INTAKE loses its proposed-* labels and keeps backlog, phase:* and held', async () => {
    await declared();
    const mir = writeMirror();
    await ask(mir, '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'filed to the backlog: found work');
    const jira = jiraLabels(['backlog', 'proposed-v1.2', 'phase:build', 'held']);
    await run('withdraw', 'R1', '--req', 'Q-R1-0001', '--reason', 'junk from a test run');
    expect(jira.labels).toEqual(['backlog', 'phase:build', 'held']);
    expect(puts().map((c) => [c[1], c[2]])).toEqual([['/issue/K-2', { update: { labels: [{ remove: 'proposed-v1.2' }] } }]]);
  });

  it('a withdrawn INTAKE whose label survives the removal fails loud, naming the label', async () => {
    await declared();
    const mir = writeMirror();
    await ask(mir, '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'filed to the backlog: found work');
    jiraLabels(['proposed-v1.2'], ['proposed-v1.2']);
    await expect(run('withdraw', 'R1', '--req', 'Q-R1-0001', '--reason', 'junk from a test run')).rejects.toThrow(/K-2 still carries proposed-v1\.2/);
  });

  it('a withdrawn REVERSION touches no label', async () => {
    await declared();
    const mir = writeMirror({ key: 'K-5', fixVersions: ['v2'] });
    await ask(mir, '--verb', 'REVERSION', '--key', 'K-5', '--from', 'v2', '--why', 'moves out of the version');
    vi.mocked(request).mockClear();
    await run('withdraw', 'R1', '--req', 'Q-R1-0001', '--reason', 'junk from a test run');
    expect(request).not.toHaveBeenCalled();
  });
});

describe('jira release pull', () => {
  const issue = (key: string, fixVersions: string[], blockedBy: string[] = []) =>
    writeFileSync(join(root, 'mirror', `${key}.md`), [
      '---', `key: "${key}"`, 'type: "Task"', 'status: "To Do"', 'priority: "Medium"', `fixVersions: ${JSON.stringify(fixVersions)}`,
      'resolution: null', 'links:', '  blocks: []', `  blocked_by: ${JSON.stringify(blockedBy)}`, '  relates: []', '---', '',
    ].join('\n'));

  it('lists each blocker, files one INTAKE for it, and a re-run files none', async () => {
    await run('operator', 'declare', 'R1', '--versions', 'v1,v2', '--decision', '106', '--verbatim-file', join(root, 'verbatim.txt'));
    mkdirSync(join(root, 'mirror'));
    writeFileSync(join(root, 'mirror', '.cursor.json'), JSON.stringify({ lastSync: '2026-10-21T09:00:00.000Z' }));
    issue('K-1', ['v1'], ['K-2']);
    issue('K-2', ['v2']);
    const mirrorRoot = join(root, 'mirror');
    await run('pull', 'R1', '--mirror-root', mirrorRoot, '--dry-run');
    await run('pull', 'R1', '--mirror-root', mirrorRoot);
    await run('pull', 'R1', '--mirror-root', mirrorRoot);
    expect(out.slice(1)).toEqual(['PULL K-2 for K-1 from v2 to v1', 'PULL K-2 for K-1 from v2 to v1 REQ Q-R1-0001']);
  });

  it('refuses a second standing record and an unknown kind', async () => {
    await run('operator', 'declare', 'R1', '--versions', 'v1,v2', '--decision', '106', '--verbatim-file', join(root, 'verbatim.txt'));
    await expect(run('operator', 'standing', 'R1', '--kind', 'blocker-pull', '--decision', '385', '--verbatim-file', join(root, 'verbatim.txt')))
      .rejects.toThrow(/already recorded/);
    await expect(run('operator', 'standing', 'R1', '--kind', 'other', '--decision', '385', '--verbatim-file', join(root, 'verbatim.txt')))
      .rejects.toThrow(/--kind is blocker-pull/);
  });
});

describe('jira release under vitest', () => {
  it('refuses a release state dir outside the temp dir', async () => {
    vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', '/srv/handovers/release');
    await expect(run('state', 'R1')).rejects.toThrow(/outside the temp dir/);
  });
});

describe.skipIf(process.platform !== 'linux')('jira release posting verbs from a test on the station', () => {
  const failure = async (...args: string[]): Promise<string> => {
    try {
      await run(...args);
      return '';
    } catch (e) {
      return (e as Error).message;
    }
  };

  beforeEach(() => {
    vi.stubEnv('HIMMEL_REAL_STATE_ASSUME_STATION', '1');
  });

  it('refuses apply and rm-run against a real Jira host before any post', async () => {
    vi.stubEnv('JIRA_BASE_URL', 'http://jira.invalid');
    expect(await failure('apply', 'R1', 'RU-1')).toMatch(/release apply: refused, nothing was posted/);
    expect(await failure('rm-run', 'R1')).toMatch(/release rm-run: refused, nothing was posted/);
    expect(request).not.toHaveBeenCalled();
  });

  it('lets apply and rm-run past the door against a loopback Jira', async () => {
    vi.stubEnv('JIRA_BASE_URL', 'http://127.0.0.1:9');
    expect(await failure('apply', 'R1', 'RU-1')).toMatch(/release R1 is UNKNOWN/);
    expect(await failure('rm-run', 'R1')).toMatch(/release R1 is UNKNOWN/);
  });
});

describe('liveJira.newestFixVersionEntry', () => {
  type Entry = { id: string; created: string; items: Array<{ field: string }> };
  const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '..', 'release', 'fixtures', 'repair');
  const real = (n: number): Entry[] => (JSON.parse(readFileSync(join(FIXTURES, `HIMMEL-${n}.json`), 'utf8')) as { changelog: Entry[] }).changelog;
  const serve = (all: Entry[]) =>
    vi.mocked(request).mockImplementation((async (_m: string, path: string) => {
      const start = Number(/startAt=(\d+)/.exec(path)?.[1] ?? 0);
      return { startAt: start, maxResults: 100, total: all.length, values: all.slice(start, start + 100) };
    }) as never);

  it('adapter picks the newest of several entries', async () => {
    const all = real(3084);
    serve(all);
    const newest = all.find((e) => e.id === '57628') as Entry;
    expect(await liveJira.newestFixVersionEntry('HIMMEL-3084')).toEqual({ id: '57628', ts: newest.created });
  });

  it('adapter returns create with no Fix Version entry', async () => {
    serve([]);
    expect(await liveJira.newestFixVersionEntry('HIMMEL-1')).toEqual({ id: 'create', ts: '' });
  });

  it('adapter returns create when only other fields changed', async () => {
    serve(real(8706));
    expect(await liveJira.newestFixVersionEntry('HIMMEL-8706')).toEqual({ id: 'create', ts: '' });
  });

  it('adapter reads the last page', async () => {
    const filler: Entry[] = Array.from({ length: 100 }, (_, i) => ({ id: String(i + 1), created: 'c', items: [{ field: 'summary' }] }));
    const all = [...filler, ...real(3084)];
    expect(all.length).toBeGreaterThan(100);
    serve(all);
    expect((await liveJira.newestFixVersionEntry('HIMMEL-3084')).id).toBe('57628');
    expect(vi.mocked(request).mock.calls.some((c) => String(c[1]).includes('startAt=100'))).toBe(true);
  });
});

// The judge reaches the API launcher only when the role map maps `judge`. A temp launcher world
// (roster, snapshot, key files, a fake claude, an alert recorder) and a recording fallback: no row reaches the real
// liveJudge, a real claude or the real alert sender, and no row reads the station's role map.
describe('routedJudge', () => {
  const INPUT = { release: 'R1', current: 'v1', versions: ['v1'], requests: [], records: [], operator: [], rulings: [], issues: [] } as unknown as JudgeInput;
  const decision = (reason: string) => ({ req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 's', ground: 'g', reason });
  const envelope = (reason: string) => JSON.stringify({ is_error: false, result: JSON.stringify([decision(reason)]) });
  let dir: string;
  const pathWithEmptyPs = (psDir: string): string => `${psDir}:${process.env.PATH ?? ''}`;

  function world(roles: unknown, fake: { out?: string; rc?: number; sleep?: number } = {}) {
    dir = mkdtempSync(join(root, 'world-'));
    const now = Math.floor(Date.now() / 1000);
    const config = { version: 1, ledger_path: join(dir, 'ledger.json'), accounts: {
      A: { organization_id: 'org-a', cycle_id: 'cycle-a', cap_usd: '5.00', key_id: 'key-a', reset_at: '2099-01-01T00:00:00Z' },
      B: { organization_id: 'org-b', cycle_id: 'cycle-b', cap_usd: '5.00', key_id: 'key-b', reset_at: '2099-01-01T00:00:00Z' },
    } };
    const snapshot = { version: 1, accounts: Object.fromEntries(['A', 'B'].map((a) => [a, {
      organization_id: `org-${a.toLowerCase()}`, cycle_id: `cycle-${a.toLowerCase()}`, grant_usd: '5.00', remaining_usd: '5.00', reconciled_spent_usd: '0',
      starts_at: now - 1000, expires_at: now + 3600, observed_at: now, source: 'operator-console-snapshot', exclusive_org: true, discrepancy: false,
    }])) };
    writeFileSync(join(dir, 'config.json'), JSON.stringify(config));
    writeFileSync(join(dir, 'snapshot.json'), JSON.stringify(snapshot));
    for (const a of ['A', 'B']) writeFileSync(join(dir, `key-${a}.env`), `ANTHROPIC_API_KEY=sk-ant-dummy-${a}-0000\n`, { mode: 0o600 });
    if (roles !== undefined) writeFileSync(join(dir, 'roles.json'), JSON.stringify({ version: 1, roles }));
    const script = (name: string, body: string) => { writeFileSync(join(dir, name), `#!/bin/bash\n${body}\n`); chmodSync(join(dir, name), 0o700); };
    script('claude-fake', `{ echo "cwd=$PWD"; echo "acct=\${HIMMEL_API_ACCOUNT:-}"; printf 'arg=%s\\n' "$@"; echo --; } >> '${join(dir, 'fake.log')}'\n${fake.sleep ? `echo "pid=$$" >> '${join(dir, 'fake.log')}'\nsleep ${fake.sleep}\n` : ''}printf '%s' '${fake.out ?? envelope('from-fake')}'\nexit ${fake.rc ?? 0}`);
    script('alert-stub', `echo "alert $TG_MESSAGE" >> '${join(dir, 'alert.log')}'`);
    script('ps', 'exit 0');
    writeFileSync(join(dir, 'native-cache.json'), JSON.stringify({ five_hour: { utilization: 100 }, seven_day: { utilization: 100 } }));
    const set: Record<string, string> = {
      HIMMEL_API_CREDIT_CONFIG: join(dir, 'config.json'), HIMMEL_API_CREDIT_SNAPSHOT: join(dir, 'snapshot.json'),
      HIMMEL_API_CREDIT_STATE: join(dir, 'ledger.json'), HIMMEL_API_CLAUDE_BIN: join(dir, 'claude-fake'),
      HIMMEL_API_ALERT_DIR: join(dir, 'alerts'), HIMMEL_API_ALERT_CMD: join(dir, 'alert-stub'), HIMMEL_API_LOCK_WAIT_MS: '2000',
      HIMMEL_FLEET_SLOTS: join(dir, 'slots'), PATH: pathWithEmptyPs(dir),
      CADENCE_USAGE_LEDGER: join(dir, 'bank-ledger'), CADENCE_USAGE_SKIP_REFRESH: '1', CADENCE_USAGE_CACHE: join(dir, 'native-cache.json'),
      ANTHROPIC_API_KEY: '', HIMMEL_API_KEY_ID: '',
    };
    for (const [k, v] of Object.entries(set)) vi.stubEnv(k, v);
    const fallbackCalls: JudgeInput[] = [];
    const fallback: Judge = async (i) => { fallbackCalls.push(i); return [decision('from-fallback')] as never; };
    const read = (f: string) => (existsSync(join(dir, f)) ? readFileSync(join(dir, f), 'utf8') : '');
    return { fallback, fallbackCalls, read };
  }

  it('the outer spawn timeout outlasts the launcher call timeout plus its five-second kill grace', () => {
    expect(JUDGE_SPAWN_TIMEOUT_MS).toBeGreaterThan((JUDGE_TIMEOUT_S + 5) * 1000);
  });

  it('unmapped: the fallback answers and the fake claude never runs', async () => {
    const w = world(undefined);
    const got = await makeRoutedJudge(w.fallback)(INPUT);
    expect(got[0]).toMatchObject({ reason: 'from-fallback' });
    expect(w.fallbackCalls).toHaveLength(1);
    expect(w.read('fake.log')).toBe('');
    expect(existsSync(join(dir, 'alerts', 'policy-refusals.jsonl'))).toBe(false);
  });

  it('mapped judge:[B]: the fake answers on account B with no tools, no settings, no turn cap and an empty cwd', async () => {
    const w = world({ judge: ['B'] });
    const got = await makeRoutedJudge(w.fallback)(INPUT);
    expect(got[0]).toMatchObject({ reason: 'from-fake' });
    expect(w.fallbackCalls).toHaveLength(0);
    expect(JSON.parse(w.read('launches.jsonl').trim()).account).toBe('B');
    expect(existsSync(join(dir, 'alerts', 'policy-refusals.jsonl'))).toBe(false);
    const log = w.read('fake.log');
    expect(log).toMatch(/^acct=B$/m);
    const args = [...log.matchAll(/^arg=(.*)$/gm)].map((m) => m[1]);
    expect(args[args.indexOf('--tools') + 1]).toBe('');
    expect(args[args.indexOf('--permission-mode') + 1]).toBe('plan');
    for (const bad of ['--settings', '--max-turns', '--mcp-config']) expect(args).not.toContain(bad);
    const cwd = /^cwd=(.*)$/m.exec(log)?.[1] ?? '';
    expect(cwd).not.toBe('');
    expect(cwd.startsWith(join(dir, '..'))).toBe(false);
    expect(existsSync(join(cwd, '.git'))).toBe(false);
  });

  it('judgeApiEnv carries exactly the pass-through names plus the pins and no other HIMMEL_API_ name', () => {
    const wide: NodeJS.ProcessEnv = { HIMMEL_API_FOO: '1', HIMMEL_API_ACCOUNT: 'A', HIMMEL_API_KIND: 'eval', ANTHROPIC_API_KEY: 'k', PATH: '/bin' };
    for (const k of JUDGE_API_PASS_ENV) wide[k] = `v-${k}`;
    const got = judgeApiEnv(wide, '/repo/.git');
    const keys = Object.keys(got).filter((k) => k.startsWith('HIMMEL_API_')).sort();
    const pins = ['HIMMEL_API_LANE', 'HIMMEL_API_ACCOUNT', 'HIMMEL_API_KIND', 'HIMMEL_API_FALLBACK', 'HIMMEL_API_TOOLS', 'HIMMEL_API_CALL_TIMEOUT_S', 'HIMMEL_API_AUTO_REPO_DIR'];
    expect(keys).toEqual([...JUDGE_API_PASS_ENV, ...pins].sort());
    expect(got).toMatchObject({ HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'judge', HIMMEL_API_FALLBACK: 'off', HIMMEL_API_TOOLS: '', HIMMEL_API_CALL_TIMEOUT_S: '900', HIMMEL_API_AUTO_REPO_DIR: '/repo/.git' });
    expect(got).not.toHaveProperty('ANTHROPIC_API_KEY');
    expect(got.HIMMEL_API_CREDIT_CONFIG).toBe('v-HIMMEL_API_CREDIT_CONFIG');
  });

  it('mapped, launcher exit non-zero: the fallback answers and the fake ran exactly once (fallback off)', async () => {
    const w = world({ judge: ['B'] }, { rc: 2, out: 'boom' });
    const got = await makeRoutedJudge(w.fallback)(INPUT);
    expect(got[0]).toMatchObject({ reason: 'from-fallback' });
    expect(w.fallbackCalls).toHaveLength(1);
    expect((w.read('fake.log').match(/^--$/gm) ?? []).length).toBe(1);
    expect(w.read('alert.log')).not.toBe('');
  });

  const ancestor = (pid: number, name: string): number => {
    for (let p = pid; p > 1; p = Number(readFileSync(`/proc/${p}/stat`, 'utf8').replace(/^.*\) /, '').split(' ')[1])) {
      if (readFileSync(`/proc/${p}/cmdline`, 'utf8').includes(name)) return p;
    }
    throw new Error(`no ${name} above pid ${pid}`);
  };
  const fakePid = (w: ReturnType<typeof world>) => Number(/^pid=(\d+)$/m.exec(w.read('fake.log'))?.[1]);

  it('mapped, the run stopped mid-call: the call is killed and no fallback runs', async () => {
    const w = world({ judge: ['B'] }, { sleep: 30 });
    const stop = new AbortController();
    const got = makeRoutedJudge(w.fallback)(INPUT, { signal: stop.signal });
    await vi.waitFor(() => expect(fakePid(w)).toBeGreaterThan(0), { timeout: 10_000 });
    stop.abort(new Error('rm-run: stopped by SIGTERM; nothing more ruled'));
    await expect(got).rejects.toThrow();
    expect(w.fallbackCalls).toHaveLength(0);
  }, 20_000);

  it.skipIf(process.platform !== 'linux')('mapped, TERM to the launcher alone: it exits 143 and no fallback runs', async () => {
    const w = world({ judge: ['B'] }, { sleep: 30 });
    const got = makeRoutedJudge(w.fallback)(INPUT);
    await vi.waitFor(() => expect(fakePid(w)).toBeGreaterThan(0), { timeout: 10_000 });
    process.kill(ancestor(fakePid(w), 'claude-api.sh'), 'SIGTERM');
    await expect(got).rejects.toMatchObject({ status: 143 });
    expect(w.fallbackCalls).toHaveLength(0);
  }, 20_000);

  it('mapped, the launcher times out its own call: the run fails and no fallback runs', async () => {
    const w = world({ judge: ['B'] }, { sleep: 30 });
    const t0 = Date.now();
    await expect(makeRoutedJudge(w.fallback, 2)(INPUT)).rejects.toThrow();
    expect(Date.now() - t0).toBeLessThan(15_000);
    expect(w.fallbackCalls).toHaveLength(0);
  }, 20_000);

  it('mapped, node kills the launcher at its spawn timeout: it exits 143, the run fails and no fallback runs', async () => {
    const w = world({ judge: ['B'] }, { sleep: 30 });
    await expect(makeRoutedJudge(w.fallback, 60, 2000)(INPUT)).rejects.toMatchObject({ killed: true, status: 143 });
    expect(w.fallbackCalls).toHaveLength(0);
  }, 20_000);

  it('judgeCall kills a call past its timeout and says so', async () => {
    const t0 = Date.now();
    await expect(judgeCall('bash', ['-c', 'sleep 5'], { input: '', cwd: root, env: process.env, timeoutMs: 100 }))
      .rejects.toThrow('rm-run: the judge call (bash) timed out after 0.1s; nothing ruled');
    expect(Date.now() - t0).toBeLessThan(3000);
  });

  it('mapped, unparseable output: the fallback answers', async () => {
    const w = world({ judge: ['B'] }, { out: 'not json at all' });
    const got = await makeRoutedJudge(w.fallback)(INPUT);
    expect(got[0]).toMatchObject({ reason: 'from-fallback' });
  });

  it('judgeFor: the himmel mirror routes, any other mirror (a SALUS one, or slice A\'s no-mirror) is liveJudge', () => {
    const w = world({ judge: ['B'] });
    void w;
    expect(judgeFor(ctxFor('R1', defaultRoot('HIMMEL')))).toBe(routedJudge);
    expect(judgeFor(ctxFor('R1', defaultRoot('SALUS')))).toBe(liveJudge);
    expect(judgeFor(ctxFor('R1', join(root, 'no-mirror')))).toBe(liveJudge);
    expect(w.read('fake.log')).toBe('');
  });
});

describe('liveJira labels', () => {
  it('reads the labels and removes them with one update call', async () => {
    vi.mocked(request).mockReset();
    vi.mocked(request).mockImplementation((async () => ({ fields: { labels: ['backlog', 'proposed-v1'] } })) as never);
    expect(await liveJira.labels('HIMMEL-1')).toEqual(['backlog', 'proposed-v1']);
    expect(vi.mocked(request).mock.calls[0].slice(0, 2)).toEqual(['GET', '/issue/HIMMEL-1?fields=labels']);
    await liveJira.removeLabels('HIMMEL-1', ['proposed-v1', 'proposed-v2']);
    expect(vi.mocked(request).mock.calls[1]).toEqual(['PUT', '/issue/HIMMEL-1', { update: { labels: [{ remove: 'proposed-v1' }, { remove: 'proposed-v2' }] } }]);
  });
});

describe('RM apply names its writer', () => {
  it('RM apply names rm-apply', async () => {
    vi.mocked(request).mockImplementation((async (method: string) =>
      method === 'GET' ? { fields: { fixVersions: [{ name: 'v1' }] } } : {}) as never);
    await liveJira.setFixVersion('HIMMEL-1', 'add', 'v1');
    const put = vi.mocked(request).mock.calls.find((c) => c[0] === 'PUT');
    expect(put?.[3]).toBe('rm-apply');
  });
});

describe('jira release bucket-check', () => {
  const vf = () => join(root, 'verbatim.txt');
  const declared = () => run('operator', 'declare', 'R1', '--versions', 'v1.1.9,v1.1.10', '--decision', '106', '--verbatim-file', vf());
  function projectMirror(...issues: Array<{ key: string; fixVersions: string[]; category?: string }>): string {
    const dir = join(root, 'jira-mirror', 'HIMMEL');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync: '2026-11-08T00:00:00Z' }));
    for (const i of issues) {
      writeFileSync(join(dir, `${i.key}.md`), `---\nkey: ${JSON.stringify(i.key)}\nstatus: "x"\nstatusCategory: ${JSON.stringify(i.category ?? 'To Do')}\n`
        + `type: "Task"\npriority: "Medium"\nfixVersions: ${JSON.stringify(i.fixVersions)}\n---\n`);
    }
    writeFileSync(`${dir}.versions.tsv`, 'v1.1.9\tfalse\t\tfalse\nv1.1.10\tfalse\t\tfalse\n');
    return dir;
  }
  const approve = (key: string, decision: string, ageDays: number) => appendChain(join(root, 'state', 'R1', 'operator.jsonl'), loadKey(join(root, 'keys', 'R1.key')), {
    id: `O-R1-ov-${decision}`, kind: 'out-of-version', decision, keys: [key], ts: new Date(Date.now() - ageDays * 86_400_000).toISOString(),
  });

  it('prints one verdict line per key in the order given', async () => {
    await declared();
    const mir = projectMirror({ key: 'HIMMEL-1', fixVersions: ['v1.1.9'] }, { key: 'HIMMEL-2', fixVersions: ['v1.1.10'], category: 'Done' });
    out = [];
    await run('bucket-check', '--mirror', mir, 'HIMMEL-2', 'HIMMEL-1');
    expect(out).toEqual(['DONE HIMMEL-2', 'IN HIMMEL-1 current=v1.1.9 via=mirror']);
    expect(process.exitCode ?? 0).toBe(0);
  });

  it('with no --mirror exits non-zero and prints no verdict line, whether JIRA_PROJECT_KEY is set or not', async () => {
    await declared();
    projectMirror({ key: 'HIMMEL-1', fixVersions: ['v1.1.9'] });
    out = [];
    for (const pk of ['HIMMEL', '']) {
      vi.stubEnv('JIRA_PROJECT_KEY', pk);
      await expect(run('bucket-check', 'HIMMEL-1')).rejects.toMatchObject({ exitCode: 1, code: 'commander.missingMandatoryOptionValue' });
    }
    expect(out).toEqual([]);
  });

  it('a key the mirror does not hold in current asks Jira, and a failed read is FAILED by name', async () => {
    await declared();
    const mir = projectMirror({ key: 'HIMMEL-5', fixVersions: ['v1.1.10'] });
    out = [];
    await run('bucket-check', '--mirror', mir, 'HIMMEL-5');
    expect(out).toHaveLength(1);
    expect(out[0]).toBe('FAILED HIMMEL-5 the live read of HIMMEL-5 failed: fetch failed');
  });

  it('an INTAKE on an approved key answers REQ approved:<id> and writes no row; a REVERSION on it still files', async () => {
    await declared();
    const mir = projectMirror({ key: 'HIMMEL-7', fixVersions: ['v1.1.10'] });
    approve('HIMMEL-7', '901', 1);
    vi.mocked(request).mockReset();
    vi.mocked(request).mockImplementation((async () => ({ fields: { labels: [] } })) as never);
    out = [];
    await run('request', 'R1', '--mirror-root', mir, '--verb', 'INTAKE', '--key', 'HIMMEL-7', '--from', 'v1.1.10', '--to', 'v1.1.9', '--why', 'worked under the chief: fold it in');
    expect(out).toEqual(['REQ approved:O-R1-ov-901']);
    expect(existsSync(join(root, 'state', 'R1', 'requests.jsonl'))).toBe(false);
    approve('HIMMEL-8', '902', 15);
    await run('request', 'R1', '--mirror-root', mir, '--verb', 'INTAKE', '--key', 'HIMMEL-8', '--to', 'v1.1.9', '--why', 'worked under the chief: fold it in');
    expect(out.at(-1)).toBe('REQ Q-R1-0001');
    await run('request', 'R1', '--mirror-root', mir, '--verb', 'REVERSION', '--key', 'HIMMEL-7', '--from', 'v1.1.10', '--to', 'backlog', '--why', 'moves out of the version');
    expect(out.at(-1)).toBe('REQ Q-R1-0002');
  });

  it('the approved INTAKE clears a proposed-* label on the key, since its proposal ends there', async () => {
    await declared();
    const mir = projectMirror({ key: 'HIMMEL-7', fixVersions: ['v1.1.10'] });
    approve('HIMMEL-7', '901', 1);
    let labels = ['core', 'proposed-v1.1.9'];
    vi.mocked(request).mockReset();
    vi.mocked(request).mockImplementation((async (method: string) => {
      if (method === 'PUT') labels = labels.filter((l) => !l.startsWith('proposed-'));
      return { fields: { labels } };
    }) as never);
    out = [];
    await run('request', 'R1', '--mirror-root', mir, '--verb', 'INTAKE', '--key', 'HIMMEL-7', '--to', 'v1.1.9', '--why', 'worked under the chief: fold it in');
    expect(out).toEqual(['REQ approved:O-R1-ov-901']);
    expect(vi.mocked(request).mock.calls.find((c) => c[0] === 'PUT')).toEqual(['PUT', '/issue/HIMMEL-7', { update: { labels: [{ remove: 'proposed-v1.1.9' }] } }]);
    expect(labels).toEqual(['core']);
  });

  it('a failed label clear on an approved INTAKE warns and keeps the REQ line and exit 0, which the folds read', async () => {
    await declared();
    const mir = projectMirror({ key: 'HIMMEL-7', fixVersions: ['v1.1.10'] });
    approve('HIMMEL-7', '901', 1);
    vi.mocked(request).mockReset();
    vi.mocked(request).mockImplementation((async () => { throw new Error('HTTP 503'); }) as never);
    const err = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    out = [];
    process.exitCode = undefined;
    await run('request', 'R1', '--mirror-root', mir, '--verb', 'INTAKE', '--key', 'HIMMEL-7', '--to', 'v1.1.9', '--why', 'worked under the chief: fold it in');
    expect(out).toEqual(['REQ approved:O-R1-ov-901']);
    expect(process.exitCode ?? 0).toBe(0);
    expect(err).toHaveBeenCalledWith('release request: WARN HTTP 503');
  });
});

describe('jira release operator out-of-version', () => {
  const decisions = () => join(root, 'specs', 'decisions');
  const header = 'Decision 699, operator, 2026-11-06, relayed by the bridge chat to chief TA.';
  const reading = 'Reading is the bridge\'s, unconfirmed: signs HIMMEL-9001 v2.';
  let mir: string;
  let sent: string;

  function decisionFile(name: string, text: string, dir = decisions()): string {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, name), text);
    return join(dir, name);
  }
  const f699 = () => decisionFile('verbatim-decision-699-operator-11-06-TA.txt', `${header}\n\nVerbatim:\n"9001 signed"\n\n${reading}\n`);
  const grant = (...extra: string[]) => {
    const args = ['--key', 'HIMMEL-7', '--decision', '699', '--verbatim-file', f699(), '--reason', 'the operator wants it this week', '--mirror-root', mir];
    for (let i = 0; i < extra.length; i += 2) {
      const at = args.indexOf(extra[i]);
      if (at >= 0) args.splice(at, 2);
      if (extra[i + 1] !== undefined) args.push(extra[i], extra[i + 1]);
    }
    return run('operator', 'out-of-version', 'R1', ...args);
  };
  const rows = () => {
    const p = join(root, 'state', 'R1', 'operator.jsonl');
    return readFileSync(p, 'utf8').trim().split('\n').map((l) => JSON.parse(l) as Record<string, unknown>).filter((r) => r.kind === 'out-of-version');
  };
  const sender = (body: string) => {
    writeFileSync(join(root, 'sender.sh'), `#!/usr/bin/env bash\n${body}\n`);
    chmodSync(join(root, 'sender.sh'), 0o755);
  };

  beforeEach(async () => {
    await run('operator', 'declare', 'R1', '--versions', 'v1.1.9,v1.1.10', '--decision', '106', '--verbatim-file', join(root, 'verbatim.txt'));
    mir = join(root, 'jira-mirror', 'HIMMEL');
    mkdirSync(mir, { recursive: true });
    writeFileSync(join(mir, '.cursor.json'), JSON.stringify({ lastSync: '2026-11-08T00:00:00Z' }));
    for (const k of ['HIMMEL-7', 'HIMMEL-8']) {
      writeFileSync(join(mir, `${k}.md`), `---\nkey: "${k}"\nstatus: "x"\nstatusCategory: "To Do"\ntype: "Task"\npriority: "Medium"\nfixVersions: ["v1.1.10"]\n---\n`);
    }
    writeFileSync(`${mir}.versions.tsv`, 'v1.1.9\tfalse\t\tfalse\nv1.1.10\tfalse\t\tfalse\n');
    sent = join(root, 'sent.txt');
    sender(`printf '%s' "$2" > ${JSON.stringify(sent)}`);
    writeFileSync(join(root, 'access.json'), '{"allowFrom":["4242"]}\n');
    vi.stubEnv('TELEGRAM_ACCESS_PATH', join(root, 'access.json'));
    vi.stubEnv('MERGE_BLOCK_ALERT_CMD', join(root, 'sender.sh'));
    vi.stubEnv('HIMMEL_TEST_FIXTURE', '1');
    vi.stubEnv('BRIDGE_ROOT', '');
    out = [];
  });

  it('a good send signs one row; the phone gets the block\'s words and not the chief\'s header or reading; bucket-check then reads APPROVED', async () => {
    await grant();
    const [row] = rows();
    expect(rows()).toHaveLength(1);
    expect(row).toMatchObject({ kind: 'out-of-version', decision: '699', keys: ['HIMMEL-7'], version: 'v1.1.10', reason: 'the operator wants it this week' });
    expect(row.verbatim).toBe(readFileSync(f699(), 'utf8').trim());
    expect(out.at(-1)).toMatch(new RegExp(`^${String(row.id)} out-of-version for HIMMEL-7 \\(decision 699\\), valid until \\d{4}-`));
    const text = readFileSync(sent, 'utf8');
    expect(text).toContain('"9001 signed"');
    expect(text).toContain('HIMMEL-7 (in v1.1.10), decision 699');
    expect(text).toContain('1 approvals open');
    expect(text).not.toContain(header);
    expect(text).not.toContain('Reading is');
    out = [];
    await run('bucket-check', '--mirror', mir, 'HIMMEL-7');
    expect(out).toEqual([`APPROVED HIMMEL-7 decision=699 record=${String(row.id)}`]);
  });

  it('the open count on the line counts the approvals still open, this one included', async () => {
    await grant();
    await grant('--key', 'HIMMEL-8');
    expect(rows()).toHaveLength(2);
    expect(readFileSync(sent, 'utf8')).toContain('HIMMEL-8 (in v1.1.10), decision 699, for 14 days; 2 approvals open');
  });

  it('a sender that exits 1 leaves no row', async () => {
    sender('exit 1');
    await expect(grant()).rejects.toThrow('release operator out-of-version: the operator alert exited 1; no record written');
    expect(rows()).toEqual([]);
  });

  it('a refused send, which the alert reports as 77, leaves no row', async () => {
    vi.stubEnv('MERGE_BLOCK_ALERT_CMD', '');
    await expect(grant()).rejects.toThrow('the operator alert exited 77 (the send was refused); no record written');
    expect(rows()).toEqual([]);
  });

  it('no operator chat id leaves no row', async () => {
    vi.stubEnv('TELEGRAM_ACCESS_PATH', join(root, 'absent.json'));
    await expect(grant()).rejects.toThrow('the operator alert exited 1; no record written');
    expect(rows()).toEqual([]);
  });

  it.each([
    ['inside a worker', () => vi.stubEnv('HIMMEL_CONSOLE_LEG', '1'), [] as string[], /refused inside a chief-spawned worker/],
    ['inside the release manager', () => vi.stubEnv('HIMMEL_RELEASE_MANAGER', '1'), [], /refused inside a chief-spawned worker/],
    ['two keys in one record', () => undefined, ['--key', 'HIMMEL-7,HIMMEL-8'], /'HIMMEL-7,HIMMEL-8' is not one ticket key/],
    ['a file outside specs/decisions', () => undefined,
      ['--verbatim-file', 'OUTSIDE'], /is not a verbatim-decision-<n>-\* file in .*\/specs\/decisions$/],
    ['a decisions file not named verbatim-decision-<n>-*', () => undefined, ['--verbatim-file', 'UNNAMED'], /is not a verbatim-decision-<n>-\* file/],
    ['a file numbered other than --decision', () => undefined, ['--decision', '700'], /verbatim-decision-699-operator-11-06-TA\.txt is decision 699, not --decision 700/],
    ['a file with no Verbatim: block', () => undefined, ['--decision', '684', '--verbatim-file', 'NOBLOCK'], /no line starting 'Verbatim:'/],
    ['the reason tbd', () => undefined, ['--reason', 'tbd'], /"tbd" is a placeholder reason/],
    ['the reason urgent, by the length check alone', () => undefined, ['--reason', 'urgent'], /the reason "urgent" is under 8 characters/],
    ['the reason xxxxxxxxxx, by the placeholder check alone', () => undefined, ['--reason', 'xxxxxxxxxx'], /"xxxxxxxxxx" is a placeholder reason/],
    ['an empty reason', () => undefined, ['--reason', '  '], /under 8 characters/],
  ])('refuses %s and sends nothing and leaves no row', async (_name, setup, extra, want) => {
    const files: Record<string, string> = {
      OUTSIDE: decisionFile('verbatim-decision-699-operator-11-06-TA.txt', `Verbatim: "9001 signed"\n`, join(root, 'elsewhere')),
      UNNAMED: decisionFile('decision-699-notes.txt', `Verbatim: "9001 signed"\n`),
      NOBLOCK: decisionFile('verbatim-decision-684-operator-11-06-SQ.txt', 'when fallback is enabled, in general we don\'t auto move things to api\n'),
    };
    setup();
    await expect(grant(...extra.map((a) => files[a] ?? a))).rejects.toThrow(want);
    expect(existsSync(sent)).toBe(false);
    expect(rows()).toEqual([]);
  });

  it('refuses with no --reason at all', async () => {
    await expect(run('operator', 'out-of-version', 'R1', '--key', 'HIMMEL-7', '--decision', '699', '--verbatim-file', f699(), '--mirror-root', mir))
      .rejects.toMatchObject({ code: 'commander.missingMandatoryOptionValue' });
    expect(rows()).toEqual([]);
  });

  it('refuses a key the mirror does not hold, before any send', async () => {
    await expect(grant('--key', 'HIMMEL-99')).rejects.toThrow('HIMMEL-99 is not in the mirror; sync it first (jira mirror)');
    expect(existsSync(sent)).toBe(false);
    expect(rows()).toEqual([]);
  });
});

describe('a request for operator work carries the operator\'s words', () => {
  const FILE = 'Operator, verbatim:\n\n"Approved one more round"\n\nAnswering the ask on HIMMEL-1: stop and park.\n';
  const WORDS = 'Approved one more round';
  const declared = () => run('operator', 'declare', 'v1.1.3', '--versions', 'v1.1.3,v1.1.4', '--decision', '106', '--verbatim-file', join(root, 'verbatim.txt'));
  const decisionFile = () => {
    mkdirSync(join(root, 'specs', 'decisions'), { recursive: true });
    writeFileSync(join(root, 'specs', 'decisions', 'verbatim-decision-9-op.txt'), FILE);
  };
  type Issue = { key: string; labels?: string[]; priority?: string; status?: string; category?: string; fixVersions?: string[] };
  const gateMirror = (...issues: Issue[]): string => {
    const dir = join(root, 'gate-mirror');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync: '2026-11-10T00:00:00Z' }));
    for (const i of issues) {
      writeFileSync(join(dir, `${i.key}.md`), `---\nkey: ${JSON.stringify(i.key)}\nstatus: ${JSON.stringify(i.status ?? 'To Do')}\n`
        + `statusCategory: ${JSON.stringify(i.category ?? 'To Do')}\ntype: "Task"\npriority: ${JSON.stringify(i.priority ?? 'Medium')}\n`
        + `labels: ${JSON.stringify(i.labels ?? [])}\nfixVersions: ${JSON.stringify(i.fixVersions ?? [])}\n---\n`);
    }
    return dir;
  };
  const ask = (mir: string, ...a: string[]) => run('request', 'v1.1.3', '--mirror-root', mir, ...a);
  const intake = (key: string, to = 'v1.1.3') => ['--verb', 'INTAKE', '--key', key, '--from', 'backlog', '--to', to, '--why', 'the operator asked for it in the chief window'];
  const refusal = async (p: Promise<unknown>): Promise<string> => {
    try {
      await p;
    } catch (e) {
      return (e as Error).message;
    }
    throw new Error('expected a refusal');
  };
  const requestsFile = () => join(root, 'state', 'v1.1.3', 'requests.jsonl');
  const operatorRows = () => readFileSync(join(root, 'state', 'v1.1.3', 'operator.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l) as Record<string, unknown>);
  const operatorDirected = { key: 'HIMMEL-1', labels: ['operator-directed', 'standalone'] };

  beforeEach(() => {
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
  });

  it('a gated INTAKE with no --decision is refused with the fix', async () => {
    await declared();
    const msg = await refusal(ask(gateMirror(operatorDirected), ...intake('HIMMEL-1')));
    expect(msg).toContain('HIMMEL-1 is operator-directed; a request that places it needs a record of the operator\'s words');
    expect(msg).toContain('jira release request v1.1.3 --verb INTAKE --key HIMMEL-1 --from backlog --to v1.1.3');
    expect(msg).toContain('--decision <n> --words "<the operator\'s exact words>"');
    expect(msg).not.toContain('454');
    expect(existsSync(requestsFile())).toBe(false);
  });

  it('a High ticket is gated', async () => {
    await declared();
    const mir = gateMirror({ key: 'HIMMEL-2', priority: 'High' }, { key: 'HIMMEL-3', priority: 'Highest', labels: ['operator-directed'] });
    expect(await refusal(ask(mir, ...intake('HIMMEL-2')))).toContain('HIMMEL-2 is High;');
    expect(await refusal(ask(mir, ...intake('HIMMEL-3')))).toContain('HIMMEL-3 is operator-directed and Highest;');
    expect(await refusal(ask(mir, '--verb', 'REVERSION', '--key', 'HIMMEL-2', '--from', 'backlog', '--to', 'v1.1.4', '--why', 'moves into the next version')))
      .toContain('needs a record of the operator\'s words');
  });

  it('a backlog target is not gated', async () => {
    await declared();
    await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1', 'backlog'));
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
  });

  it('a closed ticket is not gated', async () => {
    await declared();
    const mir = gateMirror({ ...operatorDirected, status: 'Done', category: 'Done' });
    await ask(mir, ...intake('HIMMEL-1'), '--evidence', '{"pr":12}');
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
  });

  it('a Medium unlabelled ticket is not gated, whatever its why says', async () => {
    await declared();
    await ask(gateMirror({ key: 'HIMMEL-4' }), '--verb', 'INTAKE', '--key', 'HIMMEL-4', '--to', 'v1.1.3', '--why', 'operator-directed: the operator asked for it, decision 900');
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
  });

  it('close-fold and repair origins are not gated', async () => {
    await declared();
    const ctx = ctxFor('v1.1.3', gateMirror(operatorDirected));
    const row = { verb: 'INTAKE' as const, key: 'HIMMEL-1', from_v: null, to_v: 'v1.1.3', why: 'closed into frozen v1.1.3 with no version of its own' };
    const ticket = { labels: ['operator-directed'], priority: 'Medium', open: true };
    expect(() => refuseRequest(ctx, { ...row, origin: 'close-fold', ticket })).not.toThrow();
    expect(() => refuseRequest(ctx, { ...row, origin: 'repair', ticket })).not.toThrow();
    expect(() => refuseRequest(ctx, { ...row, origin: 'cli', ticket })).toThrow(/needs a record of the operator's words/);
  });

  it('inside HIMMEL_CONSOLE_LEG=1 the gate files as today', async () => {
    await declared();
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
    await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
  });

  it('the live GET supplies labels when the mirror lacks the key', async () => {
    await declared();
    vi.mocked(request).mockReset();
    vi.mocked(request).mockImplementation((async () => ({
      fields: { labels: ['operator-directed'], priority: { name: 'Medium' }, status: { statusCategory: { name: 'To Do' } } },
    })) as never);
    expect(await refusal(ask(gateMirror(), ...intake('HIMMEL-5')))).toContain('HIMMEL-5 is operator-directed;');
    expect(vi.mocked(request).mock.calls[0].slice(0, 2)).toEqual(['GET', '/issue/HIMMEL-5?fields=labels,priority,status']);
  });

  it('an unreadable ticket on the CLI is refused, naming jira mirror and --decision', async () => {
    await declared();
    vi.mocked(request).mockReset();
    vi.mocked(request).mockImplementation((async () => { throw new Error('HTTP 503'); }) as never);
    const msg = await refusal(ask(gateMirror(), ...intake('HIMMEL-6')));
    expect(msg).toMatch(/HIMMEL-6 could not be read/);
    expect(msg).toContain('jira mirror');
    expect(msg).toContain('--decision <n> --words');
    expect(existsSync(requestsFile())).toBe(false);
  });

  it('request --decision --words records the words and files the request citing them', async () => {
    await declared();
    decisionFile();
    await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--decision', '9', '--words', WORDS);
    const id = /^OPERATOR (O-v1\.1\.3-\d{4}) /.exec(out.at(-2) ?? '')?.[1];
    expect(id).toBeDefined();
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
    const req = JSON.parse(readFileSync(requestsFile(), 'utf8').trim().split('\n').at(-1) ?? '{}');
    expect(req.evidence).toEqual({ operator: id });
  });

  it('request --decision with no --words is refused', async () => {
    await declared();
    decisionFile();
    expect(await refusal(ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--decision', '9'))).toMatch(/--decision needs --words/);
  });

  it('request --decision --words from a gloss is refused', async () => {
    await declared();
    decisionFile();
    expect(await refusal(ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--decision', '9', '--words', 'stop and park'))).toMatch(/not the operator's/);
    expect(existsSync(requestsFile())).toBe(false);
  });

  const decide = (...a: string[]) => run('operator', 'decision', 'v1.1.3', '--decision', '9', '--keys', 'HIMMEL-1', ...a);

  it('operator decision --words from a gloss is refused', async () => {
    await declared();
    decisionFile();
    expect(await refusal(decide('--op', 'add', '--to', 'v1.1.3', '--words', 'stop and park'))).toMatch(/not the operator's/);
    expect(operatorRows().filter((o) => o.kind === 'decision')).toEqual([]);
  });

  it('operator decision --op none writes a words row that places nothing and withdraws no request', async () => {
    await declared();
    decisionFile();
    await ask(gateMirror({ key: 'HIMMEL-1' }), ...intake('HIMMEL-1'));
    await decide('--op', 'none', '--words', WORDS);
    expect(operatorRows().at(-1)).toMatchObject({
      kind: 'decision', op: 'none', keys: ['HIMMEL-1'], verbatim: WORDS, words: 1, decision_file: 'specs/decisions/verbatim-decision-9-op.txt',
    });
    expect(JSON.parse(readFileSync(requestsFile(), 'utf8').trim().split('\n').at(-1) ?? '{}')).toMatchObject({ req: 'Q-v1.1.3-0001', state: 'open' });
  });

  it('operator decision --verbatim-file still writes a legacy row without words', async () => {
    await declared();
    await decide('--op', 'add', '--to', 'v1.1.3', '--verbatim-file', join(root, 'verbatim.txt'));
    const row = operatorRows().at(-1);
    expect(row).toMatchObject({ kind: 'decision', verbatim: 'R = v1 + v2' });
    expect(row).not.toHaveProperty('words');
  });

  it('operator decision takes --words or --verbatim-file, exactly one', async () => {
    await declared();
    decisionFile();
    expect(await refusal(decide('--op', 'add', '--to', 'v1.1.3'))).toMatch(/--words or --verbatim-file/);
    expect(await refusal(decide('--op', 'add', '--to', 'v1.1.3', '--words', WORDS, '--verbatim-file', join(root, 'verbatim.txt')))).toMatch(/--words or --verbatim-file/);
  });
});
