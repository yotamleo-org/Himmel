import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { remarkDocs } from './src/plugins/remark-docs.mjs';
import { readAllowlist } from './src/loaders/docs-loader.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const DOCS = path.resolve(here, '../docs');
const BASE = '/Himmel';
const ALLOW = readAllowlist(path.join(here, 'allowlist.txt'));
const HTML_PASSTHROUGH = ['adoption-trail.html', 'guide/installer-journey.html', 'guide/loops-and-graphs.html'];

// Standalone HTML pages ship byte-identical at their docs/ paths.
const copyHtml = {
  name: 'copy-standalone-html',
  hooks: {
    'astro:build:done': ({ dir }) => {
      for (const rel of HTML_PASSTHROUGH) {
        const out = path.join(fileURLToPath(dir), rel);
        fs.mkdirSync(path.dirname(out), { recursive: true });
        fs.copyFileSync(path.join(DOCS, rel), out);
      }
    },
  },
};

// Mermaid blocks are emitted as <pre class="mermaid">; bundle the renderer.
const mermaid = {
  name: 'mermaid-inject',
  hooks: {
    'astro:config:setup': ({ injectScript }) => {
      injectScript('page', `
import mermaid from 'mermaid';
const dark = matchMedia('(prefers-color-scheme: dark)').matches;
mermaid.initialize({ startOnLoad: false, theme: dark ? 'dark' : 'default' });
if (document.querySelector('pre.mermaid')) mermaid.run({ querySelector: 'pre.mermaid' });
`);
    },
  },
};

export default defineConfig({
  site: 'https://yotamleo.github.io',
  base: BASE,
  markdown: { remarkPlugins: [[remarkDocs, { base: BASE, allow: ALLOW, html: HTML_PASSTHROUGH }]] },
  integrations: [
    starlight({
      title: 'Himmel',
      sidebar: [
        { label: 'Home', slug: '' },
        {
          label: 'Get started',
          items: [
            'why-himmel', 'getting-started', 'setup/install', 'setup/profiles',
            'setup/new-machine', 'setup/updating', 'setup/migrating',
          ],
        },
        { label: 'Use it', items: ['telegram-bridge'] },
        { label: 'Concepts', items: ['architecture'] },
      ],
    }),
    mermaid,
    copyHtml,
  ],
});
