// Tracks what the live suite creates so an afterAll can undo it
// even when an assertion failed midway.
export interface Teardown {
  trackIssue(key: string): void;
  trackVersion(name: string): void;
  run(): string[];
}

export function createTeardown(ops: {
  closeIssue: (key: string) => void;
  archiveVersion: (name: string) => void;
}): Teardown {
  const issues: string[] = [];
  const versions: string[] = [];
  return {
    trackIssue: (key) => void issues.push(key),
    trackVersion: (name) => void versions.push(name),
    run() {
      const failures: string[] = [];
      const attempt = (what: string, fn: () => void) => {
        try {
          fn();
        } catch (e) {
          failures.push(`${what}: ${e instanceof Error ? e.message : String(e)}`);
        }
      };
      for (const key of issues) attempt(key, () => ops.closeIssue(key));
      for (const name of versions) attempt(name, () => ops.archiveVersion(name));
      return failures;
    },
  };
}
