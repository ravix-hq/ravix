import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './browser',
  timeout: 60_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  forbidOnly: !!process.env.CI,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    ...devices['Desktop Chrome'],
    baseURL: `http://localhost:${process.env.BROWSER_PORT || 4103}`,
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
