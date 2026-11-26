import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    setupFiles: ['./vitest.setup.ts'],
    globalSetup: ['./vitest.global-setup.ts'],
    env: { JIRA_EMAIL: 'test-user@example.invalid', JIRA_API_TOKEN: 'test-token-not-real' },
  },
});
