// A vitest run from the repo root must never reach the operator's real HOME.
// Reuse the scripts/jira sandbox (temp HOME, release state, admissions ledger, keyring off)
// so a root run is as hermetic as a run from scripts/jira.
// A plain object, not defineConfig: the root has no node_modules, so `npx vitest` fetches
// vitest into a cache where `import 'vitest/config'` would not resolve and the run would die
// before any test (a vacuous "canary survived").
export default {
  test: {
    environment: 'node',
    setupFiles: ['./scripts/jira/vitest.setup.ts'],
  },
};
