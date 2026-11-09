import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Command } from 'commander';
import { baseUrl } from '../client.js';
import { envFilePath, readEnvFile, stationJiraBaseUrl } from '../env-file.js';
import { sectorField } from './sector.js';

export interface ConfigReport {
  out: string;
  err: string;
  code: number;
}

const LAYER_KIND: Record<string, string> = {
  credentials: 'credentials dir',
  keyring: 'keyring',
  'keyring-project': 'keyring',
  dotenv: 'env-file',
};

const RESOLVER = fileURLToPath(new URL('../../../lib/himmel-secrets', import.meta.url));

function fileHolding(key: string, files: string[]): { file: string; value: string } | undefined {
  for (const file of files) {
    const seen: NodeJS.ProcessEnv = {};
    readEnvFile(file, new Set([key]), seen);
    if (seen[key]) return { file, value: seen[key] };
  }
  return undefined;
}

function setting(key: string, files: string[], fallbackSource: string): { value: string; source: string } | undefined {
  const hit = fileHolding(key, files);
  const value = process.env[key] || hit?.value;
  if (!value) return undefined;
  return { value, source: hit && hit.value === value ? hit.file : fallbackSource };
}

// Which layer serves a credential, by name only. The resolver runs with the name taken out of its
// environment so the client's own load of it into process.env cannot answer for it; its `status` verb
// prints the layer and never a value.
function resolverKind(root: string, name: string): string | undefined {
  const env = { ...process.env };
  delete env[name];
  try {
    const out = execFileSync('bash', [RESOLVER, 'status', '--root', root, name], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 10000, env,
    });
    const line = out.split('\n').find((l) => l.startsWith(`${name}: `));
    return line ? LAYER_KIND[line.slice(name.length + 2).trim()] : undefined;
  } catch {
    return undefined;
  }
}

function credential(name: string, confFiles: string[], envPath: string): string[] {
  const conf = confFiles.length > 0 ? fileHolding(name, confFiles)?.file : undefined;
  const kind = conf ?? resolverKind(dirname(envPath), name) ??
    (fileHolding(name, [envPath]) ? 'env-file' : undefined) ?? (process.env[name] ? 'env' : undefined);
  return kind ? [`${name}: set`, `  source: ${kind}`] : [`${name}: not set`];
}

/**
 * Every Jira setting, each with the file or layer it came from. The site URL, project key, severity
 * field, board id and sector field print their value; the email and API token print only set or not
 * set and the source kind, so no secret can be printed.
 */
export function configReport(confDir: string, envPath: string): ConfigReport {
  const conf = [join(confDir, 'himmel.conf.local'), join(confDir, 'himmel.conf')];
  const url = process.env.JIRA_BASE_URL || stationJiraBaseUrl(confDir, { profileFromEnv: true, envPath });
  if (!url) {
    try {
      baseUrl();
    } catch (err) {
      return { out: '', err: `${err instanceof Error ? err.message : String(err)}\n`, code: 2 };
    }
    return { out: '', err: 'JIRA_BASE_URL is not set.\n', code: 2 };
  }
  const urlHit = fileHolding('JIRA_BASE_URL', [...conf, envPath]);
  const lines = [
    `site URL: ${url}`,
    `  source: ${urlHit && urlHit.value === url ? urlHit.file : 'environment or station profile'}`,
  ];
  const plain: Array<[string, string, string[], string]> = [
    ['project key', 'JIRA_PROJECT_KEY', [...conf, envPath], 'environment or project .env'],
    ['severity field', 'JIRA_SEVERITY_FIELD', [envPath], 'environment'],
    ['board id', 'JIRA_BOARD_ID', [envPath], 'environment'],
  ];
  for (const [label, key, files, fallback] of plain) {
    const s = setting(key, files, fallback);
    lines.push(s ? `${label}: ${s.value}` : `${label}: (not set)`);
    if (s) lines.push(`  source: ${s.source}`);
  }
  try {
    const sector = sectorField();
    lines.push(sector ? `sector field: ${sector}` : 'sector field: (not set)');
    if (sector) lines.push(`  source: ${process.env.JIRA_SECTOR_FIELD ? 'environment' : join(homedir(), '.himmel', 'config.json')}`);
  } catch (err) {
    lines.push(`sector field: (unreadable: ${err instanceof Error ? err.message : String(err)})`);
  }
  lines.push(...credential('JIRA_EMAIL', conf, envPath), ...credential('JIRA_API_TOKEN', [], envPath));
  lines.push('Jira settings live in ~/.himmel/himmel.conf (or himmel.conf.local) and are read through this verb (jira config); do not read .env or a secrets file for them.');
  return { out: `${lines.join('\n')}\n`, err: '', code: 0 };
}

export function registerConfig(program: Command): void {
  program
    .command('config')
    .description('Print every Jira setting and the file or layer it came from (read only; the email and token only as set or not set)')
    .action(() => {
      const confDir = process.env.HIMMEL_CONFIG_DIR || join(process.env.HOME || homedir(), '.himmel');
      const report = configReport(confDir, envFilePath());
      if (report.out) process.stdout.write(report.out);
      if (report.err) process.stderr.write(report.err);
      if (report.code !== 0) process.exit(report.code);
    });
}
