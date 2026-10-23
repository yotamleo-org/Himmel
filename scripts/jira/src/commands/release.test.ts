import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Command } from 'commander';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

vi.mock('../client.js', () => ({ request: vi.fn(), projectKey: vi.fn(() => 'HIMMEL') }));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { projectKey, request } from '../client.js';
import { admissionBudget } from '../release/leaks.js';
import { registerRelease, renderState } from './release.js';

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
  vi.stubEnv('HIMMEL_CONSOLE_LEG', '');
  vi.stubEnv('HIMMEL_RELEASE_MANAGER', '');
  writeFileSync(join(root, 'verbatim.txt'), 'R = v1 + v2\n');
  out = [];
  vi.spyOn(console, 'log').mockImplementation((s: string) => { out.push(s); });
});

describe('jira release (HIMMEL-6796)', () => {
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
    expect(s.inputs.mirror).toBe('UNKNOWN');
    expect(s.burndown.v1.baseline).toBe(2);
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

  it('folds a batch file, prints every skipped key with its terminal and resolution, and reopens (HIMMEL-7158)', async () => {
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

  it('refuses an operator act from a console-spawned leg', async () => {
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
    await expect(run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', join(root, 'verbatim.txt')))
      .rejects.toThrow(/console-spawned leg/);
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

describe('jira release leaks (HIMMEL-7153)', () => {
  beforeEach(() => {
    vi.mocked(request).mockReset();
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

describe('jira release state admissions budget (HIMMEL-7153)', () => {
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
