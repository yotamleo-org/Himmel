import { execFileSync } from 'node:child_process';
import { liveChildEnv } from './project-guard.js';

// Runs the shipped Jira CLI as a live child: the guarded env, the station's config dir and the resolved test project.
export function runJira(cli: string, configDir: string, project: string, ...args: string[]): string {
  return execFileSync('node', [cli, ...args], {
    encoding: 'utf8',
    env: liveChildEnv(process.env, project, configDir),
  });
}
