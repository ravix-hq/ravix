import { test, expect } from '@playwright/test';
import { signIn } from './sign-in.js';

// ADR 0009 phase 4a: create a team workspace from the sidebar switcher,
// invite somebody who has not signed in yet by GitHub login, switch between
// workspaces, and the invitation accepted at the invitee's first sign-in.
// Runs under `bun run test:browser:workspace-access`, which starts the
// harness with RAVIX_WORKSPACE_ACCESS on; the default run leaves it off.
test('create a team workspace, invite by login, and switch', async ({ page, browser }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  test.setTimeout(120_000);
  await signIn(page, 'teamowner', '/home');

  // Which workspace is current depends on the teams other specs put this
  // login in, so only the menu is asked about.
  const trigger = page.locator('#workspace-switcher-trigger');
  await trigger.click();
  await expect(page.locator('#workspace-menu')).toContainText('teamowner');
  const menu = page.locator('#workspace-menu');
  await expect(menu).toBeVisible();
  await menu.getByLabel('New workspace', { exact: true }).fill('Acme Team');
  await menu.getByRole('button', { name: 'Create workspace', exact: true }).click();

  await expect(page).toHaveURL(/\/w\/[^/]+$/);
  const teamPath = new URL(page.url()).pathname;
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Acme Team');
  await expect(page.locator('#workspace-members')).toContainText('@teamowner');

  await page.getByLabel('GitHub username', { exact: true }).fill('teammate');
  await page.getByRole('button', { name: 'Invite', exact: true }).click();
  await expect(page.locator('#workspace-invites')).toContainText('@teammate');
  await expect(page.locator('#workspace-invites')).toContainText('waiting to sign in');

  // Switch to the personal workspace, whose settings its menu opens, and back.
  await page.locator('#workspace-switcher-trigger').click();
  await page.locator('#workspace-menu').getByRole('button', { name: /teamowner/ }).click();
  await expect(page).toHaveURL(/\/home$/);
  await page.locator('#workspace-switcher-trigger').click();
  await page.getByRole('link', { name: 'Settings and members of teamowner', exact: true }).click();
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('teamowner');
  await expect(page.locator('#workspace-invite-form')).toHaveCount(0);
  await page.locator('#workspace-switcher-trigger').click();
  await page.locator('#workspace-menu').getByRole('button', { name: /Acme Team/ }).click();
  await expect(page).toHaveURL(/\/home$/);
  await page.locator('#workspace-switcher-trigger').click();
  await page.getByRole('link', { name: 'Settings and members of Acme Team', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`${teamPath}$`));
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Acme Team');

  // The invitee's first sign-in accepts the invitation.
  const context = await browser.newContext();
  try {
    const mate = await context.newPage();
    await signIn(mate, 'teammate', '/home');
    await mate.locator('#workspace-switcher-trigger').click();
    await mate.locator('#workspace-menu').getByRole('button', { name: /Acme Team/ }).click();
    await mate.locator('#workspace-switcher-trigger').click();
    await mate.getByRole('link', { name: 'Settings and members of Acme Team', exact: true }).click();
    await expect(mate.getByRole('heading', { level: 1 })).toHaveText('Acme Team');
    await expect(mate.locator('#workspace-members')).toContainText('@teammate');
    await expect(mate.locator('#workspace-invite-form')).toHaveCount(0);
  } finally {
    await context.close();
  }

  // The owner's open page followed the acceptance.
  await expect(page.locator('#workspace-members')).toContainText('@teammate');
  await expect(page.locator('#workspace-invites')).not.toContainText('@teammate');
});
