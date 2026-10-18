// Loads the allowlisted docs/ pages: title from the first H1, body untouched.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { slugOf } from '../plugins/remark-docs.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const DOCS = path.join(REPO, 'docs');

export function readAllowlist(file) {
  return fs.readFileSync(file, 'utf8').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
}

export function h1Of(md) {
  let fence = false;
  for (const line of md.split('\n')) {
    if (/^\s*(```|~~~)/.test(line)) fence = !fence;
    const m = !fence && line.match(/^# (.+?)\s*$/);
    if (m) return m[1].replace(/`/g, '').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1');
  }
  throw new Error('no H1');
}

export function docsLoader(allowFile) {
  return {
    name: 'himmel-docs-loader',
    async load({ store, parseData, renderMarkdown, generateDigest, watcher }) {
      store.clear();
      for (const rel of readAllowlist(allowFile)) {
        const abs = path.join(DOCS, rel);
        if (!fs.existsSync(abs)) throw new Error(`allowlist entry missing under docs/: ${rel}`);
        const body = fs.readFileSync(abs, 'utf8');
        const id = slugOf(rel);
        const data = await parseData({ id, data: { title: h1Of(body) } });
        store.set({
          id,
          data,
          body,
          filePath: path.relative(REPO, abs),
          digest: generateDigest(body),
          rendered: await renderMarkdown(body, { fileURL: pathToFileURL(abs) }),
        });
      }
      watcher?.add(DOCS);
    },
  };
}
