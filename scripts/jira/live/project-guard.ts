// HIMMEL-4642: the live suite's project guard, kept out of jira-live.test.ts so
// a default (non-live) run can unit-test it.
const PROJECT_KEY = /^[A-Z][A-Z0-9_]+$/;

export function assertLiveProject(project: string): void {
  if (project.toUpperCase() === 'HIMMEL') {
    throw new Error('JIRA_LIVE_PROJECT must name a dedicated test project, never HIMMEL');
  }
  if (!PROJECT_KEY.test(project)) {
    throw new Error(`JIRA_LIVE_PROJECT "${project}" is not a valid Jira project key (uppercase letters, digits, _)`);
  }
}
