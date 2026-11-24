import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Command } from 'commander';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join, relative } from 'node:path';
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
const fenceTree = vi.hoisted(() => ({ at: null as { procRoot: string; hostNsPath: string } | null }));
vi.mock('../release/engine.js', async (orig) => {
  const m = await orig<typeof import('../release/engine.js')>();
  return {
    ...m,
    rmRun: ((c, j, o) => { rmRunSeen.opts = o ?? null; return m.rmRun(c, j, o); }) as typeof m.rmRun,
    operatorFence: ((c) => m.operatorFence(fenceTree.at ? { ...c, ...fenceTree.at } : c)) as typeof m.operatorFence,
  };
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
import { backlogAlerts, ctxFor, JUDGE_API_BUDGET_USD, JUDGE_API_PASS_ENV, JUDGE_CACHE, JUDGE_SELECTION_NOTE, judgeApiEnv, judgeCall, judgeEnv, judgeFor, judgePrompt, judgeSkill, JUDGE_SPAWN_TIMEOUT_MS, JUDGE_TIMEOUT_S, liveJira, liveJudge, liveJudgeArgs, liveJudgeEnv, makeRoutedJudge, parseDecisions, refuseRequest, registerRelease, renderState, routedJudge, routedJudgeArgs, runSpecCopy, sealedPage, sendSignerAlert } from './release.js';
import type { Judge, JudgeInput } from '../release/engine.js';
import * as engineMod from '../release/engine.js';
import { defaultRoot } from './mirror.js';
import { doorJudge } from '../release/door.js';
import { appendChain, loadKey, readChain } from '../release/ledger.js';
import type { OperatorRow } from '../release/types.js';

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

  it('state prints every unfinished ruling and the remainder line from the ledger it reads, not only the first', async () => {
    const vf = join(root, 'verbatim.txt');
    await run('operator', 'declare', 'R1', '--versions', 'v1,v2', '--decision', '106', '--verbatim-file', vf);
    const doc = '/abs/rm-doc.md';
    const rm = { ...ctxFor('R1', join(root, 'no-mirror')), env: { ...process.env, HIMMEL_RELEASE_MANAGER: '1', HIMMEL_CONSOLE_LEG: '1', HIMMEL_RM_DOC: doc, HIMMEL_RM_RELEASE: 'R1' } };
    const asks = ['K-2', 'K-3'].map((key) => engineMod.request(ctxFor('R1'), { verb: 'INTAKE', key, from_v: null, to_v: 'v1', why: 'w', evidence: {}, from: 'console' }));
    engineMod.leaseAcquire(rm, { expectEpoch: 0, doc, session: 'rm-1' });
    engineMod.claim(rm);
    const rulings = asks.map((q) => engineMod.rule(rm, { req: q.req, outcome: 'ADMIT', op: { kind: 'add', from_v: null, to_v: 'v1' }, sector: 'Planning & tracking',
      ground: 'regression', reason: 'breaks the console', supersedes: [], authority: { kind: 'rm', ref: null } }));
    engineMod.leaseRelease(rm);
    await run('request', 'R1', '--verb', 'INTAKE', '--key', 'C-1', '--to', 'v1', '--why', 'the rest of P-1', '--required-by', 'P-1');
    const child = out.at(-1)?.replace(/^REQ /, '');
    out.length = 0;
    await run('state', 'R1', '--mirror-root', join(root, 'no-mirror'));
    const lines = out.join('\n').split('\n');
    expect(lines.filter((l) => l.startsWith('remainder: '))).toEqual([`remainder: P-1 cannot close without C-1 (open ${child}); release-manager: jira release rm-run R1`]);
    expect(lines.filter((l) => l.startsWith('unfinished: '))).toEqual(rulings.map((r, i) => `unfinished: ${r.id} intent K-${i + 2} add backlog→v1; release-manager runs \`jira release rm-run R1\``));
  });

  it('refuses request evidence that is not a JSON object', async () => {
    const vf = join(root, 'verbatim.txt');
    await run('operator', 'declare', 'R1', '--versions', 'v1,v2', '--decision', '106', '--verbatim-file', vf);
    for (const bad of ['[1]', 'null', '3']) {
      await expect(run('request', 'R1', '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'w', '--evidence', bad))
        .rejects.toThrow(/--evidence is a JSON object/);
    }
  });

  it('claim and rule are parked: both refuse with the door message and write nothing (I8)', async () => {
    const vf = join(root, 'verbatim.txt');
    await run('operator', 'declare', 'R1', '--versions', 'v1,v2', '--decision', '106', '--verbatim-file', vf);
    await run('request', 'R1', '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'found work');
    const before = readFileSync(join(root, 'state', 'R1', 'requests.jsonl'), 'utf8');
    const door = 'placement is by the door; rm-run rules every request';
    await expect(run('claim', 'R1')).rejects.toThrow(door);
    await expect(run('rule', 'R1', '--req', 'Q-R1-0001', '--outcome', 'ADMIT', '--op', 'add', '--to', 'v1',
      '--sector', 's', '--ground', 'regression', '--authority', 'rm')).rejects.toThrow(door);
    expect(readFileSync(join(root, 'state', 'R1', 'requests.jsonl'), 'utf8')).toBe(before);
    expect(existsSync(join(root, 'state', 'R1', 'rulings.jsonl')) ? readFileSync(join(root, 'state', 'R1', 'rulings.jsonl'), 'utf8') : '').toBe('');
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

  it('reviewed is refused inside a chief-spawned worker and needs exactly one of --ruling and --through', async () => {
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
    await expect(run('reviewed', 'R1', '--ruling', 'R-R1-0001', '--reason', 'checked')).rejects.toThrow(/chief-spawned worker/);
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
    await expect(run('reviewed', 'R1', '--reason', 'checked')).rejects.toThrow(/exactly one of --ruling and --through/);
    await expect(run('reviewed', 'R1', '--ruling', 'R-R1-0001', '--through', 'R-R1-0002', '--reason', 'checked')).rejects.toThrow(/exactly one of --ruling and --through/);
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
    vi.stubEnv('HIMMEL_RM_JUDGE', 'model');
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
    expect(call?.args).toEqual(expect.arrayContaining(['--permission-mode', 'dontAsk', '--output-format', 'json', '--max-turns', '1', '--strict-mcp-config']));
    expect(call?.args).not.toContain('plan');
    expect(call?.args).not.toContain('bypassPermissions');
    expect(call?.args[call.args.indexOf('--tools') + 1]).toBe('');
    expect(call?.args[call.args.indexOf('--mcp-config') + 1]).toBe('{"mcpServers":{}}');
    expect(Object.keys(call?.env ?? {}).filter((k) => /^(ANTHROPIC_|HIMMEL_API_)/i.test(k))).toEqual([]);
    expect(call?.env.CLAUDE_CODE_OAUTH_TOKEN).toBe('dummy-oauth-token');
    const pre = judgeReply.calls.find((c) => String(c.args[0]).endsWith('usage-preflight.sh'));
    expect(pre?.env).toMatchObject({ CADENCE_USAGE_LANE: 'native', CADENCE_USAGE_WORKER: 'rm-judge' });
    for (const k of ['WORKER_SESSION_LANE', 'CADENCE_USAGE_LAUNCH', 'CADENCE_USAGE_CALLER_PID']) expect(pre?.env).not.toHaveProperty(k);
  });

  it('the spawned judge call gets the shipped cache variable whatever the caller exported', async () => {
    vi.stubEnv('DISABLE_PROMPT_CACHING', '0');
    vi.stubEnv('FORCE_PROMPT_CACHING_5M', '0');
    vi.stubEnv('ENABLE_PROMPT_CACHING_1H', '1');
    vi.stubEnv('ANTHROPIC_API_KEY', 'dummy-api-key');
    await oneRequest();
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    const call = judgeReply.calls.find((c) => c.file === 'claude');
    const sid = call?.args[(call?.args.indexOf('--session-id') ?? -2) + 1] ?? '';
    const settings = call?.args[(call?.args.indexOf('--settings') ?? -2) + 1] ?? '';
    expect(call?.args).toEqual(liveJudgeArgs(sid, settings));
    const cacheKeys = ['DISABLE_PROMPT_CACHING', 'FORCE_PROMPT_CACHING_5M', 'ENABLE_PROMPT_CACHING_1H'];
    expect(Object.fromEntries(cacheKeys.filter((k) => k in (call?.env ?? {})).map((k) => [k, call?.env[k]]))).toEqual(JUDGE_CACHE.env);
    expect(Object.keys(call?.env ?? {}).filter((k) => /^(ANTHROPIC_|HIMMEL_API_)/i.test(k))).toEqual([]);
  });

  describe('the chief alert on a High or security request ruled BACKLOG', () => {
    const rulesBacklog = async (priority: string, labels: string[] = []) => {
      await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', join(root, 'verbatim.txt'));
      await run('request', 'R1', '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1', '--why', 'found work');
      vi.mocked(request).mockImplementation((async (m: string) => (m === 'GET'
        ? { fields: { labels, priority: { name: priority }, status: { statusCategory: { name: 'To Do' } }, fixVersions: [] } }
        : { id: '10001' })) as never);
      const d = { req: 'Q-R1-0001', outcome: 'BACKLOG', op: 'none', from: null, to: null, sector: 's', ground: 'defer', reason: 'no blocker record names a version' };
      judgeReply.out = JSON.stringify({ is_error: false, result: JSON.stringify([d]) });
      out = [];
      await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    };

    it('prints an alert as the last line naming the key, the class and the reason for a High INTAKE ruled BACKLOG', async () => {
      await rulesBacklog('High');
      expect(out.at(-1)).toBe('RM-RUN R1 alert: K-2 High BACKLOG: no blocker record names a version');
    });

    it('names a security ticket by its label', async () => {
      await rulesBacklog('Medium', ['security']);
      expect(out.at(-1)).toBe('RM-RUN R1 alert: K-2 security BACKLOG: no blocker record names a version');
    });

    it('prints no alert for a Medium ticket ruled BACKLOG', async () => {
      await rulesBacklog('Medium');
      expect(out.some((l) => /alert:/.test(l))).toBe(false);
    });
  });

  const EXIT_PLAN_REPLY = '<function_calls>\n<invoke name="ExitPlanMode">\n<parameter name="plan">The rulings JSON array was already delivered.</parameter>\n</invoke>\n</function_calls>';

  it('a reply that is an ExitPlanMode block rules nothing, returns the claim to open and names its shape', async () => {
    await oneRequest();
    judgeReply.out = JSON.stringify({ is_error: false, result: EXIT_PLAN_REPLY });
    await expect(run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'))).rejects.toThrow(/reply shape: ExitPlanMode block/);
    const dir = join(root, 'state', 'R1');
    expect(JSON.parse(readFileSync(join(dir, 'requests.jsonl'), 'utf8').trim().split('\n').at(-1) ?? '{}')).toMatchObject({ req: 'Q-R1-0001', state: 'open' });
  });

  it.each([
    ['', 'empty reply'],
    ['  \n', 'empty reply'],
    ['The rulings are all in the backlog.', 'prose'],
    [EXIT_PLAN_REPLY, 'ExitPlanMode block'],
  ])('a reply with no JSON array (%j) names its shape: %s', (result, shape) => {
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result }))).toThrow(new RegExp(`holds no JSON array of decisions \\(reply shape: ${shape}\\); nothing ruled`));
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

  const U ={ input_tokens: 2, cache_creation_input_tokens: 0, cache_read_input_tokens: 649, output_tokens: 10 };
  const M = {
    'claude-opus-5-5': { inputTokens: 3, cacheCreationInputTokens: 7, cacheReadInputTokens: 650 },
    'claude-haiku-5-5': { inputTokens: 900, cacheCreationInputTokens: 0, cacheReadInputTokens: 0 },
  };
  const WANT = { input_tokens: 2, cache_creation_tokens: 0, cache_read_tokens: 649 };
  const NO_TOKENS = { input_tokens: null, cache_creation_tokens: null, cache_read_tokens: null };
  const TOKEN_DECISION = { req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 's', ground: 'g', reason: 'r' };
  const lastRow = () => {
    const rows = readFileSync(join(root, 'credit', 'launches.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    return rows[rows.length - 1];
  };
  const tokenColumns = (row: Record<string, unknown>) => ({ input_tokens: row.input_tokens, cache_creation_tokens: row.cache_creation_tokens, cache_read_tokens: row.cache_read_tokens });

  it('the token row: a billed judge run records its tokens and tier', async () => {
    await oneRequest();
    judgeReply.out = JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 1.5, usage: U, modelUsage: M, result: JSON.stringify([TOKEN_DECISION]) });
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    const row = lastRow();
    expect(row).toMatchObject({ sub_cost_usd: '1.500000', cache_ttl: JUDGE_CACHE.ttl, outcome: 'native' });
    expect(tokenColumns(row)).toEqual(WANT);
  });

  it('the token row: a refused reply that was billed still records its tokens', async () => {
    await oneRequest();
    judgeReply.out = JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 1.5, usage: U, modelUsage: M, result: 'no array here' });
    await expect(run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'))).rejects.toThrow();
    const row = lastRow();
    expect(row).toMatchObject({ sub_cost_usd: '1.500000', cache_ttl: JUDGE_CACHE.ttl, outcome: 'native-failed' });
    expect(tokenColumns(row)).toEqual(WANT);
  });

  it('the token row: a cost with no usable usage records null tokens', async () => {
    await oneRequest();
    judgeReply.out = JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 1.5, usage: { input_tokens: 2.5 }, modelUsage: {}, result: JSON.stringify([TOKEN_DECISION]) });
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    const row = lastRow();
    expect(row.sub_cost_usd).toBe('1.500000');
    expect(tokenColumns(row)).toEqual(NO_TOKENS);
  });

  it('the token row: only the chosen source counts', async () => {
    await oneRequest();
    judgeReply.out = JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 1.5, usage: {}, modelUsage: M, result: JSON.stringify([TOKEN_DECISION]) });
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    const row = lastRow();
    expect(row.sub_cost_usd).toBe('1.500000');
    expect(tokenColumns(row)).toEqual(NO_TOKENS);
  });

  it.each([[{}], [{ total_cost_usd: -1 }]])('the token row: usable tokens with no cost record neither (%j)', async (cost) => {
    await oneRequest();
    judgeReply.out = JSON.stringify({ type: 'result', is_error: false, ...cost, usage: U, modelUsage: M, result: JSON.stringify([TOKEN_DECISION]) });
    await run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'));
    const row = lastRow();
    expect(row.sub_cost_usd).toBe('');
    expect(tokenColumns(row)).toEqual(NO_TOKENS);
  });

  it('the token row: a failed call records neither', async () => {
    await oneRequest();
    judgeReply.out = JSON.stringify({ type: 'result', is_error: true, usage: U, modelUsage: M, result: '' });
    await expect(run('rm-run', 'R1', '--mirror-root', join(root, 'no-mirror'))).rejects.toThrow();
    const row = lastRow();
    expect(row.sub_cost_usd).toBe('');
    expect(tokenColumns(row)).toEqual(NO_TOKENS);
  });

  it('the token row reads the field names the API lane reads', () => {
    const usageMjs = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'api-lane', 'usage.mjs'), 'utf8');
    for (const name of Object.keys(U).filter((k) => k !== 'output_tokens')) expect(usageMjs).toContain(name);
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

  it('rm-run has no count to lift: --ruling, --chief-override and the old --console-override are unknown options', async () => {
    await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', join(root, 'verbatim.txt'));
    const mirror = join(root, 'no-mirror');
    await run('rm-run', 'R1', '--mirror-root', mirror);
    expect(out.at(-1)).toBe('RM-RUN R1: nothing pending');
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    await expect(run('rm-run', 'R1', '--mirror-root', mirror, '--ruling', '98')).rejects.toThrow(/unknown option '--ruling'/);
    await expect(run('rm-run', 'R1', '--mirror-root', mirror, '--chief-override', 'big pass')).rejects.toThrow(/unknown option '--chief-override'/);
    vi.stubEnv('HIMMEL_LEGACY_NAMES', '1');
    await expect(run('rm-run', 'R1', '--mirror-root', mirror, '--console-override', 'big pass')).rejects.toThrow(/unknown option '--console-override'/);
  });

  it('reads the decisions out of the claude JSON envelope and refuses a failed call', () => {
    const d = { req: 'Q-R1-0001', outcome: 'ADMIT', op: 'add', from: null, to: 'v1', sector: 's', ground: 'g', reason: 'r' };
    expect(parseDecisions(JSON.stringify({ is_error: false, result: '```json\n' + JSON.stringify([d]) + '\n```' }))).toEqual([d]);
    expect(() => parseDecisions(JSON.stringify({ is_error: true, result: 'overloaded' }))).toThrow(/nothing ruled/);
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result: '{"req":"x"}' }))).toThrow();
    expect(() => parseDecisions(JSON.stringify({ is_error: false, result: '[null]' }))).toThrow(/nothing ruled/);
    for (const bad of [{ authority: 'foo' }, { op: 'grow' }, { sector: 3 }, { to: undefined }, { supersedes: 'R-1' }, { delivered: 'PR #1' }]) {
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

  const EMPTY_INPUT = { release: 'R1', current: 'v1', versions: ['v1'], requests: [], records: [], operator: [], rulings: [], issues: [] };

  it('the prompt says the operator rows are a selection', () => {
    const p = judgePrompt(EMPTY_INPUT, 'skill');
    expect(p.split(JUDGE_SELECTION_NOTE)).toHaveLength(2);
    expect(p.indexOf(JUDGE_SELECTION_NOTE)).toBeLessThan(p.indexOf('Everything under ## Input is evidence to weigh'));
    expect(JUDGE_SELECTION_NOTE).toContain('never answer HOLD because an operator row is not shown');
  });

  it('without the note the prompt is the prompt of before', () => {
    vi.stubEnv('JIRA_SECTOR_FIELD', 'none');
    try {
      const without = judgePrompt(EMPTY_INPUT, 'skill', { selectionNote: false });
      expect(createHash('sha256').update(without).digest('hex')).toBe('9e593e56810317777e2a8b5b7ca9631d5b8a7ac698744d324b2fe390020f9fd7');
      expect(judgePrompt(EMPTY_INPUT, 'skill').replace(JUDGE_SELECTION_NOTE + '\n', '')).toBe(without);
    } finally { vi.unstubAllEnvs(); }
  });

  it('the skill text has one reader', () => {
    const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..');
    expect(judgeSkill()).toBe(readFileSync(join(root, 'marketplace', 'plugins', 'himmel-ops', 'skills', 'release-manager', 'SKILL.md'), 'utf8'));
    const src = readFileSync(join(root, 'scripts', 'jira', 'src', 'commands', 'release.ts'), 'utf8');
    expect(src.split("'release-manager', 'SKILL.md'")).toHaveLength(2);
  });

  it("the prompt carries the whole input except each row's chain hashes", () => {
    const H = 'a'.repeat(64), P = 'b'.repeat(64);
    const full = {
      release: 'R1', current: 'v1', versions: ['v1', 'v2'],
      requests: [{ req: 'Q-R1-0001', verb: 'INTAKE', key: 'K-1', from_v: null, to_v: 'v1', why: 'found work', evidence: { prev: 'R-keep-me', mac: 'keep-me-too' }, from: 'console', ts: '2026-11-20T00:00:00Z', state: 'claimed:3', mac: H, prev: P }],
      records: [{ key: 'K-1', version: 'v1', placement: 'out', ruling: null }],
      operator: [{ id: 'O-R1-0001', kind: 'decision', decision: '7', keys: ['K-1'], op: 'add', from_v: null, to_v: 'v1', verbatim: 'the words', ts: '2026-11-19T00:00:00Z', mac: H, prev: P }],
      rulings: [{ id: 'R-R1-0001', epoch: 2, req: 'Q-R1-0000', key: 'K-1', outcome: 'BACKLOG', reason: 'why', phase: 'receipted', ts: '2026-11-18T00:00:00Z', mac: H, prev: P }],
      issues: [{ key: 'K-1', status: 'To Do', type: 'Task', priority: 'Medium', fixVersions: [], resolution: null, sector: 's', labels: ['a'] }],
    } as unknown as JudgeInput;
    const want = structuredClone(full) as unknown as Record<string, Array<Record<string, unknown>>>;
    for (const k of ['requests', 'operator', 'rulings']) for (const row of want[k]) { delete row.mac; delete row.prev; }
    const before = JSON.stringify(full);
    const prompt = judgePrompt(full, 'skill');
    expect(JSON.parse(prompt.slice(prompt.indexOf('\n## Input\n') + '\n## Input\n'.length))).toEqual(want);
    expect(prompt).not.toContain(H);
    expect(prompt).not.toContain(P);
    expect(JSON.stringify(full)).toBe(before);
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

  describe('the priority-placement rule (decision 948)', () => {
    const input = { release: 'R1', current: 'v1', versions: ['v1'], requests: [], records: [], operator: [], rulings: [], issues: [] };
    const skill = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..', 'marketplace', 'plugins', 'himmel-ops', 'skills', 'release-manager', 'SKILL.md'), 'utf8');

    it('tells the judge words that direct placement by priority admit a High or Highest INTAKE into the current release', () => {
      const prompt = judgePrompt(input, skill);
      expect(prompt).toMatch(/direct placement by priority or urgency/);
      expect(prompt).toMatch(/High or Highest/);
      expect(prompt).toMatch(/current release/);
    });

    it('keeps the rule to INTAKE and to a High or Highest ticket, and names no quota', () => {
      const prompt = judgePrompt(input, skill);
      expect(prompt).toMatch(/INTAKE only/);
      expect(prompt).toMatch(/not a Medium, Low or unprioritised ticket/);
      expect(judgePrompt(input, 'skill')).not.toMatch(/\bquota\b|\bcap\b/i);
    });

    it('states the same rule in the skill words-record paragraph and requires a BACKLOG reason to name the missing condition', () => {
      expect(skill).toMatch(/direct placement by priority or urgency/);
      expect(skill).toMatch(/names the missing condition/);
    });
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
  it('the tier label matches the variable, and the API lane does not get it', () => {
    const want = JUDGE_CACHE.env.DISABLE_PROMPT_CACHING === '1' ? 'off' : JUDGE_CACHE.env.FORCE_PROMPT_CACHING_5M === '1' ? '5m' : '1h';
    expect(JUDGE_CACHE.ttl).toBe(want);
    expect(Object.keys(JUDGE_CACHE.env).every((k) => ['DISABLE_PROMPT_CACHING', 'FORCE_PROMPT_CACHING_5M'].includes(k))).toBe(true);
    expect(liveJudgeEnv({ PATH: '/bin', DISABLE_PROMPT_CACHING: '0' })).toEqual({ PATH: '/bin', ...JUDGE_CACHE.env });
    for (const k of Object.keys(JUDGE_CACHE.env)) expect(judgeApiEnv({ PATH: '/bin' }, '/repo')[k]).toBeUndefined();
  });
});

const FROZEN_DESC = 'frozen: 2026-10-20\nfrozen-keys: K-1';

function writeMirror(...issues: Array<{ key: string; fixVersions: string[]; status?: string; resolved?: string }>): string {
  const dir = join(root, 'mirror');
  mkdirSync(dir);
  writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync: '2026-10-23T00:00:00Z' }));
  for (const i of issues) {
    writeFileSync(join(dir, `${i.key}.md`), `---\nkey: ${JSON.stringify(i.key)}\nstatus: ${JSON.stringify(i.status ?? 'In Progress')}\n` +
      `type: "Task"\npriority: "Medium"\nfixVersions: ${JSON.stringify(i.fixVersions)}\n` +
      `${i.resolved ? `resolved: ${JSON.stringify(i.resolved)}\n` : ''}---\n`);
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

  it('8731 prints each unfinished ruling with its owner and next action, and nothing when none is owed', () => {
    const base = JSON.parse(JSON.stringify({ ...(stateOut(0) as object) })) as Record<string, unknown>;
    const u = { ruling: 'R-R1-0003', req: 'Q-R1-0003', key: 'K-2', phase: 'applied', op: 'add backlog→v1', owner: 'release-manager', next: 'jira release rm-run R1' };
    expect(renderState({ ...base, unfinished_rulings: [u] } as never)).toContain('unfinished: R-R1-0003 applied K-2 add backlog→v1; release-manager runs `jira release rm-run R1`');
    expect(renderState({ ...base, unfinished_rulings: [] } as never)).not.toContain('unfinished:');
  });

  it('prints blocked membership and the chief remedy without pretending prose is a command', () => {
    const blocked = { ruling: 'R-R1-0003', req: 'Q-R1-0003', key: 'K-2', phase: 'intent',
      op: 'move v1→v2', status: 'blocked', owner: 'chief', observed: 'K-2 is in v1, v2',
      next: 'choose finish or restore after checking live membership' };
    const output = renderState({ ...stateOut(0), unfinished_rulings: [blocked] } as never);
    expect(output).toContain('blocked: K-2 is in v1, v2; chief: choose finish or restore after checking live membership');
    expect(output).not.toContain('chief runs `choose');
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

describe('jira release state prints the version lines', () => {
  const base = {
    release: 'R1', status: 'OK', mode: 'observe', inputs: {}, admissions_today: {},
    leaks: { unauthorized: [], ruled_in_non_member: [] }, requests: { open: [], claimed: [] }, integrity: [],
  };
  const dayOf = (n: number, came: number, done: number, left = 0, extra: Record<string, unknown> = {}) => ({
    day: `2026-10-${String(n).padStart(2, '0')}`, came_in: came, done, left, open: came - done - left,
    closed_undelivered: 0, arrived: {}, arrived_serious: 0, ...extra,
  });
  const lines = (days: unknown[], extra: Record<string, unknown> = {}) => ({
    status: 'OK', as_of: (days.at(-1) as { day: string }).day, days, left: [], done_undated: 0,
    open_by_priority: {}, oldest_untouched: null, unrecorded: { open: [], closed: [] }, ...extra,
  });

  it('prints every line kind, with the seven-day rise and the as-of day', () => {
    const days = [
      dayOf(1, 2, 0, 0, { arrived: { baseline: 2 } }), dayOf(2, 3, 0, 0, { arrived: { regression: 1 } }),
      dayOf(3, 4, 1, 0, { arrived: { fold: 1 } }), dayOf(4, 4, 1, 0), dayOf(5, 5, 1, 0, { arrived: { regression: 1 }, arrived_serious: 1 }),
      dayOf(6, 6, 2, 1, { arrived: { 'door:repair': 1 } }), dayOf(7, 6, 2, 1), dayOf(8, 7, 3, 1, { arrived: { regression: 1 } }),
      dayOf(9, 7, 4, 1, { closed_undelivered: 1 }),
    ];
    const text = renderState({ ...base, burndown: {}, version_lines: { v1: lines(days, {
      left: [{ key: 'K-6', day: '2026-10-06', authority: 'rm' }], done_undated: 1,
      open_by_priority: { none: 1, High: 1 }, oldest_untouched: { key: 'K-3', since: '2026-10-02', days: 7 },
      unrecorded: { open: ['K-9'], closed: [] },
    }) } } as never);
    expect(text.split('\n').filter((l) => l.startsWith('v1 '))).toEqual([
      'v1 as of 2026-10-09: came in 7 (+4 in 7 days), done 4 (+4; 1 closed without delivery), left 1 (1 not by the operator), open 2 (came in, not done, not left)',
      'v1 arrived in 7 days: regression 2, door:repair 1, fold 1',
      'v1 arrived serious in 7 days: 1',
      'v1 open by priority: High 1, none 1',
      'v1 oldest untouched: K-3, waiting 7 days since 2026-10-02',
      'v1 in Jira with no ledger record: 1 open, 0 closed (keys in --json)',
      'v1 done with no date: 1',
    ]);
  });

  it('a three-day series prints its real span', () => {
    const text = renderState({ ...base, burndown: {}, version_lines: { v1: lines([dayOf(1, 1, 0), dayOf(2, 2, 0), dayOf(3, 3, 1)]) } } as never);
    expect(text).toContain('v1 as of 2026-10-03: came in 3 (+3 in 3 days), done 1 (+1;');
    expect(text).toContain('v1 arrived in 3 days: none');
    expect(text).toContain('v1 oldest untouched: none');
    expect(text).not.toContain('in 7 days');
  });

  it('prints the burn-down\'s admitted open and the lines\' open each with its label', () => {
    const burndown = { v1: { baseline: 1, baseline_open: 0, admitted_open: 0, emergency_open: 0, deferred_out: 0 } };
    const text = renderState({ ...base, burndown, version_lines: { v1: lines([dayOf(1, 1, 0), dayOf(2, 2, 1)]) } } as never);
    expect(text).toContain('v1: baseline 1 (open 0), admitted open 0,');
    expect(text).toContain('open 1 (came in, not done, not left)');
  });

  it('prints an unknown version as UNKNOWN with its reason and no number', () => {
    const text = renderState({ ...base, burndown: {}, version_lines: { v1: { status: 'UNKNOWN', reason: 'the Jira mirror is unknown' } } } as never);
    expect(text.split('\n').filter((l) => l.startsWith('v1 '))).toEqual(['v1 lines: UNKNOWN (the Jira mirror is unknown)']);
  });

  it('renderState prints the state\'s figures, never a recount', () => {
    const records = ['K-1', 'K-2', 'K-3'].map((key) => ({ key, version: 'v1', placement: 'in', actual_member: true }));
    const burndown = { v1: { baseline: 3, baseline_open: 3, admitted_open: 1, emergency_open: 0, deferred_out: 0 } };
    const text = renderState({ ...base, records, burndown, version_lines: { v1: lines([dayOf(1, 7, 2)]) } } as never);
    expect(text).toContain('came in 7');
    expect(text).toContain('open 5 (came in, not done, not left)');
    expect(text).not.toContain('came in 3');
  });

  it.each(['2026-10-22T08:00:00.000+0000', ''])('the state command exits 0 with a resolved date of %j', async (resolved) => {
    const vf = join(root, 'verbatim.txt');
    await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '106', '--verbatim-file', vf);
    await run('operator', 'freeze', 'R1', '--version', 'v1', '--keys', 'K-1', '--decision', '104', '--verbatim-file', vf);
    const mir = writeMirror({ key: 'K-1', fixVersions: ['v1'], status: 'Done', resolved });
    process.exitCode = undefined;
    out = [];
    await run('state', 'R1', '--mirror-root', mir);
    expect(process.exitCode).toBeUndefined();
    expect(out.join('\n')).toMatch(/v1 as of \d{4}-\d\d-\d\d: came in 1 .*, done 1 /);
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

  it('ctxFor wires the merged-PR lookup to gh, so rule and rm-run verify merge evidence', () => {
    const bin = join(root, 'bin');
    mkdirSync(bin);
    writeFileSync(join(bin, 'gh'), '#!/bin/sh\necho \'[{"number":77,"url":"https://github.com/o/r/pull/77","title":"fix: [K-9] a thing"}]\'\n');
    chmodSync(join(bin, 'gh'), 0o755);
    vi.stubEnv('PATH', `${bin}:${process.env.PATH}`);
    const lookup = ctxFor('R1').deliveredPr;
    expect(lookup?.('K-9')).toBe(77);
    expect(lookup?.('K-8')).toBeUndefined();
  });

  it('records delivered-follows-merge once on a release declared before it existed, and refuses a second', async () => {
    await run('operator', 'declare', 'R1', '--versions', 'v1,v2', '--decision', '106', '--verbatim-file', join(root, 'verbatim.txt'));
    await expect(run('operator', 'standing', 'R1', '--kind', 'delivered-follows-merge', '--decision', '929', '--verbatim-file', join(root, 'verbatim.txt')))
      .rejects.toThrow(/O-R1-delivered-follows-merge is already recorded/);
    const c = ctxFor('R1');
    const k = loadKey(c.keyPath);
    const path = join(c.dir, 'operator.jsonl');
    const kept = readChain<OperatorRow>(path, k).verified.filter((r) => r.id !== 'O-R1-delivered-follows-merge').map(({ prev: _p, mac: _m, ...r }) => r);
    rmSync(path);
    for (const r of kept) appendChain(path, k, r);
    out = [];
    await run('operator', 'standing', 'R1', '--kind', 'delivered-follows-merge', '--decision', '929', '--verbatim-file', join(root, 'verbatim.txt'));
    expect(out).toEqual([expect.stringMatching(/^O-R1-delivered-follows-merge recorded/)]);
    await expect(run('operator', 'standing', 'R1', '--kind', 'delivered-follows-merge', '--decision', '929', '--verbatim-file', join(root, 'verbatim.txt')))
      .rejects.toThrow(/already recorded/);
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
    const hostTmp = tmpdir();
    const ownTmp = mkdtempSync(join(hostTmp, 'release-tmp-'));
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
      WORKER_SESSION_DOC: '', FLEET_LAUNCH_DOC: '', FLEET_LAUNCH_MANIFEST: '', FLEET_LAUNCH_ATTEMPT: '', WORKER_SESSION_ATTEMPT_ID: '', WORKER_SESSION_PROFILE: '', FLEET_LAUNCH_WORKER_INTENT: '',
      TMPDIR: ownTmp,
    };
    for (const [k, v] of Object.entries(set)) vi.stubEnv(k, v);
    const fallbackCalls: JudgeInput[] = [];
    const fallback: Judge = async (i) => { fallbackCalls.push(i); return [decision('from-fallback')] as never; };
    const read = (f: string) => (existsSync(join(dir, f)) ? readFileSync(join(dir, f), 'utf8') : '');
    return { fallback, fallbackCalls, read, hostTmp };
  }

  it('the outer spawn timeout outlasts the launcher call timeout plus its five-second kill grace', () => {
    expect(JUDGE_SPAWN_TIMEOUT_MS).toBeGreaterThan((JUDGE_TIMEOUT_S + 5) * 1000);
  });

  it('the launcher arguments come from one exported list that takes the per-call budget', () => {
    const args = routedJudgeArgs();
    expect(args.slice(0, 7)).toEqual(['-p', '--model', 'opus', '--effort', 'high', '--permission-mode', 'dontAsk']);
    expect(args[args.indexOf('--max-budget-usd') + 1]).toBe(String(JUDGE_API_BUDGET_USD));
    expect(args.slice(-2)).toEqual(['--output-format', 'json']);
    expect(routedJudgeArgs(3)[routedJudgeArgs(3).indexOf('--max-budget-usd') + 1]).toBe('3');
    const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'release.ts'), 'utf8');
    expect(src.split("'--max-budget-usd'")).toHaveLength(2);
    expect(src.split('routedJudgeArgs(')).toHaveLength(3);
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
    expect(args[args.indexOf('--permission-mode') + 1]).toBe('dontAsk');
    expect(args).not.toContain('plan');
    expect(args).not.toContain('bypassPermissions');
    for (const bad of ['--settings', '--max-turns', '--mcp-config']) expect(args).not.toContain(bad);
    const cwd = /^cwd=(.*)$/m.exec(log)?.[1] ?? '';
    expect(cwd).not.toBe('');
    expect(cwd.startsWith(join(dir, '..'))).toBe(false);
    expect(existsSync(join(cwd, '.git'))).toBe(false);
  });

  it('mapped inside a registered worker session: the managed-launch variables are blank, so the launcher runs against the test fleet and the fake answers', async () => {
    const bucket = join(root, 'handovers');
    mkdirSync(bucket);
    writeFileSync(join(bucket, 'fleet-control.json'), JSON.stringify({ schema: 1, family: '00000000-0000-4000-8000-000000000000', mode: 'active', generation: 1, target: 30, attempts: {} }));
    const doc = join(bucket, 'HIMMEL-10843-N10843-routed-judge-release-tests-2026-11-23.md');
    writeFileSync(doc, '# HIMMEL-10843 - the routed-judge release tests - worker N10843 (claude-sonnet-5-5, native), 2026-11-23\n');
    const managed = ['WORKER_SESSION_DOC', 'FLEET_LAUNCH_DOC', 'FLEET_LAUNCH_MANIFEST', 'FLEET_LAUNCH_ATTEMPT', 'WORKER_SESSION_ATTEMPT_ID', 'WORKER_SESSION_PROFILE', 'FLEET_LAUNCH_WORKER_INTENT'];
    for (const k of managed) vi.stubEnv(k, k === 'FLEET_LAUNCH_WORKER_INTENT' ? '1' : k === 'WORKER_SESSION_PROFILE' ? 'worker-impl' : doc);
    const w = world({ judge: ['B'] });
    for (const k of managed) expect(process.env[k], k).toBe('');
    const got = await makeRoutedJudge(w.fallback)(INPUT);
    expect(got[0]).toMatchObject({ reason: 'from-fake' });
    expect(w.fallbackCalls).toHaveLength(0);
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
    let fire!: () => void;
    const gate = new Promise<void>((resolve) => { fire = resolve; });
    const got = expect(makeRoutedJudge(w.fallback, 60, undefined, gate)(INPUT)).rejects.toMatchObject({ killed: true, status: 143 });
    await vi.waitFor(() => expect(fakePid(w)).toBeGreaterThan(0), { timeout: 10_000 });
    fire();
    await got;
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

  it('judgeFor: the door places every mirror by default (I3); only HIMMEL_RM_JUDGE=model reaches the parked judges', () => {
    const w = world({ judge: ['B'] });
    vi.stubEnv('TMPDIR', w.hostTmp);
    for (const m of [defaultRoot('HIMMEL'), defaultRoot('SALUS'), join(root, 'no-mirror')]) expect(judgeFor(ctxFor('R1', m))).toBe(doorJudge);
    vi.stubEnv('HIMMEL_RM_JUDGE', 'model');
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

  it('RM apply passes the ruling\'s record on to the client', async () => {
    vi.mocked(request).mockImplementation((async (method: string) =>
      method === 'GET' ? { fields: { fixVersions: [] } } : {}) as never);
    const op = { kind: 'move' as const, from_v: 'v1', to_v: null };
    await liveJira.setFixVersion('HIMMEL-1', 'remove', 'v1', { by: 'O-R-0001', op });
    const put = vi.mocked(request).mock.calls.find((c) => c[0] === 'PUT');
    expect(put?.[3]).toBe('rm-apply');
    expect(put?.[4]).toEqual({ leave: { by: 'O-R-0001', op } });
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

  it('an approved key is queued like any other: an INTAKE, an INTAKE on an expired approval and a REVERSION each file their own request', async () => {
    await declared();
    const mir = projectMirror({ key: 'HIMMEL-7', fixVersions: ['v1.1.10'] });
    approve('HIMMEL-7', '901', 1);
    vi.mocked(request).mockReset();
    vi.mocked(request).mockImplementation((async () => ({ fields: { labels: [] } })) as never);
    out = [];
    await run('request', 'R1', '--mirror-root', mir, '--verb', 'INTAKE', '--key', 'HIMMEL-7', '--from', 'v1.1.10', '--to', 'v1.1.9', '--why', 'worked under the chief: fold it in');
    expect(out).toEqual(['REQ Q-R1-0001']);
    expect(existsSync(join(root, 'state', 'R1', 'requests.jsonl'))).toBe(true);
    approve('HIMMEL-8', '902', 15);
    await run('request', 'R1', '--mirror-root', mir, '--verb', 'INTAKE', '--key', 'HIMMEL-8', '--to', 'v1.1.9', '--why', 'worked under the chief: fold it in');
    expect(out.at(-1)).toBe('REQ Q-R1-0002');
    await run('request', 'R1', '--mirror-root', mir, '--verb', 'REVERSION', '--key', 'HIMMEL-7', '--from', 'v1.1.10', '--to', 'backlog', '--why', 'moves out of the version');
    expect(out.at(-1)).toBe('REQ Q-R1-0003');
  });

  it('an approved INTAKE touches no label: the proposal ends with its ruling, never with a request', async () => {
    await declared();
    const mir = projectMirror({ key: 'HIMMEL-7', fixVersions: ['v1.1.10'] });
    approve('HIMMEL-7', '901', 1);
    vi.mocked(request).mockReset();
    vi.mocked(request).mockImplementation((async () => ({ fields: { labels: ['core', 'proposed-v1.1.9'] } })) as never);
    out = [];
    await run('request', 'R1', '--mirror-root', mir, '--verb', 'INTAKE', '--key', 'HIMMEL-7', '--to', 'v1.1.9', '--why', 'worked under the chief: fold it in');
    expect(out).toEqual(['REQ Q-R1-0001']);
    expect(vi.mocked(request).mock.calls.find((c) => c[0] === 'PUT')).toBeUndefined();
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

  it('an operator-directed INTAKE with no --decision files, and the door rules it', async () => {
    await declared();
    await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
    expect(existsSync(requestsFile())).toBe(true);
  });

  it('a High or Highest ticket files with no words, an INTAKE and a REVERSION alike', async () => {
    await declared();
    const mir = gateMirror({ key: 'HIMMEL-2', priority: 'High' }, { key: 'HIMMEL-3', priority: 'Highest', labels: ['operator-directed'] });
    await ask(mir, ...intake('HIMMEL-2'));
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
    await ask(mir, ...intake('HIMMEL-3'));
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0002');
    await ask(mir, '--verb', 'REVERSION', '--key', 'HIMMEL-2', '--from', 'backlog', '--to', 'v1.1.4', '--why', 'moves into the next version');
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0003');
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

  it('no origin is gated: cli, create, close-fold and repair all pass an operator-directed ask', async () => {
    await declared();
    const ctx = ctxFor('v1.1.3', gateMirror(operatorDirected));
    const row = { verb: 'INTAKE' as const, key: 'HIMMEL-1', from_v: null, to_v: 'v1.1.3', why: 'closed into frozen v1.1.3 with no version of its own' };
    const ticket = { labels: ['operator-directed'], priority: 'Medium', open: true };
    for (const origin of ['cli', 'create', 'close-fold', 'repair'] as const) expect(() => refuseRequest(ctx, { ...row, origin, ticket })).not.toThrow();
  });

  it('inside HIMMEL_CONSOLE_LEG=1 the gate files as today', async () => {
    await declared();
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
    await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
  });

  it('a key the mirror lacks files with no live read of its labels', async () => {
    await declared();
    vi.mocked(request).mockReset();
    vi.mocked(request).mockImplementation((async () => { throw new Error('HTTP 503'); }) as never);
    await ask(gateMirror(), ...intake('HIMMEL-6'));
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
    expect(vi.mocked(request).mock.calls.find((c) => String(c[1]).startsWith('/issue/HIMMEL-6'))).toBeUndefined();
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

  // 9818: a live out-of-version approval is work permission; it never stands in for a placement the operator's new words ask for.
  describe('9818 an out-of-version approval and an explicit placement', () => {
    const approve = (key: string, ageDays = 1) => appendChain(join(root, 'state', 'v1.1.3', 'operator.jsonl'), loadKey(join(root, 'keys', 'v1.1.3.key')), {
      id: `O-v1.1.3-ov-${key}`, kind: 'out-of-version', decision: '518', keys: [key], ts: new Date(Date.now() - ageDays * 86_400_000).toISOString(),
    });
    const quiet = () => {
      vi.mocked(request).mockReset();
      vi.mocked(request).mockImplementation((async () => ({ fields: { labels: [] } })) as never);
    };
    const queued = () => (existsSync(requestsFile()) ? readFileSync(requestsFile(), 'utf8').trim().split('\n').map((l) => JSON.parse(l) as Record<string, unknown>) : []);

    it('RED: a 14-day approval plus new words queues the request carrying them, never REQ approved', async () => {
      await declared();
      decisionFile();
      approve('HIMMEL-1');
      quiet();
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--decision', '9', '--words', WORDS);
      expect(out.join('\n')).not.toMatch(/approved/);
      const id = /^OPERATOR (O-v1\.1\.3-\d{4}) /.exec(out.at(-2) ?? '')?.[1];
      expect(id).toBeDefined();
      expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
      expect(queued()).toMatchObject([{ key: 'HIMMEL-1', verb: 'INTAKE', to_v: 'v1.1.3', evidence: { operator: id } }]);
    });

    // The live shape of the 2026-11-16 correction audit: the underfill investigation answered `REQ approved:O-v1.1.3-0518` instead of queuing its placement.
    it('seed from the correction audit: HIMMEL-10208 with the old approval O-v1.1.3-0518 queues the new placement with its words and prints no approval', async () => {
      const seed = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'release', 'fixtures', 'correction-audit-2026-11-16.json'), 'utf8')) as {
        old_work_approval_case: { key: string; approval_record: string; returned: string };
      };
      const c = seed.old_work_approval_case;
      await declared();
      decisionFile();
      appendChain(join(root, 'state', 'v1.1.3', 'operator.jsonl'), loadKey(join(root, 'keys', 'v1.1.3.key')), {
        id: c.approval_record, kind: 'out-of-version', decision: '518', keys: [c.key], ts: new Date(Date.now() - 86_400_000).toISOString(),
      });
      quiet();
      await ask(gateMirror({ key: c.key, labels: ['operator-directed', 'standalone'] }), ...intake(c.key), '--decision', '9', '--words', WORDS);
      expect(out.join('\n')).not.toContain(c.returned);
      expect(out.join('\n')).not.toMatch(/approved/);
      const id = /^OPERATOR (O-v1\.1\.3-\d{4}) /.exec(out.at(-2) ?? '')?.[1];
      expect(id).toBeDefined();
      expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
      expect(queued()).toMatchObject([{ key: c.key, verb: 'INTAKE', to_v: 'v1.1.3', state: 'open', evidence: { operator: id } }]);
      expect(operatorRows().find((o) => o.id === c.approval_record)).toMatchObject({ kind: 'out-of-version', keys: [c.key] });
    });

    it('RED: an approval on an ordinary ungated key still files the INTAKE through normal placement; the approval is only work permission', async () => {
      await declared();
      approve('HIMMEL-4');
      quiet();
      out = [];
      await ask(gateMirror({ key: 'HIMMEL-4' }), ...intake('HIMMEL-4'));
      expect(out).toEqual(['REQ Q-v1.1.3-0001']);
      expect(queued()).toMatchObject([{ key: 'HIMMEL-4', verb: 'INTAKE', to_v: 'v1.1.3', state: 'open' }]);
      expect(vi.mocked(request).mock.calls.find((c) => c[0] === 'PUT')).toBeUndefined();
    });

    it('an approval is no placement: an operator-directed key with no words files a plain request that names no record', async () => {
      await declared();
      approve('HIMMEL-1');
      quiet();
      out = [];
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
      expect(out).toEqual(['REQ Q-v1.1.3-0001']);
      expect(queued()).toMatchObject([{ key: 'HIMMEL-1', state: 'open', evidence: {} }]);
      expect(vi.mocked(request).mock.calls.find((c) => c[0] === 'PUT')).toBeUndefined();
    });

    it('an approved key repeating its ask returns the same open request (the normal dedupe), never a second Q', async () => {
      await declared();
      approve('HIMMEL-4');
      quiet();
      await ask(gateMirror({ key: 'HIMMEL-4' }), ...intake('HIMMEL-4'));
      await ask(gateMirror({ key: 'HIMMEL-4' }), ...intake('HIMMEL-4'));
      expect(out.slice(-2)).toEqual(['REQ Q-v1.1.3-0001', 'REQ Q-v1.1.3-0001']);
      expect(queued()).toHaveLength(1);
    });

    it('malformed new authority still refuses with an approval live: --decision without --words, and a gloss', async () => {
      await declared();
      decisionFile();
      approve('HIMMEL-1');
      quiet();
      out = [];
      expect(await refusal(ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--decision', '9'))).toMatch(/--decision needs --words/);
      expect(await refusal(ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--words', WORDS))).toMatch(/--words needs --decision/);
      expect(await refusal(ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--decision', '9', '--words', 'stop and park'))).toMatch(/not the operator's/);
      expect(queued()).toEqual([]);
      expect(out).toEqual([]);
    });

    it('an approval for another key or an expired one does not change the explicit path or the ordinary path', async () => {
      await declared();
      decisionFile();
      approve('HIMMEL-2');
      approve('HIMMEL-3', 15);
      quiet();
      await ask(gateMirror(operatorDirected, { key: 'HIMMEL-3' }), ...intake('HIMMEL-3'));
      expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--decision', '9', '--words', WORDS);
      expect(out.at(-1)).toBe('REQ Q-v1.1.3-0002');
    });
  });

  describe('a words record on file is not cited at the request: the ask files plain', () => {
    const record = (key: string, kind: string, from: string, to: string, words = WORDS) =>
      run('operator', 'decision', 'v1.1.3', '--decision', '9', '--keys', key, '--op', kind, '--from', from, '--to', to, '--words', words);
    const queued = () => (existsSync(requestsFile()) ? readFileSync(requestsFile(), 'utf8').trim().split('\n').map((l) => JSON.parse(l) as Record<string, unknown>) : []);
    const lastId = () => String(operatorRows().at(-1)?.id);
    const quietJira = () => {
      vi.mocked(request).mockReset();
      vi.mocked(request).mockImplementation((async () => ({ fields: { labels: [] } })) as never);
    };

    it('files with no --decision, prints no OPERATOR line, names no record and records no operator row', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-1', 'add', 'backlog', 'v1.1.3');
      const rows = operatorRows().length;
      out = [];
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
      expect(out).toEqual(['REQ Q-v1.1.3-0001']);
      expect(queued()).toMatchObject([{ key: 'HIMMEL-1', verb: 'INTAKE', from_v: null, to_v: 'v1.1.3', state: 'open', evidence: {} }]);
      expect(operatorRows()).toHaveLength(rows);
    });

    it('a REVERSION with a move record on file files plain', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-1', 'move', 'backlog', 'v1.1.4');
      await ask(gateMirror(operatorDirected), '--verb', 'REVERSION', '--key', 'HIMMEL-1', '--from', 'backlog', '--to', 'v1.1.4', '--why', 'moves into the next version');
      expect(queued()).toMatchObject([{ key: 'HIMMEL-1', verb: 'REVERSION', to_v: 'v1.1.4', evidence: {} }]);
    });

    it('a repeat of the ask returns the same open request and queues nothing more', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-1', 'add', 'backlog', 'v1.1.3');
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
      out = [];
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
      expect(out).toEqual(['REQ Q-v1.1.3-0001']);
      expect(queued()).toHaveLength(1);
    });

    it('the request reads no record: coveringRecord is never called', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-1', 'add', 'backlog', 'v1.1.3');
      const spy = vi.spyOn(engineMod, 'coveringRecord');
      try {
        await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
        expect(spy).not.toHaveBeenCalled();
      } finally {
        spy.mockRestore();
      }
    });

    it('an operator claim in --evidence files as the filer wrote it and adds no operator row', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-2', 'add', 'backlog', 'v1.1.3');
      const rows = operatorRows().length;
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--evidence', JSON.stringify({ operator: lastId() }));
      expect(queued()).toMatchObject([{ key: 'HIMMEL-1', evidence: { operator: lastId() } }]);
      expect(operatorRows()).toHaveLength(rows);
    });

    it('a ticket that is not gated files plain and cites nothing, even when a record on file names its key', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-4', 'add', 'backlog', 'v1.1.3');
      await ask(gateMirror({ key: 'HIMMEL-4' }), ...intake('HIMMEL-4'));
      expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
      expect(out.some((l) => l.startsWith('OPERATOR '))).toBe(false);
      expect(queued()).toMatchObject([{ key: 'HIMMEL-4', evidence: {} }]);
    });

    it('a pending ask that cites nothing is returned as it stands, and no operator record is claimed for it', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-1', 'add', 'backlog', 'v1.1.3');
      vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
      vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
      out = [];
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
      expect(out).toEqual(['REQ Q-v1.1.3-0001']);
      expect(queued()).toMatchObject([{ key: 'HIMMEL-1', evidence: {} }]);
    });

    it('--decision with WRONG words is refused as before even when a covering record is on file for the same key', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-1', 'add', 'backlog', 'v1.1.3');
      const rows = operatorRows().length;
      expect(await refusal(ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--decision', '9', '--words', 'stop and park'))).toMatch(/not the operator's/);
      expect(queued()).toEqual([]);
      expect(operatorRows()).toHaveLength(rows);
    });

    it('--decision with the right words and a covering record on file runs the words path: the same record is cited, no second row', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-1', 'add', 'backlog', 'v1.1.3');
      const id = lastId();
      const rows = operatorRows().length;
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--decision', '9', '--words', WORDS);
      expect(out.at(-2)).toContain(`OPERATOR ${id} (decision 9, the operator's words)`);
      expect(queued()).toMatchObject([{ key: 'HIMMEL-1', evidence: { operator: id } }]);
      expect(operatorRows()).toHaveLength(rows);
    });

    it('a console leg files plain and cites nothing, as every filer does', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-1', 'add', 'backlog', 'v1.1.3');
      vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
      expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
      expect(queued()).toMatchObject([{ key: 'HIMMEL-1', evidence: {} }]);
      expect(out.some((l) => l.startsWith('OPERATOR '))).toBe(false);
    });

    it('a bridge session files plain and claims no record on file', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-1', 'add', 'backlog', 'v1.1.3');
      vi.stubEnv('HIMMEL_BRIDGE_SESSION', '1');
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'));
      expect(queued()).toMatchObject([{ key: 'HIMMEL-1', evidence: {} }]);
    });

    it('the release manager still cannot file a request, with or without a record', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-1', 'add', 'backlog', 'v1.1.3');
      vi.stubEnv('HIMMEL_RELEASE_MANAGER', '1');
      await expect(ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'))).rejects.toThrow(/the chief writes requests/);
      expect(queued()).toEqual([]);
    });

    it('--decision with --words still records the words and files as before, whatever else is on file', async () => {
      await declared();
      decisionFile();
      await record('HIMMEL-2', 'add', 'backlog', 'v1.1.3');
      quietJira();
      await ask(gateMirror(operatorDirected), ...intake('HIMMEL-1'), '--decision', '9', '--words', WORDS);
      const id = /^OPERATOR (O-v1\.1\.3-\d{4}) /.exec(out.at(-2) ?? '')?.[1];
      expect(id).toBeDefined();
      expect(queued()).toMatchObject([{ key: 'HIMMEL-1', evidence: { operator: id } }]);
    });
  });

  describe('required parent remainder at intake', () => {
    const queuedRows = () => readFileSync(requestsFile(), 'utf8').trim().split('\n').map((l) => JSON.parse(l) as { evidence: Record<string, unknown>; state: string });

    it('--required-by records the typed remainder evidence on the queued request', async () => {
      await declared();
      await ask(gateMirror({ key: 'HIMMEL-9953' }), ...intake('HIMMEL-9953'), '--required-by', 'HIMMEL-9914');
      expect(queuedRows()[0].evidence).toEqual({ follow_up_of: 'HIMMEL-9914', remainder: true });
    });

    it('--required-by on a request already open returns that request carrying the relation (a signed update, not the old empty-evidence row)', async () => {
      await declared();
      const m = gateMirror({ key: 'HIMMEL-9953' });
      await ask(m, ...intake('HIMMEL-9953'));
      expect(queuedRows()[0].evidence).toEqual({});
      await ask(m, ...intake('HIMMEL-9953'), '--required-by', 'HIMMEL-9914');
      expect(out.slice(-2)).toEqual(['REQ Q-v1.1.3-0001', 'REQ Q-v1.1.3-0001']);
      expect(queuedRows().at(-1)?.evidence).toEqual({ follow_up_of: 'HIMMEL-9914', remainder: true });
      expect(queuedRows().at(-1)?.state).toBe('open');
      const n = queuedRows().length;
      await ask(m, ...intake('HIMMEL-9953'), '--required-by', 'HIMMEL-9914');
      expect(queuedRows()).toHaveLength(n);
    });

    it('U1: --decision --words on a pending request that carries --required-by refiles it carrying the relation, and never invents one', async () => {
      await declared();
      decisionFile();
      const m = gateMirror({ key: 'HIMMEL-9953' }, { key: 'HIMMEL-9932' });
      await ask(m, ...intake('HIMMEL-9953'), '--required-by', 'HIMMEL-9914');
      await ask(m, ...intake('HIMMEL-9953'), '--decision', '9', '--words', WORDS);
      const id = /^OPERATOR (O-v1\.1\.3-\d{4}) /.exec(out.at(-3) ?? '')?.[1];
      expect(id).toBeDefined();
      expect(out.slice(-2)).toEqual(['WITHDRAWN Q-v1.1.3-0001 (withdrawn:' + id + ')', 'REQ Q-v1.1.3-0002']);
      expect(queuedRows().at(-1)).toMatchObject({ state: 'open', evidence: { follow_up_of: 'HIMMEL-9914', remainder: true, operator: id } });
      // an ask that never had the relation gets none through the words path
      await ask(m, ...intake('HIMMEL-9932'));
      await ask(m, ...intake('HIMMEL-9932'), '--decision', '9', '--words', WORDS);
      const id2 = /^OPERATOR (O-v1\.1\.3-\d{4}) /.exec(out.at(-3) ?? '')?.[1];
      expect(id2).toBeDefined();
      expect(queuedRows().at(-1)).toMatchObject({ state: 'open', evidence: { operator: id2 } });
      expect(Object.keys(queuedRows().at(-1)?.evidence ?? {})).toEqual(['operator']);
    });

    it('--required-by is refused for itself, a non-key, or evidence naming another parent', async () => {
      await declared();
      const m = gateMirror({ key: 'HIMMEL-9953' });
      expect(await refusal(ask(m, ...intake('HIMMEL-9953'), '--required-by', 'HIMMEL-9953'))).toMatch(/names another ticket key/);
      expect(await refusal(ask(m, ...intake('HIMMEL-9953'), '--required-by', 'nine'))).toMatch(/names another ticket key/);
      expect(await refusal(ask(m, ...intake('HIMMEL-9953'), '--required-by', 'HIMMEL-9914', '--evidence', '{"follow_up_of":"HIMMEL-1"}'))).toMatch(/may not carry follow_up_of; pass --required-by/);
      expect(existsSync(requestsFile())).toBe(false);
    });

    it('an unchanged ask after the refusal says so on stderr and queues nothing; new evidence queues', async () => {
      await declared();
      const m = gateMirror({ key: 'HIMMEL-9953' });
      await ask(m, ...intake('HIMMEL-9953'));
      const k = loadKey(join(root, 'keys', 'v1.1.3.key'));
      const path = requestsFile();
      const first = readChain<Record<string, unknown>>(path, k).verified[0];
      const { prev: _p, mac: _m, ...rest } = first as Record<string, unknown>;
      appendChain(path, k, { ...rest, state: 'ruled:R-v1.1.3-0001' } as never);
      appendChain(join(root, 'state', 'v1.1.3', 'rulings.jsonl'), k, {
        id: 'R-v1.1.3-0001', epoch: 1, req: 'Q-v1.1.3-0001', ts: new Date().toISOString(), verb: 'INTAKE', key: 'HIMMEL-9953', op: { kind: 'none', from_v: null, to_v: null },
        outcome: 'BACKLOG', class: 'backlog', sector: 'x', ground: 'defer', reason: 'no operator record', supersedes: [], authority: { kind: 'rm', ref: null }, phase: 'receipted',
      } as never);
      const err = vi.spyOn(console, 'error').mockImplementation(() => undefined);
      out = [];
      await ask(m, ...intake('HIMMEL-9953'));
      expect(out).toEqual(['REQ Q-v1.1.3-0001']);
      expect(err.mock.calls.flat().join('\n')).toMatch(/already ruled:R-v1.1.3-0001 and nothing in this ask is new/);
      expect(queuedRows()).toHaveLength(2);
      await ask(m, ...intake('HIMMEL-9953'), '--required-by', 'HIMMEL-9914');
      expect(out.at(-1)).toBe('REQ Q-v1.1.3-0002');
    });
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

describe('the door at the request entry point', () => {
  const vf = () => join(root, 'verbatim.txt');
  const declared = () => run('operator', 'declare', 'v1.1.3', '--versions', 'v1.1.3,v1.1.4', '--decision', '106', '--verbatim-file', vf());
  type Issue = { key: string; labels?: string[]; priority?: string; fixVersions?: string[] };
  const doorMirror = (...issues: Issue[]): string => {
    const dir = join(root, 'door-mirror');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync: '2026-11-22T00:00:00Z' }));
    for (const i of issues) {
      writeFileSync(join(dir, `${i.key}.md`), `---\nkey: ${JSON.stringify(i.key)}\nstatus: "To Do"\nstatusCategory: "To Do"\ntype: "Task"\n`
        + `priority: ${JSON.stringify(i.priority ?? 'Medium')}\nlabels: ${JSON.stringify(i.labels ?? [])}\nfixVersions: ${JSON.stringify(i.fixVersions ?? [])}\n---\n`);
    }
    return dir;
  };
  const ask = (mir: string, ...a: string[]) => run('request', 'v1.1.3', '--mirror-root', mir, ...a);
  const intake = (key: string, to = 'v1.1.3') => ['--verb', 'INTAKE', '--key', key, '--from', 'backlog', '--to', to, '--why', 'the chief places it after the review'];
  const refusal = async (p: Promise<unknown>): Promise<string> => {
    try {
      await p;
    } catch (e) {
      return (e as Error).message;
    }
    throw new Error('expected a refusal');
  };
  const requests = () => {
    const path = join(root, 'state', 'v1.1.3', 'requests.jsonl');
    return existsSync(path) ? readChain<Record<string, unknown>>(path, loadKey(join(root, 'keys', 'v1.1.3.key'))).verified : [];
  };
  const tree = (marker: Record<string, string> = {}) => {
    const procRoot = mkdtempSync(join(root, 'proc-'));
    for (const [pid, ppid, uid, env] of [[300, 200, 1000, {}], [200, 100, 1000, marker], [100, 1, 1000, {}], [1, 0, 0, null]] as const) {
      mkdirSync(join(procRoot, String(pid)));
      writeFileSync(join(procRoot, String(pid), 'status'), `Name:\tp\nPPid:\t${ppid}\nUid:\t${uid}\t${uid}\t${uid}\t${uid}\nNSpid:\t${pid}\n`);
      if (env) writeFileSync(join(procRoot, String(pid), 'environ'), Object.entries({ PATH: '/usr/bin', ...env }).map(([k, v]) => `${k}=${v}\0`).join(''));
    }
    mkdirSync(join(procRoot, '300', 'ns'));
    symlinkSync('pid:[4026531836]', join(procRoot, '300', 'ns', 'pid'));
    symlinkSync('user:[4026531837]', join(procRoot, '300', 'ns', 'user'));
    symlinkSync('300', join(procRoot, 'self'));
    const hostNsPath = join(procRoot, 'host-ns-ref');
    writeFileSync(hostNsPath, 'pid:[4026531836] user:[4026531837]\n');
    return { procRoot, hostNsPath };
  };

  beforeEach(() => {
    vi.stubEnv('HIMMEL_ADMISSIONS_LEDGER', join(root, 'admissions-ledger.jsonl'));
    fenceTree.at = tree();
  });
  afterEach(() => {
    fenceTree.at = null;
  });

  it('the evidence fence refuses each field only its own path writes, one at a time, and files nothing (I12, T8)', async () => {
    await declared();
    const m = doorMirror({ key: 'K-2' });
    for (const [field, value] of [['chief_placement', { reason: 'x' }], ['operator_record', 'O-v1.1.3-0001'], ['filed_by', 'bridge'], ['operator_update', 7],
      ['bridge_chat', 1], ['remainder', true], ['follow_up_of', 'K-1']] as const) {
      expect(await refusal(ask(m, ...intake('K-2'), '--evidence', JSON.stringify({ [field]: value })))).toMatch(new RegExp(`--evidence may not carry ${field}`));
    }
    expect(requests()).toEqual([]);
  });

  it('the fence lets a PR number and the typed --required-by through (I12)', async () => {
    await declared();
    const m = doorMirror({ key: 'K-2' }, { key: 'K-3' });
    await ask(m, ...intake('K-2'), '--evidence', '{"pr":12}');
    await ask(m, ...intake('K-3'), '--required-by', 'K-1');
    expect(requests().map((r) => r.evidence)).toEqual([{ pr: 12 }, { follow_up_of: 'K-1', remainder: true }]);
  });

  it('--chief-reason is the console session\'s only, and never under a worker (I12)', async () => {
    await declared();
    const m = doorMirror({ key: 'K-2' });
    expect(await refusal(ask(m, ...intake('K-2'), '--chief-reason', 'the release needs it'))).toMatch(/--chief-reason refused: .*HIMMEL_CONSOLE=1/);
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    fenceTree.at = tree({ HIMMEL_CONSOLE_LEG: '1' });
    expect(await refusal(ask(m, ...intake('K-2'), '--chief-reason', 'the release needs it'))).toMatch(/--chief-reason refused: .*chief-spawned worker/);
    expect(requests()).toEqual([]);
  });

  it('an operator-directed INTAKE with no --decision files for any filer, and the door rules it (S3, I7)', async () => {
    await declared();
    await ask(doorMirror({ key: 'K-2', labels: ['operator-directed'] }), '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1.1.3', '--why', 'the operator asked for it in the chief window');
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
    expect(requests()).toMatchObject([{ key: 'K-2', to_v: 'v1.1.3', state: 'open', evidence: {} }]);
  });

  it('with both checks passing, --chief-reason writes chief_placement on a High ticket that files without it too (I12, D-j)', async () => {
    await declared();
    const m = doorMirror({ key: 'K-2', priority: 'High' }, { key: 'K-3', priority: 'High' });
    await ask(m, ...intake('K-3'));
    expect(out.at(-1)).toBe('REQ Q-v1.1.3-0001');
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    await ask(m, ...intake('K-2'), '--chief-reason', 'the release needs it');
    const [, row] = requests();
    expect(row).toMatchObject({ key: 'K-2', to_v: 'v1.1.3', state: 'open', evidence: { chief_placement: { reason: 'the release needs it' } } });
    expect((row.evidence as { chief_placement: { ts: string } }).chief_placement.ts).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  it('--chief-reason never places a key later than a version it holds, nor in the backlog while it holds one (P5)', async () => {
    await declared();
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    const m = doorMirror({ key: 'K-2', fixVersions: ['v1.1.3'] });
    expect(await refusal(ask(m, '--verb', 'INTAKE', '--key', 'K-2', '--to', 'v1.1.4', '--why', 'the chief places it after the review', '--chief-reason', 'later')))
      .toMatch(/cannot place K-2 in v1\.1\.4, later than v1\.1\.3/);
    expect(await refusal(ask(m, '--verb', 'INTAKE', '--key', 'K-2', '--to', 'backlog', '--why', 'the chief places it after the review', '--chief-reason', 'out')))
      .toMatch(/cannot send K-2 to the backlog while it holds v1\.1\.3/);
    expect(requests()).toEqual([]);
  });

  it('--chief-reason joins a waiting request as the same request, and refuses a claimed one or another move (P11)', async () => {
    await declared();
    const m = doorMirror({ key: 'K-2' }, { key: 'K-3' });
    await ask(m, ...intake('K-2', 'v1.1.4'));
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    expect(await refusal(ask(m, ...intake('K-2'), '--chief-reason', 'the release needs it')))
      .toMatch(/Q-v1\.1\.3-0001 on K-2 waits for INTAKE backlog to v1\.1\.4; withdraw it to place the key elsewhere/);
    await ask(m, ...intake('K-2', 'v1.1.4'), '--chief-reason', 'the release needs it');
    const rows = requests();
    expect(rows.map((r) => r.req)).toEqual(['Q-v1.1.3-0001', 'Q-v1.1.3-0001']);
    expect(Object.keys(rows[1]).sort()).toEqual(Object.keys(rows[0]).sort());
    expect(rows[1]).toMatchObject({ state: 'open', to_v: 'v1.1.4', evidence: { chief_placement: { reason: 'the release needs it' } } });
    vi.stubEnv('HIMMEL_CONSOLE', '');
    await ask(m, ...intake('K-3'));
    const doc = '/abs/rm-doc.md';
    const rm = { ...ctxFor('v1.1.3', m), env: { ...process.env, HIMMEL_RELEASE_MANAGER: '1', HIMMEL_CONSOLE_LEG: '1', HIMMEL_RM_DOC: doc, HIMMEL_RM_RELEASE: 'v1.1.3' } };
    engineMod.leaseAcquire(rm, { expectEpoch: 0, doc, session: 'rm-1' });
    engineMod.claim(rm);
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    expect(await refusal(ask(m, ...intake('K-3'), '--chief-reason', 'the release needs it'))).toMatch(/Q-v1\.1\.3-0002 on K-3 is claimed; ask again after the run/);
  });

  it('the repair line apply prints for a door ruling holding both ends runs as written and files the chief placement (P1, T5)', async () => {
    await declared();
    vi.stubEnv('HOME', join(root, 'home'));
    vi.stubEnv('JIRA_PROJECT_KEY', 'HIMMEL');
    const mir = join(root, 'home', '.himmel', 'state', 'jira-mirror', 'HIMMEL');
    mkdirSync(mir, { recursive: true });
    writeFileSync(join(mir, '.cursor.json'), JSON.stringify({ lastSync: '2026-11-22T00:00:00Z' }));
    writeFileSync(join(mir, 'HIMMEL-4.md'), '---\nkey: "HIMMEL-4"\nstatus: "To Do"\nstatusCategory: "To Do"\ntype: "Task"\npriority: "Medium"\nlabels: []\nfixVersions: ["v1.1.3","v1.1.4"]\n---\n');
    vi.stubEnv('HIMMEL_CONSOLE', '1');
    const line = 'jira release request v1.1.3 --verb REVERSION --key HIMMEL-4 --from v1.1.4 --to v1.1.3 --why "finish R-v1.1.3-0001: HIMMEL-4 holds both v1.1.4 and v1.1.3"'
      + ' --chief-reason "repair of R-v1.1.3-0001, interrupted between its add and its remove"';
    const argv = [...line.matchAll(/"([^"]*)"|(\S+)/g)].map((x) => x[1] ?? x[2]);
    expect(argv.slice(0, 2)).toEqual(['jira', 'release']);
    await run(...argv.slice(2));
    expect(requests()).toMatchObject([{ verb: 'REVERSION', key: 'HIMMEL-4', from_v: 'v1.1.4', to_v: 'v1.1.3', state: 'open',
      evidence: { chief_placement: { reason: 'repair of R-v1.1.3-0001, interrupted between its add and its remove' } } }]);
  });
});

describe('jira release for-project', () => {
  it('prints the declared release and its current for HIMMEL, and [] for SALUS (T10)', async () => {
    await run('operator', 'declare', 'v1.1.3', '--versions', 'v1.1.3,v1.1.4', '--decision', '106', '--verbatim-file', join(root, 'verbatim.txt'));
    await run('for-project', 'HIMMEL', '--json');
    expect(JSON.parse(out.at(-1) as string)).toEqual([{ release: 'v1.1.3', current: 'v1.1.3', versions: ['v1.1.3', 'v1.1.4'] }]);
    await run('for-project', 'SALUS', '--json');
    expect(JSON.parse(out.at(-1) as string)).toEqual([]);
  });

  it('fails when a declaration that could name the project does not parse', async () => {
    mkdirSync(join(root, 'state', 'R9'), { recursive: true });
    writeFileSync(join(root, 'state', 'R9', 'release.json'), 'not json');
    await expect(run('for-project', 'HIMMEL', '--json')).rejects.toThrow(/cannot be read/);
  });
});

describe('the door\'s alerts after rm-run (N4, I13)', () => {
  const mirror = (key: string, priority: string, labels: string[]) => {
    const dir = join(root, 'alert-mirror');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, '.cursor.json'), JSON.stringify({ lastSync: '2026-11-22T00:00:00Z' }));
    writeFileSync(join(dir, `${key}.md`), `---\nkey: "${key}"\nstatus: "To Do"\nstatusCategory: "To Do"\ntype: "Task"\npriority: "${priority}"\nlabels: ${JSON.stringify(labels)}\nfixVersions: []\n---\n`);
    return dir;
  };
  const line = (key: string, verb: string, op: string, outcome: string, ground: string) =>
    `RULING R-R1-0001 Q-R1-0001 ${verb} ${key} ${op} backlog→backlog ${outcome} backlog sector=s — ${ground}: the reason`;

  it('a door BACKLOG on a security key still alerts; a door line raises no High alert; a non-door High BACKLOG does', async () => {
    const sec = ctxFor('R1', mirror('K-2', 'Medium', ['security']));
    expect(await backlogAlerts(sec, 'R1', [line('K-2', 'INTAKE', 'none', 'BACKLOG', 'door:mild-no-next')]))
      .toEqual(['RM-RUN R1 alert: K-2 security BACKLOG: the reason']);
    const high = ctxFor('R1', mirror('K-3', 'High', []));
    expect(await backlogAlerts(high, 'R1', [line('K-3', 'INTAKE', 'none', 'BACKLOG', 'door:operator-standing:R-R1-0009')])).toEqual([]);
    expect(await backlogAlerts(high, 'R1', [line('K-3', 'INTAKE', 'none', 'BACKLOG', 'frozen-set')])).toEqual(['RM-RUN R1 alert: K-3 High BACKLOG: the reason']);
  });

  it('a door AD-HOC no change and a door KEEP print nothing (I13)', async () => {
    const high = ctxFor('R1', mirror('K-3', 'High', ['security']));
    expect(await backlogAlerts(high, 'R1', [
      line('K-3', 'INTAKE', 'none', 'AD-HOC', 'door:operator-standing:R-R1-0009'),
      line('K-3', 'REVERSION', 'keep', 'KEEP', 'door:only-operator-moves-out'),
    ])).toEqual([]);
  });
});

describe('liveJira.issue reads the labels and takes the run\'s signal (R3-F1, F4)', () => {
  it('asks Jira for labels, returns them on the snapshot, and passes the signal on', async () => {
    vi.mocked(request).mockReset();
    vi.mocked(request).mockImplementation((async () => ({ fields: {
      status: { name: 'In Progress', statusCategory: { name: 'In Progress' } }, issuetype: { name: 'Task' }, priority: null,
      fixVersions: [], resolution: null, labels: ['operator-directed'],
    } })) as never);
    const stop = new AbortController();
    const got = await liveJira.issue('HIMMEL-7', { signal: stop.signal });
    const [method, path, body, writer, opts] = vi.mocked(request).mock.calls[0] as unknown[];
    expect([method, body, writer]).toEqual(['GET', undefined, undefined]);
    expect(String(path)).toMatch(/^\/issue\/HIMMEL-7\?fields=.*\blabels\b/);
    expect((opts as { signal?: AbortSignal }).signal).toBe(stop.signal);
    expect(got).toMatchObject({ key: 'HIMMEL-7', labels: ['operator-directed'], priority: '', statusCategory: 'In Progress', sector: null });
  });

  it('adds labels with one update call', async () => {
    vi.mocked(request).mockReset();
    vi.mocked(request).mockImplementation((async () => undefined) as never);
    await liveJira.addLabels('HIMMEL-7', ['backlog']);
    expect(vi.mocked(request).mock.calls[0]).toEqual(['PUT', '/issue/HIMMEL-7', { update: { labels: [{ add: 'backlog' }] } }]);
  });
});

describe('release core-check reads who signs (I13)', () => {
  const CORE_PATH = 'scripts/handover/chief-kit/tick.sh';
  let mirror: string;
  let corePaths: string;

  beforeEach(async () => {
    mirror = join(root, 'mirror');
    mkdirSync(mirror);
    writeFileSync(join(mirror, '.cursor.json'), JSON.stringify({ lastSync: '2026-11-23T00:00:00Z' }));
    for (const k of ['K-5', 'K-6']) writeFileSync(join(mirror, `${k}.md`), `---\nkey: "${k}"\nstatus: "To Do"\ntype: "Task"\npriority: "Medium"\nfixVersions: []\n---\n`);
    corePaths = join(root, 'core-paths.txt');
    writeFileSync(corePaths, '^scripts/handover/chief-kit/tick\\.sh$\n');
    const vf = join(root, 'verbatim.txt');
    for (const r of ['R1', 'R2']) await run('operator', 'declare', r, '--versions', r === 'R1' ? 'v1' : 'v2', '--decision', '1', '--verbatim-file', vf);
    await run('operator', 'core-bypass', 'R1', '--keys', 'K-5', '--decision', '412', '--verbatim-file', vf);
    await run('operator', 'core-bypass', 'R1', '--keys', 'K-6', '--decision', '413', '--verbatim-file', vf);
    out = [];
  });
  const check = async (...keys: string[]) => {
    out = [];
    await run('core-check', '--paths', CORE_PATH, '--key', ...keys, '--mirror', mirror, '--core-paths', corePaths);
    return out;
  };

  it('release core-check on a fixture root holding a mark and an operator core-bypass for the same key, both appended as chain rows, prints no BYPASS for it', async () => {
    expect(await check('K-5', 'K-6')).toEqual([expect.stringMatching(/^BYPASS-NEEDS-SPEC K-5 operator no spec-review record for K-5 \(bypass: O-R1-\d+ decision 412\)$/), expect.stringMatching(/^BYPASS-NEEDS-SPEC K-6 operator no spec-review record for K-6 \(bypass: O-R1-\d+ decision 413\)$/)]);
    const path = join(root, 'state', 'R1', 'operator.jsonl');
    const key = loadKey(join(root, 'keys', 'R1.key'));
    appendChain<OperatorRow>(path, key, {
      id: `O-R1-${String(readChain<OperatorRow>(path, key).rows.length + 1).padStart(4, '0')}`,
      kind: 'spec-signer', ts: new Date().toISOString(), decision: '1170', keys: ['K-5'], signer: 'operator', verbatim: 'K-5 is mine to sign',
    });
    expect(await check('K-5', 'K-6')).toEqual([`CORE K-5 ${CORE_PATH}`, expect.stringMatching(/^BYPASS-NEEDS-SPEC K-6 operator no spec-review record for K-6 \(bypass: O-R1-\d+ decision 413\)$/)]);
  });

  it('with the operator core-bypass in a healthy declared release and a chain break in another, release core-check prints no BYPASS for it', async () => {
    const broken = join(root, 'state', 'R2', 'operator.jsonl');
    writeFileSync(broken, `${readFileSync(broken, 'utf8')}not json\n`);
    expect(await check('K-5', 'K-6')).toEqual([`CORE K-5 ${CORE_PATH}`, `CORE K-6 ${CORE_PATH}`]);
  });
});

describe('the spec signer: operator spec-signer, operator spec --signer and signer-check', () => {
  const opPath = () => join(root, 'state', 'R1', 'operator.jsonl');
  const rowsOf = (kind: string) => readChain<OperatorRow>(opPath(), loadKey(join(root, 'keys', 'R1.key'))).verified.filter((r) => r.kind === kind);
  let mir: string;
  let sent: string;
  const sender = (body: string) => {
    writeFileSync(join(root, 'sender.sh'), `#!/usr/bin/env bash\n${body}\n`);
    chmodSync(join(root, 'sender.sh'), 0o755);
  };
  const decide = (n: string, words: string) => {
    mkdirSync(join(root, 'specs', 'decisions'), { recursive: true });
    writeFileSync(join(root, 'specs', 'decisions', `verbatim-decision-${n}-operator-11-23.txt`), `Decision ${n}, operator, 2026-11-23.\n\n${words}\n`);
  };
  function specFile(name: string, ticket: string | null, base = 'specs'): string {
    const dir = join(root, base, name.replace(/\.md$/, ''));
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'est.json'), JSON.stringify({ median_seq: 1, sigma: 0.1, dod: { passed: true } }));
    const p = join(dir, name);
    writeFileSync(p, [`# ${ticket ?? 'K-1'}: a fixture design${ticket ? `\n\n- Ticket: ${ticket}` : ''}`, '', 'Estimate record: est.json', '',
      '## Alternatives considered', '', '- none better.', '', '## Definition of done', '', '- the fixture signs.', '', '## Invariants', '', 'none', ''].join('\n'));
    writeFileSync(`${p}.critic-spec-r1.md`, 'the critic\'s return\n\nSPEC CLEAN\n');
    writeFileSync(`${p}.critic-plan-r1.md`, 'the critic\'s return\n\nPLAN CLEAN\n');
    return p;
  }
  const signArgs = (keys: string, p: string) => ['operator', 'spec', 'R1', '--keys', keys, '--spec', p, '--verdict', `${p}.critic-spec-r1.md`, '--verdict', `${p}.critic-plan-r1.md`];
  const chiefSign = (keys: string, p: string) => run(...signArgs(keys, p), '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'));
  const put = (keys: string[] | undefined, signer: 'chief' | 'operator', decision: string) => {
    const k = loadKey(join(root, 'keys', 'R1.key'));
    return appendChain<OperatorRow>(opPath(), k, {
      id: `O-R1-${String(readChain<OperatorRow>(opPath(), k).rows.length + 1).padStart(4, '0')}`,
      kind: 'spec-signer', ts: new Date().toISOString(), decision, signer, ...(keys ? { keys } : {}), verbatim: `the operator's words, decision ${decision}`,
    });
  };
  const signerCheck = async (...args: string[]) => {
    out = [];
    await run('signer-check', '--mirror', mir, ...args);
    return out;
  };
  const STATION_CHIEF = 'the chief signs every spec again from now on';
  const OP_K1 = 'the operator signs K-1 himself, spec and plan';

  beforeEach(async () => {
    vi.stubEnv('JIRA_PROJECT_KEY', '');
    await run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '106', '--verbatim-file', join(root, 'verbatim.txt'));
    mir = join(root, 'jira-mirror', 'HIMMEL');
    mkdirSync(mir, { recursive: true });
    writeFileSync(join(mir, '.cursor.json'), JSON.stringify({ lastSync: '2026-11-23T00:00:00Z', complete: false }));
    for (const [k, type, parent] of [['V-1', 'Task'], ['K-1', 'Task'], ['K-2', 'Task'], ['K-9', 'Task'], ['K-4', 'Subtask', 'V-1']]) {
      writeFileSync(join(mir, `${k}.md`), `---\nkey: "${k}"\nstatus: "x"\nstatusCategory: "To Do"\ntype: "${type}"\npriority: "Medium"\n${parent ? `parent: "${parent}"\n` : ''}---\n`);
    }
    sent = join(root, 'sent.txt');
    sender(`printf '%s\\n' "$2" >> ${JSON.stringify(sent)}`);
    writeFileSync(join(root, 'access.json'), '{"allowFrom":["4242"]}\n');
    vi.stubEnv('TELEGRAM_ACCESS_PATH', join(root, 'access.json'));
    vi.stubEnv('MERGE_BLOCK_ALERT_CMD', join(root, 'sender.sh'));
    vi.stubEnv('HIMMEL_TEST_FIXTURE', '1');
    vi.stubEnv('BRIDGE_ROOT', '');
    decide('1201', STATION_CHIEF);
    decide('1202', OP_K1);
    out = [];
  });

  it('with HIMMEL_TEST_FIXTURE=1 and TELEGRAM_ACCESS_PATH at a no-chat file, operator spec --signer operator writes no row, and operator spec-signer --signer chief writes no row; with the stub sender, each writes its row and the sender captured one line of its kind (I6)', async () => {
    const p = specFile('K-1-own.md', null);
    const opSign = () => run(...signArgs('K-1', p), '--signer', 'operator', '--decision', '1202', '--words', OP_K1);
    const station = () => run('operator', 'spec-signer', 'R1', '--signer', 'chief', '--decision', '1201', '--words', STATION_CHIEF);
    vi.stubEnv('TELEGRAM_ACCESS_PATH', join(root, 'absent.json'));
    await expect(opSign()).rejects.toThrow('release operator spec: the operator alert exited 1; no record written');
    await expect(station()).rejects.toThrow('release operator spec-signer: the operator alert exited 1; no record written');
    expect(rowsOf('spec')).toEqual([]);
    expect(rowsOf('spec-signer')).toEqual([]);
    expect(existsSync(sent)).toBe(false);
    vi.stubEnv('TELEGRAM_ACCESS_PATH', join(root, 'access.json'));
    await opSign();
    await station();
    const [sig] = rowsOf('spec');
    const [rec] = rowsOf('spec-signer');
    expect(sig).toMatchObject({ signer: 'operator', operator_keys: ['K-1'], decision: '1202', verbatim: OP_K1 });
    expect(rec).toMatchObject({ signer: 'chief', decision: '1201', verbatim: STATION_CHIEF });
    expect(out).toContain(`${rec.id} spec-signer the station default signed by chief`);
    const lines = readFileSync(sent, 'utf8').trim().split('\n');
    expect(lines).toHaveLength(2);
    expect(lines[0]).toContain(`"${OP_K1}" — operator signature recorded for K-1, decision 1202`);
    expect(lines[1]).toContain(`"${STATION_CHIEF}" — spec signer: the station default now signed by chief, decision 1201`);
  });

  it.each(['MERGE_BLOCK_ALERT_CMD', 'TELEGRAM_ACCESS_PATH', 'BRIDGE_ROOT'])('sendSignerAlert with %s set and HIMMEL_TEST_FIXTURE unset returns non-zero naming the variable and runs no sender; operator spec-signer --signer chief under the same environment writes no row (I6)', async (v) => {
    vi.stubEnv('MERGE_BLOCK_ALERT_CMD', '');
    vi.stubEnv('TELEGRAM_ACCESS_PATH', '');
    vi.stubEnv(v, join(root, 'sender.sh'));
    vi.stubEnv('HIMMEL_TEST_FIXTURE', '');
    const errs: string[] = [];
    vi.spyOn(console, 'error').mockImplementation((s: string) => { errs.push(s); });
    const a = { kind: 'record' as const, scope: 'the station default', signer: 'chief' as const, decision: '1201', words: STATION_CHIEF, notes: [], chiefSigned: [] };
    expect(sendSignerAlert(a)).not.toBe(0);
    expect(errs.join('\n')).toContain(v);
    await expect(run('operator', 'spec-signer', 'R1', '--signer', 'chief', '--decision', '1201', '--words', STATION_CHIEF)).rejects.toThrow(/the operator alert exited 1; no record written/);
    expect(rowsOf('spec-signer')).toEqual([]);
    expect(existsSync(sent)).toBe(false);
  });

  it('sendSignerAlert with timeoutMs 200, HIMMEL_TEST_FIXTURE=1 and MERGE_BLOCK_ALERT_CMD set to a sender that sleeps 2 s returns non-zero (I6)', () => {
    sender('sleep 2');
    const t = Date.now();
    expect(sendSignerAlert({ kind: 'record', scope: 'K-1', signer: 'operator', decision: '1202', words: OP_K1, notes: [], chiefSigned: [] }, 200)).not.toBe(0);
    expect(Date.now() - t).toBeLessThan(1800);
  });

  describe('the copy to the operator after a chief signature (I8, I16)', () => {
    const bridge = () => join(root, 'bridge');
    const docLines = (): number => {
      const walk = (d: string): string[] => (existsSync(d) ? readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)])) : []);
      return walk(bridge()).filter((f) => f.endsWith('.jsonl')).reduce((n, f) => n + readFileSync(f, 'utf8').split('\n').filter((l) => l.includes('document_path')).length, 0);
    };
    const sentLines = () => (existsSync(sent) ? readFileSync(sent, 'utf8').trim().split('\n') : []);
    function sealed(p: string): string {
      const page = p.replace(/\.md$/, '.html');
      writeFileSync(page, '<!doctype html><title>spec</title>\n');
      const sha = createHash('sha256').update(readFileSync(page)).digest('hex');
      writeFileSync(`${p}.critic-spec-r1.md`, `the critic's return\n\nCONTENT-SHA256 ${sha} ${relative(dirname(p), page)}\nSPEC CLEAN\n`);
      writeFileSync(`${p}.critic-plan-r1.md`, `the critic's return\n\nPLAN CLEAN\n`);
      return page;
    }
    const sealedSign = (keys: string, p: string) =>
      run('operator', 'spec', 'R1', '--keys', keys, '--spec', p, '--verdict', `${p}.critic-spec-r1.md`, '--verdict', `${p}.critic-plan-r1.md`, '--decision', '387', '--verbatim-file', join(root, 'verbatim.txt'));
    function ledgerSealed(): string {
      const candidate = fileURLToPath(new URL('../../../../', import.meta.url));
      const bun = execFileSync('which', ['bun'], { encoding: 'utf8' }).trim();
      const key = 'HIMMEL-9831';
      const page = { path: `specs/designs/${key}-sliced.html`, text: '<!doctype html><title>spec</title>\n' };
      const estimate = { path: 'specs/designs/estimate.json', text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' };
      const request = {
        scratchRoot: mkdtempSync(join(root, 'ledger-')), key, specStem: `${key}-sliced`,
        specText: `---\ntickets: ${key}\n---\n# ${key} fixture\n\nEstimate record: estimate.json\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n`,
        planText: `---\ntickets: ${key}\n---\n# ${key} plan\n\n- Ticket: ${key}\n\n- Task 1: build the fixture.\n`,
        returns: [
          { kind: 'spec', round: 1, text: 'SPEC CLEAN\n', reads: ['spec', estimate, page] },
          { kind: 'plan', round: 1, text: 'PLAN CLEAN\n', reads: ['spec', 'plan', estimate, page] },
        ],
      };
      const built = JSON.parse(execFileSync(bun, [join(candidate, 'scripts/telegram/testlib-capped-fold.ts')], { input: JSON.stringify(request), encoding: 'utf8', timeout: 15000 })) as { spec: string };
      return built.spec;
    }
    const lastSpecRow = () => rowsOf('spec').at(-1) as OperatorRow;
    beforeEach(() => { vi.stubEnv('BRIDGE_ROOT', bridge()); mkdirSync(bridge(), { recursive: true }); });

    it('sealedPage gives the page when the row\'s SPEC verdict seals it at its current bytes, and null after the page is edited (I16)', async () => {
      const p = specFile('V-1-sliced.md', 'V-1', 'work');
      const page = sealed(p);
      await sealedSign('V-1', p);
      expect(sealedPage(lastSpecRow())).toBe(page);
      writeFileSync(page, '<!doctype html><title>edited</title>\n');
      expect(sealedPage(lastSpecRow())).toBeNull();
    });

    it('sealedPage gives null for a row whose verdicts seal nothing (I16)', async () => {
      const p = specFile('V-1-sliced.md', 'V-1', 'work');
      writeFileSync(p.replace(/\.md$/, '.html'), '<!doctype html>\n');
      await chiefSign('V-1,K-1', p);
      expect(sealedPage(lastSpecRow())).toBeNull();
    });

    it('a chief signature: a sealed page queues one document_path line; an edited page queues none and the sender captures the text line; an operator signature queues neither (I16)', async () => {
      await sealedSign('HIMMEL-9831', ledgerSealed());
      expect(docLines()).toBe(1);
      expect(sentLines()).toEqual([]);
      const q = specFile('V-2-edited.md', 'V-2', 'work');
      writeFileSync(sealed(q), '<!doctype html><title>edited</title>\n');
      await sealedSign('V-2', q);
      expect(docLines()).toBe(1);
      expect(sentLines()).toHaveLength(1);
      expect(sentLines()[0]).toContain(`spec ${q} sha256 `);
      const o = specFile('K-1-own.md', null, 'work');
      await run(...signArgs('K-1', o), '--signer', 'operator', '--decision', '1202', '--words', OP_K1);
      expect(docLines()).toBe(1);
      expect(sentLines()).toHaveLength(2);
      expect(sentLines()[1]).toContain('operator signature recorded');
    });

    it('a chief signature with a failing sender and no page: the row is written, the WARN with the resend line is printed, and the command exits 0', async () => {
      sender('exit 1');
      const errs: string[] = [];
      vi.spyOn(console, 'error').mockImplementation((s: string) => { errs.push(s); });
      const p = specFile('V-1-sliced.md', 'V-1');
      await chiefSign('V-1,K-1', p);
      expect(lastSpecRow()).toMatchObject({ signer: 'chief' });
      const warn = errs.find((l) => l.startsWith('WARN spec copy not sent')) ?? '';
      expect(warn).toContain('spec-cc.sh');
      expect(warn).toContain(lastSpecRow().id);
      expect(warn.endsWith(" '-'")).toBe(true);
    });

    it('runSpecCopy with timeoutMs 200, page -, HIMMEL_TEST_FIXTURE=1 and MERGE_BLOCK_ALERT_CMD set to a sender that sleeps 2 s returns non-zero (I8)', () => {
      sender('sleep 2');
      const t = Date.now();
      expect(runSpecCopy({ oid: 'O-R1-0001', keys: 'K-1', spec: '/x/spec.md', sha: 'a'.repeat(64), page: '-' }, 200)).not.toBe(0);
      expect(Date.now() - t).toBeLessThan(1800);
    });
  });

  it('signer-check prints default chief with no record, the mark\'s id for a marked key, the station id under a station record, UNKNOWN on a broken chain, UNKNOWN for a sub-task missing from an incomplete mirror under a parent mark, and its answer, never UNKNOWN, for a key absent from the mirror under a station-only record or holding its own record; it runs under a test fixture root (I15)', async () => {
    expect(await signerCheck('K-1', 'K-77')).toEqual(['SIGNER K-1 chief default', 'SIGNER K-77 chief default']);
    const station = put(undefined, 'operator', '1180');
    expect(await signerCheck('K-2', 'K-77')).toEqual([`SIGNER K-2 operator ${station.id}`, `SIGNER K-77 operator ${station.id}`]);
    put(['K-88'], 'chief', '1181');
    const mark = put(['V-1'], 'operator', '1182');
    expect(await signerCheck('V-1', 'K-4', 'K-5', 'K-88')).toEqual([
      `SIGNER V-1 operator ${mark.id}`, `SIGNER K-4 operator ${mark.id}`,
      'UNKNOWN K-5 K-5 is not in the Jira mirror, so its parent\'s mark cannot be read', `SIGNER K-88 operator ${station.id}`,
    ]);
    vi.stubEnv('HIMMEL_REAL_STATE_ASSUME_STATION', '1');
    vi.stubEnv('HIMMEL_REAL_STATE_EXTRA_ROOTS', root);
    expect(await signerCheck('V-1')).toEqual([`SIGNER V-1 operator ${mark.id}`]);
    writeFileSync(opPath(), `${readFileSync(opPath(), 'utf8')}not json\n`);
    const [broken] = await signerCheck('K-1');
    expect(broken).toMatch(/^UNKNOWN K-1 release R1: operator\.jsonl/);
  });

  it('signer-check K-1 prints SIGNER K-1 operator <mark id> via V-1; signer-check --spec <a spec naming V-1> K-9 prints the same via line for an unsigned key; signer-check K-1 prints SIGNER K-1 chief default once the mark is lifted (R5, I18 c)', async () => {
    const p = specFile('V-1-sliced.md', 'V-1');
    await chiefSign('V-1,K-1,K-2', p);
    expect(await signerCheck('K-1')).toEqual(['SIGNER K-1 chief default']);
    const mark = put(['V-1'], 'operator', '1170');
    expect(await signerCheck('K-1', 'K-2')).toEqual([`SIGNER K-1 operator ${mark.id} via V-1`, `SIGNER K-2 operator ${mark.id} via V-1`]);
    expect(await signerCheck('K-9')).toEqual(['SIGNER K-9 chief default']);
    expect(await signerCheck('--spec', p, 'K-9')).toEqual([`SIGNER K-9 operator ${mark.id} via V-1`]);
    put(['V-1'], 'chief', '1171');
    expect(await signerCheck('K-1')).toEqual(['SIGNER K-1 chief default']);
  });

  it('operator spec with --signer operator and --verbatim-file is refused naming --words; the old flag set signs as chief; a chief signature without --decision is refused; a chief signature without --verbatim-file is refused', async () => {
    const p = specFile('K-1-flags.md', null);
    const vf = join(root, 'verbatim.txt');
    await expect(run(...signArgs('K-1', p), '--signer', 'operator', '--decision', '1202', '--verbatim-file', vf)).rejects.toThrow(/--signer operator takes --words/);
    await expect(run(...signArgs('K-1', p), '--verbatim-file', vf)).rejects.toThrow('release operator spec: a signature needs --decision');
    await expect(run(...signArgs('K-1', p), '--decision', '387')).rejects.toThrow('release operator spec: a chief signature needs --decision and --verbatim-file');
    expect(rowsOf('spec')).toEqual([]);
    await chiefSign('K-1', p);
    expect(rowsOf('spec')).toEqual([expect.objectContaining({ signer: 'chief', keys: ['K-1'], decision: '387' })]);
  });
});
