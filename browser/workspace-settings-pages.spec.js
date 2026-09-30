import { test, expect } from '@playwright/test';
import { signIn } from './sign-in.js';
import { createWorkspace, breadcrumb } from './settings.js';

// RAV-73: a workspace's settings pages. The role chosen for an invitation
// is the one granted, even when the username's suggestions redraw the form
// after it was chosen; and a member leaves from the Danger zone, which the
// owner's open Members page follows.
// Runs under `bun run test:browser:workspace-access`, with the switch on.
test('invite an admin, then that admin leaves from the Danger zone', async ({ page, browser }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  test.setTimeout(120_000);

  // Somebody who has signed in joins at once.
  const context = await browser.newContext();
  try {
    const mate = await context.newPage();
    await signIn(mate, 'escaper', '/home');

    await signIn(page, 'mentioner', '/home');
    await createWorkspace(page, 'Leave Team');
    const base = new URL(page.url()).pathname.replace(/\/settings\/members$/, '');
    await expect(page.locator('#workspace-roles')).toContainText('Invites and removes members');

    // Admin is chosen before the debounced suggestion answers and redraws.
    await page.getByLabel('GitHub username', { exact: true }).fill('escaper');
    await page.locator('#workspace-invite-role').selectOption('admin');
    await page.waitForTimeout(400);
    await expect(page.locator('#workspace-invite-role')).toHaveValue('admin');
    await page.getByRole('button', { name: 'Invite', exact: true }).click();
    await expect(page.getByLabel('Role of @escaper', { exact: true })).toHaveValue('admin');

    // Each section is its own page on the frame.
    for (const [key, title] of [['repositories', 'Repositories'], ['projects', 'Projects'], ['danger', 'Danger zone']]) {
      await page.locator(`#settings-nav-${key}`).click();
      await expect(page).toHaveURL(new RegExp(`${base}/settings/${key}$`));
      await expect(page.getByRole('heading', { level: 1 })).toHaveText(title);
    }
    await page.locator('#settings-nav-members').click();
    await expect(page.locator('#workspace-members')).toContainText('@escaper');

    // The admin leaves; they are not offered the delete.
    await mate.goto(`${base}/settings/danger`);
    await expect(mate.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await expect(breadcrumb(mate)).toContainText('Leave Team');
    await expect(mate.locator('#delete-workspace-form')).toHaveCount(0);
    mate.once('dialog', dialog => dialog.accept());
    await mate.getByRole('button', { name: 'Leave Leave Team', exact: true }).click();
    await expect(mate).toHaveURL(/\/home$/);
    await expect(mate.getByText('You left Leave Team.')).toBeVisible();

    // The owner's open page followed.
    await expect(page.locator('#workspace-members')).not.toContainText('@escaper');
  } finally {
    await context.close();
  }
});
