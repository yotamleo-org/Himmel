import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, rmSync, symlinkSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const jiraDir = join(dirname(fileURLToPath(import.meta.url)), '..');

// The CLI reads its .env from its own install path, never the cwd.
// A fixture install (<root>/scripts/jira/dist + a <root>/.env) is run from an
// unrelated cwd with no JIRA_* in the environment.
describe('CLI .env resolution from an unrelated cwd', () => {
  let root: string;
  let cwd: string;

  beforeAll(() => {
    root = mkdtempSync(join(tmpdir(), 'jira-own-path-root-'));
    cwd = mkdtempSync(join(tmpdir(), 'jira-own-path-cwd-'));
    const installed = join(root, 'scripts', 'jira');
    mkdirSync(installed, { recursive: true });
    cpSync(join(jiraDir, 'dist'), join(installed, 'dist'), { recursive: true });
    cpSync(join(jiraDir, 'package.json'), join(installed, 'package.json'));
    symlinkSync(join(jiraDir, 'node_modules'), join(installed, 'node_modules'));
    writeFileSync(
      join(root, '.env'),
      'JIRA_BASE_URL=https://fixture.invalid\nJIRA_EMAIL=dummy@example.invalid\n' +
        'JIRA_API_TOKEN=dummy\nJIRA_PROJECT_KEY=DUMMY\n',
    );
  });

  afterAll(() => {
    rmSync(root, { recursive: true, force: true });
    rmSync(cwd, { recursive: true, force: true });
  });

  it('finds the install .env when the cwd is not the repo and no JIRA_* is exported', () => {
    expect(existsSync(join(jiraDir, 'dist', 'index.js'))).toBe(true);
    const run = spawnSync(process.execPath, [join(root, 'scripts', 'jira', 'dist', 'index.js'), 'get', 'DUMMY-1'], {
      cwd,
      env: { PATH: process.env.PATH, HOME: process.env.HOME },
      encoding: 'utf8',
      timeout: 30000,
    });
    const output = `${run.stdout}${run.stderr}`;
    expect(output).not.toContain('JIRA_BASE_URL is not set');
    expect(output).not.toContain('falling back to cwd');
  });
});
