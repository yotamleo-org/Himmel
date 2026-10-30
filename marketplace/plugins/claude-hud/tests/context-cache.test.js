// himmel delta (HIMMEL-4578): the HUD must keep writing the per-session context
// snapshot that scripts/context-fill.sh reads (upstream v0.10.0 dropped the writer).
// End to end: run the built HUD on a fixture session, then ask context-fill.sh.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const entry = fileURLToPath(new URL('../dist/index.js', import.meta.url));
const contextFill = fileURLToPath(new URL('../../../../scripts/context-fill.sh', import.meta.url));
const SID = 'cccccccc-1111-2222-3333-444444444444';
// himmel spawns the resolved bash, never a bare word (run-hook-with-bash.test.mjs lint).
const BASH_BIN = process.env.BASH_BIN || process.env.BASH || 'bash';

async function session(stdinOverrides) {
  const home = await mkdtemp(path.join(tmpdir(), 'hud-ctxcache-'));
  const configDir = path.join(home, '.claude');
  const transcript = path.join(configDir, 'projects', 'fixture', `${SID}.jsonl`);
  await mkdir(path.dirname(transcript), { recursive: true });
  await writeFile(transcript, '{"type":"assistant","message":{"usage":{"input_tokens":1}}}\n');
  const env = { PATH: process.env.PATH, HOME: home, CLAUDE_CONFIG_DIR: configDir, LANG: 'C', CLAUDE_CODE_SESSION_ID: SID };
  const hud = spawnSync(process.execPath, [entry], {
    input: JSON.stringify({
      model: { display_name: 'Opus' },
      cwd: home,
      transcript_path: transcript,
      session_name: 'worker-fixture',
      context_window: { context_window_size: 200000, used_percentage: 42, remaining_percentage: 58, ...stdinOverrides },
    }),
    encoding: 'utf8',
    env,
  });
  assert.equal(hud.status, 0, hud.stderr);
  return { home, configDir, env };
}

test('the HUD writes the snapshot context-fill.sh reads, and --percent returns it', { skip: !existsSync(contextFill) }, async () => {
  const { home, configDir, env } = await session();
  try {
    const dir = path.join(configDir, 'plugins', 'claude-hud', 'context-cache');
    const files = readdirSync(dir);
    assert.equal(files.length, 1);
    assert.match(files[0], /^[0-9a-f]{64}\.json$/);
    const snapshot = JSON.parse(readFileSync(path.join(dir, files[0]), 'utf8'));
    assert.equal(snapshot.used_percentage, 42);
    assert.equal(snapshot.remaining_percentage, 58);
    assert.equal(snapshot.context_window_size, 200000);
    assert.equal(typeof snapshot.saved_at, 'number');
    assert.equal(snapshot.session_name, 'worker-fixture');

    const fill = spawnSync(BASH_BIN, [contextFill, '--percent'], { encoding: 'utf8', env });
    assert.equal(fill.status, 0, fill.stderr);
    assert.match(fill.stdout.trim(), /^42\b/);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test('a 0% frame with live usage is cached as a derived percent, not dropped', async () => {
  const { home, configDir } = await session({
    used_percentage: 0,
    remaining_percentage: 100,
    current_usage: { input_tokens: 50000, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 50000 },
  });
  try {
    const dir = path.join(configDir, 'plugins', 'claude-hud', 'context-cache');
    const [file] = readdirSync(dir);
    const snapshot = JSON.parse(readFileSync(path.join(dir, file), 'utf8'));
    assert.equal(snapshot.used_percentage, 50);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
