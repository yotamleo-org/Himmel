(function () {
  var KEY = 'himmel-trail-level';
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  var wide = window.matchMedia('(min-width: 1100px)');
  var mods = Array.prototype.slice.call(document.querySelectorAll('details.lvl'));
  var links = Array.prototype.slice.call(document.querySelectorAll('.rail a[href^="#m-"]'));
  var chips = Array.prototype.slice.call(document.querySelectorAll('.stepper a[href^="#t-"]'));

  function store(id) { try { localStorage.setItem(KEY, id); } catch (e) { /* storage off */ } }
  function stored() { try { return localStorage.getItem(KEY); } catch (e) { return null; } }

  function card(id) {
    var el = document.getElementById(id);
    if (el && /^lvl-[0-9]+$/.test(id)) el = el.closest('details.lvl');
    return el && el.classList.contains('lvl') ? el : null;
  }

  function current(d) {
    links.forEach(function (a) { a.setAttribute('aria-current', a.getAttribute('href') === '#' + d.id ? 'true' : 'false'); });
    chips.forEach(function (a) { a.setAttribute('aria-current', a.getAttribute('href') === '#t-' + d.dataset.track ? 'true' : 'false'); });
  }

  function openModule(id, scroll) {
    var d = card(id);
    if (!d) return;
    d.open = true;
    store(d.id.slice(2));
    current(d);
    if (scroll) d.scrollIntoView({ behavior: reduce.matches ? 'auto' : 'smooth', block: 'start' });
  }

  links.forEach(function (a) {
    a.addEventListener('click', function (e) {
      e.preventDefault();
      var id = a.getAttribute('href').slice(1);
      openModule(id, true);
      history.replaceState(null, '', '#' + id);
    });
  });

  mods.forEach(function (d) {
    d.addEventListener('toggle', function () {
      if (d.open) { store(d.id.slice(2)); current(d); }
    });
  });

  var ANCHOR = /^(m-[a-z-]+|lvl-[0-9]+)$/;
  window.addEventListener('hashchange', function () {
    var h = location.hash.slice(1);
    if (ANCHOR.test(h)) openModule(h, true);
  });

  var hash = location.hash.slice(1);
  if (ANCHOR.test(hash)) {
    openModule(hash, true);
  } else if (!/^t-[a-z]+$/.test(hash)) {
    var v = stored();
    var d = v === null ? null : card(/^[0-9]+$/.test(v) ? 'lvl-' + v : 'm-' + v);
    var note = document.getElementById('resume');
    if (d && note) {
      d.open = true;
      current(d);
      var head = document.getElementById('t-' + d.dataset.track);
      var a = document.createElement('a');
      a.href = '#' + d.id;
      a.textContent = d.querySelector('.lt strong').textContent + (head ? ', in ' + head.querySelector('.bn').textContent : '');
      a.addEventListener('click', function (e) { e.preventDefault(); openModule(d.id, true); });
      note.textContent = 'Welcome back. You were on ';
      note.appendChild(a);
      note.appendChild(document.createTextNode('.'));
      note.hidden = false;
    }
  }

  if ('IntersectionObserver' in window) {
    var seen = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { if (en.isIntersecting) current(en.target); });
    }, { rootMargin: '-35% 0px -60% 0px' });
    mods.forEach(function (d) { seen.observe(d); });
  }

  var panel = document.createElement('aside');
  panel.className = 'sidepanel';
  panel.hidden = true;
  panel.tabIndex = -1;
  panel.setAttribute('aria-label', 'Component detail');
  panel.innerHTML = '<header><strong></strong><button type="button" class="x" aria-label="Close">×</button></header><div class="pbody"></div>';
  document.body.appendChild(panel);
  var opener = null;

  function closePanel() {
    if (opener) opener.parentElement.open = true;
    panel.hidden = true;
    if (opener) { opener.removeAttribute('aria-expanded'); opener.focus(); opener = null; }
  }

  document.querySelectorAll('details.comp > summary').forEach(function (s) {
    s.addEventListener('click', function (e) {
      if (!wide.matches) return;
      e.preventDefault();
      if (opener === s) { closePanel(); return; }
      if (opener) opener.removeAttribute('aria-expanded');
      opener = s;
      s.setAttribute('aria-expanded', 'true');
      panel.querySelector('strong').innerHTML = s.querySelector('.cn').innerHTML;
      var body = panel.querySelector('.pbody');
      body.textContent = '';
      var badge = s.querySelector('.badge');
      if (badge) body.appendChild(badge.cloneNode(true));
      body.appendChild(s.parentElement.querySelector('.cd').cloneNode(true));
      panel.hidden = false;
      panel.focus();
    });
  });
  panel.querySelector('.x').addEventListener('click', closePanel);
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && !panel.hidden) closePanel(); });
  wide.addEventListener('change', function () { if (!wide.matches) closePanel(); });

  document.documentElement.classList.add('js');
})();
