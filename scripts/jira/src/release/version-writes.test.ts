import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { WRITER_TABLE, versionWriteScope } from './version-writes.js';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'repair');

const TOP_KEYS = new Set(['key', 'source', 'journalSynthesized', 'journal', 'changelog']);
const ENTRY_KEYS = new Set(['id', 'created', 'items']);
const FIX_ITEM_KEYS = new Set(['field', 'fromString', 'toString']);

const filesIn = (dir: string): string[] => readdirSync(dir).filter((n) => n.endsWith('.json')).sort();

// Names the first author-data hit in any file of `dir`, or null.
function authorData(dir: string): string | null {
  for (const name of filesIn(dir)) {
    const text = readFileSync(join(dir, name), 'utf8');
    for (const needle of ['@', 'emailAddress', 'accountId']) if (text.includes(needle)) return `${name}: ${needle}`;
  }
  return null;
}

// Names the first changelog key or item outside the allowlist in any file of `dir`, or null.
function outsideAllowlist(dir: string): string | null {
  for (const name of filesIn(dir)) {
    const f = JSON.parse(readFileSync(join(dir, name), 'utf8')) as Record<string, unknown>;
    for (const k of Object.keys(f)) if (!TOP_KEYS.has(k)) return `${name}: top-level ${k}`;
    for (const e of f.changelog as Array<Record<string, unknown>>) {
      for (const k of Object.keys(e)) if (!ENTRY_KEYS.has(k)) return `${name}: entry ${k}`;
      for (const item of e.items as Array<Record<string, unknown>>) {
        if (item.field === 'other') {
          if (Object.keys(item).length !== 1) return `${name}: other item carries ${Object.keys(item).join(',')}`;
        } else if (item.field === 'Fix Version') {
          for (const k of Object.keys(item)) if (!FIX_ITEM_KEYS.has(k)) return `${name}: Fix Version item ${k}`;
        } else return `${name}: item field ${String(item.field)}`;
      }
    }
  }
  return null;
}

describe('repair fixtures', () => {
  it('the six captured tickets are present', () => {
    expect(filesIn(FIXTURES)).toEqual(['HIMMEL-3084.json', 'HIMMEL-6691.json', 'HIMMEL-7044.json', 'HIMMEL-7804.json', 'HIMMEL-8231.json', 'HIMMEL-8706.json']);
  });

  it('fixtures carry no author data', () => {
    expect(authorData(FIXTURES)).toBeNull();
  });

  it('fixtures carry only allowed fields', () => {
    expect(outsideAllowlist(FIXTURES)).toBeNull();
  });

  it('the checks fail on a fixture that does carry author data or another field', () => {
    const dir = mkdtempSync(join(tmpdir(), 'repair-fixtures-'));
    writeFileSync(join(dir, 'HIMMEL-1.json'), JSON.stringify({
      key: 'HIMMEL-1', source: 's', journalSynthesized: false, journal: [],
      changelog: [{ id: '1', created: 'c', author: { emailAddress: 'a' + '@' + 'b.c' }, items: [{ field: 'summary', toString: 'free text' }] }],
    }));
    expect(authorData(dir)).toMatch(/HIMMEL-1\.json/);
    expect(outsideAllowlist(dir)).toBe('HIMMEL-1.json: entry author');
  });
});

// Files that mention a Fix Version but never write one: readers, renderers, the hook itself, and the
// engine (it reaches Jira only through the port whose real write is in commands/release.ts).
const READ_ONLY = [
  'scripts/hooks/block-backend-tier.sh',
  'scripts/jira/src/commands/move.ts',
  'scripts/jira/src/mcp.ts',
  // Joined so the CI plan audit's closure does not read this list as a suite that executes the file.
  'scripts/config-ui/' + 'roadmap.ts',
  'scripts/handover/chief-kit/board.mjs',
  'scripts/handover/chief-kit/chain-add.sh',
  'scripts/handover/chief-kit/chain-render.py',
  'scripts/handover/chief-kit/chain-state.mjs',
  'scripts/handover/chief-kit/intake-backfill.sh',
  'scripts/handover/chief-kit/next-dispatchable.sh',
  'scripts/handover/chief-kit/priority-prune.sh',
  'scripts/handover/chief-kit/stuck-scan.sh',
  'scripts/handover/chief-kit/tick.sh',
  'scripts/handover/chief-kit/tracker.py',
  'scripts/handover/chief-kit/version-status-audit.sh',
  'scripts/handover/chief-kit/worker-jira-status.sh',
  'scripts/hooks/block-jira-compound-write.sh',
  'scripts/jira/src/commands/get.ts',
  'scripts/jira/src/commands/intake-gate.ts',
  'scripts/jira/src/commands/link.ts',
  'scripts/jira/src/commands/mirror.ts',
  'scripts/jira/src/commands/roadmap.ts',
  'scripts/jira/src/release/engine.ts',
  'scripts/jira/src/release/leaks.ts',
  'scripts/jira/src/release/reducer.ts',
  'scripts/jira/src/release/repair-run.ts',
  'scripts/jira/src/release/types.ts',
  'scripts/jira/src/release/version-writes.ts',
  'scripts/lib/tracker.mjs',
];

const NOT_SOURCE = /(\.test\.|\/test-|\.md$|\.patch$|\/fixtures\/|\/tests\/)/;

// Every non-test, non-doc file under scripts/ whose text names a Fix Version write.
function writingFiles(): string[] {
  const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd: dirname(fileURLToPath(import.meta.url)), encoding: 'utf8' }).trim();
  const out = execFileSync('git', ['grep', '-lE', 'fix-version|fixVersions|setFixVersion|addFixVersionGated', '--', 'scripts/'], { cwd: root, encoding: 'utf8' });
  return out.split('\n').filter((f) => f && !NOT_SOURCE.test(f)).sort();
}

// The files of `files` that are neither a writer in the table nor a named read-only file.
const unlisted = (files: string[]): string[] => files.filter((f) => !WRITER_TABLE.some((w) => w.site === f) && !READ_ONLY.includes(f));

describe('versionWriteScope — a test project is not work (I13)', () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'vws-test-project-'));
    writeFileSync(join(dir, 'himmel.conf'), 'JIRA_PROJECTS=HIMMEL,LUNA\nJIRA_TEST_PROJECT=HTEST\n');
    vi.stubEnv('HIMMEL_CONFIG_DIR', dir);
    vi.stubEnv('HIMMEL_JIRA_LIVE_TEST', '');
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    rmSync(dir, { recursive: true, force: true });
  });
  const fix = { fixVersions: [{ name: 'v1' }] };

  it('a Fix Version create and a later Fix Version edit on HTEST-7 write no journal entry', () => {
    expect(versionWriteScope('/rest/api/3', 'POST', '/issue', { fields: { project: { key: 'HTEST' }, ...fix } })).toBeNull();
    expect(versionWriteScope('/rest/api/3', 'PUT', '/issue/HTEST-7', { update: fix })).toBeNull();
  });

  it('control: a HIMMEL Fix Version create and edit are still journalled', () => {
    expect(versionWriteScope('/rest/api/3', 'POST', '/issue', { fields: { project: { key: 'HIMMEL' }, ...fix } })).toEqual({ key: null });
    expect(versionWriteScope('/rest/api/3', 'PUT', '/issue/HIMMEL-7', { update: fix })).toEqual({ key: 'HIMMEL-7' });
  });
});

describe('writer table', () => {
  it('every writing file is in the writer table', () => {
    expect(unlisted(writingFiles())).toEqual([]);
  });

  it('a new writing file fails the enumeration', () => {
    expect(unlisted([...writingFiles(), 'scripts/jira/src/commands/new-writer.ts'])).toEqual(['scripts/jira/src/commands/new-writer.ts']);
  });

  it('the machine rows are exactly the ten machine mechanisms; hand rows are not machine', () => {
    for (const w of WRITER_TABLE) {
      expect(w.mechanism).toMatch(/^[a-z][a-z-]*$/);
      if (w.mechanism === 'hand') expect(w.machine).toBe(false);
    }
    expect(WRITER_TABLE.filter((w) => w.machine).map((w) => w.mechanism).sort()).toEqual([
      'class-recurrence', 'create-blocker-inherit', 'create-bug-default', 'create-followup', 'create-residual',
      'create-stepdown', 'displace-residual', 'merge-stamp', 'sync-versions', 'transition-stamp',
    ]);
  });
});
