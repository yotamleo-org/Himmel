import type { Command } from 'commander';
import { stationJiraBaseUrl } from '../env-file.js';
import { liveTestContext, resolveTestProject, testProjectConfigDir } from '../live-test-guard.js';

// The read-only answer every other surface (setter, doctor, gen-briefs, live suite, guest_exec) asks.
export function registerLiveTest(program: Command): void {
  program
    .command('live-test')
    .description('Print the live-test context and the configured Jira test project (read only)')
    .option('--json', 'Print JSON (the only output form)')
    .option('--candidate <key>', 'Validate this key as the test project instead of JIRA_TEST_PROJECT')
    .action((options: { json?: boolean; candidate?: string }) => {
      const ctx = liveTestContext();
      const dir = testProjectConfigDir();
      const resolved = dir
        ? resolveTestProject(dir, options.candidate)
        : { testProject: null, problem: 'the live-test config dir could not be read from the marked claude ancestor' };
      const out = {
        context: ctx.set,
        own_keys: ctx.ownKeys,
        test_project: resolved.testProject,
        problem: resolved.problem,
        jira_configured: dir !== null && stationJiraBaseUrl(dir, { profileFromEnv: false }) !== null,
      };
      process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
    });
}
