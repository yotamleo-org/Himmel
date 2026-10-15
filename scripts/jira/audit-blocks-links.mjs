#!/usr/bin/env node
// scripts/jira/audit-blocks-links.mjs — READ-ONLY audit of Blocks links on open tickets.
//
// Prints a TSV of every Blocks link with a proposed flip. It only
// issues GETs; it never creates, deletes or edits a link. An operator approves
// the list before any flip is applied by hand (`unlink` then `link --blocks`).
//
// Usage: node audit-blocks-links.mjs [--project HIMMEL] [--jira-cli <dist/index.js>]
//
// Heuristic (ponytail: text match only, operator reviews every row; upgrade is
// a per-ticket read of the description): propose `flip` when the stored blocker's
// summary names the stored blocked key as its prerequisite
// ("after|requires|needs|depends on|follow-up to|blocked by <KEY>").

import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { isMain } from '../lib/is-main.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const HEADER = ['link_id', 'blocker', 'blocker_summary', 'blocked', 'blocked_summary', 'proposal', 'reason'];

function namesAsPrerequisite(text, key) {
  const k = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`\\b(after|requires?|needs?|depends? on|follow-?up (to|of)|blocked by)\\b[^\\n]{0,40}\\b${k}\\b`, 'i').test(text);
}

export function collectBlocksRows(issues) {
  const summaries = new Map(issues.map((i) => [i.key, i.fields?.summary ?? '']));
  const seen = new Set();
  const rows = [];
  for (const issue of issues) {
    for (const link of issue.fields?.issuelinks ?? []) {
      if (link.type?.name !== 'Blocks' || seen.has(link.id)) continue;
      seen.add(link.id);
      // Jira: the inward issue "is blocked by" the outward issue.
      const blocked = link.outwardIssue ? issue.key : link.inwardIssue?.key;
      const blocker = link.outwardIssue ? link.outwardIssue.key : issue.key;
      if (!blocked || !blocker) continue;
      const blockerSummary = summaries.get(blocker) ?? link.outwardIssue?.fields?.summary ?? '';
      const blockedSummary = summaries.get(blocked) ?? link.inwardIssue?.fields?.summary ?? '';
      const flip = namesAsPrerequisite(blockerSummary, blocked);
      rows.push({
        id: link.id, blocker, blockerSummary, blocked, blockedSummary,
        proposal: flip ? 'flip' : 'keep',
        reason: flip ? `${blocker} summary names ${blocked} as its prerequisite` : '',
      });
    }
  }
  return rows;
}

const cell = (v) => String(v ?? '').replace(/[\t\r\n]+/g, ' ');

export function toTsv(rows) {
  const lines = [HEADER.join('\t')];
  for (const r of rows) {
    lines.push([r.id, r.blocker, r.blockerSummary, r.blocked, r.blockedSummary, r.proposal, r.reason].map(cell).join('\t'));
  }
  return lines.join('\n');
}

async function loadOpenIssues({ request, project }) {
  const issues = [];
  let token;
  do {
    const q = new URLSearchParams({
      jql: `project = ${project} AND statusCategory != Done`,
      fields: 'summary,issuelinks',
      maxResults: '100',
    });
    if (token) q.set('nextPageToken', token);
    const page = await request('GET', `/search/jql?${q}`);
    issues.push(...(page.issues ?? []));
    token = page.nextPageToken;
  } while (token);
  return issues;
}

async function main() {
  const argv = process.argv.slice(2);
  const opt = (name, dflt) => {
    const i = argv.indexOf(name);
    return i >= 0 ? argv[i + 1] : dflt;
  };
  const project = opt('--project', process.env.JIRA_PROJECT_KEY);
  if (!project) {
    console.error('audit-blocks-links: --project or JIRA_PROJECT_KEY required');
    process.exit(2);
  }
  const jiraCli = opt('--jira-cli', join(HERE, 'dist', 'index.js'));
  const { request } = await import(pathToFileURL(join(dirname(jiraCli), 'client.js')).href);
  console.log(toTsv(collectBlocksRows(await loadOpenIssues({ request, project }))));
}

if (isMain(import.meta.url)) main();
