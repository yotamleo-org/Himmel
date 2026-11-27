#!/usr/bin/env node
// Builds the three trail pages, each from layout.html and its own body
// template: docs/adoption-trail.html (hero.html), docs/adoption-trail-levels.html
// (levels.html, with the tracks and modules from levels.json and trail.js) and
// docs/adoption-trail-questions.html (questions.html). Each page is
// self-contained (no request to another file or host) because the docs site
// copies it through unchanged (HTML_PASSTHROUGH in site/astro.config.mjs).
//
// Usage: node site/src/trail/render.mjs           write the pages
//        node site/src/trail/render.mjs --check   exit 1 when a page differs
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');

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

const byId = new Map(data.modules.map((m) => [m.id, m]));
const inTrack = (t) => data.modules.filter((m) => m.track === t.id);

function closure(m) {
  const out = new Set();
  const todo = [...m.requires];
  while (todo.length) {
    const r = todo.pop();
    if (!byId.has(r)) throw new Error(`${m.id} requires an unknown module: ${r}`);
    if (!out.has(r)) { out.add(r); todo.push(...byId.get(r).requires); }
  }
  return out;
}

function trackNeeds(t) {
  const owners = new Set();
  for (const m of inTrack(t)) for (const r of closure(m)) owners.add(byId.get(r).track);
  return data.tracks.filter((x) => x.id !== t.id && owners.has(x.id));
}

function moduleCard(m, pos) {
  const counts = { beta: 0, roadmap: 0 };
  for (const c of m.components) if (c.status in counts) counts[c.status] += 1;
  const chips = [
    counts.beta ? `<span class="badge b-beta">${counts.beta} preview</span>` : '',
    counts.roadmap ? `<span class="badge b-road">${counts.roadmap} planned</span>` : '',
  ].join('');
  const list = (xs) => (xs.length ? `<ul>${xs.map((x) => `<li>${x}</li>`).join('')}</ul>` : '<p>Nothing beyond what its track needs.</p>');
  const docs = m.docs.map((d) => `<a href="${esc(d.href)}">${esc(d.label)}</a>`).join(' · ');
  return [
    `<details class="lvl trk-${m.track}" id="m-${m.id}" data-track="${m.track}">`,
    `<summary><span class="alias" id="lvl-${m.legacy_n}"></span><span class="lk">${pos}</span><span class="lt"><strong>${esc(m.title)}</strong><span>${m.summary}</span></span><span class="lc">${chips}</span></summary>`,
    '<div class="lvl-body">',
    `<p class="outcome">${m.outcome}</p>`,
    '<dl class="schema">',
    `<dt>Turn it on</dt><dd><p>${m.turn_on.charAt(0).toUpperCase()}${m.turn_on.slice(1)}</p></dd>`,
    `<dt>What you get</dt><dd><ul class="comps">\n${m.components.map(component).join('\n')}\n</ul></dd>`,
    `<dt>Try it</dt><dd class="example"><p><b>${esc(m.example.title)}</b></p>\n${m.example.blocks.map(block).join('\n')}</dd>`,
    `<dt>You need</dt><dd>${list(m.prereqs)}</dd>`,
    `<dt>Setup time</dt><dd><p>${m.setup_time === null ? 'Not measured yet.' : esc(m.setup_time)}</p></dd>`,
    `<dt>What it costs</dt><dd>${list(m.cost)}</dd>`,
    `<dt>Turn it off</dt><dd><p>${m.turn_off}</p></dd>`,
    `<dt>Who it is for</dt><dd><p>${esc(m.audience)}</p></dd>`,
    `<dt>Read more</dt><dd><p>${docs}</p></dd>`,
    '</dl>',
    '</div>',
    '</details>',
  ].join('\n');
}

function trail() {
  const rail = data.tracks.map((t) => [
    `<li class="band trk-${t.id}">${esc(t.name)}</li>`,
    ...inTrack(t).map((m, i) => `<li class="trk-${t.id}"><a href="#m-${m.id}"><span class="knot">${i + 1}</span><span>${esc(m.title)}</span></a></li>`),
  ].join('\n')).join('\n');
  const stepper = data.tracks.map((t) => `<li class="trk-${t.id}"><a href="#t-${t.id}" aria-label="${esc(t.name)}">${esc(t.short)}</a></li>`).join('');
  const cards = data.tracks.map((t) => {
    const needs = trackNeeds(t);
    return [
      `<div class="bandhead trk-${t.id}" id="t-${t.id}" data-needs="${needs.map((x) => x.id).join(' ')}"><span class="bn">${esc(t.name)}</span><h3>${esc(t.title)}</h3><p>${esc(t.lede)}</p><p class="needs">Needs: ${needs.length ? needs.map((x) => esc(x.name)).join(' and ') : 'nothing'}</p></div>`,
      ...inTrack(t).map((m, i) => moduleCard(m, i + 1)),
    ].join('\n');
  }).join('\n');
  return [
    '<p class="legend"><span>No badge: shipped and supported</span><span><span class="badge b-beta">preview</span> works, still changing</span><span><span class="badge b-road">planned</span> not built yet</span></p>',
    '<p class="resume" id="resume" hidden></p>',
    '<div class="trail">',
    `<nav class="rail" aria-label="Tracks"><ol>\n${rail}\n</ol></nav>`,
    `<nav class="stepper" aria-label="Tracks"><ol style="grid-template-columns:repeat(${data.tracks.length}, minmax(0, 1fr))">${stepper}</ol></nav>`,
    `<div class="cards">\n${cards}\n</div>`,
    '</div>',
    '<div class="testing">',
    '<h3>Being tried out</h3>',
    `<ul>${data.experimental.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>`,
    '<p>Experiments, not on the trail yet. They join a track once they work for someone other than us.</p>',
    '</div>',
    '<figure class="placeholder" id="fleet-recording"><figcaption>Placeholder: a short recording of a fleet at work goes here. Not recorded yet.</figcaption></figure>',
    '<p class="trail-foot"><a href="getting-started/">Getting started</a><a href="setup/profiles/">Install profiles</a><a href="cadences/">Scheduled jobs</a><a href="orchestration-patterns/">Orchestration patterns</a></p>',
  ].join('\n');
}

const fill = (name, parts) => read(`site/src/trail/${name}`).replace(/\{\{([A-Z_]+)\}\}/g, (_, k) => {
  if (!(k in parts)) throw new Error(`${name} names an unknown part: ${k}`);
  return parts[k];
});

const shared = {
  TOKENS: read('site/src/styles/tokens.css').trimEnd(),
  CSS: read('site/src/trail/trail.css').trimEnd(),
};
const PAGES = [
  {
    out: 'docs/adoption-trail.html',
    body: 'hero.html',
    title: 'Start here',
    description: 'What himmel is, what it installs on your machine and where, and how to undo it.',
    parts: {
      MANIFEST_N: String(manifest.length),
      CORE_N: String(coreN),
      FLOWS_SVG: read('docs/assets/flows.svg').trimEnd(),
    },
    // A link to a part of the trail that now lives on another page goes there.
    script: [
      '<script>',
      "var h = location.hash;",
      "if (/^#(trial|trial-h|trail|trail-h|resume|lvl-[0-9]+|m-[a-z-]+|t-[a-z]+|os-linux|os-mac|fleet-recording)$/.test(h)) location.replace('adoption-trail-levels.html' + h);",
      "else if (h === '#control' || h === '#control-h') location.replace('adoption-trail-questions.html#q-control');",
      '</script>',
    ].join('\n'),
  },
  {
    out: 'docs/adoption-trail-levels.html',
    body: 'levels.html',
    title: 'The adoption trail',
    description: 'A practice run on a spare project, then the Guarded Core and each track of himmel with its cost and its off switch.',
    parts: { TRAIL: trail() },
    script: `<script>\n${read('site/src/trail/trail.js').trimEnd()}\n</script>`,
  },
  {
    out: 'docs/adoption-trail-questions.html',
    body: 'questions.html',
    title: 'Questions and words',
    description: 'The questions people ask before they install himmel, and the words the trail uses.',
    parts: {},
  },
];

let stale = false;
for (const p of PAGES) {
  const html = fill('layout.html', {
    ...shared,
    TITLE: esc(p.title),
    DESCRIPTION: esc(p.description),
    BODY: fill(p.body, p.parts).trimEnd(),
    SCRIPT: p.script || '',
  });
  if (process.argv.includes('--check')) {
    let current = '';
    try { current = read(p.out); } catch { /* missing page counts as stale */ }
    if (current !== html) {
      console.error(`${p.out} is stale: run node site/src/trail/render.mjs`);
      stale = true;
    }
  } else {
    writeFileSync(join(root, p.out), html);
    console.log(`wrote ${p.out}`);
  }
}
if (stale) process.exit(1);
