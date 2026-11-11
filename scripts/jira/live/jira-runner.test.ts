import { describe, it, expect } from 'vitest';
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runJira } from './jira-runner.js';
import { LIVE_BODY } from './project-guard.js';

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

describe('runJira', () => {
  it('drives the shipped CLI with the given project and config dir: one create POST reaches the loopback stub', async () => {
    const stub = spawn('node', ['--input-type=module', '-e', STUB], { stdio: ['ignore', 'pipe', 'inherit'] });
    const lines: string[] = [];
    let buffered = '';
    const ready = new Promise<number>((ok) => {
      stub.stdout.setEncoding('utf8');
      stub.stdout.on('data', (chunk: string) => {
        buffered += chunk;
        const parts = buffered.split('\n');
        buffered = parts.pop() ?? '';
        for (const line of parts) {
          if (line.startsWith('PORT ')) ok(Number(line.slice(5)));
          else lines.push(line);
        }
      });
    });
    const port = await ready;
    const conf = mkdtempSync(join(tmpdir(), 'live-runner-conf-'));
    writeFileSync(join(conf, 'himmel.conf'), 'JIRA_TEST_PROJECT=HTEST\n');
    const keep = { ...process.env };
    process.env.JIRA_BASE_URL = `http://127.0.0.1:${port}`;
    process.env.JIRA_EMAIL = 'live@example.invalid';
    process.env.JIRA_API_TOKEN = 'token';
    let out: string;
    try {
      out = runJira(CLI, conf, 'HTEST', 'create', '--type', 'Task', '--title', 'runner probe', '--desc', LIVE_BODY);
    } finally {
      for (const k of ['JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN']) {
        if (keep[k] === undefined) delete process.env[k];
        else process.env[k] = keep[k];
      }
      await new Promise((ok) => setTimeout(ok, 100));
      stub.kill();
    }
    expect(out).toContain('Created HTEST-1');
    expect(lines.filter((l) => l.startsWith('POST '))).toEqual(['POST /rest/api/3/issue']);
    expect(lines.filter((l) => l.startsWith('GET '))).toEqual([]);
  });
});
