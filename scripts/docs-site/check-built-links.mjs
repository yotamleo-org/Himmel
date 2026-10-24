// scripts/docs-site/check-built-links.mjs <dist> [base]
// Walks every built .html under <dist> (generated pages and raw passthrough
// guides alike) and fails on a local <a href> whose route is not built or whose
// #fragment is not an id/name on the target page. External schemes are skipped.
// Exit 0 clean, 1 dead links found (one line each), 2 nothing to check.
import fs from 'node:fs';
import path from 'node:path';

const dist = path.resolve(process.argv[2] ?? '');
const base = (process.argv[3] ?? '/Himmel').replace(/\/$/, '');

const htmlFiles = [];
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith('.html')) htmlFiles.push(p);
  }
})(dist);
if (htmlFiles.length === 0) {
  console.error(`check-built-links: no .html under ${dist}`);
  process.exit(2);
}

const named = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };
const unescapeHtml = (s) =>
  s.replace(/&(?:#(\d+)|#x([0-9a-f]+)|(amp|lt|gt|quot|apos));/gi, (all, dec, hex, name) => {
    if (name) return named[name.toLowerCase()];
    const code = dec ? Number(dec) : parseInt(hex, 16);
    return code <= 0x10ffff ? String.fromCodePoint(code) : all;
  });

const withoutInert = (html) => html.replace(/<!--[\s\S]*?-->|<(script|style)\b[\s\S]*?<\/\1\s*>/gi, ' ');

const idCache = new Map();
const idsOf = (file) => {
  if (!idCache.has(file)) {
    const ids = new Set();
    for (const m of withoutInert(fs.readFileSync(file, 'utf8')).matchAll(/\s(?:id|name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))/gi)) {
      ids.add(unescapeHtml(m[1] ?? m[2] ?? m[3]));
    }
    idCache.set(file, ids);
  }
  return idCache.get(file);
};

const resolveTarget = (p) => {
  if (fs.existsSync(p) && fs.statSync(p).isFile()) return p;
  const idx = path.join(p, 'index.html');
  return fs.existsSync(idx) ? idx : null;
};

let checked = 0;
const dead = [];
for (const file of htmlFiles) {
  const rel = path.relative(dist, file);
  const html = withoutInert(fs.readFileSync(file, 'utf8'));
  for (const m of html.matchAll(/<a\s(?:[^>]*?\s)?href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/gi)) {
    const href = unescapeHtml(m[1] ?? m[2] ?? m[3]).trim();
    if (href === '' || /^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('//')) continue;
    checked++;
    const hash = href.indexOf('#');
    const frag = hash >= 0 ? href.slice(hash + 1) : '';
    let target = (hash >= 0 ? href.slice(0, hash) : href).split('?')[0];
    try {
      target = decodeURIComponent(target);
    } catch {}
    let abs;
    if (target === '') abs = file;
    else if (target.startsWith('/')) {
      if (target !== base && !target.startsWith(`${base}/`)) {
        dead.push(`${rel}: dead route ${href} (outside ${base}/)`);
        continue;
      }
      abs = path.join(dist, target.slice(base.length));
    } else abs = path.resolve(path.dirname(file), target);
    const inside = path.relative(dist, abs);
    if (inside === '..' || inside.startsWith(`..${path.sep}`) || path.isAbsolute(inside)) {
      dead.push(`${rel}: dead route ${href} (escapes the site)`);
      continue;
    }
    const resolved = abs === file ? file : resolveTarget(abs);
    if (!resolved) {
      dead.push(`${rel}: dead route ${href}`);
      continue;
    }
    if (frag === '' || frag === 'top' || !resolved.endsWith('.html')) continue;
    let name = frag;
    try {
      name = decodeURIComponent(frag);
    } catch {}
    if (!idsOf(resolved).has(name)) {
      dead.push(`${rel}: dead fragment ${href} (no #${name} in ${path.relative(dist, resolved)})`);
    }
  }
}

for (const d of dead) console.log(d);
console.log(`check-built-links: ${htmlFiles.length} pages, ${checked} local links, ${dead.length} dead`);
process.exit(dead.length ? 1 : 0);
