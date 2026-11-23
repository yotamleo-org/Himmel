import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { declare, type Ctx, type JiraPort } from './engine.js';
import { setFixVersion } from '../commands/versions.js';

let root: string;

function releaseCtx(release: string): Ctx {
  return {
    release, dir: join(root, 'release', release), keyPath: join(root, 'keys', `${release}.key`),
    env: {}, now: () => new Date('2026-11-23T10:00:00.000Z'), jira: {} as JiraPort, mirrorRoot: null,
  };
}

function versionsTsv(project: string, rows: Array<[string, boolean]>): void {
  const dir = join(process.env.HOME as string, '.himmel', 'state', 'jira-mirror');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${project}.versions.tsv`), rows.map(([n, released]) => `${n}\t${released}\t\tfalse`).join('\n') + '\n');
}

interface Transport { set: string[]; calls: Array<{ method: string; path: string; body?: unknown }> }

function transport(set: string[]): Transport {
  const t: Transport = { set: [...set], calls: [] };
  const reply = (status: number, body: unknown) => ({ ok: status < 400, status, headers: new Headers(), text: async () => (body === undefined ? '' : JSON.stringify(body)) });
  vi.stubGlobal('fetch', vi.fn(async (url: string, init: RequestInit = {}) => {
    const method = init.method ?? 'GET';
    const u = new URL(url);
    const path = u.pathname.replace('/rest/api/3', '');
    const body = init.body ? JSON.parse(String(init.body)) as { update?: { fixVersions?: Array<{ add?: { name: string }; remove?: { name: string } }> } } : undefined;
    t.calls.push({ method, path, ...(body ? { body } : {}) });
    if (method === 'GET') return reply(200, { fields: { fixVersions: t.set.map((name) => ({ name })) } });
    for (const op of body?.update?.fixVersions ?? []) {
      if (op.add) t.set = [...new Set([...t.set, op.add.name])];
      if (op.remove) t.set = t.set.filter((v) => v !== op.remove?.name);
    }
    return reply(204, undefined);
  }));
  return t;
}

const puts = (t: Transport) => t.calls.filter((c) => c.method !== 'GET');

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'leave-'));
  vi.stubEnv('JIRA_BASE_URL', 'http://127.0.0.1:9');
  vi.stubEnv('HIMMEL_RELEASE_STATE_DIR', join(root, 'release'));
  vi.stubEnv('HIMMEL_RELEASE_KEY_DIR', join(root, 'keys'));
  vi.stubEnv('HIMMEL_VERSION_WRITES', '');
  vi.stubEnv('HIMMEL_VERSION_WRITER', '');
  vi.stubEnv('HOME', join(root, 'home'));
  mkdirSync(join(root, 'home'), { recursive: true });
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  rmSync(root, { recursive: true, force: true });
});

describe('leave check (RED row)', () => {
  it('fix-version HIMMEL-1 --remove v1.1.3 on a ticket holding only v1.1.3 is refused before any PUT', async () => {
    declare(releaseCtx('v1.1.3'), { project: 'HIMMEL', versions: ['v1.1.3', 'v1.1.4'], decision: '1', verbatim: 'R = v1.1.3 + v1.1.4', mode: 'observe' });
    versionsTsv('HIMMEL', [['v1.1.2', true], ['v1.1.3', false], ['v1.1.4', false]]);
    const t = transport(['v1.1.3']);
    await expect(setFixVersion('HIMMEL-1', 'remove', 'v1.1.3')).rejects.toThrow(/v1\.1\.3/);
    expect(puts(t)).toHaveLength(0);
    expect(t.set).toEqual(['v1.1.3']);
  });
});
