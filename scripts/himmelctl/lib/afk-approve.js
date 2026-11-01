'use strict';
// scripts/himmelctl/lib/afk-approve.js — `himmelctl approve <id>`, `himmelctl deny <id>` and
// `himmelctl approve status <id>`: the SSH way to answer an AFK request.
//
// A thin caller of the root afk-sudo helper, the same helper the Telegram route calls:
//   sudo -n /usr/local/libexec/himmel/afk-sudo approve|deny ID --from OP --chat OP --via ssh --approver USER
// The helper and its broker do every check (nonce, TOTP code, replay, expiry, operator id, the frozen
// record, the never-remote floor). This file only
//   - refuses unless it runs as the config's operator_user, before anything is sent,
//   - sends the config's own operator_id as --from/--chat, so SSH can never name anyone else,
//   - tags the call --via ssh --approver <that user>, which the ledger rows carry, and
//   - reads the nonce and the TOTP code from stdin (masked on a TTY) and hands them to the helper's
//     stdin. Neither goes in argv, a log or a ledger row.
//
// Test seams (an operator-run CLI gains no privilege from them: they only change which file this
// user's own process reads, or which program it runs in place of `sudo -n <helper>`):
//   HIMMELCTL_AFK_CONFIG  config path (default /etc/himmel/afk-sudo.json)
//   HIMMELCTL_AFK_SUDO    program run in place of `sudo -n <helper>`

const fs = require('fs');
const os = require('os');
const { spawnSync } = require('child_process');

const HELPER = '/usr/local/libexec/himmel/afk-sudo';
const CONFIG = '/etc/himmel/afk-sudo.json';
const ID_RE = /^[a-z2-7]{8}$/;
// The nonce root sent (4 characters, Crockford base32) then the 6-digit code; spaces between are free.
const REPLY_RE = /^([0-9A-Za-z]{4})([0-9]{6})$/;

function readConfig(env) {
  try {
    const c = JSON.parse(fs.readFileSync(env.HIMMELCTL_AFK_CONFIG || CONFIG, 'utf8'));
    return c && typeof c === 'object' ? c : null;
  } catch (_) {
    return null;
  }
}

async function readReply(input, output) {
  if (input.isTTY) {
    const reply = await require('./secret-prompt').readMasked('Nonce Code: ', { input, output });
    input.pause(); // readMasked leaves stdin flowing, which would keep this process alive after the reply
    return reply;
  }
  let data = '';
  for await (const chunk of input) {
    data += chunk;
    if (data.includes('\n')) break;
  }
  return data.split('\n')[0];
}

// verb: approve | deny | status. Returns the exit code (0 ok, 2 usage, 5 refused or failed).
async function runAfkApprove({ verb, id, env = process.env, input = process.stdin, output = process.stdout, out = console.log, err = console.error }) {
  if (!ID_RE.test(id || '')) {
    err(`himmelctl ${verb}: the id is 8 characters of a-z and 2-7`);
    return 2;
  }
  let args = [verb, id];
  let stdin = '';
  if (verb !== 'status') {
    const user = os.userInfo().username;
    const cfg = readConfig(env);
    if (!cfg) {
      err('himmelctl: afk-sudo is not installed here, or its config is unreadable, nothing sent');
      return 5;
    }
    const op = cfg.operator_id;
    if (!Number.isInteger(op) || op <= 0 || typeof cfg.operator_user !== 'string' || cfg.operator_user === '') {
      err('himmelctl: the afk-sudo config names no operator, nothing sent');
      return 5;
    }
    if (user !== cfg.operator_user) {
      err(`himmelctl: only the operator (${cfg.operator_user}) can ${verb}; this is ${user}, nothing sent`);
      return 5;
    }
    args = [verb, id, '--from', String(op), '--chat', String(op), '--via', 'ssh', '--approver', user];
    if (verb === 'approve') {
      const m = REPLY_RE.exec((await readReply(input, output)).replace(/\s+/g, ''));
      if (!m) {
        err('himmelctl approve: type the 4-character nonce from the notice, then the 6-digit code, nothing sent');
        return 2;
      }
      stdin = `${m[1]} ${m[2]}\n`;
    }
  }
  const [cmd, ...pre] = env.HIMMELCTL_AFK_SUDO ? [env.HIMMELCTL_AFK_SUDO] : ['sudo', '-n', HELPER];
  const r = spawnSync(cmd, [...pre, ...args], { input: stdin, encoding: 'utf8', env });
  if (r.error) {
    err(`himmelctl: could not run the afk-sudo helper: ${r.error.code || r.error.message}`);
    return 5;
  }
  if (r.stdout) out(r.stdout.replace(/\n$/, ''));
  if (r.stderr) err(r.stderr.replace(/\n$/, ''));
  return r.status === 0 ? 0 : 5;
}

module.exports = { runAfkApprove, ID_RE, REPLY_RE };
