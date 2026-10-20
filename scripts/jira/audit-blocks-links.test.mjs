import { describe, it, expect } from 'vitest';
import { collectBlocksRows, toTsv } from './audit-blocks-links.mjs';

const blocks = { name: 'Blocks', inward: 'is blocked by', outward: 'blocks' };
const issue = (key, summary, links = []) => ({ key, fields: { summary, issuelinks: links } });

describe('collectBlocksRows', () => {
  it('dedupes a link seen from both ends and reads blocker/blocked from inward/outward', () => {
    // A-1 blocks B-2: A-1's entry carries outwardIssue B-2, B-2's carries inwardIssue A-1.
    const issues = [
      issue('A-1', 'Ship feature', [{ id: '9', type: blocks, outwardIssue: { key: 'B-2' } }]),
      issue('B-2', 'Prereq', [{ id: '9', type: blocks, inwardIssue: { key: 'A-1' } }]),
    ];
    const rows = collectBlocksRows(issues);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ id: '9', blocker: 'A-1', blocked: 'B-2', proposal: 'keep' });
  });

  it('proposes a flip when the stored blocker text names the stored blocked ticket as its prerequisite', () => {
    const issues = [
      issue('A-1', 'Rollout, after B-2 lands', [{ id: '5', type: blocks, outwardIssue: { key: 'B-2' } }]),
      issue('B-2', 'Foundation'),
    ];
    expect(collectBlocksRows(issues)[0]).toMatchObject({ blocker: 'A-1', blocked: 'B-2', proposal: 'flip' });
  });

  it('ignores non-Blocks links and renders a TSV with a header', () => {
    const relates = { name: 'Relates', inward: 'relates to', outward: 'relates to' };
    const rows = collectBlocksRows([issue('A-1', 's', [{ id: '1', type: relates, outwardIssue: { key: 'B-2' } }])]);
    expect(rows).toEqual([]);
    expect(toTsv(rows).split('\n')[0]).toBe('link_id\tblocker\tblocker_summary\tblocked\tblocked_summary\tproposal\treason');
  });
});
