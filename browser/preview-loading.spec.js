import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn, connectClaude } from './sign-in.js';
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


test('track logs stay open through status patches and failure still opens diagnostics', async ({ page }) => {
  await signIn(page, 'eli', '/home');
  // Its own agent: New project needs one, and relying on an earlier spec to
  // have connected it for this person breaks whenever sharding reorders them.
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill('Preview disclosure');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();

  const track = new URL(page.url()).pathname.split('/t/')[1];
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || !/^[a-f0-9-]{36}$/.test(track)) throw new Error('Invalid browser fixture');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  const quote = value => `'${value.replaceAll("'", "''")}'`;
  // Only the harness-owned database is changed. desired=stopped keeps the
  // reconciler from starting a machine while these display states are tested.
  const status = (state, logs) => {
    if (!['starting', 'failed'].includes(state)) throw new Error('Invalid preview state');
    const changed = execFileSync('psql', [`${server}/${database}`, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c',
      `UPDATE ravix.previews SET state = '${state}', desired = 'stopped', logs = ${quote(logs)}, error = ${state === 'failed' ? "'App failed'" : 'NULL'} WHERE track_id = '${track}' RETURNING track_id`
    ], { encoding: 'utf8' }).trim();
    expect(changed).toBe(track);
  };
  await page.locator('button[phx-click="panel"][phx-value-name="preview"]').click();
  const disclosure = page.locator('#preview-logs');
  const summary = disclosure.locator('summary');
  const logs = disclosure.locator('pre');
  const refresh = page.locator('button[phx-click="refresh-panel"]');
  await expect(disclosure).toBeAttached();

  for (const opener of ['summary', 'button']) {
    status('starting', `Before ${opener}`);
    await refresh.click();
    await expect(logs).toHaveText(`Before ${opener}`);
    await expect(disclosure).toHaveJSProperty('open', false);
    if (opener === 'summary') await summary.click();
    else await page.locator('button[phx-value-action="logs"]').click();
    await expect(logs).toBeVisible();

    status('starting', `After ${opener}`);
    await refresh.click();
    await expect(logs).toHaveText(`After ${opener}`);
    await expect(disclosure).toHaveJSProperty('open', true);
    await expect(logs).toBeVisible();
    await summary.click();
    await expect(logs).not.toBeVisible();
  }

  status('failed', 'Failure diagnostics');
  await refresh.click();
  await expect(page.getByRole('alert')).toContainText('App failed');
  await expect(logs).toHaveText('Failure diagnostics');
  await expect(disclosure).toHaveJSProperty('open', true);
  await expect(logs).toBeVisible();
});
