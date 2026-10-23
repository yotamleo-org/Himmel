'use strict';
// scripts/himmelctl/lib/ui-service.js — `himmelctl ui --service install|uninstall|status|url`: the AG-UI fleet page
// as a systemd USER unit (himmel-ui.service), modelled on telegram-bridge.service (bridge-persistence.js).
// The unit runs scripts/config-ui/server.ts --service on a fixed 127.0.0.1 port: no idle exit, a stable token in
// ~/.himmel/state/ui-token (mode 600, created once), HANDOVER_DIR set so the console board works, Restart=on-failure.
// Every verb returns { ok, lines } instead of throwing on an expected failure; zero npm deps, systemctl via spawnSync.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
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
  let st = null;
  try { st = fs.lstatSync(p); } catch (_e) { /* absent: minted below */ }
  if (st) {
    if (!st.isFile() || (st.mode & 0o777) !== 0o600 || !/^[0-9a-f]{64}$/.test(fs.readFileSync(p, 'utf8').trim())) {
      throw new Error(`${p} must be a regular mode-600 file holding a 64-hex token (the server refuses anything else); fix or remove it`);
    }
    return p;
  }
  fs.mkdirSync(path.dirname(p), { recursive: true, mode: 0o700 });
  fs.writeFileSync(p, `${require('crypto').randomBytes(32).toString('hex')}\n`, { mode: 0o600, flag: 'wx' });
  return p;
}

// page: a console page id (config, setup, ...) to land on; omitted, the fleet page.
function url(page) {
  const port = installedPort();
  if (port === null) return { ok: false, lines: [`${UNIT_NAME} is not installed (run: himmelctl ui --service install)`] };
  let t;
  try { t = fs.readFileSync(tokenPath(), 'utf8').trim(); } catch (_e) { return { ok: false, lines: [`no token file at ${tokenPath()}`] }; }
  return { ok: true, lines: [page ? `http://127.0.0.1:${port}/#t=${t}&page=${page}` : `http://127.0.0.1:${port}/agui/#t=${t}`] };
}

// The ad-hoc UI that `himmelctl install` starts is token-bound and idles out like `himmelctl ui`; unlike the service it
// may save a secret. Its port and token live in a mode-600 file so a second install reuses it instead of starting another.
const adhocPath = () => path.join(process.env.HOME || os.homedir(), '.himmel', 'state', 'ui-adhoc.json');
const LAUNCH_URL = /^http:\/\/127\.0\.0\.1:(\d+)\/(?:agui\/)?#t=([0-9a-f]{16,})\s*$/m;
const setupLink = (port, token) => `http://127.0.0.1:${port}/#t=${token}&page=setup`;

function portOpen(port) {
  return new Promise((resolve) => {
    const s = require('net').connect({ port, host: '127.0.0.1' });
    const done = (ok) => { s.destroy(); resolve(ok); };
    s.setTimeout(1000, () => done(false));
    s.once('connect', () => done(true));
    s.once('error', () => done(false));
  });
}

// ponytail: liveness is a connect to the recorded port, so another process that took a dead UI's port would pass; upgrade path is a token-checked /api probe.
async function adhocLink() {
  let s;
  try { s = JSON.parse(fs.readFileSync(adhocPath(), 'utf8')); } catch (_e) { return null; }
  if (!s || !Number.isInteger(s.port) || typeof s.token !== 'string' || !(await portOpen(s.port))) return null;
  return setupLink(s.port, s.token);
}

// Start `bun scripts/config-ui/server.ts` detached and read the URL it prints; the server exits on its own after 30 minutes idle.
async function startAdhoc({ repoRoot, timeoutMs = 20000 }) {
  const bun = which('bun');
  if (!bun) return { ok: false, lines: ['bun is required (https://bun.sh)'] };
  const server = path.join(repoRoot, 'scripts', 'config-ui', 'server.ts');
  if (!fs.existsSync(server)) return { ok: false, lines: [`${server} not found (needs a himmel checkout)`] };
  const dir = path.dirname(adhocPath());
  const outFile = path.join(dir, `ui-adhoc.${process.pid}.out`);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const fd = fs.openSync(outFile, 'w', 0o600);
  const child = spawn(bun, [server, '--port', '0'], { detached: true, stdio: ['ignore', fd, 'ignore'] });
  fs.closeSync(fd);
  let gone = null;
  child.once('error', (e) => { gone = e.message; });
  child.once('exit', (code) => { gone = `exited with code ${code}`; });
  child.unref();
  try {
    for (const deadline = Date.now() + timeoutMs; Date.now() < deadline && gone === null;) {
      const m = LAUNCH_URL.exec(fs.readFileSync(outFile, 'utf8'));
      if (m) {
        fs.writeFileSync(adhocPath(), `${JSON.stringify({ pid: child.pid, port: Number(m[1]), token: m[2] })}\n`, { mode: 0o600 });
        return { ok: true, lines: [setupLink(m[1], m[2])] };
      }
      await new Promise((r) => setTimeout(r, 100));
    }
  } finally { fs.rmSync(outFile, { force: true }); }
  if (gone === null) { try { process.kill(-child.pid); } catch (_e) { /* already gone */ } }
  return { ok: false, lines: [`the UI server ${gone === null ? 'did not print its link in time' : gone}`] };
}

function install({ repoRoot, port, dryRun }) {
  const bun = which('bun');
  if (!bun) return { ok: false, lines: ['bun is required (https://bun.sh)'] };
  const handoverDir = process.env.HANDOVER_DIR;
  if (!handoverDir) return { ok: false, lines: ['HANDOVER_DIR is not set; the console board needs it (see docs/handover/running-a-console.md)'] };
  if (!which('systemctl')) return noSystemctl;
  const unit = renderUnit({ repoRoot, bun, handoverDir, envPath: process.env.PATH || '/usr/bin:/bin', port: port === null ? DEFAULT_PORT : port });
  if (dryRun) return { ok: true, lines: [`dry-run: would write ${unitPath()}`, `dry-run: would write ${tokenPath()} (mode 600) if absent`, 'dry-run: would run systemctl --user daemon-reload, enable --now ' + UNIT_NAME] }; // t13b-ok: dry-run message text only, starts no process
  try { ensureToken(); } catch (e) { return { ok: false, lines: [e.message] }; }
  fs.mkdirSync(UNIT_DIR, { recursive: true });
  const tmp = `${unitPath()}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, unit, 'utf8');
  fs.renameSync(tmp, unitPath());
  for (const a of [['daemon-reload'], ['enable', '--now', UNIT_NAME]]) { // t13b-ok: installs the user unit, operator-run verb
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
  if (dryRun) return { ok: true, lines: [`dry-run: would disable --now ${UNIT_NAME}, remove ${unitPath()} and ${tokenPath()}, daemon-reload`] }; // t13b-ok: dry-run message text only, starts no process
  const dis = sctl('disable', '--now', UNIT_NAME); // absent unit: nothing to disable, still remove the files
  if (dis.status !== 0 && !['inactive', 'failed'].includes((sctl('is-active', UNIT_NAME).stdout || '').trim())) {
    return { ok: false, lines: [`systemctl --user disable --now ${UNIT_NAME} failed (rc=${dis.status}) and the service is not confirmed stopped; nothing removed: ${(dis.stderr || '').trim()}`] };
  }
  for (const p of [unitPath(), tokenPath()]) fs.rmSync(p, { force: true });
  const rl = sctl('daemon-reload'); // t13b-ok: unit reload after uninstall, starts no process
  if (rl.status !== 0) return { ok: false, lines: [`unit and token files removed, but systemctl --user daemon-reload failed (rc=${rl.status}): ${(rl.stderr || '').trim()}`] }; // t13b-ok: failure message text only, starts no process
  return { ok: true, lines: [`${UNIT_NAME} removed (unit file and token file)`] };
}

function status() {
  if (!which('systemctl')) return noSystemctl;
  const active = sctl('is-active', UNIT_NAME);
  const state = (active.stdout || '').trim() || 'unknown';
  const enabled = (sctl('is-enabled', UNIT_NAME).stdout || '').trim() || 'unknown';
  return { ok: state === 'active', lines: [`${UNIT_NAME}: ${state} (${enabled})`, installedPort() === null ? 'not installed' : `port ${installedPort()}`] };
}

module.exports = { UNIT_NAME, DEFAULT_PORT, renderUnit, install, uninstall, status, url, adhocLink, startAdhoc };
