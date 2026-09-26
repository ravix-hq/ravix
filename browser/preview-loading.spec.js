import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import AxeBuilder from '@axe-core/playwright';

// Exercise the production gateway template and its poll script without a
// production preview grant. Gateway tests cover rendering and access checks.
const template = readFileSync(new URL('../lib/ravix_web/preview_gateway/start.html.eex', import.meta.url), 'utf8');
const html = template
  .replace('<%= escape(back) %>', 'http://localhost:4103/home')
  .replace('<%= escape(label) %>', 'Starting the app… Waiting for it to answer on /health.');

test('standalone preview loads quietly, reveals diagnostics, fails visibly and redirects when ready', async ({ page }) => {
  let status = { state: 'starting', logs: '[stdout] app booting\n<script>window.injected=true</script>' };
  await page.route('http://preview.test/__ravix/start', route => route.fulfill({ contentType: 'text/html', body: html }));
  await page.route('http://preview.test/__ravix/status', route => route.fulfill({ json: status }));
  await page.route('http://preview.test/', route => route.fulfill({ contentType: 'text/html', body: '<h1>Ready app</h1>' }));
  await page.goto('http://preview.test/__ravix/start');
  await expect(page.getByRole('status')).toContainText('Waiting for it to answer on /health');
  await expect(page.locator('.loading-spinner')).toBeVisible();
  await expect(page.locator('#logs')).toHaveText(status.logs);
  await expect(page.locator('#logs')).not.toBeVisible();
  await page.getByText('Show logs', { exact: true }).click();
  await expect(page.locator('#logs')).toBeVisible();
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
  await page.getByText('Show logs', { exact: true }).click();

  status = { state: 'failed', error: 'App did not answer', logs: '[stderr] missing dependency' };
  await expect(page.getByRole('alert')).toHaveText('App did not answer');
  await expect(page.locator('#logs')).toBeVisible();
  await expect(page.locator('#logs')).toHaveText(status.logs);
  await expect(page.locator('.loading-spinner')).not.toBeVisible();
  const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(result.violations).toEqual([]);

  status = { state: 'ready', logs: '' };
  await page.goto('http://preview.test/__ravix/start');
  await expect(page).toHaveURL('http://preview.test/');
  await expect(page.getByRole('heading')).toHaveText('Ready app');
});
