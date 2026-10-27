import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Match the Jira CLI: own install, primary checkout, then HIMMEL_REPO.
export function envFilePath(override) {
  if (override) return override;
  const here = dirname(fileURLToPath(import.meta.url));
  const own = join(here, '..', '..', '..', '.env');
  if (existsSync(own)) return own;
  const candidates = [];
  try {
    const common = execFileSync(
      'git',
      ['rev-parse', '--path-format=absolute', '--git-common-dir'],
      { encoding: 'utf8', cwd: here, stdio: ['ignore', 'pipe', 'ignore'] },
    ).trim();
    candidates.push(join(dirname(common), '.env'));
  } catch {
    // An install outside git can still use HIMMEL_REPO or the home fallback.
  }
  if (process.env.HIMMEL_REPO) candidates.push(join(process.env.HIMMEL_REPO, '.env'));
  return candidates.find((c) => existsSync(c)) ??
    join(process.env.HOME || process.env.USERPROFILE || '.', '.config', 'himmel-cli', 'jira.env');
}

export async function jiraFetch(method, path, body) {
  const base = process.env.JIRA_BASE_URL;
  if (!base) throw new Error('JIRA_BASE_URL not set — run /jira-init');
  const email = process.env.JIRA_EMAIL || '';
  const token = process.env.JIRA_API_TOKEN || '';
  const auth = `Basic ${Buffer.from(`${email}:${token}`).toString('base64')}`;
  const res = await fetch(`${base}/rest/api/3${path}`, {
    method,
    headers: { Authorization: auth, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const body = await res.text();
    const snippet = body.length > 300 ? body.slice(0, 300) + '…' : body;
    throw new Error(`HTTP ${res.status}: ${snippet}`);
  }
  const t = await res.text();
  return t.trim() ? JSON.parse(t) : {};
}
