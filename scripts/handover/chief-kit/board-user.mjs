// board-user.mjs — The user shift board (v5 frame 15): what is running now, what waits for
// you, what shipped. A second renderer over the reads board.mjs already makes (`--view user`);
// it takes plain rows and returns one self-contained page: no network, one column, phone width.
// It leaves out everything operator-side: failure classes, the phase ladder, leg ids, lanes,
// the fleet and the usage budget, and it redacts like the operator board does.
import { redact } from './redact.mjs';

const esc = (s) => String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const clip = (s, n) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);
// A worker's prose may name its own leg: that id is operator-side, so it reads "a worker".
// A home directory path names the operator's machine, so it reads "[path]".
const plain = (s, n) => esc(clip(redact(String(s)).replace(/\bN\d+[a-z]*\b/g, 'a worker').replace(/(?:\/(?:home|Users)\/|[A-Za-z]:\\Users\\)\S*/g, '[path]'), n));

// A PR title without its conventional-commit prefix and ticket keys: the goal in plain words.
export const goalOf = (title) => redact(String(title || '').replace(/^[a-z]+(?:\([^)]*\))?!?:\s*/i, '').replace(/\[[A-Z][A-Z0-9]*-\d+\]\s*/g, ''));

const row = ({ ticket, goal, tag, text }) => `<li>${ticket ? `<b>${esc(ticket)}</b> ` : ''}${goal ? `${plain(goal, 110)} ` : ''}${tag ? `<span class="tag">${esc(tag)}</span>` : ''}${text ? `<p>${plain(text, 140)}</p>` : ''}</li>`;

const section = (key, title, rows, empty) => `<section data-section="${key}" data-count="${rows.length}"><h2>${esc(title)} <b>${rows.length}</b></h2>${rows.length ? `<ul>${rows.map(row).join('\n')}</ul>` : `<p class="none">${esc(empty)}</p>`}</section>`;

// running / waiting / shipped: arrays of { ticket, goal, tag, text }; shippedNote replaces the
// empty line when the merged list could not be read.
export const renderUserBoard = ({ stamp, running, waiting, shipped, shippedNote }) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Shift board</title>
<style>
:root { --bg:#f6f7f9; --surface:#fff; --text:#1c2128; --muted:#5b6672; --line:#d9dee4; --accent:#2457c5; --warn:#9a6700; --ok:#1a7f37; }
@media (prefers-color-scheme: dark) { :root { --bg:#0f1318; --surface:#181d24; --text:#e6e9ed; --muted:#96a1ad; --line:#2b333d; --accent:#7aa2ff; --warn:#d29922; --ok:#3fb950; } }
* { box-sizing: border-box; }
body { margin:0; padding:16px; background:var(--bg); color:var(--text); font:15px/1.45 system-ui, sans-serif; overflow-wrap:anywhere; }
main { max-width:640px; margin:0 auto; }
h1 { font-size:1.35rem; margin:0 0 2px; } h2 { font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:0 0 8px; } h2 b { color:var(--text); }
.sub { color:var(--muted); font-size:.85rem; margin:0 0 14px; }
section { background:var(--surface); border:1px solid var(--line); border-radius:10px; padding:12px; margin:0 0 12px; }
section[data-section="waiting"] { border-color:var(--warn); } section[data-section="shipped"] h2 b { color:var(--ok); }
ul { list-style:none; margin:0; padding:0; } li { padding:6px 0; border-top:1px solid var(--line); } li:first-child { border-top:0; }
li p { margin:2px 0 0; color:var(--muted); font-size:.85rem; } .tag { color:var(--accent); font-weight:600; font-size:.85rem; } .none { color:var(--muted); margin:0; }
</style>
</head>
<body>
<main>
<h1>Shift board</h1>
<p class="sub">rendered ${esc(stamp)}</p>
${section('running', 'Running now', running, 'nothing is running')}
${section('waiting', 'Waiting on you', waiting, 'nothing is waiting on you')}
${section('shipped', 'Shipped · last 24 hours', shipped, shippedNote || 'nothing shipped in the last 24 hours')}
</main>
</body>
</html>
`;
