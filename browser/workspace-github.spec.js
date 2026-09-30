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

// RAV-69: an owner whose GitHub App installation the workspace does not use
// yet is offered it in the empty state, and one click connects it, without
// a round trip to GitHub's install page.
test('add one of your GitHub accounts to a workspace from its empty state', async ({ page }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  test.setTimeout(120_000);
  await signIn(page, 'addowner', '/home');
  await connectClaude(page);
  await page.goto('/home');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);

  await page.locator('#workspace-switcher-trigger').click();
  const menu = page.locator('#workspace-menu');
  await menu.getByLabel('New workspace', { exact: true }).fill('Add Team');
  await menu.getByRole('button', { name: 'Create workspace', exact: true }).click();
  await expect(page).toHaveURL(/\/w\/[^/?]+$/);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);

  await expect(page.locator('#github-empty')).toContainText('No GitHub account is connected yet.');
  const offered = page.locator('#available-installations li', { hasText: '@mockuser' });
  await offered.getByRole('button', { name: /^Add @mockuser to Add Team$/ }).click();

  await expect(page.locator('#workspace-installations li[data-status=active]')).toContainText('@mockuser');
  await expect(page.locator('#github-empty')).toHaveCount(0);
  await expect(page.locator('#available-installations')).toHaveCount(0);
  await expect(page.locator('#workspace-catalog')).toContainText('mockuser/atlas-api');
  expect(new URL(page.url()).pathname).toMatch(/^\/w\/[^/]+$/);
});
