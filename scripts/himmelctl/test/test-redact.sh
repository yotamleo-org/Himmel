#!/usr/bin/env bash
# test-redact.sh: redact.js keeps hyphen-separated session names
# readable (a chief or worker name is 32+ chars of word segments), while every
# token shape, secret assignment, .env literal and random run still masks.
#
# WHY: LONG_RUN masked any 32+ char mixed letter+digit run, so every full session
# name showed as the redaction marker in the config UI. Nothing token-shaped is
# committed: the 40-char random runs are fixed non-secret strings built here.
set -uo pipefail

root="$(git rev-parse --show-toplevel)"
node_bin="${NODE:-node}"

RD_ROOT="$root" "$node_bin" - <<'NODE'
'use strict';
const path = require('path');
const { redact, redactDeep, REDACTED } = require(path.join(process.env.RD_ROOT, 'scripts/himmelctl/lib/redact.js'));

let fails = 0;
function row(n, fn) { try { fn(); console.log('PASS - ' + n); } catch (e) { fails++; console.log('FAIL - ' + n + ': ' + (e && e.message)); } }
function eq(a, b, m) { if (a !== b) throw new Error((m || 'eq') + ': got ' + JSON.stringify(a) + ' want ' + JSON.stringify(b)); }

const NAMES = [
  'HIMMEL-nextleg-2026-11-04RD-roadmap-chief',
  'HIMMEL-9152-N4748-hud-no-economics-lines-2026-11-04',
  'HIMMEL-9176-N4750-redactor-keeps-session-names-2026-11-05',
];
const RAND40 = 'aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5zA7c';

for (const name of NAMES) {
  row('session name stays readable: ' + name, () => eq(redact(name), name));
  row('session name stays readable inside prose: ' + name, () => eq(redact('chief ' + name + ' running'), 'chief ' + name + ' running'));
}
row('redactDeep keeps a session name in a nested value', () => eq(redactDeep({ chief: { name: NAMES[0] } }).chief.name, NAMES[0]));
row('a short id stays', () => eq(redact('N4748'), 'N4748'));

// controls: these masked before the change and still must
row('control: a 40-char random run masks', () => eq(redact(RAND40), REDACTED));
row('control: a 40-char random run masks inside prose', () => eq(redact('key ' + RAND40 + ' end'), 'key ' + REDACTED + ' end'));
row('control: a hyphenated base64url-like run (mixed segments) masks', () => eq(redact('aB3dE5fG7hI9-jK1lM3nO5pQ7-rS9tU1vW3xY5zA7'), REDACTED));
row('control: a UUID-like run with a mixed 12-char tail masks', () => eq(redact('0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d'), REDACTED));
row('control: a UUID whose segments are each only letters or only digits masks', () => eq(redact('abcdefab-1234-4123-8123-123456789012'), REDACTED));
row('control: a UUID inside a longer name masks (prefix)', () => eq(redact('x-abcdefab-1234-4123-8123-123456789012'), REDACTED));
row('control: a UUID inside a longer name masks (suffix)', () => eq(redact('abcdefab-1234-4123-8123-123456789012-chief'), REDACTED));
row('control: a UUID-shaped run of non-hex words inside a longer name masks (only the UUID rule catches it)', () => {
  eq(redact('x-abcdefgh-1234-4123-8123-abcdefghijkl'), REDACTED);
  eq(redact('abcdefgh-1234-4123-8123-abcdefghijkl-chief'), REDACTED);
});
row('control: mixed-case junk segments mask (the word rule is lower, Capitalised or ALL-CAPS only)', () => eq(redact('aBcDeFgHiJ-kLmNoPqRsT-2026-11-05'), REDACTED));
row('control: three short letter+digit ids mask (cap is two)', () => eq(redact('HIMMEL-a1B2c-D3e4F-g5H6i-roadmap-chief'), REDACTED));
row('control: a 6-char letter+digit id masks (id limit is 5)', () => eq(redact('HIMMEL-9176-aB3dE5-roadmap-chief-2026'), REDACTED));
row('control: an 8-hex worker nonce inside a name masks (digits only)', () => eq(redact('HIMMEL-9176-V-N255-93727264-roadmap-chief'), REDACTED));
row('control: an 8-hex worker nonce inside a name masks (letters and digits)', () => eq(redact('HIMMEL-9176-V-N255-93f72f64-roadmap-chief'), REDACTED));
row('control: a run with an underscore masks', () => eq(redact('aB3dE5fG7hI9_jK1lM3nO5pQ7_rS9tU1vW3xY5zA7'), REDACTED));
row('control: a hyphenated run of many short mixed chunks masks', () => eq(redact('a1B2c-D3e4F-g5H6i-J7k8L-m9N0o-P1q2R-s3T4u'), REDACTED));
row('control: a two-segment hyphenated random run masks', () => eq(redact('aB3dE5fG7hI9jK1lM3nO5pQ7-rS9tU1vW3xY5zA7'), REDACTED));
row('control: a pure-hex digest stays', () => eq(redact('828e3341329be53caec9326a35c968781ccf4145'), '828e3341329be53caec9326a35c968781ccf4145'));

row('control: an .env literal inside a session-name-shaped string masks', () => {
  const lit = 'hunter9zebraquartz';
  const out = redact('HIMMEL-9152-N4748-' + lit + '-hud-no-economics-2026-11-04', { literals: [lit] });
  eq(out, 'HIMMEL-9152-N4748-' + REDACTED + '-hud-no-economics-2026-11-04');
  eq(out.includes(lit), false, 'literal gone');
});
row('control: a token shape inside a session-name-shaped string masks', () => {
  const tok = 'ghp_' + 'aB3dE5fG7hI9jK1lM3nO5pQ7';
  const out = redact('HIMMEL-9152-N4748-' + tok + '-hud-2026-11-04');
  eq(out.includes(tok), false, 'token gone');
  eq(out.includes(REDACTED), true, 'marker present');
});
row('control: an sk- token inside a session-name-shaped string masks', () => {
  const tok = 'sk-' + 'aB3dE5fG7hI9jK1lM3nO5pQ7';
  const out = redact('worker-' + tok + '-hud-2026-11-04');
  eq(out.includes('aB3dE5fG7hI9'), false, 'token gone');
});
row('control: a secret assignment with a session-name-shaped value masks', () => {
  eq(redact('API_TOKEN=HIMMEL-9152-N4748-hud-no-economics-lines-2026-11-04'), 'API_TOKEN=' + REDACTED);
});

console.log(fails ? fails + ' failure(s)' : 'all rows passed');
process.exit(fails ? 1 : 0);
NODE
