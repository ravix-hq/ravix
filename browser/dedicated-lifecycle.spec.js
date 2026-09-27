import { test, expect } from '@playwright/test';
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
