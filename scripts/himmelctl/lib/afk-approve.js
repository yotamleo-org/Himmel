'use strict';
// scripts/himmelctl/lib/afk-approve.js: `himmelctl approve <id>`, `himmelctl deny <id>` and
// `himmelctl approve status <id>`: the SSH way to answer an AFK request.
//
// A thin caller of the root afk-sudo helper, the same helper the Telegram route calls:
//   sudo -n /usr/local/libexec/himmel/afk-sudo approve|deny ID --from OP --chat OP --via ssh --approver USER
// The helper and its broker do every check (nonce, TOTP code, replay, expiry, operator id, the frozen
// record, the never-remote floor). This file only
//   - refuses unless it runs as the config's operator_user, before anything is sent,
//   - sends the config's own operator_id as --from/--chat, so SSH can never name anyone else,
//   - tags the call --via ssh --approver <that user>, which the ledger rows carry, and
//   - for an approve, asks for the nonce from the request's Telegram notice, refuses a malformed one, and only
//     then asks for the TOTP code (one line each on stdin, masked prompts on a TTY); for a deny, reads the nonce
//     (and the code once the request has seen three wrong nonces) on one line. Both go to the helper's stdin,
//     never argv, a log or a ledger row.
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
const NONCE_RE = /^[0-9A-Za-z]{4}$/;
const CODE_RE = /^[0-9]{6}$/;
const DENY_RE = /^([0-9A-Za-z]{4})([0-9]{6})?$/;

function readConfig(env) {
  try {
    const c = JSON.parse(fs.readFileSync(env.HIMMELCTL_AFK_CONFIG || CONFIG, 'utf8'));
    return c && typeof c === 'object' ? c : null;
  } catch (_) {
    return null;
  }
}

function replyReader(input, output) {
  if (input.isTTY) {
    const ask = async (label) => {
      const reply = await require('./secret-prompt').readMasked(label, { input, output });
      input.pause(); // readMasked leaves stdin flowing, which would keep this process alive after the reply
      return reply;
    };
    ask.close = async () => {};
    return ask;
  }
  const chunks = input[Symbol.asyncIterator]();
  let data = '';
  let ended = false;
  const ask = async () => {
    while (!ended && !data.includes('\n')) {
      const next = await chunks.next();
      if (next.done) ended = true;
      else data += next.value;
    }
    const nl = data.indexOf('\n');
    const line = nl < 0 ? data : data.slice(0, nl);
    data = nl < 0 ? '' : data.slice(nl + 1);
    return line;
  };
  ask.close = async () => { await chunks.return(); };
  return ask;
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
    const ask = replyReader(input, output);
    try {
      if (verb === 'approve') {
        if (input.isTTY) output.write(`Approving request ${id}: first the nonce from its Telegram notice, then the authenticator code.\n`);
        const nonce = (await ask('Nonce: ')).replace(/\s+/g, '');
        if (!NONCE_RE.test(nonce)) {
          err('himmelctl approve: the nonce is the 4 characters in the request\'s Telegram notice, typed on its own; nothing sent');
          return 2;
        }
        const code = (await ask('Code: ')).replace(/\s+/g, '');
        if (!CODE_RE.test(code)) {
          err('himmelctl approve: the code is the 6 digits of your authenticator app; nothing sent');
          return 2;
        }
        stdin = `${nonce} ${code}\n`;
      } else {
        const m = DENY_RE.exec((await ask('Nonce [Code]: ')).replace(/\s+/g, ''));
        if (!m) {
          err('himmelctl deny: type the 4-character nonce from the notice (and the 6-digit code once the helper asks), nothing sent');
          return 2;
        }
        stdin = m[2] ? `${m[1]} ${m[2]}\n` : `${m[1]}\n`;
      }
    } finally {
      await ask.close();
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

module.exports = { runAfkApprove, ID_RE, NONCE_RE, CODE_RE };
