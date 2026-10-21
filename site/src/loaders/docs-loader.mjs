// Loads the allowlisted docs/ pages: title from the first H1, body untouched.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { slugOf } from '../plugins/remark-docs.mjs';
import { homeData, homeBody } from '../home.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const DOCS = path.join(REPO, 'docs');

export function readAllowlist(file) {
  return fs.readFileSync(file, 'utf8').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
}

export function h1Of(md) {
  let fence = null;
  for (const line of md.split('\n')) {
    const f = line.match(/^\s*(`{3,}|~{3,})/);
    if (f) {
      if (!fence) fence = f[1];
      else if (f[1][0] === fence[0] && f[1].length >= fence.length) fence = null;
    }
    const m = !fence && !f && line.match(/^# (.+?)\s*$/);
    if (m) {
      const spans = [];
      return m[1].replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
        .replace(/(`+)(.+?)\1(?!`)/g, (_, _ticks, code) => `\0${spans.push(code) - 1}\0`)
        .replace(/\*\*(?=\S)(.+?)(?<=\S)\*\*/g, '$1')
        .replace(/(^|\W)__(?=\S)(.+?)(?<=\S)__(?!\w)/g, '$1$2')
        .replace(/\*(?=\S)(.+?)(?<=\S)\*/g, '$1')
        .replace(/(^|\W)_(?=\S)(.+?)(?<=\S)_(?!\w)/g, '$1$2')
        .replace(/`/g, '')
        .replace(/\0(\d+)\0/g, (_, i) => spans[i]);
    }
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
      const homeFile = fileURLToPath(new URL('../home.mjs', import.meta.url));
      store.set({
        id: 'index',
        data: await parseData({ id: 'index', data: homeData }),
        body: homeBody,
        filePath: path.relative(REPO, homeFile),
        digest: generateDigest(homeBody + JSON.stringify(homeData)),
        rendered: await renderMarkdown(homeBody, { fileURL: pathToFileURL(homeFile) }),
      });
      watcher?.add(DOCS);
    },
  };
}
