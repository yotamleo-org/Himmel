import { legacyNamesOn } from '../../../../scripts/lib/env-alias.mjs';

// The one edge table (spec §3), shared by the server and the CLI. `peers` maps
// name -> registration {role, console?, pair?, predecessor?}. An edge is
// symmetric: (a) worker/judge/consult <-> its console, (c) worker <-> its pair,
// (d) console <-> its predecessor/successor console. A pair never involves a
// console, and a worker is always one end of it. Nothing else is allowed,
// so a declaration only counts when both endpoints hold the role it requires.

// A stored record from before the rename carries the old role name: it reads as
// `worker` while the legacy-names switch is on, and as an unknown role (no pair
// edge) when it is off.
export const canonRole = value => (value === 'leg' && legacyNamesOn() ? 'worker' : value);
const role = (peers, name) => canonRole(peers[name]?.role);
const PAIRED = ['worker', 'judge', 'consult'];

function declared(peers, name) {
  const me = peers[name];
  const mine = role(peers, name);
  const out = [];
  if (me.console && mine !== 'console' && role(peers, me.console) === 'console') out.push(me.console);
  const mate = role(peers, me.pair);
  if (me.pair && PAIRED.includes(mine) && PAIRED.includes(mate) && (mine === 'worker' || mate === 'worker')) out.push(me.pair);
  if (me.predecessor && mine === 'console' && role(peers, me.predecessor) === 'console') out.push(me.predecessor);
  return out.filter(other => other !== name);
}

export function edgeList(peers, name) {
  if (!peers[name]) return [];
  const out = new Set(declared(peers, name));
  for (const other of Object.keys(peers)) {
    if (declared(peers, other).includes(name)) out.add(other);
  }
  return [...out].sort();
}

// The refusal lists only the caller's own edges, never another console's (threat T5).
export function check(peers, from, to) {
  const list = edgeList(peers, from);
  if (list.includes(to)) return { ok: true };
  return { ok: false, error: `no edge to ${to}; your edges: ${list.join(', ') || '(none)'}` };
}
