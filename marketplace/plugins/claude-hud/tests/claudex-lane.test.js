// himmel delta rows on the v0.10.0 layout: the claudex lane (HIMMEL-2900) and the
// session-token cache write/read split (HIMMEL-2161). Each row drives dist/index.js
// the way Claude Code does, in a throwaway HOME with a clean environment.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, copyFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const entry = fileURLToPath(new URL('../dist/index.js', import.meta.url));
const transcriptFixture = fileURLToPath(new URL('./golden/transcript.jsonl', import.meta.url));

function stripAnsi(text) {
  return text
    .replace(/\x1b\[[0-9;]*m/g, '')
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '');
}

async function run({ env = {}, display = {}, stdin = {} } = {}) {
  const home = await mkdtemp(path.join(tmpdir(), 'hud-claudex-'));
  try {
    const configDir = path.join(home, '.claude');
    const project = path.join(home, 'dev', 'my-project');
    const transcript = path.join(configDir, 'projects', 'lane', 'transcript.jsonl');
    const pluginDir = path.join(configDir, 'plugins', 'claude-hud');
    await mkdir(project, { recursive: true });
    await mkdir(path.dirname(transcript), { recursive: true });
    await mkdir(pluginDir, { recursive: true });
    await copyFile(transcriptFixture, transcript);
    await writeFile(path.join(pluginDir, 'config.json'), JSON.stringify({ display }));
    const result = spawnSync(process.execPath, [entry], {
      input: JSON.stringify({
        model: { display_name: 'Opus' },
        cwd: project,
        transcript_path: transcript,
        cost: { total_cost_usd: 1.23 },
        context_window: {
          context_window_size: 200000,
          used_percentage: 5,
          current_usage: { input_tokens: 10000 },
        },
        ...stdin,
      }),
      encoding: 'utf8',
      env: { PATH: process.env.PATH, HOME: home, CLAUDE_CONFIG_DIR: configDir, LANG: 'C', ...env },
    });
    assert.equal(result.error, undefined, result.error?.message);
    assert.equal(result.status, 0, result.stderr);
    return stripAnsi(result.stdout);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

const LANE = { CLAUDEX_LANE_OK: '1', CODEX_MODEL: 'gpt-6-astra' };

test('claudex lane: the model badge reads CODEX_MODEL, not the stdin display_name', async () => {
  const out = await run({ env: LANE });
  const first = out.split('\n')[0];
  assert.match(first, /\[gpt-6-astra\]/);
  assert.ok(!first.includes('Opus'), first);
});

test('claudex lane control: without the lane the badge is the stdin model', async () => {
  const out = await run({ env: { CODEX_MODEL: 'gpt-6-astra' } });
  const first = out.split('\n')[0];
  assert.match(first, /\[Opus\]/);
  assert.ok(!first.includes('gpt-6-astra'), first);
});

test('claudex lane: the cost slot reads unmeasured, never a dollar figure', async () => {
  const out = await run({ env: LANE, display: { showCost: true } });
  assert.match(out, /Cost unmeasured/);
  assert.ok(!out.includes('$'), out);
});

test('claudex lane control: without the lane the native cost renders', async () => {
  const out = await run({ display: { showCost: true } });
  assert.match(out, /Cost \$1\.23/);
  assert.ok(!out.includes('unmeasured'), out);
});

test('claudex lane: the context value carries the configured label', async () => {
  const out = await run({ env: LANE });
  assert.match(out, /\(configured\)/);
});

test('claudex lane control: without the lane the context value has no configured label', async () => {
  const out = await run();
  assert.ok(!out.includes('(configured)'), out);
});

test('session tokens: cache write and read are separate figures', async () => {
  const out = await run({ display: { showSessionTokens: true } });
  assert.match(out, /Tokens [\d.]+k? \(in: [^,]+, out: [^,]+, cache-w: [^,]+, cache-r: [^)]+\)/);
  assert.ok(!/cache: /.test(out), out);
});
