import { describe, it, expect, beforeEach } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const CLI = resolve(__dirname, '../lib/repo-context-cli.mjs');

let workDir;
let cacheRoot;
let stub;

// FORGE=bitbucket + BITBUCKET_CLI=<node stub> routes the CLI at a node script
// that echoes fixture JSON — the analogue of the fake-gh PATH shim.
function envBb(extras = {}) {
  const env = {
    ...process.env,
    FORGE: 'bitbucket',
    // JSON-array form: exact argv, no space-split — safe when
    // process.execPath contains a space.
    BITBUCKET_CLI: JSON.stringify([process.execPath, stub]),
    ...extras,
  };
  env.XDG_CACHE_HOME = cacheRoot;
  delete env.HOME;
  return env;
}

function writeStub(body) {
  stub = join(workDir, 'bb-stub.mjs');
  writeFileSync(stub, body);
}

beforeEach(() => {
  workDir = mkdtempSync(join(tmpdir(), 'himmel-gh-bb-cli-'));
  cacheRoot = join(workDir, 'cache');
});

// BITBUCKET_CLI takes a JSON-array form parsed as exact argv, so a space in
// process.execPath never reaches the (space-splitting) legacy path — same
// seam the thread CLIs use.
describe('repo-context-cli — bitbucket forge', () => {
  it('repo view JSON {workspace, repo_slug} → owner=workspace name=repo_slug', () => {
    writeStub(
      `process.stdout.write(JSON.stringify({ workspace: 'example-ws', repo_slug: 'demo', full_name: 'example-ws/demo', default_branch: 'main' })); process.exit(0);`, // leak-allow: hostname test fixture stubbed bitbucket repo-view JSON response
    );
    const r = spawnSync(process.execPath, [CLI], { env: envBb(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(0);
    expect(r.stdout).toMatch(/owner=example-ws name=demo/); // leak-allow: hostname asserts the fixture workspace parsed as owner
  });

  it('missing repo_slug → exit 1', () => {
    writeStub(`process.stdout.write(JSON.stringify({ workspace: 'ws' })); process.exit(0);`);
    const r = spawnSync(process.execPath, [CLI], { env: envBb(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/missing workspace\/repo_slug/);
  });

  it('invalid JSON → exit 1', () => {
    writeStub(`process.stdout.write('nope'); process.exit(0);`);
    const r = spawnSync(process.execPath, [CLI], { env: envBb(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/invalid JSON/);
  });

  it('CLI non-zero exit → propagates exit code', () => {
    writeStub(`process.stderr.write('bb auth 401\\n'); process.exit(3);`);
    const r = spawnSync(process.execPath, [CLI], { env: envBb(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(3);
  });
});
