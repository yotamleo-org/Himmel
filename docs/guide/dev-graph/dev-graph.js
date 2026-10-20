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
    svgEl('text', { class: 'dg-glyph', x: p.x + bw / 2 - 10, y: p.y - bh / 2 + 15, 'text-anchor': 'middle', 'aria-hidden': 'true' }, g);
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
    g.setAttribute('tabindex', '-1');
    nodeEls.set(n.id, g);
    svgEl('rect', { class: 'dg-box', x: N.x, y: top, width: N.nodeW, height: N.nodeH, rx: 6 }, g);
    svgEl('rect', { class: 'dg-stripe', x: N.x, y: top + 6, width: 4, height: N.nodeH - 12 }, g);
    const t = svgEl('text', { class: 'dg-label', x: N.x + 14, y: top + N.nodeH / 2 + 4 }, g);
    t.textContent = n.label;
    const chip = svgEl('text', { class: 'dg-chip', x: N.x + N.nodeW - 10, y: top + N.nodeH / 2 + 4, 'text-anchor': 'end' }, g);
    chip.textContent = lane ? lane.label : n.lane;
    svgEl('text', { class: 'dg-glyph', x: N.x + N.nodeW - 10, y: top + 15, 'text-anchor': 'middle', 'aria-hidden': 'true' }, g);

    stubs.get(n.id).forEach((row, r) => {
      const y = top + N.nodeH + 4 + r * (N.stubH + N.stubGap);
      for (const s of row) {
        const a = svgEl('g', {
          class: 'dg-stub dg-' + s.e.kind, 'data-edge': s.e.id, 'data-to': s.e.to, role: 'link', tabindex: 0,
          'aria-label': s.text + ', ' + s.e.condition,
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
          to.focus({ preventScroll: true });
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

function conditions(root, data) {
  const label = new Map(data.nodes.map((n) => [n.id, n.label]));
  const box = htmlEl('details', 'dg-conditions', null, root);
  htmlEl('summary', null, 'Every step and transition as text (' + data.nodes.length + ' steps, ' + data.edges.length + ' transitions)', box);
  const steps = htmlEl('ul', 'dg-steps', null, box);
  for (const n of data.nodes) htmlEl('li', null, n.label + ' — ' + n.summary, steps);
  const ul = htmlEl('ul', null, null, box);
  for (const e of data.edges) {
    const text = (label.get(e.from) || e.from) + ' → ' + (label.get(e.to) || e.to) + ': ' + (e.exit != null ? 'exit ' + e.exit + ', ' : '') + e.condition;
    htmlEl('li', 'dg-cond dg-cond-' + e.kind, text, ul);
  }
}

const GLYPH = { active: ['●', 'Active'], passed: ['✓', 'Passed'], refused: ['✕', 'Refused'], hold: ['⏸', 'On hold'] };
const STEP_STATES = ['refused', 'hold'];
const SOURCE_BASE = 'https://github.com/yotamleo-org/Himmel/blob/main/';
const STEP_MS = 2400;
const TRAVEL_MS = 600;

// The edge a walkthrough takes from node a to node b: a decision or loop beats a refusal.
function takenEdge(data, a, b) {
  const hits = data.edges.filter((e) => e.from === a && e.to === b);
  return hits.find((e) => e.kind !== 'refusal') || hits[0] || null;
}

// Every problem that would make a walkthrough lie. An empty list means the walkthroughs can run.
function validate(data) {
  const bad = [];
  const nodes = new Set(data.nodes.map((n) => n.id));
  const edges = new Set(data.edges.map((e) => e.id));
  for (const e of data.edges) if (!nodes.has(e.from) || !nodes.has(e.to)) bad.push('edge ' + e.id + ' joins an unknown node');
  if (!Array.isArray(data.walkthroughs) || !data.walkthroughs.length) return bad.concat('the data has no walkthroughs');
  const seen = new Set();
  for (const w of data.walkthroughs) {
    if (seen.has(w.id)) bad.push('walkthrough ' + w.id + ' appears twice');
    seen.add(w.id);
    if (!Array.isArray(w.steps) || !w.steps.length) { bad.push(w.id + ': no steps'); continue; }
    w.steps.forEach((s, i) => {
      const where = w.id + ' step ' + (i + 1) + ': ';
      if (!nodes.has(s.at)) bad.push(where + 'unknown node ' + s.at);
      if (s.ghost != null && !edges.has(s.ghost)) bad.push(where + 'unknown edge ' + s.ghost);
      if (s.state != null && STEP_STATES.indexOf(s.state) < 0) bad.push(where + 'unknown state ' + s.state);
      const prev = i ? w.steps[i - 1].at : null;
      if (prev && nodes.has(prev) && nodes.has(s.at) && prev !== s.at && !takenEdge(data, prev, s.at)) bad.push(where + 'no edge from ' + prev + ' to ' + s.at);
    });
  }
  return bad;
}

function banner(root, problems) {
  const box = htmlEl('div', 'dg-banner', null, root);
  box.setAttribute('role', 'alert');
  htmlEl('p', null, 'The walkthroughs are switched off: the graph data has ' + problems.length + (problems.length === 1 ? ' problem.' : ' problems.'), box);
  const ul = htmlEl('ul', null, null, box);
  for (const p of problems) htmlEl('li', null, p, ul);
}

function button(text, cls, parent) {
  const b = htmlEl('button', 'dg-btn ' + cls, text, parent);
  b.type = 'button';
  return b;
}

function controls(root, data, uid) {
  const bar = htmlEl('div', 'dg-controls', null, root);
  bar.setAttribute('role', 'group');
  bar.setAttribute('aria-label', 'Playback');
  const lab = htmlEl('label', 'dg-pick', null, bar);
  lab.setAttribute('for', uid + '-walk');
  htmlEl('span', null, 'Walkthrough', lab);
  const select = htmlEl('select', 'dg-walk', null, lab);
  select.id = uid + '-walk';
  for (const w of data.walkthroughs) {
    const o = htmlEl('option', null, w.title || w.id, select);
    o.value = w.id;
  }
  const restart = button('Restart', 'dg-restart', bar);
  const prev = button('Prev', 'dg-prev', bar);
  const play = button('Play', 'dg-play', bar);
  const next = button('Next', 'dg-next', bar);
  const scrub = htmlEl('input', 'dg-scrub', null, bar);
  scrub.type = 'range';
  scrub.min = '0';
  scrub.setAttribute('aria-label', 'Step');
  return { bar, select, restart, prev, play, next, scrub };
}

function caption(root) {
  const box = htmlEl('div', 'dg-caption', null, root);
  box.setAttribute('aria-live', 'polite');
  box.setAttribute('aria-atomic', 'true');
  const c = { box };
  c.no = htmlEl('p', 'dg-stepno', null, box);
  c.title = htmlEl('h3', 'dg-cap-title', null, box);
  c.state = htmlEl('p', 'dg-state', null, box);
  const dl = htmlEl('dl', null, null, box);
  htmlEl('dt', null, 'What happened', dl);
  c.what = htmlEl('dd', null, null, dl);
  htmlEl('dt', null, 'Why', dl);
  c.why = htmlEl('dd', null, null, dl);
  htmlEl('dt', null, 'Source', dl);
  c.src = htmlEl('dd', null, null, dl);
  c.ghost = htmlEl('p', 'dg-ghost-note', null, box);
  return c;
}

function edgeText(e) {
  return (e.exit != null ? 'exit ' + e.exit + ': ' : '') + e.condition;
}

// Plays the walkthroughs: step state on the drawn nodes and edges, the caption, the controls,
// autoplay, the #w=&s= link. Returns a function that undoes every listener it added.
function walk(root, data, uid, reduced) {
  const stage = root.querySelector('.dg-stage');
  const ui = controls(root, data, uid);
  const body = htmlEl('div', 'dg-body', null, null);
  root.insertBefore(body, stage);
  body.appendChild(stage);
  root.insertBefore(ui.bar, body);
  const cap = caption(body);
  const byId = new Map(data.nodes.map((n) => [n.id, n]));
  const group = (list, key) => {
    const m = new Map();
    for (const el of list) {
      const id = el.getAttribute(key);
      if (!m.has(id)) m.set(id, []);
      m.get(id).push(el);
    }
    return m;
  };
  const nodeEls = group(stage.querySelectorAll('.dg-node'), 'data-id');
  const edgeEls = group(stage.querySelectorAll('.dg-edge'), 'data-id');
  for (const [id, els] of group(stage.querySelectorAll('.dg-stub'), 'data-edge')) edgeEls.set(id, (edgeEls.get(id) || []).concat(els));
  stage.tabIndex = 0;
  stage.setAttribute('role', 'group');
  stage.setAttribute('aria-label', 'Graph. Left and right arrows step, space plays or pauses, Home restarts.');

  let wi = 0;
  let step = 0;
  let playing = false;
  let hover = false;
  let focus = false;
  let timer = 0;
  const cur = () => data.walkthroughs[wi];
  const last = () => cur().steps.length - 1;

  function writeHash() {
    const keep = location.hash.slice(1).split('&').filter((p) => p && !/^(w|s)=/.test(p));
    keep.push('w=' + cur().id, 's=' + (step + 1));
    try { history.replaceState(null, '', '#' + keep.join('&')); } catch (e) { /* a sandboxed frame has no history */ }
  }

  function travel(id) {
    for (const el of edgeEls.get(id) || []) {
      const p = el.querySelector('path');
      if (!p || !p.animate || !p.getTotalLength) continue;
      const len = p.getTotalLength();
      const dash = len + ' ' + len;
      p.animate([{ strokeDasharray: dash, strokeDashoffset: len }, { strokeDasharray: dash, strokeDashoffset: 0 }], { duration: TRAVEL_MS, easing: 'ease-in-out' });
      if (el.classList.contains('dg-refusal')) el.animate([{ opacity: 0.25 }, { opacity: 1 }], { duration: TRAVEL_MS / 2, iterations: 2 });
    }
  }

  function paint() {
    const w = cur();
    const nodeState = new Map();
    const edgeState = new Map();
    for (let j = 0; j <= step; j++) {
      const s = w.steps[j];
      nodeState.set(s.at, j === step ? s.state || 'active' : 'passed');
      const e = j ? takenEdge(data, w.steps[j - 1].at, s.at) : null;
      if (e) edgeState.set(e.id, j === step ? 'active' : 'passed');
    }
    const now = w.steps[step];
    if (now.ghost && !edgeState.has(now.ghost)) edgeState.set(now.ghost, 'ghost');
    for (const [id, els] of nodeEls) {
      const st = nodeState.get(id) || 'idle';
      for (const el of els) {
        el.setAttribute('data-state', st);
        const g = el.querySelector('.dg-glyph');
        if (g) g.textContent = GLYPH[st] ? GLYPH[st][0] : '';
      }
    }
    for (const [id, els] of edgeEls) for (const el of els) el.setAttribute('data-state', edgeState.get(id) || 'idle');
    return edgeState;
  }

  function describe() {
    const w = cur();
    const s = w.steps[step];
    const node = byId.get(s.at);
    const st = s.state || 'active';
    const into = step ? takenEdge(data, w.steps[step - 1].at, s.at) : null;
    let why = into && into.kind !== 'flow' ? into : null;
    if (!why && s.state === 'refused' && step < last()) {
      const out = takenEdge(data, s.at, w.steps[step + 1].at);
      if (out && out.kind !== 'flow') why = out;
    }
    cap.no.textContent = 'Step ' + (step + 1) + ' of ' + w.steps.length + ' · ' + w.title;
    cap.title.textContent = node.label;
    cap.state.textContent = GLYPH[st][0] + ' ' + GLYPH[st][1];
    cap.what.textContent = s.caption || node.summary;
    cap.why.textContent = why ? edgeText(why) : node.summary;
    cap.src.replaceChildren();
    const src = (node.sources || [])[0];
    if (src) {
      const a = htmlEl('a', null, src.file, cap.src);
      a.href = SOURCE_BASE + src.file;
      a.rel = 'noopener';
      htmlEl('span', 'dg-anchor', ' — “' + src.anchor + '”', cap.src);
    } else {
      cap.src.textContent = 'not tied to a file';
    }
    const ghost = s.ghost ? data.edges.find((e) => e.id === s.ghost) : null;
    cap.ghost.textContent = ghost ? 'Not taken: ' + edgeText(ghost) : '';
    cap.ghost.hidden = !ghost;
  }

  function reveal() {
    for (const el of nodeEls.get(cur().steps[step].at) || []) {
      if (el.getClientRects().length && el.scrollIntoView) el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: reduced() ? 'auto' : 'smooth' });
    }
  }

  // opts: forward (animate the edge just taken), hash (write the link), reveal (scroll the node into view)
  function show(w, s, opts) {
    wi = Math.max(0, Math.min(w, data.walkthroughs.length - 1));
    step = Math.max(0, Math.min(s, last()));
    const o = opts || {};
    const taken = paint();
    describe();
    ui.select.value = cur().id;
    ui.scrub.max = String(last());
    ui.scrub.value = String(step);
    ui.scrub.setAttribute('aria-valuetext', 'Step ' + (step + 1) + ' of ' + (last() + 1) + ': ' + byId.get(cur().steps[step].at).label);
    ui.prev.setAttribute('aria-disabled', String(step === 0));
    ui.next.setAttribute('aria-disabled', String(step === last()));
    if (o.forward && !reduced()) {
      for (const [id, st] of taken) if (st === 'active') travel(id);
    }
    if (o.hash !== false) writeHash();
    if (o.reveal) reveal();
  }

  function schedule() {
    clearTimeout(timer);
    timer = 0;
    if (!playing || hover || focus || document.hidden) return;
    timer = setTimeout(() => {
      show(wi, step + 1, { forward: true });
      if (step >= last()) setPlaying(false); else schedule();
    }, STEP_MS);
  }

  function setPlaying(on) {
    playing = on;
    ui.play.textContent = on ? 'Pause' : 'Play';
    schedule();
  }

  const goto = (s) => { setPlaying(false); show(wi, s, { forward: s === step + 1, reveal: true }); };
  const toggle = () => {
    if (playing) { setPlaying(false); return; }
    focus = false;
    if (step >= last()) show(wi, 0, { reveal: true });
    setPlaying(true);
  };

  ui.restart.addEventListener('click', () => goto(0));
  ui.prev.addEventListener('click', () => goto(step - 1));
  ui.next.addEventListener('click', () => goto(step + 1));
  ui.play.addEventListener('click', toggle);
  ui.select.addEventListener('change', () => { setPlaying(false); show(data.walkthroughs.findIndex((x) => x.id === ui.select.value), 0, { reveal: true }); });
  ui.scrub.addEventListener('input', () => goto(Number(ui.scrub.value)));
  stage.addEventListener('mouseenter', () => { hover = true; schedule(); });
  stage.addEventListener('mouseleave', () => { hover = false; schedule(); });
  stage.addEventListener('focusin', () => { focus = true; schedule(); });
  stage.addEventListener('focusout', () => { focus = false; schedule(); });

  const onKey = (ev) => {
    if (ev.defaultPrevented || ev.altKey || ev.ctrlKey || ev.metaKey) return;
    const tag = ev.target.tagName;
    const field = tag === 'SELECT' || tag === 'INPUT';
    if ((ev.key === 'ArrowRight' || ev.key === 'ArrowLeft') && !field) goto(step + (ev.key === 'ArrowRight' ? 1 : -1));
    else if (ev.key === 'Home' && !field) goto(0);
    else if (ev.key === ' ' && !field && tag !== 'BUTTON' && tag !== 'SUMMARY' && tag !== 'A') toggle();
    else return;
    ev.preventDefault();
  };
  root.addEventListener('keydown', onKey);

  const fromHash = () => {
    const parts = location.hash.slice(1).split('&');
    const get = (k) => { const p = parts.find((x) => x.indexOf(k + '=') === 0); return p ? p.slice(k.length + 1) : null; };
    const w = data.walkthroughs.findIndex((x) => x.id === get('w'));
    const s = parseInt(get('s'), 10);
    return { w: Math.max(0, w), s: s > 0 ? s - 1 : 0, has: Number.isFinite(s) };
  };
  const onHash = () => { const h = fromHash(); setPlaying(false); show(h.w, h.s, { hash: false, reveal: true }); };
  const onVisible = () => schedule();
  window.addEventListener('hashchange', onHash);
  document.addEventListener('visibilitychange', onVisible);

  const start = fromHash();
  show(start.w, start.s, { hash: false });
  if (!start.has && !reduced()) setPlaying(true);

  return () => {
    clearTimeout(timer);
    window.removeEventListener('hashchange', onHash);
    document.removeEventListener('visibilitychange', onVisible);
  };
}

export function mount(el, data) {
  if (!data || data.version !== 1 || !data.view || !data.view.wide) throw new Error('dev-graph: not a version 1 graph with a view');
  const mq = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  const reduced = () => !!(mq && mq.matches);
  const uid = 'dg' + Math.random().toString(36).slice(2, 8);
  const root = htmlEl('div', 'dg', null);
  const problems = validate(data);
  if (problems.length) banner(root, problems);
  legend(root, data.lanes);
  const stage = htmlEl('div', 'dg-stage', null, root);
  renderWide(stage, data, uid);
  renderNarrow(stage, data, uid, reduced);
  const stop = problems.length ? null : walk(root, data, uid, reduced);
  conditions(root, data);
  el.replaceChildren(root);
  return { el: root, destroy() { if (stop) stop(); root.remove(); } };
}
