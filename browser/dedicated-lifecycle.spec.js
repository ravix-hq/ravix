import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn, connectClaude } from './sign-in.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

test('a flagged track copies secrets, becomes ready, and deletes its own machine and secrets on close', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Dedicated lifecycle');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.getByRole('navigation', { name: 'Project tracks', exact: true })
    .getByRole('button', { name: 'New track', exact: true }).click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('#track-machine-scope')).toHaveText('Own machine');
  await expect(page.locator('#track-setup-status')).toContainText('Prompts will wait until setup is ready.');
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });
  const trackId = new URL(page.url()).pathname.split('/t/')[1];
  const response = await request.get(`${mock}/api/vaults`);
  const copies = (await response.json()).data.filter(v => v.metadata?.ravix?.track === trackId);
  expect(copies).toHaveLength(1);
  const vaultId = copies[0].id;
  const boxes = (await (await request.get(`${mock}/api/sandboxes`)).json()).data;
  const box = boxes.find(b => b.vault_id === vaultId);
  expect(box).toBeTruthy();
  await page.getByRole('button', { name: 'Close track', exact: true }).click();
  const close = page.getByRole('dialog', { name: 'Close track', exact: true });
  await expect(close).toContainText('uncommitted changes and unpushed commits will be deleted');
  await close.getByLabel('Delete machine, uncommitted changes and unpushed commits', { exact: true }).check();
  await close.getByRole('button', { name: 'Close track', exact: true }).click();
  await expect(page.locator('#track-setup-status')).toContainText('Closing… cleaning up this track\'s machine');
  await expect.poll(async () => (await request.get(`${mock}/api/sandboxes/${box.id}`)).status(), { timeout: 30_000 }).toBe(404);
  await expect.poll(async () => (await request.get(`${mock}/api/vaults/${vaultId}`)).status()).toBe(404);
});


test('an owner confirms an uncertain secret change and can save again', async ({ page }) => {
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Secret change recovery');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectId = new URL(page.url()).pathname.split('/p/')[1];
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || !/^[a-f0-9-]{36}$/.test(projectId)) throw new Error('Invalid browser fixture');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  const sql = query => execFileSync('psql', [`${server}/${database}`, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c', query], { encoding: 'utf8' }).trim();
  // Persisted state after a provider timeout or worker loss. Only this harness's database.
  sql(`UPDATE ravix.projects SET secrets_pending = true, secrets_generation = 1 WHERE id = '${projectId}'`);
  await page.locator('.crumbs').getByRole('button', { name: 'Settings', exact: true }).click();
  const settings = page.getByRole('dialog', { name: 'Project settings', exact: true });
  await settings.getByRole('button', { name: 'Secrets', exact: true }).click();
  const confirmation = page.locator('#secret-confirmation-form');
  await expect(confirmation).toContainText('Values cannot be checked here');
  await confirmation.getByLabel('I confirmed the previous secret change has finished in Fountain.', { exact: true }).check();
  await confirmation.getByRole('button', { name: 'Confirm and unlock secret changes', exact: true }).click();
  await expect(confirmation).toHaveCount(0);
  expect(sql(`SELECT secrets_pending FROM ravix.projects WHERE id = '${projectId}'`)).toBe('f');
  await settings.getByLabel('Store', { exact: true }).selectOption('vault');
  await settings.getByLabel('Key', { exact: true }).fill('RECOVERY_TEST');
  await settings.getByLabel('Value', { exact: true }).fill('browser-fixture-only');
  await settings.getByRole('button', { name: 'Update secret', exact: true }).click();
  await expect(settings).toContainText('RECOVERY_TEST');
  expect(sql(`SELECT secrets_generation || ':' || secrets_pending FROM ravix.projects WHERE id = '${projectId}'`)).toBe('2:false');
});
