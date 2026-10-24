import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Point HOME at an empty dir so the operator's real ~/.himmel/config.json
// (jira.sectorField) never leaks into a test.
process.env.HOME = mkdtempSync(join(tmpdir(), 'jira-test-home-'));
delete process.env.JIRA_SECTOR_FIELD;

// A --backlog filing queues an INTAKE under a declared release: keep every test
// off the operator's real release state.
process.env.HIMMEL_RELEASE_STATE_DIR = mkdtempSync(join(tmpdir(), 'jira-test-release-'));
process.env.HIMMEL_ADMISSIONS_LEDGER = join(mkdtempSync(join(tmpdir(), 'jira-test-admissions-')), 'admissions-ledger.jsonl');
