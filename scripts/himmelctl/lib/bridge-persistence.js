'use strict';
// scripts/himmelctl/lib/bridge-persistence.js — installer PRIMITIVES for the
// Telegram bridge's Linux systemd-user persistence.
//
// This module ships the primitives ONLY — it never calls them, never
// prompts, never writes without being asked. The wizard consent step that
// calls these (a `--dry-run`-aware install offer) is a DIFFERENT task (8c);
// no wizard code lives here. Zero npm deps (house convention) — Node
// builtins only, and every real command is run via spawnSync on the actual
// binary (systemctl / loginctl), never a spawned bash (a standing lint
// blocks that).
//
// Every mutating function (installSystemdUnit / uninstallSystemdUnit /
// enableLinger) returns a structured `{ ok, actions: string[], detail }`
// instead of throwing on an EXPECTED failure — a missing systemctl/loginctl
// (e.g. this repo's Windows dev host) is exactly that: a clear non-Linux
// result, never a crash. `actions` under dryRun:true is the exact list of
// steps that WOULD run (strings), so a `--dry-run` caller can print it
// without this module having performed any write or spawn.
//
// SYSTEMD_USER_UNIT_DIR is resolved once at require-time (os.homedir(),
// overridable via HIMMELCTL_SYSTEMD_USER_UNIT_DIR for the hermetic test —
// each test case spawns a fresh `node -e` invocation with the env var
// already set, same seam class as helpers.js's HIMMELCTL_CACHE_DIR).

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { which } = require('./helpers.js');
const provLib = require('./provenance.js');

const SYSTEMD_UNIT_NAME = 'telegram-bridge.service';
const SYSTEMD_USER_UNIT_DIR = process.env.HIMMELCTL_SYSTEMD_USER_UNIT_DIR
  || path.join(os.homedir(), '.config', 'systemd', 'user');

const TEMPLATE_PATH = path.join(__dirname, '..', '..', 'telegram', 'systemd', SYSTEMD_UNIT_NAME);
const UNIT_PATH = path.join(SYSTEMD_USER_UNIT_DIR, SYSTEMD_UNIT_NAME);

function haveSystemctl() { return Boolean(which('systemctl')); }
function haveLoginctl() { return Boolean(which('loginctl')); }

// partialFail — shared by installSystemdUnit AND uninstallSystemdUnit
// (generalized to uninstall an earlier fix for consumer
// consistency: `partial` is a CONTRACT a caller branches on, not prose in
// `detail` — a caller reading `{ok, partial, actions, detail}` should not
// have to know which function produced it). Once a durable side effect has
// landed (install: the file write; uninstall: disable/stop actually
// succeeding), any LATER failure in that same call must say what already
// landed rather than read as a flat "nothing happened".
function partialFail(actionsSoFar, detail) {
  return { ok: false, partial: true, actions: actionsSoFar, detail };
}

// systemd unit files treat `%` as a specifier
// prefix (%h -> home, %i -> instance, ...) in EVERY directive, so a checkout
// path containing a literal `%` — legal on every filesystem — got silently
// mis-expanded or, worse, rejected outright: verified live against systemd
// 255 (WSL) that an un-escaped `%` in WorkingDirectory/Environment/ExecStart
// makes the WHOLE unit fail to start with "Failed to resolve unit
// specifiers ... Invalid slot". `%%` is systemd's own escape for a literal
// `%`, confirmed to fix it in the same test.
function systemdPercentEscape(s) {
  return s.replace(/%/g, '%%');
}

// Additionally escapes for use INSIDE a double-quoted systemd value —
// ExecStart=/ExecStop= tokenize their line like a command line (unquoted
// whitespace SPLITS an argument — verified live: an unquoted space in
// repoRoot produced 3 separate argv entries instead of 1) and Environment=
// parses multiple space-separated VAR=value assignments (an unquoted space
// there is silently dropped with "Invalid environment assignment,
// ignoring"). Wrapping the value in `"..."` and backslash-escaping `\` and
// `"` fixes both — verified live: a value containing a literal `"` and `\`
// round-tripped byte-for-byte through a real ExecStart= argv this way.
// WorkingDirectory= is DIFFERENT and deliberately NOT quoted: it takes the
// raw rest-of-line as the path with no tokenization (a space alone is
// already fine there), and — also verified live — literal quote CHARACTERS
// in a WorkingDirectory= value are NOT stripped by systemd, they're parsed
// as part of the path and rejected as "bad unit file setting". So the two
// contexts need genuinely different escaping, decided per-directive below
// — never uniform. Boundary, stated explicitly rather than left for the
// next reader to re-derive: COVERED — `%`, embedded spaces, `"`, `\` (all
// escaped/quoted below), and CR/LF (REJECTED outright, see
// hasUnitFileNewline() — there is no correct rendering of a newline inside
// a unit directive: it doesn't corrupt a string, it CREATES additional,
// unintended directives nobody wrote, so escaping is the wrong tool and
// refusal is the only correct one). NOT covered, deliberately: NUL (already
// structurally impossible in a real filesystem path on every OS we target —
// a real `repoRoot` can never carry one, so there is nothing to defend
// against here) and other control characters / an arbitrarily long path
// against systemd's own line-length limits (neither creates a NEW directive
// the way CR/LF does; accepted as a residual, not silently — a checkout
// path is operator-chosen, and %/space/quote/backslash already proved
// "operator-chosen" alone doesn't mean harmless, so this residual is a
// judgment call named here, not an oversight).
function systemdQuoteEscape(percentEscaped) {
  return `"${percentEscaped.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

// hasUnitFileNewline — CR or LF anywhere in the value. A newline inside a
// systemd directive's value starts a NEW line, which systemd parses as a
// new directive (or a stray, possibly-meaningful fragment) — verified
// against the same live systemd 255 instance this escaping was designed
// against: there is no quoting/escaping that keeps a literal newline inside
// one directive's value, so the only correct response is refusal, not a
// corrupted-but-non-crashing render.
function hasUnitFileNewline(s) {
  return /[\r\n]/.test(s);
}

// one provenance row, never fatal — a ledger fault must not
// fail the unit install (residue over breakage), it only warns.
function provRow(recArgs) {
  try {
    provLib.provRecord(recArgs);
  } catch (e) {
    console.error(`himmelctl: WARN: provenance ledger not updated (${e.message})`);
  }
}

function installSystemdUnit({ repoRoot, dryRun } = {}) {
  if (!repoRoot) return { ok: false, actions: [], detail: 'installSystemdUnit: repoRoot is required' };
  if (hasUnitFileNewline(repoRoot)) {
    return {
      ok: false,
      actions: [],
      detail: `installSystemdUnit: repoRoot contains a CR or LF character — refusing to render it into ${SYSTEMD_UNIT_NAME} (a newline would create additional, unintended unit directives, not just a corrupted string): ${JSON.stringify(repoRoot)}`,
    };
  }

  let template;
  try {
    template = fs.readFileSync(TEMPLATE_PATH, 'utf8');
  } catch (e) {
    return { ok: false, actions: [], detail: `template not found at ${TEMPLATE_PATH}: ${e.message}` };
  }
  // Line-aware substitution — NOT a uniform template.split().join(repoRoot):
  // WorkingDirectory= needs the raw (percent-escaped only) value;
  // Environment=/ExecStart=/ExecStop= need the quote-escaped, double-quoted
  // form, since only they tokenize/parse their line's value. Keeps the
  // template file itself untouched (a single @HIMMEL_REPO@ placeholder,
  // same as before) — only this rendering step got smarter.
  //
  // The ExecStop= arm is deliberately kept even though the current template
  // carries none: moved the unit to Type=simple with the bun
  // supervisor as MAINPID, so systemd's default KillMode=control-group stops
  // it (and its poller child) without an explicit ExecStop. The arm is the
  // per-directive escaping RULE, not a claim about today's template — nothing
  // here depends on which directives the template happens to contain.
  const percentEscaped = systemdPercentEscape(repoRoot);
  const quoted = systemdQuoteEscape(percentEscaped);
  const rendered = template
    .split('\n')
    .map((line) => {
      if (line.startsWith('WorkingDirectory=')) return line.split('@HIMMEL_REPO@').join(percentEscaped);
      if (line.startsWith('Environment=') || line.startsWith('ExecStart=') || line.startsWith('ExecStop=')) {
        return line.split('@HIMMEL_REPO@').join(quoted);
      }
      return line;
    })
    .join('\n');

  const actions = [
    `write ${UNIT_PATH}`,
    'systemctl --user daemon-reload',
    `systemctl --user enable --now ${SYSTEMD_UNIT_NAME}`,
  ];
  if (dryRun) {
    return { ok: true, actions, detail: `dry-run: would install ${SYSTEMD_UNIT_NAME} at ${UNIT_PATH} with @HIMMEL_REPO@ -> ${repoRoot}` };
  }

  if (!haveSystemctl()) {
    return { ok: false, actions: [], detail: `'systemctl' not found on PATH — not a systemd/Linux host; ${SYSTEMD_UNIT_NAME} was NOT installed` };
  }

  // read the pre-state BEFORE the write — whether the unit file
  // existed (a replace backs the prior bytes up) and whether linger was already
  // on for this user (null = not determinable, recorded as such).
  let unitPre = ['create', '--pre-absent'];
  try {
    if (fs.existsSync(UNIT_PATH)) unitPre = ['replace', '--pre-text', fs.readFileSync(UNIT_PATH, 'utf8'), '--backup'];
  } catch (e) {
    // unknown pre-state: recording it as absent would claim ownership of bytes
    // this run replaces without keeping them, so record nothing for the file
    unitPre = null;
    console.error(`himmelctl: WARN: provenance pre-state of ${UNIT_PATH} unreadable (${e.message}) — not recording the unit file`);
  }
  let lingerPre = null;
  try { lingerPre = lingerEnabled({ user: os.userInfo().username }); } catch (_e) { lingerPre = null; }

  try {
    fs.mkdirSync(SYSTEMD_USER_UNIT_DIR, { recursive: true });
    const tmp = `${UNIT_PATH}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, rendered, 'utf8');
    fs.renameSync(tmp, UNIT_PATH);
  } catch (e) {
    return { ok: false, actions: [], detail: `failed to write ${UNIT_PATH}: ${e.message}` };
  }
  if (unitPre) provRow([unitPre[0], 'file', UNIT_PATH,...unitPre.slice(1), '--post-file', UNIT_PATH, '--scope', 'user', '--class', 'code']);

  // everything below this point runs AFTER the
  // first durable side effect (the unit file is now really on disk at
  // UNIT_PATH) — a failure here must never read as a flat "not installed".
  // `partial:true` + a detail naming exactly what landed lets a summary
  // consumer tell "nothing happened" from "there is a file (and maybe a
  // reload, maybe an enablement) sitting on the adopter's disk that needs
  // cleanup or a retry" — the same partial-state honesty the earlier
  // applied to the enable/start split, generalized to every step after the
  // write instead of just that one branch. No auto-rollback here either,
  // same reasoning as uninstallSystemdUnit's refuse-before-removing.
  const reload = spawnSync('systemctl', ['--user', 'daemon-reload'], { encoding: 'utf8' });
  if (reload.status !== 0) {
    return partialFail(
      [`write ${UNIT_PATH}`],
      `unit file IS written at ${UNIT_PATH}, but systemctl --user daemon-reload failed (rc=${reload.status}): ${(reload.stderr || '').trim()} — systemd does not know about it yet. Remediation: fix the reload error and re-run install (or run 'systemctl --user daemon-reload' manually), or uninstall to remove the file.`
    );
  }
  const enable = spawnSync('systemctl', ['--user', 'enable', '--now', SYSTEMD_UNIT_NAME], { encoding: 'utf8' });
  if (enable.status !== 0) {
    // `enable --now` enables THEN starts — a start failure does not undo an
    // enablement that already stuck, so the unit can be left ENABLED (will
    // start again at next boot) even though `--now` itself reports failure.
    // Probe is-enabled and say which half actually took.
    const stillEnabled = spawnSync('systemctl', ['--user', 'is-enabled', SYSTEMD_UNIT_NAME], { encoding: 'utf8' });
    const enabledNow = stillEnabled.status === 0;
    return partialFail(
      [`write ${UNIT_PATH}`, 'systemctl --user daemon-reload'],
      enabledNow
        ? `systemctl --user enable --now ${SYSTEMD_UNIT_NAME} failed to START (rc=${enable.status}): ${(enable.stderr || '').trim()} — but the unit file IS written, systemd IS reloaded, and the unit IS now enabled (will start at next boot); it is NOT running now. Remediation: 'systemctl --user status ${SYSTEMD_UNIT_NAME}' / 'journalctl --user -u ${SYSTEMD_UNIT_NAME}' to diagnose, then 'systemctl --user start ${SYSTEMD_UNIT_NAME}' once fixed.`
        : `unit file IS written at ${UNIT_PATH} and systemd IS reloaded, but systemctl --user enable --now ${SYSTEMD_UNIT_NAME} failed (rc=${enable.status}): ${(enable.stderr || '').trim()} — the unit is NOT enabled and NOT running. Remediation: fix the enable error and re-run install, or uninstall to remove the file.`
    );
  }
  provRow(['register', 'unit', '-', '--unit', SYSTEMD_UNIT_NAME, '--scope', 'user', '--class', 'code',
    '--field', `linger_preexisted=${JSON.stringify(lingerPre)}`]);
  return { ok: true, actions, detail: `${SYSTEMD_UNIT_NAME} installed at ${UNIT_PATH}, enabled and started` };
}

function uninstallSystemdUnit({ dryRun } = {}) {
  // installSystemdUnit reloads the systemd user daemon
  // after writing the unit file — uninstall must mirror that after REMOVING
  // it, or systemd keeps its cached definition loaded (still "known") even
  // though the file and the reported ok:true both say gone. Listed in
  // `actions` so --dry-run shows it too — it under-described the real path
  // before (disable + remove only).
  const actions = [
    `systemctl --user disable --now ${SYSTEMD_UNIT_NAME}`,
    `remove ${UNIT_PATH}`,
    'systemctl --user daemon-reload',
  ];
  if (dryRun) {
    return { ok: true, actions, detail: `dry-run: would disable+stop ${SYSTEMD_UNIT_NAME}, remove ${UNIT_PATH}, and reload the systemd user daemon` };
  }

  if (!haveSystemctl()) {
    return { ok: false, actions: [], detail: `'systemctl' not found on PATH — not a systemd/Linux host; nothing to uninstall` };
  }

  // `systemctl --user disable --now` on a unit that is
  // already gone exits non-zero — checking disable.status (below) BEFORE
  // checking whether the file even exists made re-running uninstall on an
  // already-uninstalled bridge report a false ok:false failure. Uninstall
  // paths get re-run in normal use (retries, re-running `ensure`, an
  // adopter repeating a step), so "nothing to uninstall" must be a clean
  // no-op success, checked FIRST — before ever calling disable at all. The
  // refuse-before-removing behavior below for a GENUINE disable failure
  // (unit still present) is unchanged.
  //
  //  (a regression of the earlier ruling, not an
  // implementation bug — recorded here so it doesn't slip past on the
  // grounds that it was asked for): an absent unit FILE is not proof the
  // service is uninstalled. systemd can still have the unit loaded,
  // running, and enabled after the file is gone — the same
  // file-on-disk-as-proof-of-service-state class the daemon-reload finding
  // (codex-4) was about. So the no-op shortcut requires BOTH: no file, AND
  // systemd genuinely no longer knows the unit (neither enabled nor
  // active). If systemd still has it in any state, fall through to the
  // real disable/stop + reload path below even with no file present —
  // `fs.existsSync(UNIT_PATH)` inside that path already handles "remove a
  // file that isn't there" as a no-op, so nothing else needs to change.
  if (!fs.existsSync(UNIT_PATH)) {
    // is-enabled/is-active exit non-zero for BOTH
    // "systemd has never heard of this unit" AND "systemd knows it fine and
    // it's merely disabled/stopped" — the same non-zero either way, so the
    // round-5 confirmed-negative check took the no-op shortcut on a unit
    // systemd still has loaded, silently skipping the required daemon-reload
    // and reporting a stale definition as fully uninstalled. LoadState is
    // the fact this shortcut actually needs: `not-found` means genuinely
    // unknown; `loaded`/`masked`/anything else means systemd still knows it
    // — go through the real path. A spawn error (status===null) stays
    // INCONCLUSIVE, never a confirmed negative, same rule an earlier fix established.
    const show = spawnSync('systemctl', ['--user', 'show', SYSTEMD_UNIT_NAME, '--property=LoadState'], { encoding: 'utf8' });
    const loadState = show.status === 0 ? (/^LoadState=(.*)$/m.exec(show.stdout || '') || [])[1] : null;
    if (loadState === 'not-found') {
      return { ok: true, actions: [], detail: `${UNIT_PATH} already absent and systemd reports LoadState=not-found for ${SYSTEMD_UNIT_NAME} — nothing to uninstall` };
    }
    // else: fall through — systemd still knows it (loaded/masked/etc, or we
    // couldn't confirm either way), go through the real path.
  }

  const disable = spawnSync('systemctl', ['--user', 'disable', '--now', SYSTEMD_UNIT_NAME], { encoding: 'utf8' });
  // a failed (or unspawnable — status is `null` on a spawn
  // error) `disable` means the unit may still be loaded/running. Removing
  // the file out from under a still-running unit is WORSE than leaving it —
  // systemd would keep the service running with no file left to reload or
  // reason about — so this REFUSES the removal and reports ok:false naming
  // the still-running unit, rather than removing the file and reporting a
  // successful uninstall while the bridge keeps running (the false-green
  // this fix closes: `ok: true` was returned unconditionally before).
  if (disable.status !== 0) {
    return {
      ok: false,
      actions: [],
      detail: `systemctl --user disable --now ${SYSTEMD_UNIT_NAME} failed (rc=${disable.status}): ${(disable.stderr || '').trim()} — refusing to remove ${UNIT_PATH} while the unit may still be running`,
    };
  }

  // `disable --now` succeeding above IS a
  // durable side effect (the unit is now genuinely disabled/stopped on this
  // machine) — everything below that can still fail must say so via
  // partial:true, mirroring installSystemdUnit()'s own write-is-durable
  // boundary. A GENUINE disable failure above stays a flat ok:false: refused
  // before any of OUR actions landed, nothing to describe as partial.
  let removed = false;
  try {
    if (fs.existsSync(UNIT_PATH)) {
      fs.unlinkSync(UNIT_PATH);
      removed = true;
    }
  } catch (e) {
    return partialFail(
      [`systemctl --user disable --now ${SYSTEMD_UNIT_NAME}`],
      `systemctl --user disable --now ${SYSTEMD_UNIT_NAME} succeeded, but failed to remove ${UNIT_PATH}: ${e.message} — the unit IS disabled/stopped; the file is still on disk.`
    );
  }

  // mirrors installSystemdUnit's reload-after-write — a
  // reload that fails is folded into the result honestly (ok:false), never
  // reported as a fully clean uninstall, even though the file is already
  // gone at this point (removal is not undone; systemd's stale cached
  // definition is the thing left unresolved, named in the detail).
  const reload = spawnSync('systemctl', ['--user', 'daemon-reload'], { encoding: 'utf8' });
  if (reload.status !== 0) {
    return partialFail(
      [`systemctl --user disable --now ${SYSTEMD_UNIT_NAME}`, `remove ${UNIT_PATH}`],
      `systemctl --user disable --now ${SYSTEMD_UNIT_NAME} succeeded; unit file ${removed ? 'removed' : 'was already absent'} at ${UNIT_PATH}, but systemctl --user daemon-reload failed (rc=${reload.status}): ${(reload.stderr || '').trim()} — systemd may still list the removed unit until a reload succeeds`
    );
  }
  return {
    ok: true,
    actions,
    detail: `systemctl --user disable --now rc=0; unit file ${removed ? 'removed' : 'was already absent'} at ${UNIT_PATH}; daemon-reload rc=0`,
  };
}

function enableLinger({ user, dryRun } = {}) {
  if (!user) return { ok: false, actions: [], detail: 'enableLinger: user is required' };
  const actions = [`loginctl enable-linger ${user}`];
  if (dryRun) {
    return { ok: true, actions, detail: `dry-run: would run loginctl enable-linger ${user}` };
  }
  if (!haveLoginctl()) {
    return { ok: false, actions: [], detail: `'loginctl' not found on PATH — not a systemd/Linux host; linger was NOT enabled for ${user}` };
  }
  const r = spawnSync('loginctl', ['enable-linger', user], { encoding: 'utf8' });
  if (r.status !== 0) {
    return { ok: false, actions: [], detail: `loginctl enable-linger ${user} failed (rc=${r.status}): ${(r.stderr || '').trim()}` };
  }
  return { ok: true, actions, detail: `linger enabled for ${user}` };
}

// lingerEnabled(user) — read-only probe. true/false when determinable, null
// when it cannot be (no loginctl on this host, or the query itself failed).
function lingerEnabled({ user } = {}) {
  if (!user) return null;
  if (!haveLoginctl()) return null;
  const r = spawnSync('loginctl', ['show-user', user, '--property=Linger'], { encoding: 'utf8' });
  if (r.status !== 0) return null;
  const out = (r.stdout || '').trim();
  if (/(^|=)yes$/i.test(out)) return true;
  if (/(^|=)no$/i.test(out)) return false;
  return null;
}

// systemdUnitInstalled() — read-only: unit file presence + (best-effort)
// enabled state. `enabled` is null when it cannot be determined (no
// systemctl on this host, or an unexpected `is-enabled` exit code).
function systemdUnitInstalled() {
  const fileExists = fs.existsSync(UNIT_PATH);
  let enabled = null;
  if (haveSystemctl()) {
    const r = spawnSync('systemctl', ['--user', 'is-enabled', SYSTEMD_UNIT_NAME], { encoding: 'utf8' });
    if (r.status === 0) enabled = true;
    else if (r.status === 1) enabled = false;
  }
  return { fileExists, enabled, unitPath: UNIT_PATH };
}

module.exports = {
  SYSTEMD_UNIT_NAME,
  SYSTEMD_USER_UNIT_DIR,
  installSystemdUnit,
  uninstallSystemdUnit,
  enableLinger,
  lingerEnabled,
  systemdUnitInstalled,
};
