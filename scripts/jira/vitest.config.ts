import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    setupFiles: ['./vitest.setup.ts'],
    // Here, not in vitest.setup.ts: the root bunfig preloads that file into every bun suite, and a credential there
    // leaks into the config-ui tests that assert the keyring is the only holder.
    env: { JIRA_EMAIL: 'test-user@example.invalid', JIRA_API_TOKEN: 'test-token-not-real' },
  },
});
