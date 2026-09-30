import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './browser',
  timeout: 60_000,
  expect: { timeout: 15_000 },
  // One worker per app: tests share its database and provider mock, so a
  // run is serial. `fullyParallel` only lets `--shard` split by test rather
  // than by file; CI runs each shard against its own app (see ci.yml).
  fullyParallel: true,
  workers: 1,
  retries: 0,
  forbidOnly: !!process.env.CI,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    ...devices['Desktop Chrome'],
    // BROWSER_HOST is a loopback name under `.localhost`; see browser/server.py.
    baseURL: `http://${process.env.BROWSER_HOST || 'localhost'}:${process.env.BROWSER_PORT || 4103}`,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  webServer: {
    command: 'python3 browser/server.py',
    url: `http://localhost:${process.env.BROWSER_PORT || 4103}/healthz`,
    reuseExistingServer: false,
    timeout: 120_000,
    gracefulShutdown: { signal: 'SIGTERM', timeout: 30_000 },
  },
});
