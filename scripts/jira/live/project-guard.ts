import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const PROJECT_KEY = /^[A-Z][A-Z0-9_]+$/;

export function assertLiveProject(project: string, configured: string): void {
  if (!PROJECT_KEY.test(project)) {
    throw new Error(`JIRA_LIVE_PROJECT "${project}" is not a valid Jira project key (uppercase letters, digits, _)`);
  }
  if (project !== configured) {
    throw new Error(`the live suite writes only to the configured test project ${configured}, not ${project}`);
  }
}

// The station's config dir, read before vitest.setup.ts redirects HOME and HIMMEL_CONFIG_DIR; nothing outside a live run.
export function recordLiveConfigDir(env: NodeJS.ProcessEnv, passwdHome: string): string | undefined {
  if (env.JIRA_LIVE_TEST !== '1') return undefined;
  return env.HIMMEL_CONFIG_DIR || join(passwdHome, '.himmel');
}

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

// Runs the shipped Jira CLI as a live child: the guarded env, the station's config dir and the resolved test project.
export function runJira(cli: string, configDir: string, project: string, ...args: string[]): string {
  return execFileSync('node', [cli, ...args], {
    encoding: 'utf8',
    env: liveChildEnv(process.env, project, configDir),
  });
}

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

export const liveVersionName = (stamp: string): string => `v0.0.0-live.${stamp}`;

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

## Proof
The live suite passes against the test project.

## Agent detail
scripts/jira/live/jira-live.test.ts
`;
