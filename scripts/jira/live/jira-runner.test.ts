import { describe, it, expect } from 'vitest';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LIVE_BODY, runJira } from './project-guard.js';

const CLI = fileURLToPath(new URL('../dist/index.js', import.meta.url));

// runJira blocks (execFileSync), so the loopback stub must live in its own process: it prints its port,
// then one "METHOD url" line per request, and answers every POST with an issue and every GET with {}.
const STUB = `
import { createServer } from 'node:http';
const server = createServer((req, res) => {
  req.resume();
  req.on('end', () => {
    console.log(req.method + ' ' + req.url);
    res.setHeader('content-type', 'application/json');
    res.end(req.method === 'POST' ? JSON.stringify({ id: '10001', key: 'HTEST-1' }) : '{}');
  });
});
server.listen(0, '127.0.0.1', () => console.log('PORT ' + server.address().port));
`;

const until = async (done: () => boolean, ms: number): Promise<void> => {
  for (const deadline = Date.now() + ms; !done() && Date.now() < deadline; ) await new Promise((ok) => setTimeout(ok, 20));
};

describe('runJira', () => {
  it('drives the shipped CLI with the given project and config dir: one create POST reaches the loopback stub', async () => {
    const stub = spawn('node', ['--input-type=module', '-e', STUB], { stdio: ['ignore', 'pipe', 'inherit'] });
    const conf = mkdtempSync(join(tmpdir(), 'live-runner-conf-'));
    const keep = { ...process.env };
    const lines: string[] = [];
    let port = 0;
    let buffered = '';
    stub.stdout.setEncoding('utf8');
    stub.stdout.on('data', (chunk: string) => {
      buffered += chunk;
      const parts = buffered.split('\n');
      buffered = parts.pop() ?? '';
      for (const line of parts) {
        if (line.startsWith('PORT ')) port = Number(line.slice(5));
        else lines.push(line);
      }
    });
    let out = '';
    try {
      await until(() => port > 0 || stub.exitCode !== null, 5000);
      expect(port, 'the loopback stub did not start').toBeGreaterThan(0);
      writeFileSync(join(conf, 'himmel.conf'), 'JIRA_TEST_PROJECT=HTEST\n');
      process.env.JIRA_BASE_URL = `http://127.0.0.1:${port}`;
      process.env.JIRA_EMAIL = 'live@example.invalid';
      process.env.JIRA_API_TOKEN = 'token';
      out = runJira(CLI, conf, 'HTEST', 'create', '--type', 'Task', '--title', 'runner probe', '--desc', LIVE_BODY);
      await until(() => lines.some((l) => l.startsWith('POST ')), 5000);
    } finally {
      for (const k of ['JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN']) {
        if (keep[k] === undefined) delete process.env[k];
        else process.env[k] = keep[k];
      }
      stub.kill();
      rmSync(conf, { recursive: true, force: true });
    }
    expect(out).toContain('Created HTEST-1');
    expect(lines.filter((l) => l.startsWith('POST '))).toEqual(['POST /rest/api/3/issue']);
    expect(lines.filter((l) => l.startsWith('GET '))).toEqual([]);
  });
});
