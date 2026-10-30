/**
 * pull-cadence.sh behavioral tests — no network, no real connector.
 *
 * Uses the PULL_CMD test seam: the wrapper passes PULL_CMD to `bash -c` so
 * a shell snippet like 'exit 75' substitutes the real pull invocation.
 */
import { test, expect } from 'bun:test';
import { mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

// ── helpers ───────────────────────────────────────────────────────────────────

const SCRIPT = join(import.meta.dir, 'pull-cadence.sh');

const BASH = Bun.which('bash') ?? 'bash';

interface RunResult {
  rc: number;
  stdout: string;
  stderr: string;
}

/**
 * Invoke pull-cadence.sh with a PULL_CMD snippet and pinned date window.
 * LUNA_VITALS_ARTIFACT_DIR is a fresh tmpdir to avoid cross-test pollution.
 */
async function runWrapper(pullCmdSnippet: string): Promise<RunResult> {
  // Forward-slash path for Git Bash compatibility on Windows.
  const dir = mkdtempSync(join(tmpdir(), 'pull-cadence-test-')).replace(/\\/g, '/');
  const proc = Bun.spawn([BASH, SCRIPT], {
    env: {
      ...process.env,
      PULL_CMD: pullCmdSnippet,
      LUNA_VITALS_ARTIFACT_DIR: dir,
      HIMMEL_FLOW_RUNS_LEDGER: join(dir, 'flow-runs.jsonl'),
      FROM: '2026-06-28',
      TO: '2026-06-29',
    },
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const [rc, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  return { rc, stdout: stdout.trim(), stderr: stderr.trim() };
}

// ── tests ─────────────────────────────────────────────────────────────────────

// 60 s per test. Each run spawns bash plus three nested
// `bash flow-run-ledger.sh` subprocesses; on Windows that costs ~2.5 s idle
// but >15 s when the rest of the suite is spawning subprocesses in parallel,
// which timed the old 15 s budget out. The budget is a harness allowance, not
// a performance assertion — the wrapper's real work is a minutes-long network
// pull.
const TIMEOUT = 60_000;

test('PULL_CMD exit 75 -> wrapper exits 75 and prints re-consent reminder', async () => {
  const { rc, stderr } = await runWrapper('exit 75');
  expect(rc).toBe(75);
  const msg = stderr.toLowerCase();
  // Must mention re-consent and auth steps.
  expect(msg).toContain('re-consent');
  expect(msg).toContain('auth');
}, TIMEOUT);

test('PULL_CMD exit 0 -> wrapper exits 0, artifact path on stdout, no re-consent', async () => {
  const { rc, stdout, stderr } = await runWrapper('exit 0');
  expect(rc).toBe(0);
  // Artifact file name must appear on stdout (operator needs to review it).
  expect(stdout).toContain('gh-2026-06-29.json');
  // No re-consent reminder on success.
  expect(stderr.toLowerCase()).not.toContain('re-consent');
}, TIMEOUT);

test('PULL_CMD exit 1 -> wrapper exits 1, no re-consent reminder', async () => {
  const { rc, stderr } = await runWrapper('exit 1');
  expect(rc).toBe(1);
  expect(stderr.toLowerCase()).not.toContain('re-consent');
}, TIMEOUT);
