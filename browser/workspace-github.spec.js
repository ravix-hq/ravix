import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

// ADR 0009 phase 4b: connect GitHub to a workspace through the install
// round trip, see the workspace's repository catalog, add a repository as
// the workspace's project, and find the same project when it is added again.
// Runs under `bun run test:browser:workspace-access`, with the switch on.
test('connect GitHub to a workspace, add a repository, and re-add it', async ({ page }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  test.setTimeout(120_000);
  await signIn(page, 'teamowner', '/home');
  await connectClaude(page);
  await page.goto('/home');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);

  await page.locator('#workspace-switcher-trigger').click();
  const menu = page.locator('#workspace-menu');
  await menu.getByLabel('New workspace', { exact: true }).fill('Repo Team');
  await menu.getByRole('button', { name: 'Create workspace', exact: true }).click();
  await expect(page).toHaveURL(/\/w\/[^/?]+$/);
  const workspacePath = new URL(page.url()).pathname;

  // To GitHub's install page and straight back through the callback.
  await page.getByRole('link', { name: 'Connect GitHub', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`${workspacePath}\\?github=connected$`));
  await expect(page.locator('#workspace-installations')).toContainText('@mockuser');
  const catalog = page.locator('#workspace-catalog');
  await expect(catalog).toContainText('mockuser/atlas-api');

  const row = catalog.locator('li', { hasText: 'mockuser/ledger' });
  await row.getByRole('button', { name: 'Add', exact: true }).click();
  await expect(page).toHaveURL(/\/p\/[^/]+$/);
  const projectPath = new URL(page.url()).pathname;

  // Re-adding leads to the same project rather than a second one.
  await page.goto(workspacePath);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  const again = page.locator('#workspace-catalog li', { hasText: 'mockuser/ledger' });
  await again.getByRole('link', { name: 'Open project', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`${projectPath}$`));
});
