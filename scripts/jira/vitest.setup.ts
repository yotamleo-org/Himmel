import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Point HOME at an empty dir so the operator's real ~/.himmel/config.json
// (jira.sectorField) never leaks into a test.
process.env.HOME = mkdtempSync(join(tmpdir(), 'jira-test-home-'));
delete process.env.JIRA_SECTOR_FIELD;

// A marked live-test worker still runs these unit suites, whose fetches are mocked; guard tests set the
// marker themselves.
delete process.env.HIMMEL_JIRA_LIVE_TEST;

// A --backlog filing queues an INTAKE under a declared release: keep every test
// off the operator's real release state.
process.env.HIMMEL_RELEASE_STATE_DIR = mkdtempSync(join(tmpdir(), 'jira-test-release-'));
process.env.HIMMEL_ADMISSIONS_LEDGER = join(mkdtempSync(join(tmpdir(), 'jira-test-admissions-')), 'admissions-ledger.jsonl');

// An inherited config or handover root would point a test at the station's own files:
// replace both with empty temp dirs.
process.env.HIMMEL_CONFIG_DIR = mkdtempSync(join(tmpdir(), 'jira-test-conf-'));
process.env.HANDOVER_DIR = mkdtempSync(join(tmpdir(), 'jira-test-handover-'));

// authHeader() refuses a missing email or token up front, so every suite starts with
// dummy credentials and never the station's own; a test of the refusal unsets them itself.
process.env.JIRA_EMAIL = 'test-user@example.invalid';
process.env.JIRA_API_TOKEN = 'test-token-not-real';

// Keep every test off the real keyring; the resolver test turns it back on with a stub.
process.env.HIMMEL_SECRETS_KEYRING = "off";
