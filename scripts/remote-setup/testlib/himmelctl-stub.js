'use strict';
// Test stub for `node scripts/himmelctl/bin.js`, not shipped logic. The suite copies it over
// the fixture checkout's bin.js. State lives under $RST:
//   items.json        {"<item id>": {"severity": "green|degraded|red|n/a", "detail": "..."}}
//   items.omit        item ids the stub leaves out of a status answer
//   himmelctl.fail    an exit code: `status` then fails with it
//   bridge-enable.rc  an exit code for `bridge enable` (default 0)
//   himmelctl.calls   every call, one line each
const fs = require('fs');
const path = require('path');
const RST = process.env.RST;
const argv = process.argv.slice(2);
const at = (f) => path.join(RST, f);
const read = (f, fallback) => { try { return fs.readFileSync(at(f), 'utf8'); } catch (_e) { return fallback; } };
fs.appendFileSync(at('himmelctl.calls'), argv.join(' ') + '\n');

if (argv[0] === 'status') {
  const failure = read('himmelctl.fail', null);
  if (failure !== null) {
    process.stderr.write('himmelctl stub: refused\n');
    process.exit(Number(failure.trim()) || 1);
  }
  const i = argv.indexOf('--items');
  const ids = i >= 0 ? argv[i + 1].split(',') : [];
  let table = {};
  try { table = JSON.parse(read('items.json', '{}')); } catch (_e) { table = {}; }
  const omit = read('items.omit', '').split(/\s+/).filter(Boolean);
  const items = ids.filter((id) => !omit.includes(id)).map((id) => {
    const row = table[id] || { severity: 'n/a', detail: 'not set up' };
    return { id, kind: 'lane', desired: true, actual: null, severity: row.severity, detail: row.detail || '' };
  });
  const summary = { red: 0, degraded: 0, green: 0, na: 0 };
  for (const it of items) {
    if (it.severity === 'red') summary.red++;
    else if (it.severity === 'degraded') summary.degraded++;
    else if (it.severity === 'green') summary.green++;
    else summary.na++;
  }
  process.stdout.write(JSON.stringify({ schemaVersion: 1, target: 'user', items, summary }) + '\n');
  process.exit(0);
}

if (argv[0] === 'bridge' && argv[1] === 'enable') {
  const rc = Number((read('bridge-enable.rc', '0')).trim()) || 0;
  process.stdout.write(JSON.stringify({ ok: rc === 0, actions: [], detail: rc === 0 ? 'stub: enabled' : 'stub: refused' }) + '\n');
  process.exit(rc);
}

process.stderr.write('himmelctl stub: unknown call\n');
process.exit(2);
