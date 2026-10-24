#!/usr/bin/env node
// Builds docs/adoption-trail.html from levels.json, page.html, trail.css,
// trail.js and site/src/styles/tokens.css. The page is self-contained (no
// request to another file or host) because the docs site copies it through
// unchanged (HTML_PASSTHROUGH in site/astro.config.mjs).
//
// Usage: node site/src/trail/render.mjs           write the page
//        node site/src/trail/render.mjs --check   exit 1 when the page differs
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const OUT = 'docs/adoption-trail.html';

const data = JSON.parse(read('site/src/trail/levels.json'));
const manifest = JSON.parse(read('scripts/install/manifest.json')).items;
const coreN = manifest.filter((i) => i.profiles.includes('core')).length;

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const BADGE = {
  shipped: '',
  beta: '<span class="badge b-beta">preview</span>',
  roadmap: '<span class="badge b-road">planned</span>',
};

function badge(status) {
  if (!(status in BADGE)) throw new Error(`unknown component status: ${status}`);
  return BADGE[status];
}

function promptLines(text, prompt) {
  return text.split('\n').map((l) => (l.startsWith(prompt) ? `<span class="p">${esc(prompt)}</span>${esc(l.slice(prompt.length))}` : esc(l))).join('\n');
}

function block(b) {
  switch (b.kind) {
    case 'cmd':
      return `<div class="io cmd"><span class="lab">${esc(b.label)}</span><pre><code>${promptLines(b.text, '$ ')}</code></pre></div>`;
    case 'out':
      return `<div class="io out"><span class="lab">${esc(b.label)}</span><pre><code>${esc(b.text)}</code></pre></div>`;
    case 'say':
      return b.text
        ? `<div class="io say"><span class="lab">${esc(b.label)}</span><pre><code><span class="p">› </span>${esc(b.text)}</code></pre></div>`
        : `<p class="sayline"><span class="p">›</span> ${esc(b.label)}</p>`;
    case 'p':
      return `<p>${b.html}</p>`;
    default:
      throw new Error(`unknown example block: ${b.kind}`);
  }
}

function cadenceTable() {
  const c = data.cadences;
  const rows = c.shown.map((x) => `<tr><td><code>${esc(x.id)}</code></td><td>${esc(x.what)}</td><td>${esc(x.offered_when)}</td></tr>`);
  const out = c.left_out.map((x) => `<li><code>${esc(x.id)}</code>: ${esc(x.why)}</li>`);
  return [
    '<div class="tblwrap">',
    '<table class="cadtbl">',
    `<caption>Scheduled jobs: pick from ${c.shown.length}</caption>`,
    '<thead><tr><th>Job</th><th>What it does</th><th>Offered when</th></tr></thead>',
    '<tbody>',
    ...rows,
    '</tbody>',
    '</table>',
    '</div>',
    `<p>Not offered on the trail (${c.left_out.length}):</p>`,
    `<ul>${out.join('')}</ul>`,
  ].join('\n');
}

function component(c) {
  const extra = c.cadences ? `\n${cadenceTable()}` : '';
  return [
    '<li><details class="comp">',
    `<summary><span class="cn">${c.name}</span>${badge(c.status)}</summary>`,
    `<div class="cd">${c.detail}${extra}</div>`,
    '</details></li>',
  ].join('\n');
}

function level(l) {
  const counts = { beta: 0, roadmap: 0 };
  for (const c of l.components) if (c.status in counts) counts[c.status] += 1;
  const chips = [
    counts.beta ? `<span class="badge b-beta">${counts.beta} preview</span>` : '',
    counts.roadmap ? `<span class="badge b-road">${counts.roadmap} planned</span>` : '',
  ].join('');
  const list = (xs) => `<ul>${xs.map((x) => `<li>${x}</li>`).join('')}</ul>`;
  const docs = l.docs.map((d) => `<a href="${esc(d.href)}">${esc(d.label)}</a>`).join(' · ');
  return [
    `<details class="lvl ${l.band}" id="lvl-${l.n}">`,
    `<summary><span class="lk">${l.n}</span><span class="lt"><strong>${esc(l.title)}</strong><span>${l.summary}</span></span><span class="lc">${chips}</span></summary>`,
    '<div class="lvl-body">',
    `<p class="outcome">${l.outcome}</p>`,
    '<dl class="schema">',
    `<dt>Turn it on</dt><dd><p>${l.turn_on.charAt(0).toUpperCase()}${l.turn_on.slice(1)}</p></dd>`,
    `<dt>What you get</dt><dd><ul class="comps">\n${l.components.map(component).join('\n')}\n</ul></dd>`,
    `<dt>Try it</dt><dd class="example"><p><b>${esc(l.example.title)}</b></p>\n${l.example.blocks.map(block).join('\n')}</dd>`,
    `<dt>You need</dt><dd>${list(l.prereqs)}</dd>`,
    `<dt>Setup time</dt><dd><p>${l.setup_time === null ? 'Not measured yet.' : esc(l.setup_time)}</p></dd>`,
    `<dt>What it costs</dt><dd>${list(l.cost)}</dd>`,
    `<dt>Turn it off</dt><dd><p>${l.turn_off}</p></dd>`,
    `<dt>Who it is for</dt><dd><p>${esc(l.audience)}</p></dd>`,
    `<dt>Read more</dt><dd><p>${docs}</p></dd>`,
    '</dl>',
    '</div>',
    '</details>',
  ].join('\n');
}

function trail() {
  const bands = data.bands;
  const railLink = (l, cls) => `<li class="${cls}"><a href="#lvl-${l.n}"><span class="knot">${l.n}</span><span>${esc(l.title)}</span></a></li>`;
  const rail = bands.map((b) => [
    `<li class="band ${b.id}">${esc(b.name)}</li>`,
    ...data.levels.filter((l) => l.band === b.id).map((l) => railLink(l, b.id === 'camp' ? 'camp-l' : 'climb-l')),
  ].join('\n')).join('\n');
  const stepper = data.levels.map((l) => `<li class="${l.band === 'camp' ? 'camp-l' : 'climb-l'}"><a href="#lvl-${l.n}" aria-label="Level ${l.n}: ${esc(l.title)}">${l.n}</a></li>`).join('');
  const nCamp = data.levels.filter((l) => l.band === 'camp').length;
  const cards = bands.map((b) => [
    `<div class="bandhead ${b.id}"><span class="bn">${esc(b.name)}</span><h3>${esc(b.title)}</h3><p>${esc(b.lede)}</p></div>`,
    ...data.levels.filter((l) => l.band === b.id).map(level),
  ].join('\n')).join('\n');
  return [
    '<p class="legend"><span>No badge: shipped and supported</span><span><span class="badge b-beta">preview</span> works, still changing</span><span><span class="badge b-road">planned</span> not built yet</span></p>',
    '<p class="resume" id="resume" hidden></p>',
    '<div class="trail">',
    `<nav class="rail" aria-label="Levels"><ol>\n${rail}\n</ol></nav>`,
    `<nav class="stepper" aria-label="Levels"><ol>${stepper}</ol><div class="bands" aria-hidden="true" style="grid-template-columns:${nCamp}fr ${data.levels.length - nCamp}fr"><i></i><i></i></div></nav>`,
    `<div class="cards">\n${cards}\n</div>`,
    '</div>',
    '<div class="testing">',
    '<h3>Being tried out</h3>',
    `<ul>${data.experimental.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>`,
    '<p>Experiments, not on the trail yet. They join a level once they work for someone other than us.</p>',
    '</div>',
    '<figure class="placeholder" id="fleet-recording"><figcaption>Placeholder: a short recording of a fleet at work goes here. Not recorded yet.</figcaption></figure>',
    '<p class="trail-foot"><a href="getting-started/">Getting started</a><a href="setup/profiles/">Install profiles</a><a href="cadences/">Scheduled jobs</a><a href="orchestration-patterns/">Orchestration patterns</a></p>',
  ].join('\n');
}

const parts = {
  TOKENS: read('site/src/styles/tokens.css').trimEnd(),
  CSS: read('site/src/trail/trail.css').trimEnd(),
  JS: read('site/src/trail/trail.js').trimEnd(),
  MANIFEST_N: String(manifest.length),
  CORE_N: String(coreN),
  TRAIL: trail(),
};
const html = read('site/src/trail/page.html').replace(/\{\{([A-Z_]+)\}\}/g, (_, k) => {
  if (!(k in parts)) throw new Error(`page.html names an unknown part: ${k}`);
  return parts[k];
});

if (process.argv.includes('--check')) {
  let current = '';
  try { current = read(OUT); } catch { /* missing page counts as stale */ }
  if (current !== html) {
    console.error(`${OUT} is stale: run node site/src/trail/render.mjs`);
    process.exit(1);
  }
} else {
  writeFileSync(join(root, OUT), html);
  console.log(`wrote ${OUT}`);
}
