// Remark shim that lets Starlight ingest docs/ as-is: drops the H1 (the loader
// turns it into the title), rewrites links, and keeps bare <placeholder> text.
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const DOCS = path.join(REPO, 'docs');
const BLOB = 'https://github.com/yotamleo/himmel/blob/main/';
const TREE = 'https://github.com/yotamleo/himmel/tree/main/';

const KNOWN = new Set(('a abbr b blockquote br code dd del details div dl dt em h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol p picture pre q s samp small source span strong sub summary sup table tbody td tfoot th thead tr u ul').split(' '));

export const slugOf = (rel) =>
  rel.replace(/\.md$/, '').replace(/(^|\/)README$/, '').replace(/\/$/, '') || 'index';

function walk(node, fn, parent = null) {
  fn(node, parent);
  if (node.children) for (const c of [...node.children]) walk(c, fn, node);
}

export function remarkDocs(opts) {
  const base = opts.base.replace(/\/$/, '');
  const allow = new Set(opts.allow);
  const html = new Set(opts.html);
  return (tree, file) => {
    const src = path.resolve(file.path);
    const dir = path.dirname(src);
    const rewrite = (url) => {
      if (!url || /^[a-z][a-z0-9+.-]*:/i.test(url) || url.startsWith('#') || url.startsWith('/')) return url;
      const m = url.match(/^([^#?]*)([?#].*)?$/);
      const target = path.resolve(dir, decodeURIComponent(m[1]));
      const suffix = m[2] ?? '';
      const rel = path.relative(DOCS, target).split(path.sep).join('/');
      if (!rel.startsWith('..')) {
        if (allow.has(rel)) return `${base}/${slugOf(rel)}/`.replace('//', '/') + suffix;
        if (html.has(rel)) return `${base}/${rel}` + suffix;
      }
      if (!fs.existsSync(target)) {
        throw new Error(`broken link in ${path.relative(REPO, src)}: ${url}`);
      }
      const repoRel = path.relative(REPO, target).split(path.sep).join('/');
      return (fs.statSync(target).isDirectory() ? TREE : BLOB) + repoRel + suffix;
    };

    let h1Dropped = false;
    walk(tree, (node, parent) => {
      if ((node.type === 'link' || node.type === 'definition') && node.url) node.url = rewrite(node.url);
      if (node.type === 'heading' && node.depth === 1 && !h1Dropped) {
        h1Dropped = true;
        parent.children.splice(parent.children.indexOf(node), 1);
      }
      if (node.type === 'code' && node.lang === 'mermaid') {
        const esc = node.value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        node.type = 'html';
        node.value = `<pre class="mermaid">${esc}</pre>`;
        delete node.lang;
      }
      if (node.type === 'html') {
        const t = node.value.trim().match(/^<\/?([A-Za-z][\w-]*)\s*\/?>$/);
        if (t && !KNOWN.has(t[1].toLowerCase())) node.type = 'text';
      }
    });
  };
}
