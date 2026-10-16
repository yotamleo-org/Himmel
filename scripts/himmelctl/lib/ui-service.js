'use strict';
// scripts/himmelctl/lib/ui-service.js — `himmelctl ui --service install|uninstall|status|url`: the AG-UI fleet page
// as a systemd USER unit (himmel-ui.service), modelled on telegram-bridge.service (bridge-persistence.js).
// The unit runs scripts/config-ui/server.ts --service on a fixed 127.0.0.1 port: no idle exit, a stable token in
// ~/.himmel/state/ui-token (mode 600, created once), HANDOVER_DIR set so the console board works, Restart=on-failure.
// Every verb returns { ok, lines } instead of throwing on an expected failure; zero npm deps, systemctl via spawnSync.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { which } = require('./helpers.js');

const UNIT_NAME = 'himmel-ui.service';
const DEFAULT_PORT = 47391;
const UNIT_DIR = process.env.HIMMELCTL_SYSTEMD_USER_UNIT_DIR || path.join(os.homedir(), '.config', 'systemd', 'user');
const unitPath = () => path.join(UNIT_DIR, UNIT_NAME);
const tokenPath = () => path.join(process.env.HOME || os.homedir(), '.himmel', 'state', 'ui-token');

// A unit value: `%` is a specifier prefix, and a quoted value needs `\` and `"` escaped; CR/LF cannot be rendered at all.
const q = (s) => {
  if (/[\r\n]/.test(s)) throw new Error(`refusing a value with a newline in the unit: ${JSON.stringify(s)}`);
  return `"${s.replace(/%/g, '%%').replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
};

function renderUnit({ repoRoot, bun, handoverDir, envPath, port }) {
  return [
    '# himmel-ui.service — written by `himmelctl ui --service install`; re-run it rather than editing this copy.',
    '[Unit]',
    'Description=Himmel AG-UI fleet page (config-ui server, loopback only)',
    'After=network-online.target',
    'StartLimitIntervalSec=600',
    'StartLimitBurst=5',
    '',
    '[Service]',
    'Type=simple',
    `WorkingDirectory=${repoRoot.replace(/%/g, '%%')}`,
    `Environment=${q(`HANDOVER_DIR=${handoverDir}`)}`,
    `Environment=${q(`PATH=${envPath}`)}`,
    `ExecStart=${q(bun)} ${q(path.join(repoRoot, 'scripts', 'config-ui', 'server.ts'))} --service --port ${port}`,
    'Restart=on-failure',
    'RestartSec=5',
    '',
    '[Install]',
    'WantedBy=default.target',
    '',
  ].join('\n');
}

const sctl = (...a) => spawnSync('systemctl', ['--user', ...a], { encoding: 'utf8' });
const noSystemctl = { ok: false, lines: [`'systemctl' not found on PATH — not a systemd/Linux host; ${UNIT_NAME} was not touched`] };

function installedPort() {
  try {
    const m = /--service --port (\d+)/.exec(fs.readFileSync(unitPath(), 'utf8'));
    return m ? Number(m[1]) : null;
  } catch (_e) { return null; }
}

// The token is minted by the installer so `url` works before the first start; the server reads the same file.
function ensureToken() {
  const p = tokenPath();
  if (fs.existsSync(p)) return p;
  fs.mkdirSync(path.dirname(p), { recursive: true, mode: 0o700 });
  fs.writeFileSync(p, `${require('crypto').randomBytes(32).toString('hex')}\n`, { mode: 0o600, flag: 'wx' });
  return p;
}

function url() {
  const port = installedPort();
  if (port === null) return { ok: false, lines: [`${UNIT_NAME} is not installed (run: himmelctl ui --service install)`] };
  let t;
  try { t = fs.readFileSync(tokenPath(), 'utf8').trim(); } catch (_e) { return { ok: false, lines: [`no token file at ${tokenPath()}`] }; }
  return { ok: true, lines: [`http://127.0.0.1:${port}/agui/#t=${t}`] };
}

function install({ repoRoot, port, dryRun }) {
  const bun = which('bun');
  if (!bun) return { ok: false, lines: ['bun is required (https://bun.sh)'] };
  const handoverDir = process.env.HANDOVER_DIR;
  if (!handoverDir) return { ok: false, lines: ['HANDOVER_DIR is not set; the console board needs it (see docs/handover/running-a-console.md)'] };
  if (!which('systemctl')) return noSystemctl;
  const unit = renderUnit({ repoRoot, bun, handoverDir, envPath: process.env.PATH || '/usr/bin:/bin', port: port === null ? DEFAULT_PORT : port });
  if (dryRun) return { ok: true, lines: [`dry-run: would write ${unitPath()}`, `dry-run: would write ${tokenPath()} (mode 600) if absent`, 'dry-run: would run systemctl --user daemon-reload, enable --now ' + UNIT_NAME] };
  ensureToken();
  fs.mkdirSync(UNIT_DIR, { recursive: true });
  const tmp = `${unitPath()}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, unit, 'utf8');
  fs.renameSync(tmp, unitPath());
  for (const a of [['daemon-reload'], ['enable', '--now', UNIT_NAME]]) {
    const r = sctl(...a);
    if (r.status !== 0) return { ok: false, lines: [`unit file written at ${unitPath()}, but systemctl --user ${a.join(' ')} failed (rc=${r.status}): ${(r.stderr || '').trim()}`] };
  }
  // restart so an already-running older copy of the unit picks up the rewritten file
  const re = sctl('restart', UNIT_NAME);
  if (re.status !== 0) return { ok: false, lines: [`systemctl --user restart ${UNIT_NAME} failed (rc=${re.status}): ${(re.stderr || '').trim()}`] };
  return { ok: true, lines: [`${UNIT_NAME} installed and started`, url().lines[0]] };
}

function uninstall({ dryRun }) {
  if (!which('systemctl')) return noSystemctl;
  if (dryRun) return { ok: true, lines: [`dry-run: would disable --now ${UNIT_NAME}, remove ${unitPath()} and ${tokenPath()}, daemon-reload`] };
  sctl('disable', '--now', UNIT_NAME); // absent unit: nothing to disable, still remove the files
  for (const p of [unitPath(), tokenPath()]) fs.rmSync(p, { force: true });
  sctl('daemon-reload');
  return { ok: true, lines: [`${UNIT_NAME} removed (unit file and token file)`] };
}

function status() {
  if (!which('systemctl')) return noSystemctl;
  const active = sctl('is-active', UNIT_NAME);
  const state = (active.stdout || '').trim() || 'unknown';
  const enabled = (sctl('is-enabled', UNIT_NAME).stdout || '').trim() || 'unknown';
  return { ok: state === 'active', lines: [`${UNIT_NAME}: ${state} (${enabled})`, installedPort() === null ? 'not installed' : `port ${installedPort()}`] };
}

module.exports = { UNIT_NAME, DEFAULT_PORT, renderUnit, install, uninstall, status, url };
