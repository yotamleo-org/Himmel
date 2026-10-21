import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Command } from 'commander';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

vi.mock('../client.js', () => ({ request: vi.fn(), projectKey: () => 'HIMMEL' }));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { registerRelease } from './release.js';

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

  it('refuses an operator act from a console-spawned leg', async () => {
    vi.stubEnv('HIMMEL_CONSOLE_LEG', '1');
    await expect(run('operator', 'declare', 'R1', '--versions', 'v1', '--decision', '1', '--verbatim-file', join(root, 'verbatim.txt')))
      .rejects.toThrow(/console-spawned leg/);
  });
});
