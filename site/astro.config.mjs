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

// Raw files that keep resolving at their docs/ paths: every allowlisted .md
// plus the install JSON files the setup pages link to.
const RAW_FILES = [
  ...ALLOW,
  'setup/settings-template.json',
  ...fs.readdirSync(path.join(DOCS, 'setup/profiles')).filter((f) => f.endsWith('.json')).map((f) => `setup/profiles/${f}`),
];

// Standalone HTML pages and raw files ship byte-identical at their docs/ paths.
const copyPassthrough = {
  name: 'copy-passthrough',
  hooks: {
    'astro:build:done': ({ dir }) => {
      for (const rel of [...HTML_PASSTHROUGH, ...RAW_FILES]) {
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
  // Starlight drops the .html from a sidebar link; this serves the trail at the extensionless path too.
  redirects: { '/adoption-trail': `${BASE}/adoption-trail.html` },
  markdown: { remarkPlugins: [[remarkDocs, { base: BASE, allow: ALLOW, html: HTML_PASSTHROUGH }]] },
  integrations: [
    starlight({
      title: 'Himmel',
      sidebar: [
        { label: 'Home', slug: '' },
        {
          label: 'Get started',
          items: [
            'why-himmel',
            { label: 'Adoption trail', link: '/adoption-trail.html' },
            { label: 'Quickstart (15 min)', slug: 'getting-started' },
            { label: 'Install on your project', slug: 'setup/install' },
            { label: 'Install profiles', slug: 'setup/profiles' },
            'setup/new-machine',
            { label: 'Updating & uninstalling', slug: 'setup/updating' },
            { label: 'Migrating an older install', slug: 'setup/migrating' },
          ],
        },
        {
          label: 'Use it',
          items: [
            { label: 'The daily loop', slug: 'daily-loop' },
            { label: 'Slash commands', slug: 'commands-catalog' },
            { label: 'himmelctl', slug: 'himmelctl' },
            { label: 'Configuration & gates', slug: 'configuration' },
            { label: 'Cadences (scheduled jobs)', slug: 'cadences' },
            { label: 'UI surfaces', slug: 'ui' },
            {
              label: 'Lanes & launchers',
              items: [
                { label: 'Launchers and lanes', slug: 'launchers' },
                { label: 'Running under Codex', slug: 'setup/codex' },
                { label: 'CLIProxyAPI codex lane', slug: 'setup/cli-proxy-lane' },
                { label: 'Hermes runbook', slug: 'hermes-runbook' },
              ],
            },
            { label: 'Cloud sessions', slug: 'setup/cloud-environment' },
            { label: 'Telegram bridge', slug: 'telegram-bridge' },
            {
              label: 'Second brain (luna)',
              items: [
                { label: 'Overview', slug: 'luna' },
                { label: 'Compounding loop', slug: 'luna/compounding' },
                { label: 'End-session wiki', slug: 'luna/end-session-wiki' },
                { label: 'Session note schema', slug: 'luna/end-session-wiki-schema' },
                { label: 'Google Health connector', slug: 'luna/google-health-connector-setup' },
                { label: 'PR-lane guard', slug: 'luna/pr-lane-guard' },
              ],
            },
            {
              label: 'Optional subsystems',
              items: [
                { label: 'Jarvis subsystems', slug: 'jarvis-subsystems' },
                { label: 'himmel-bus (early)', slug: 'himmel-bus' },
                { label: 'Voice (beta)', slug: 'voice' },
              ],
            },
            {
              label: 'Plugins',
              items: [
                { label: 'himmel-guard', link: 'https://github.com/yotamleo/himmel/tree/main/marketplace/plugins/himmel-guard' },
                { label: 'shadcn-mcp', link: 'https://github.com/yotamleo/himmel/tree/main/marketplace/plugins/shadcn-mcp' },
                { label: 'handover', link: 'https://github.com/yotamleo/himmel/tree/main/marketplace/plugins/handover' },
              ],
            },
          ],
        },
        {
          label: 'Run a fleet',
          items: [
            { label: 'Overnight mode', slug: 'handover/overnight-mode' },
            { label: 'Running a console', slug: 'handover/running-a-console' },
            { label: 'Handover system', slug: 'internals/handover-system' },
            { label: 'Orchestration patterns', slug: 'orchestration-patterns' },
            { label: 'Token economy', slug: 'token-economy' },
          ],
        },
        {
          label: 'Concepts',
          items: [
            { label: 'System design', slug: 'system-design' },
            { label: 'Architecture diagrams', slug: 'architecture' },
            { label: 'Context architecture', slug: 'internals/context-architecture' },
            { label: 'Glossary', slug: 'glossary' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Enforcement layers', slug: 'internals/enforcement' },
            { label: 'When a guardrail stops you', slug: 'internals/stuck-playbook' },
            { label: 'Data-egress matrix', slug: 'internals/egress-matrix' },
            { label: 'Harness compatibility (Codex)', slug: 'internals/harness-compat' },
            { label: 'Headless modes', slug: 'internals/headless-modes' },
            { label: 'Jira CLI and MCP', slug: 'internals/jira-plugin' },
            { label: 'Testing', slug: 'internals/testing' },
            { label: 'Environment gotchas', slug: 'internals/environment-gotchas' },
            { label: 'Lane calibration', slug: 'internals/lane-calibration' },
            { label: 'Lane parity', slug: 'internals/lane-parity' },
            { label: 'RETASK channel', slug: 'internals/retask-channel' },
            { label: 'Prompt cache', slug: 'internals/prompt-cache' },
            { label: 'Config layers', slug: 'internals/config-layers' },
            { label: 'MCP servers', slug: 'internals/mcp-servers' },
            { label: 'The ponytail convention', slug: 'internals/ponytail-convention' },
          ],
        },
        {
          label: 'Project',
          items: [
            { label: 'Contributing', slug: 'contributing' },
            {
              label: 'Security',
              items: [
                { label: 'Security review', slug: 'security-review' },
                { label: 'npm policy', slug: 'security/npm-policy' },
                { label: 'Python policy', slug: 'security/python-policy' },
              ],
            },
            {
              label: 'Tool adoption',
              items: [
                { label: 'Rubric', slug: 'tool-adoption/rubric' },
                { label: 'Registry', slug: 'tool-adoption/registry' },
                { label: 'Telemetry', slug: 'tool-adoption/telemetry' },
                { label: 'Lane adoption playbook', slug: 'tool-adoption/lane-adoption-playbook' },
              ],
            },
            {
              label: 'Evals',
              items: [
                { label: 'Prompt cache', slug: 'evals/prompt-cache' },
                { label: 'Review panel', slug: 'evals/review-panel' },
              ],
            },
            {
              label: 'Releases',
              items: [
                { label: 'v1.1.2 notes', slug: 'release/v1.1.2-notes' },
                { label: 'v1.0.0 notes', slug: 'release/v1.0.0-notes' },
                { label: 'Versioning scheme', slug: 'release/versioning-scheme' },
              ],
            },
            {
              label: 'Licenses',
              items: [
                { label: 'License audit', slug: 'license-audit' },
                { label: 'Third-party licenses', slug: 'third-party-licenses' },
              ],
            },
          ],
        },
      ],
    }),
    mermaid,
    copyPassthrough,
  ],
});
