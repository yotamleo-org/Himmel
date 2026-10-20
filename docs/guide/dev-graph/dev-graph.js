// dev-graph.js — renders docs/guide/dev-graph/graph.json as an SVG.
//
// One ES module, no dependencies. It touches the DOM only through
// createElementNS/setAttribute (never a style attribute) and the CSSOM, so a page
// under `default-src 'self'` can mount it. Styles live in dev-graph.css and
// name tokens only.
//
// Usage: mount(el, data) -> { el, destroy() }
//   data is the parsed graph.json (version 1). The wide drawing uses
//   data.view.wide plus pos.wide and path.wide; the narrow drawing (a single
//   column for phones) uses pos.narrow.y and lists each edge as a stub.

const NS = 'http://www.w3.org/2000/svg';
const TOKEN = /^--[a-z0-9-]+$/;
const NARROW = { w: 360, x: 16, nodeW: 328, nodeH: 44, gap: 18, stubH: 18, stubGap: 4, headH: 34 };

function svgEl(name, attrs, parent) {
  const n = document.createElementNS(NS, name);
  for (const k in attrs) n.setAttribute(k, String(attrs[k]));
  if (parent) parent.appendChild(n);
  return n;
}

function htmlEl(name, cls, text, parent) {
  const n = document.createElement(name);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  if (parent) parent.appendChild(n);
  return n;
}

function titled(node, text) {
  const t = svgEl('title', {}, node);
  t.textContent = text;
}

// Sets --lane through the CSSOM, which a style-src-less CSP allows.
function laneColour(node, lane) {
  if (lane && TOKEN.test(lane.token || '')) node.style.setProperty('--lane', 'var(' + lane.token + ')');
}

// The segments of an M/H/V path, as [x1, y1, x2, y2].
function segments(path) {
  const out = [];
  let x = 0;
  let y = 0;
  for (const m of path.matchAll(/([MHV])\s*(-?[\d.]+)(?:\s*,\s*(-?[\d.]+))?/g)) {
    const a = Number(m[2]);
    if (m[1] === 'M') { x = a; y = Number(m[3]); continue; }
    const nx = m[1] === 'H' ? a : x;
    const ny = m[1] === 'V' ? a : y;
    out.push([x, y, nx, ny]);
    x = nx;
    y = ny;
  }
  return out;
}

function longest(path) {
  let best = null;
  let len = -1;
  for (const s of segments(path)) {
    const l = Math.abs(s[2] - s[0]) + Math.abs(s[3] - s[1]);
    if (l > len) { len = l; best = s; }
  }
  return best ? [(best[0] + best[2]) / 2, (best[1] + best[3]) / 2] : null;
}

function defs(svg, id) {
  const d = svgEl('defs', {}, svg);
  for (const kind of ['flow', 'decision', 'refusal', 'loop']) {
    const m = svgEl('marker', {
      id: id + '-' + kind, class: 'dg-arrow dg-arrow-' + kind, viewBox: '0 0 10 10',
      refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto',
    }, d);
    svgEl('path', { d: 'M0,0 L10,5 L0,10 z' }, m);
  }
}

function nodeGroup(parent, n, lane) {
  const g = svgEl('g', { class: 'dg-node', 'data-id': n.id, 'data-lane': n.lane, 'data-state': 'idle' }, parent);
  laneColour(g, lane);
  titled(g, n.label + ' — ' + n.summary);
  return g;
}

function renderWide(root, data, uid) {
  const v = data.view.wide;
  const [bw, bh] = v.box;
  const svg = svgEl('svg', {
    class: 'dg-svg dg-wide', viewBox: '0 0 ' + v.w + ' ' + v.h, role: 'group',
    'aria-label': 'Development graph, wide layout',
  }, root);
  defs(svg, uid + '-w');
  const lanes = new Map(data.lanes.map((l) => [l.id, l]));

  data.lanes.forEach((l, i) => {
    const band = v.lanes[l.id];
    if (!band) return;
    const g = svgEl('g', { class: 'dg-lane', 'data-lane': l.id }, svg);
    laneColour(g, l);
    svgEl('rect', { class: 'dg-band' + (i % 2 ? ' dg-band-alt' : ''), x: 0, y: band[0], width: v.w, height: band[1] }, g);
    svgEl('rect', { class: 'dg-rule', x: 0, y: band[0], width: 4, height: band[1] }, g);
    const t = svgEl('text', {
      class: 'dg-lane-label', transform: 'rotate(-90)', x: -(band[0] + band[1] / 2), y: v.lm - 10, 'text-anchor': 'middle',
    }, g);
    t.textContent = l.label;
  });

  data.phases.forEach((p, i) => {
    const cell = v.phases[i];
    if (!cell) return;
    const t = svgEl('text', {
      class: 'dg-phase', x: v.lm + v.slot * (cell[0] + cell[1] / 2), y: v.hdr - 10, 'text-anchor': 'middle',
    }, svg);
    t.textContent = p.label;
  });

  const eg = svgEl('g', { class: 'dg-edges' }, svg);
  for (const e of data.edges) {
    const d = e.path && e.path.wide;
    if (!d) continue;
    const g = svgEl('g', { class: 'dg-edge dg-' + e.kind, 'data-id': e.id, 'data-state': 'idle' }, eg);
    svgEl('path', { d, fill: 'none', 'marker-end': 'url(#' + uid + '-w-' + e.kind + ')' }, g);
    titled(g, (e.exit != null ? 'exit ' + e.exit + ': ' : '') + e.condition);
    if (e.kind === 'refusal' && e.exit != null) {
      const at = longest(d);
      if (!at) continue;
      const w = 8 + 7 * String(e.exit).length;
      const b = svgEl('g', { class: 'dg-badge' }, g);
      svgEl('rect', { x: at[0] - w / 2, y: at[1] - 8, width: w, height: 16, rx: 8 }, b);
      const t = svgEl('text', { x: at[0], y: at[1] + 4, 'text-anchor': 'middle' }, b);
      t.textContent = String(e.exit);
    }
  }

  const ng = svgEl('g', { class: 'dg-nodes' }, svg);
  for (const n of data.nodes) {
    const p = n.pos && n.pos.wide;
    if (!p) continue;
    const g = nodeGroup(ng, n, lanes.get(n.lane));
    svgEl('rect', { class: 'dg-box', x: p.x - bw / 2, y: p.y - bh / 2, width: bw, height: bh, rx: 6 }, g);
    svgEl('rect', { class: 'dg-stripe', x: p.x - bw / 2, y: p.y - bh / 2 + 6, width: 4, height: bh - 12 }, g);
    const t = svgEl('text', { class: 'dg-label', x: p.x - bw / 2 + 14, y: p.y + 4 }, g);
    t.textContent = n.label;
  }
  return svg;
}

function clip(s, n) {
  return s.length > n ? s.slice(0, n - 1) + '…' : s;
}

function renderNarrow(root, data, uid, reduced) {
  const N = NARROW;
  const lanes = new Map(data.lanes.map((l) => [l.id, l]));
  const byId = new Map(data.nodes.map((n) => [n.id, n]));
  const phases = new Map(data.phases.map((p) => [p.id, p.label]));
  const out = new Map();
  for (const e of data.edges) {
    if (!out.has(e.from)) out.set(e.from, []);
    out.get(e.from).push(e);
  }
  const order = data.nodes.filter((n) => n.pos && n.pos.narrow).sort((a, b) => a.pos.narrow.y - b.pos.narrow.y);

  // Stub rows per node, wrapped to the drawing width.
  const stubs = new Map();
  for (const n of order) {
    const rows = [[]];
    let x = N.x;
    for (const e of out.get(n.id) || []) {
      const target = byId.get(e.to);
      const text = (e.exit != null ? 'exit ' + e.exit + ' ' : '') + (e.to === n.id ? '↻ ' : '→ ') + clip(target ? target.label : e.to, 22);
      const w = 16 + Math.round(text.length * 6.2);
      if (x + w > N.x + N.nodeW && rows[rows.length - 1].length) { rows.push([]); x = N.x; }
      rows[rows.length - 1].push({ e, text, x, w });
      x += w + N.stubGap;
    }
    stubs.set(n.id, rows[0].length ? rows : []);
  }

  // Walk down the column: honour pos.narrow.y, never overlap the previous block.
  const placed = [];
  let bottom = 0;
  let prevPhase = null;
  for (const n of order) {
    let top = n.pos.narrow.y - N.nodeH / 2;
    const head = n.phase !== prevPhase;
    if (head) top = Math.max(top, bottom + N.headH);
    else top = Math.max(top, bottom + N.gap);
    prevPhase = n.phase;
    const rows = stubs.get(n.id);
    placed.push({ n, top, head });
    bottom = top + N.nodeH + (rows.length ? 4 + rows.length * (N.stubH + N.stubGap) : 0);
  }
  const height = bottom + N.gap;

  const svg = svgEl('svg', {
    class: 'dg-svg dg-narrow', viewBox: '0 0 ' + N.w + ' ' + Math.ceil(height), role: 'group',
    'aria-label': 'Development graph, phone layout',
  }, root);
  defs(svg, uid + '-n');
  const nodeEls = new Map();

  for (const { n, top, head } of placed) {
    if (head) {
      const t = svgEl('text', { class: 'dg-phase dg-phase-narrow', x: N.x, y: top - 12 }, svg);
      t.textContent = phases.get(n.phase) || n.phase;
    }
    const lane = lanes.get(n.lane);
    const g = nodeGroup(svg, n, lane);
    nodeEls.set(n.id, g);
    svgEl('rect', { class: 'dg-box', x: N.x, y: top, width: N.nodeW, height: N.nodeH, rx: 6 }, g);
    svgEl('rect', { class: 'dg-stripe', x: N.x, y: top + 6, width: 4, height: N.nodeH - 12 }, g);
    const t = svgEl('text', { class: 'dg-label', x: N.x + 14, y: top + N.nodeH / 2 + 4 }, g);
    t.textContent = n.label;
    const chip = svgEl('text', { class: 'dg-chip', x: N.x + N.nodeW - 10, y: top + N.nodeH / 2 + 4, 'text-anchor': 'end' }, g);
    chip.textContent = lane ? lane.label : n.lane;

    stubs.get(n.id).forEach((row, r) => {
      const y = top + N.nodeH + 4 + r * (N.stubH + N.stubGap);
      for (const s of row) {
        const a = svgEl('g', {
          class: 'dg-stub dg-' + s.e.kind, 'data-edge': s.e.id, 'data-to': s.e.to, role: 'link', tabindex: 0,
        }, svg);
        svgEl('rect', { x: s.x, y, width: s.w, height: N.stubH, rx: 9 }, a);
        const st = svgEl('text', { x: s.x + 8, y: y + 13 }, a);
        st.textContent = s.text;
        titled(a, s.e.condition);
        const go = (ev) => {
          const to = nodeEls.get(s.e.to);
          if (!to) return;
          ev.preventDefault();
          to.scrollIntoView({ behavior: reduced() ? 'auto' : 'smooth', block: 'center' });
        };
        a.addEventListener('click', go);
        a.addEventListener('keydown', (ev) => { if (ev.key === 'Enter' || ev.key === ' ') go(ev); });
      }
    });
  }
  return svg;
}

function legend(root, lanes) {
  const ul = htmlEl('ul', 'dg-legend', null, root);
  ul.setAttribute('aria-label', 'Legend');
  const items = [
    ['flow', 'flow'],
    ['decision', 'decision, with its condition'],
    ['refusal', 'refusal, numbered by its exit code'],
    ['loop', 'loop back'],
  ];
  for (const [kind, text] of items) {
    const li = htmlEl('li', 'dg-key dg-key-' + kind, null, ul);
    const s = svgEl('svg', { viewBox: '0 0 28 10', width: 28, height: 10, 'aria-hidden': 'true' }, li);
    const g = svgEl('g', { class: 'dg-edge dg-' + kind }, s);
    svgEl('path', { d: 'M1,5 H27', fill: 'none' }, g);
    htmlEl('span', null, text, li);
  }
  for (const l of lanes) {
    const li = htmlEl('li', 'dg-key dg-key-lane', null, ul);
    laneColour(li, l);
    htmlEl('i', 'dg-swatch', null, li);
    htmlEl('span', null, l.label, li);
  }
}

export function mount(el, data) {
  if (!data || data.version !== 1 || !data.view || !data.view.wide) throw new Error('dev-graph: not a version 1 graph with a view');
  const mq = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  const reduced = () => !!(mq && mq.matches);
  const uid = 'dg' + Math.random().toString(36).slice(2, 8);
  const root = htmlEl('div', 'dg', null);
  legend(root, data.lanes);
  const stage = htmlEl('div', 'dg-stage', null, root);
  renderWide(stage, data, uid);
  renderNarrow(stage, data, uid, reduced);
  el.replaceChildren(root);
  return { el: root, destroy() { root.remove(); } };
}
