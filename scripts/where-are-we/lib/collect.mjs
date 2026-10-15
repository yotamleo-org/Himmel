// scripts/where-are-we/lib/collect.mjs
import { branchToKey } from './query.mjs';

/**
 * Normalize a Jira status string to lowercase-hyphenated form.
 * e.g. 'In Progress' → 'in-progress', 'To Do' → 'to-do'
 *
 * @param {string} s
 * @returns {string}
 */
export function normalizeJiraStatus(s) {
  return s.toLowerCase().replace(/\s+/g, '-');
}

/**
 * Map raw Jira rows to ledger records.
 * Only emits the fields authoritative for source='jira', kind='ticket': status.
 *
 * @param {Array<{key: string, status: string}>} rows
 * @param {string} now  ISO timestamp string
 * @returns {object[]}
 */
export function jiraRecords(rows, now) {
  return rows.map((row) => ({
    ts: now,
    source: 'jira',
    key: row.key,
    kind: 'ticket',
    status: normalizeJiraStatus(row.status),
  }));
}

const GREEN_CONCLUSIONS = new Set(['SUCCESS', 'NEUTRAL', 'SKIPPED']);

// A rollup entry is green when it is a completed CheckRun with a passing
// conclusion, or a StatusContext in SUCCESS. Anything pending/failed is not.
function checkIsGreen(c) {
  if (c.state !== undefined) return c.state === 'SUCCESS';
  return c.status === 'COMPLETED' && GREEN_CONCLUSIONS.has(c.conclusion);
}

// Open, conflict-free, merge-state CLEAN, with at least one check and all green.
function isGreenMergeable(pr) {
  return String(pr.state).toUpperCase() === 'OPEN'
    && pr.mergeable === 'MERGEABLE'
    && pr.mergeStateStatus === 'CLEAN'
    && Array.isArray(pr.statusCheckRollup)
    && pr.statusCheckRollup.length > 0
    && pr.statusCheckRollup.every(checkIsGreen);
}

/**
 * Map raw GitHub PR objects to ledger records.
 * Emits fields authoritative for source='pr', kind='pr': status, branch. When the
 * reader supplied merge data (`mergeable` present) it also emits awaiting_operator:
 * one entry for a green + mergeable open PR, an explicit [] otherwise so a PR that
 * went red, conflicted or merged drops out of the digest.
 *
 * @param {Array<{number: number, state: string, headRefName: string, title?: string,
 *   mergeable?: string, mergeStateStatus?: string, statusCheckRollup?: object[]}>} prs
 * @param {string} now  ISO timestamp string
 * @returns {object[]}
 */
export function prRecords(prs, now) {
  return prs.map((pr) => {
    const rec = {
      ts: now,
      source: 'pr',
      key: `#${pr.number}`,
      kind: 'pr',
      status: pr.state.toLowerCase(),
      branch: pr.headRefName,
    };
    if (pr.mergeable !== undefined) {
      rec.awaiting_operator = isGreenMergeable(pr)
        ? [`green + mergeable: ${pr.title ?? pr.headRefName}`]
        : [];
    }
    return rec;
  });
}

/**
 * Parse `git worktree list --porcelain` output into ledger records.
 * Only emits records for LOCKED worktrees whose branch resolves to a ticket key.
 * Emits source='git', kind='ticket', with the 'lock' field (always authoritative).
 *
 * @param {string} porcelain  raw multi-line text from git worktree list --porcelain
 * @param {string} now        ISO timestamp string
 * @returns {object[]}
 */
export function gitRecords(porcelain, now) {
  if (!porcelain) return [];

  const blocks = porcelain.split(/\n\s*\n/);
  const records = [];

  for (const block of blocks) {
    const lines = block.trim().split('\n');
    if (lines.length === 0 || !lines[0]) continue;

    let branchLine = null;
    let lockLine = null;
    let isLocked = false;

    for (const line of lines) {
      if (line.startsWith('branch ')) {
        branchLine = line.slice('branch '.length).trim();
      } else if (line === 'locked' || line.startsWith('locked ')) {
        isLocked = true;
        lockLine = line;
      }
    }

    if (!isLocked) continue;

    // Strip refs/heads/ prefix before calling branchToKey (it is ^-anchored)
    const branchName = branchLine
      ? branchLine.replace(/^refs\/heads\//, '')
      : null;

    const key = branchName ? branchToKey(branchName) : null;
    if (!key) continue;

    // Parse lock reason: 'locked' alone → fallback text; 'locked <reason>' → reason
    let lock;
    if (lockLine === 'locked') {
      lock = 'worktree locked';
    } else {
      lock = lockLine.slice('locked '.length);
    }

    records.push({ ts: now, source: 'git', key, kind: 'ticket', lock });
  }

  return records;
}
