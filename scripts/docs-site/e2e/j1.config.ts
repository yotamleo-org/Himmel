// Journey J1 against `astro preview` of a built site/dist. Needs @playwright/test 1.64.1 resolvable from here
// (pages.yml links scripts/config-ui/tests/e2e/node_modules in) and a prior `npm run build` in site/.
import { defineConfig } from "@playwright/test";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PORT = 4331;

export default defineConfig({
  testDir: ".",
  // not *.spec.ts: `bun test` would pick that up and choke on @playwright/test
  testMatch: "*.e2e.ts",
  workers: 1,
  fullyParallel: false,
  retries: 0,
  timeout: 60_000,
  reporter: [["list"]],
  outputDir: join(tmpdir(), "docs-site-j1-results"),
  use: { headless: true, baseURL: `http://127.0.0.1:${PORT}` },
  webServer: {
    command: `node node_modules/astro/bin/astro.mjs preview --ignore-lock --host 127.0.0.1 --port ${PORT}`,
    cwd: "../../../site",
    url: `http://127.0.0.1:${PORT}/Himmel/`,
    reuseExistingServer: false,
    timeout: 60_000,
  },
});
