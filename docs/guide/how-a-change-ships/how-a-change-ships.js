/* How a change ships: an enhancement only. Without it every step is a details element below the graph. */
(function deliveryGraph() {
  var svg = document.getElementById('graph'); if (!svg) return;
  document.documentElement.classList.add('js');
  var reduce = false;
  try { reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (e) { /* old browser */ }
  function txt(el) { return el ? el.textContent.replace(/\s+/g, ' ').trim() : ''; }
  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function each(list, f) { Array.prototype.forEach.call(list, f); }

  function probe(chain, hit) {
    var items = Array.prototype.slice.call(chain.querySelectorAll('.ck'));
    var target = items.filter(function (it) { return it.dataset.k === hit; })[0] || items[items.length - 1];
    var my = (chain._run = (chain._run || 0) + 1);
    items.forEach(function (it) { it.classList.remove('pass', 'at', 'hit'); });
    chain.classList.add('probing');
    var idx = items.indexOf(target);
    if (reduce) { items.slice(0, idx).forEach(function (it) { it.classList.add('pass'); }); target.classList.add('hit'); return Promise.resolve(); }
    return (async function () {
      for (var i = 0; i <= idx; i++) {
        if (chain._run !== my) return;
        if (i > 0) { items[i - 1].classList.remove('at'); items[i - 1].classList.add('pass'); }
        items[i].classList.add('at');
        await wait(i === idx ? 200 : 380);
      }
      if (chain._run !== my) return;
      target.classList.remove('at'); target.classList.add('hit');
    })();
  }

  var gl1 = document.getElementById('gl1'), gl2 = document.getElementById('gl2'), slot = document.getElementById('gslot');
  var crumb = document.getElementById('gcrumb-name'), levels = Array.prototype.slice.call(document.querySelectorAll('.glevels li'));
  var NS = 'http://www.w3.org/2000/svg', current = null, home = null, playing = false, run = 0;
  var tok0 = svg.querySelector('.gtok');
  var stage = document.getElementById('gstage');
  var glv = document.querySelector('.glevels');
  var ICON = {
    plan: '<path d="M3 6l6-3 6 3 6-3v15l-6 3-6-3-6 3z"/><path d="M9 3v15M15 6v15"/>',
    build: '<circle cx="6" cy="5" r="2"/><circle cx="6" cy="19" r="2"/><circle cx="18" cy="8" r="2"/><path d="M6 7v10M18 10c0 4-4 6-10 7"/>',
    guard: '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M9 12l2 2 4-4"/>',
    ci: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 12l3 3 7-7"/>',
    review: '<circle cx="11" cy="11" r="6"/><path d="M16 16l5 5"/><path d="M8.5 11h5"/>',
    gate: '<path d="M12 2l10 10-10 10L2 12z"/><path d="M8 12h8"/>',
    approve: '<circle cx="12" cy="8" r="4"/><path d="M4 21c1-5 5-7 8-7s7 2 8 7"/>',
    ship: '<path d="M5 21V4"/><path d="M5 4h12l-2 4 2 4H5"/>',
    hood: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2"/>'
  };
  function svgi(k) { return '<svg viewBox="0 0 24 24" aria-hidden="true">' + (ICON[k] || '') + '</svg>'; }
  function setLevel(n) { levels.forEach(function (li) { li.classList.toggle('on', li.dataset.l === String(n)); }); stage.classList.remove('at1', 'at2', 'at3'); stage.classList.add('at' + n); }
  function nodeEl(id) { return svg.querySelector('[data-node="' + id + '"]'); }
  function pulse(id) { var g = nodeEl(id); if (!g || reduce) return; g.classList.remove('pulse'); void g.getBBox(); g.classList.add('pulse'); }

  function ring(d) {
    if (d._ring) return d._ring;
    var items = Array.prototype.slice.call(d.querySelectorAll('ol.inner > li')).map(txt);
    if (!items.length) return null;
    var s = document.createElementNS(NS, 'svg'); s.setAttribute('viewBox', '0 0 520 300'); s.setAttribute('class', 'innerring'); s.setAttribute('aria-hidden', 'true');
    var cx = 260, cy = 135, rx = 185, ry = 92;
    var p = document.createElementNS(NS, 'path');
    p.setAttribute('d', 'M' + (cx - rx) + ' ' + cy + ' a' + rx + ' ' + ry + ' 0 1 1 ' + (2 * rx) + ' 0 a' + rx + ' ' + ry + ' 0 1 1 ' + (-2 * rx) + ' 0');
    p.setAttribute('class', 'ir-track'); s.appendChild(p);
    var p2 = p.cloneNode(); p2.setAttribute('class', 'ir-dir'); s.appendChild(p2);
    var c = document.createElementNS(NS, 'text'); c.setAttribute('x', cx); c.setAttribute('y', cy + 5); c.setAttribute('class', 'ir-c'); c.textContent = txt(d.querySelector('.gnd-n')); s.appendChild(c);
    var nodes = items.map(function (label, i) {
      var a = Math.PI + (2 * Math.PI * i) / items.length, x = cx + rx * Math.cos(a), y = cy + ry * Math.sin(a);
      var g = document.createElementNS(NS, 'g'); g.setAttribute('class', 'ir-n'); g.setAttribute('transform', 'translate(' + x.toFixed(1) + ' ' + y.toFixed(1) + ')');
      g.innerHTML = '<circle r="17"/><text class="ir-k" dy="5">' + (i + 1) + '</text><text dy="' + (y < cy ? -26 : 36) + '"></text>';
      g.lastChild.textContent = label; s.appendChild(g); return g;
    });
    var t = document.createElementNS(NS, 'circle'); t.setAttribute('r', '7'); t.setAttribute('class', 'ir-tok'); s.appendChild(t);
    d._ring = { svg: s, path: p, nodes: nodes, tok: t };
    return d._ring;
  }
  function themeLevels(d) {
    if (d._themed) return; d._themed = true;
    var body = d.querySelector('.gbody'), kids = Array.prototype.slice.call(body.children);
    var w2 = document.createElement('div'), w3 = document.createElement('div'), cur = w2;
    w2.className = 'lv lv2'; w3.className = 'lv lv3';
    kids.forEach(function (k) { if (k.classList.contains('gl-h') && /^\s*3/.test(k.textContent)) cur = w3; cur.appendChild(k); });
    body.appendChild(w2); if (w3.children.length) body.appendChild(w3);
    var p2 = document.createElement('div'); p2.className = 'lv-plate'; p2.innerHTML = svgi(d.dataset.t) + '<span>Level 2 · inside</span><b></b>';
    p2.querySelector('b').textContent = txt(d.querySelector('.gnd-n')); w2.insertBefore(p2, w2.firstChild);
    if (w3.children.length) { var p3 = document.createElement('div'); p3.className = 'lv-plate'; p3.innerHTML = svgi('hood') + '<span>Level 3 · under the hood</span>'; w3.insertBefore(p3, w3.firstChild); }
  }
  function lap(r, my) {
    if (reduce) { r.nodes.forEach(function (g) { g.classList.add('on'); }); r.tok.setAttribute('visibility', 'hidden'); return Promise.resolve(); }
    var L = r.path.getTotalLength(), n = r.nodes.length;
    return new Promise(function (done) {
      var t0 = 0, dur = 3600;
      function f(ts) {
        if (my !== run) return done();
        if (!t0) t0 = ts;
        var k = Math.min(1, (ts - t0) / dur), pt = r.path.getPointAtLength(k * L);
        r.tok.setAttribute('cx', pt.x); r.tok.setAttribute('cy', pt.y);
        var at = Math.min(n - 1, Math.floor(k * n + 0.02));
        r.nodes.forEach(function (g, i) { g.classList.toggle('on', i <= at); });
        if (k < 1) requestAnimationFrame(f); else done();
      }
      requestAnimationFrame(f);
    });
  }
  function open(id) {
    stopPlay();
    var d = document.getElementById(id), g = nodeEl(id); if (!d || !g) return;
    var my = ++run, bb; try { bb = g.getBBox(); } catch (e) { bb = null; }
    if (!bb || !bb.width) bb = { x: 500, y: 280, width: 0, height: 0 };
    gl1.style.transformOrigin = ((bb.x + bb.width / 2) / 10) + '% ' + ((bb.y + bb.height / 2) / 5.6) + '%';
    function show() {
      gl1.hidden = true;
      home = document.createComment('gnd'); d.parentNode.insertBefore(home, d); current = d;
      var r = ring(d), list = d.querySelector('ol.inner');
      if (r && list && !r.svg.parentNode) list.parentNode.insertBefore(r.svg, list);
      slot.appendChild(d); d.open = true; themeLevels(d); stage.dataset.t = d.dataset.t || ''; glv.dataset.t = d.dataset.t || '';
      crumb.textContent = txt(d.querySelector('.gnd-n'));
      gl2.hidden = false; gl2.classList.remove('zoom-in'); void gl2.offsetWidth; if (!reduce) gl2.classList.add('zoom-in');
      setLevel(2); gl2.querySelector('.gback').focus({ preventScroll: true });
      if (reduce) gl2.scrollIntoView({ block: 'nearest' }); else gl2.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      if (r) lap(r, my).then(function () {
        if (my !== run) return;
        var ch = d.querySelector('.chain'); if (!ch) return;
        setLevel(3); probe(ch, ch.querySelector('.ck.end').dataset.k);
      }); else setLevel(3);
    }
    if (reduce) show(); else { gl1.classList.add('zoom-out'); setTimeout(function () { if (my === run) show(); }, 430); }
  }
  function back() {
    if (!current) return;
    var id = current.id; run++;
    current.open = false; home.parentNode.insertBefore(current, home); home.remove(); current = null;
    delete stage.dataset.t; delete glv.dataset.t;
    gl2.hidden = true; gl1.hidden = false; setLevel(1);
    if (!reduce) void gl1.offsetWidth;
    gl1.classList.remove('zoom-out');
    var g = nodeEl(id), m = gl1.querySelector('.gmini a[data-node="' + id + '"]');
    var target = m && m.offsetParent ? m : g;
    if (target) target.focus({ preventScroll: true });
  }
  each(svg.querySelectorAll('a.gn'), function (a) {
    a.setAttribute('role', 'button'); a.setAttribute('aria-label', 'Open ' + txt(a.querySelector('text:not(.gsym)')));
    a.addEventListener('click', function (e) { e.preventDefault(); open(a.dataset.node); });
    a.addEventListener('keydown', function (e) { if (e.key === ' ') { e.preventDefault(); open(a.dataset.node); } });
  });
  each(gl1.querySelectorAll('.gmini a.gm'), function (a) { a.addEventListener('click', function (e) { e.preventDefault(); open(a.dataset.node); }); });
  gl2.querySelector('.gback').addEventListener('click', back);
  gl2.addEventListener('keydown', function (e) { if (e.key === 'Escape') back(); });
  each(document.querySelectorAll('.gnd .try'), function (row) {
    row.hidden = false;
    each(row.querySelectorAll('button'), function (b) {
      b.setAttribute('aria-pressed', 'false');
      b.addEventListener('click', function () {
        run++; setLevel(3);
        each(row.querySelectorAll('button'), function (o) { o.setAttribute('aria-pressed', String(o === b)); });
        var ch = row.previousElementSibling; while (ch && !ch.classList.contains('chain')) ch = ch.previousElementSibling;
        if (ch) probe(ch, b.dataset.hit);
      });
    });
  });

  /* run a change through the graph, only when asked */
  var btn = gl1.querySelector('.gplay');
  function stopPlay() {
    playing = false; run++;
    each(svg.querySelectorAll('.gtok.tmp'), function (t) { t.remove(); });
    each(svg.querySelectorAll('.ge.lit'), function (e) { e.classList.remove('lit'); });
    if (btn) { btn.setAttribute('aria-pressed', 'false'); btn.textContent = '▶ Run a change through the graph'; }
  }
  function travel(path, my, ms, split) {
    return new Promise(function (done) {
      var t = tok0.cloneNode(); t.classList.add('tmp'); if (split) t.classList.add('split'); svg.appendChild(t);
      var L = path.getTotalLength(), t0 = 0; path.classList.add('lit');
      function f(ts) {
        if (my !== run) { t.remove(); path.classList.remove('lit'); return done(); }
        if (!t0) t0 = ts;
        var k = Math.min(1, (ts - t0) / ms), e = k < .5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2, pt = path.getPointAtLength(e * L);
        t.setAttribute('cx', pt.x); t.setAttribute('cy', pt.y);
        if (k < 1) requestAnimationFrame(f); else { t.remove(); path.classList.remove('lit'); done(); }
      }
      requestAnimationFrame(f);
    });
  }
  function seg(ids, my, ms, split) { return Promise.all(ids.map(function (id) { return travel(document.getElementById(id), my, ms, split); })); }
  function orbit(my) {
    var p = document.createElementNS(NS, 'path'); p.setAttribute('d', 'M386 250 a114 40 0 1 0 228 0 a114 40 0 1 0 -228 0'); p.setAttribute('fill', 'none'); svg.insertBefore(p, svg.firstChild);
    return travel(p, my, 1100).then(function () { return travel(p, my, 1100); }).then(function () { p.remove(); });
  }
  async function play() {
    var my = ++run; playing = true;
    var gate = nodeEl('gn-gate'); gate.classList.remove('open');
    var steps = [
      function () { return seg(['e-in1', 'e-in2', 'e-in3'], my, 900); }, function () { pulse('gn-plan'); return seg(['e-pb'], my, 600); },
      function () { pulse('gn-build'); return orbit(my); }, function () { return seg(['e-bg', 'e-bc', 'e-br'], my, 800, true); },
      function () { ['gn-guard', 'gn-ci', 'gn-review'].forEach(pulse); return seg(['e-gg', 'e-cg', 'e-rg'], my, 800, true); },
      function () { gate.classList.add('open'); pulse('gn-gate'); return seg(['e-ga'], my, 600); },
      function () { pulse('gn-approve'); return wait(900); },
      function () { return seg(['e-as'], my, 500); }, function () { pulse('gn-ship'); return seg(['e-sp'], my, 1400); },
      function () { pulse('gn-plan'); return Promise.resolve(); }
    ];
    for (var i = 0; i < steps.length; i++) { if (my !== run) return; await steps[i](); }
    if (my === run) { playing = false; btn.setAttribute('aria-pressed', 'false'); btn.textContent = '▶ Run it again'; }
  }
  if (!reduce && btn) {
    gl1.querySelector('.gctl').hidden = false;
    btn.addEventListener('click', function () { if (playing) { stopPlay(); return; } btn.setAttribute('aria-pressed', 'true'); btn.textContent = '■ Stop'; play(); });
  }
})();

(function theme() {
  var tb = document.getElementById('theme'); if (!tb) return;
  var mode;
  try { mode = localStorage.getItem('himmel-guide-theme') || 'auto'; } catch (e) { mode = 'auto'; }
  function apply() {
    if (mode === 'auto') document.documentElement.removeAttribute('data-theme'); else document.documentElement.setAttribute('data-theme', mode);
    tb.textContent = 'Theme: ' + mode;
  }
  tb.addEventListener('click', function () {
    mode = mode === 'auto' ? 'light' : mode === 'light' ? 'dark' : 'auto';
    try { localStorage.setItem('himmel-guide-theme', mode); } catch (e) { /* private window */ }
    apply();
  });
  apply();
})();
