// The live suite's project guard and child-process helpers, kept out of jira-live.test.ts so
// a default (non-live) run can unit-test them.
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const PROJECT_KEY = /^[A-Z][A-Z0-9_]+$/;

/** The one project the suite may write to: a valid key that equals the configured test project. */
export function assertLiveProject(project: string, configured: string): void {
  if (!PROJECT_KEY.test(project)) {
    throw new Error(`JIRA_LIVE_PROJECT "${project}" is not a valid Jira project key (uppercase letters, digits, _)`);
  }
  if (project !== configured) {
    throw new Error(`the live suite writes only to the configured test project ${configured}, not ${project}`);
  }
}

/** Under JIRA_LIVE_TEST=1, record the config dir the CLI would read as JIRA_LIVE_CONFIG_DIR: call before HOME and HIMMEL_CONFIG_DIR are redirected. */
export function recordLiveConfigDir(env: NodeJS.ProcessEnv): void {
  if (env.JIRA_LIVE_TEST !== '1') return;
  env.JIRA_LIVE_CONFIG_DIR = env.HIMMEL_CONFIG_DIR || join(env.HOME || homedir(), '.himmel');
}

/** The env a live child runs in: marker none, the station config dir, the project, and no test-runner signal. */
export function liveChildEnv(base: NodeJS.ProcessEnv, project: string, configDir: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    ...base,
    HIMMEL_JIRA_LIVE_TEST: 'none',
    HIMMEL_CONFIG_DIR: configDir,
    JIRA_PROJECT_KEY: project,
  };
  delete env.VITEST;
  delete env.NODE_ENV;
  return env;
}

/** Ask the `jira live-test` verb for the configured test project; throw when there is none or the override differs. */
export function resolveLiveProject(configDir: string, cli: string): string {
  const out = execFileSync('node', [cli, 'live-test', '--json'], {
    encoding: 'utf8',
    env: liveChildEnv(process.env, '', configDir),
  });
  const { test_project: testProject, problem } = JSON.parse(out) as { test_project: string | null; problem: string | null };
  if (!testProject) {
    throw new Error(`no Jira test project is configured for the live suite: ${problem ?? 'unknown'}. Run: himmelctl config set jira.testProject <KEY>`);
  }
  const override = process.env.JIRA_LIVE_PROJECT;
  if (override) assertLiveProject(override, testProject);
  return testProject;
}

/** A semver pre-release name, so the version passes checkVersionName. */
export const liveVersionName = (stamp: string): string => `v0.0.0-live.${stamp}`;

/** The six plain-block sections a create requires. */
export const LIVE_BODY = `## Impact
Nobody: this is a live test issue in the Jira test project.

## What
A throwaway issue the live suite creates and closes.

## Why
The live suite proves each CLI write really changes the field.

## Plan
1. Create the issue, edit it, read each change back, close it.

## DoD
- The live suite reads back every field it wrote.

## Agent detail
scripts/jira/live/jira-live.test.ts
`;
