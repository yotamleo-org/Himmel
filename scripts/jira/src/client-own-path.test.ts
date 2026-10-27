import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, rmSync, symlinkSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const jiraDir = join(dirname(fileURLToPath(import.meta.url)), '..');

// The CLI reads credentials from its own install path, never the cwd.
// A fixture install (<root>/scripts/jira/dist + a <root>/.env) is run from an
// unrelated cwd with no JIRA_* in the environment.
describe('CLI .env resolution from an unrelated cwd', () => {
  let root: string;
  let cwd: string;
  let home: string;

  beforeAll(() => {
    root = mkdtempSync(join(tmpdir(), 'jira-own-path-root-'));
    cwd = mkdtempSync(join(tmpdir(), 'jira-own-path-cwd-'));
    home = mkdtempSync(join(tmpdir(), 'jira-own-path-home-'));
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
    rmSync(home, { recursive: true, force: true });
  });

  it('finds the install .env when the cwd is not the repo and no JIRA_* is exported', () => {
    expect(existsSync(join(jiraDir, 'dist', 'index.js'))).toBe(true);
    const run = spawnSync(process.execPath, [join(root, 'scripts', 'jira', 'dist', 'index.js'), 'get', 'DUMMY-1'], {
      cwd,
      env: { PATH: process.env.PATH, HOME: home },
      encoding: 'utf8',
      timeout: 30000,
    });
    expect(run.error).toBeUndefined();
    const output = `${run.stdout}${run.stderr}`;
    // The op reached the request (the fixture host does not resolve): the CLI
    // started and loaded the .env, rather than crashing before it read it.
    expect(output).toMatch(/jira: get DUMMY-1 failed: .*(fetch failed|ENOTFOUND|fixture\.invalid)/);
    expect(output).not.toContain('JIRA_BASE_URL is not set');
    expect(output).not.toContain('falling back ' + 'to cwd');
  });

  it.each([
    { name: 'repo-root project key', nested: false, planted: false, exported: undefined, config: undefined, local: undefined, install: undefined, want: 'PROJECT', token: 'dummy' },
    { name: 'repo-root key from a nested cwd, ignoring cwd credentials', nested: true, planted: true, exported: undefined, config: undefined, local: undefined, install: undefined, want: 'PROJECT', token: '' },
    { name: 'exported key before project and user config', nested: false, planted: false, exported: 'EXPORTED', config: 'CONFIG', local: 'LOCAL', install: 'INSTALL', want: 'EXPORTED', token: 'dummy' },
    { name: 'local user config before project key', nested: false, planted: false, exported: undefined, config: 'CONFIG', local: 'LOCAL', install: 'INSTALL', want: 'LOCAL', token: 'dummy' },
    { name: 'user config before project key', nested: false, planted: false, exported: undefined, config: 'CONFIG', local: undefined, install: 'INSTALL', want: 'CONFIG', token: 'dummy' },
    { name: 'project key before install fallback', nested: false, planted: false, exported: undefined, config: undefined, local: undefined, install: 'INSTALL', want: 'PROJECT', token: 'dummy' },
  ])('list uses $name', ({ nested, planted, exported, config, local, install, want, token }) => {
    const project = mkdtempSync(join(cwd, 'project-'));
    const projectHome = mkdtempSync(join(home, 'home-'));
    const init = spawnSync('git', ['init', '--quiet', project], { encoding: 'utf8' });
    expect(init.status).toBe(0);
    writeFileSync(join(project, '.env'), 'JIRA_PROJECT_KEY=PROJECT\n' +
      (planted ? 'JIRA_API_TOKEN=planted-token\nJIRA_EMAIL=planted@example.invalid\nJIRA_BASE_URL=https://planted.invalid\n' : ''));
    const runCwd = nested ? join(project, 'nested') : project;
    if (nested) {
      mkdirSync(runCwd);
      writeFileSync(join(runCwd, '.env'), 'JIRA_PROJECT_KEY=WRONG\nJIRA_API_TOKEN=nested-token\n');
    }
    mkdirSync(join(projectHome, '.himmel'));
    if (config) writeFileSync(join(projectHome, '.himmel', 'himmel.conf'), `JIRA_PROJECT_KEY=${config}\n`);
    if (local) writeFileSync(join(projectHome, '.himmel', 'himmel.conf.local'), `JIRA_PROJECT_KEY=${local}\n`);
    writeFileSync(join(root, '.env'),
      'JIRA_BASE_URL=https://fixture.invalid\nJIRA_EMAIL=dummy@example.invalid\n' +
      `JIRA_API_TOKEN=${token}\n` + (install ? `JIRA_PROJECT_KEY=${install}\n` : ''));
    const preload = join(projectHome, 'fetch.mjs');
    writeFileSync(preload,
      'globalThis.fetch = async (url, init) => {\n' +
      '  console.log(JSON.stringify({ url, auth: init.headers.Authorization }));\n' +
      '  return new Response(JSON.stringify({ issues: [] }));\n' +
      '};\n');
    const run = spawnSync(process.execPath, [
      '--import', pathToFileURL(preload).href,
      join(root, 'scripts', 'jira', 'dist', 'index.js'), 'list',
    ], {
      cwd: runCwd,
      env: { PATH: process.env.PATH, HOME: projectHome, ...(exported ? { JIRA_PROJECT_KEY: exported } : {}) },
      encoding: 'utf8',
      timeout: 30000,
    });
    expect(run.error).toBeUndefined();
    expect(run.stderr).toBe('');
    expect(run.status).toBe(0);
    const request = JSON.parse(run.stdout);
    const url = new URL(request.url);
    expect(url.origin).toBe('https://fixture.invalid');
    expect(url.searchParams.get('jql')).toBe(
      `project=${want} AND status in ("To Do","Planning","Ready","In Progress") ORDER BY created DESC`,
    );
    expect(request.auth).toBe(`Basic ${Buffer.from(`dummy@example.invalid:${token}`).toString('base64')}`);
  });
});
