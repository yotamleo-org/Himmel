// Enhancement only: with this script removed every level and component is
// still a native <details> with its full text. It opens the level a rail link
// points at, highlights the level in view, remembers the last level opened,
// and on wide screens shows a component's detail in a side panel.
(function () {
  var KEY = 'himmel-trail-level';
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  var wide = window.matchMedia('(min-width: 1100px)');
  var levels = Array.prototype.slice.call(document.querySelectorAll('details.lvl'));
  var links = Array.prototype.slice.call(document.querySelectorAll('.rail a[href^="#lvl-"], .stepper a[href^="#lvl-"]'));

  function store(n) { try { localStorage.setItem(KEY, n); } catch (e) { /* storage off */ } }
  function stored() { try { return localStorage.getItem(KEY); } catch (e) { return null; } }

  function current(id) {
    links.forEach(function (a) { a.setAttribute('aria-current', a.getAttribute('href') === '#' + id ? 'true' : 'false'); });
  }

  function openLevel(id, scroll) {
    var d = document.getElementById(id);
    if (!d || !d.classList.contains('lvl')) return;
    d.open = true;
    current(id);
    if (scroll) d.scrollIntoView({ behavior: reduce.matches ? 'auto' : 'smooth', block: 'start' });
  }

  links.forEach(function (a) {
    a.addEventListener('click', function (e) {
      e.preventDefault();
      var id = a.getAttribute('href').slice(1);
      openLevel(id, true);
      history.replaceState(null, '', '#' + id);
    });
  });

  levels.forEach(function (d) {
    d.addEventListener('toggle', function () {
      if (d.open) { store(d.id.slice(4)); current(d.id); }
    });
  });

  window.addEventListener('hashchange', function () {
    var h = location.hash.slice(1);
    if (/^lvl-[0-9]+$/.test(h)) openLevel(h, true);
  });

  var hash = location.hash.slice(1);
  if (/^lvl-[0-9]+$/.test(hash)) {
    openLevel(hash, true);
  } else {
    var n = stored();
    var d = n === null ? null : document.getElementById('lvl-' + n);
    var note = document.getElementById('resume');
    if (d && note) {
      d.open = true;
      current(d.id);
      var a = document.createElement('a');
      a.href = '#' + d.id;
      a.textContent = 'Level ' + n + ', ' + d.querySelector('.lt strong').textContent;
      a.addEventListener('click', function (e) { e.preventDefault(); openLevel(d.id, true); });
      note.textContent = 'Welcome back. You were on ';
      note.appendChild(a);
      note.appendChild(document.createTextNode('.'));
      note.hidden = false;
    }
  }

  if ('IntersectionObserver' in window) {
    var seen = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { if (en.isIntersecting) current(en.target.id); });
    }, { rootMargin: '-35% 0px -60% 0px' });
    levels.forEach(function (d) { seen.observe(d); });
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
    panel.hidden = true;
    if (opener) { opener.setAttribute('aria-expanded', 'false'); opener.focus(); opener = null; }
  }

  document.querySelectorAll('details.comp > summary').forEach(function (s) {
    s.addEventListener('click', function (e) {
      if (!wide.matches) return;
      e.preventDefault();
      if (opener === s) { closePanel(); return; }
      if (opener) opener.setAttribute('aria-expanded', 'false');
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
