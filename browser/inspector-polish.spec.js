import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

// RAV-101: the inspector's Checks, Preview and toolbar, and the dock's
// Machine stats and "+". `SCREENSHOT_DIR` saves the review shots.
test.use({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });

const shoot = async (target, name) => {
  if (process.env.SCREENSHOT_DIR) await target.screenshot({ path: `${process.env.SCREENSHOT_DIR}/${name}.png` });
};

test('inspector and dock polish', async ({ page }) => {
  test.setTimeout(150_000);
  await signIn(page, 'inspectorpolish', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const dialog = page.getByRole('dialog', { name: 'New project', exact: true });
  await dialog.getByLabel('Project name', { exact: true }).fill('Atlas API');
  await expect(dialog.locator('#project-repositories option')).not.toHaveCount(0);
  await dialog.getByLabel('Repository', { exact: true }).fill('mockuser/atlas-api');
  await dialog.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page).toHaveURL(url => url.pathname.includes('/t/') && !url.search);
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 45_000 });
  const tabs = page.getByRole('navigation', { name: 'Inspector panels' });

  await tabs.getByRole('button', { name: 'Checks', exact: true }).click();
  await expect(page.locator('#git-uncommitted')).toBeVisible({ timeout: 15_000 });
  await page.waitForTimeout(1500);
  await shoot(page.locator('#inspector'), 'checks');

  await tabs.getByRole('button', { name: 'Preview', exact: true }).click();
  await page.waitForTimeout(1500);
  await shoot(page.locator('#inspector'), 'preview');

  await page.getByRole('button', { name: 'Machine stats', exact: true }).click();
  await page.waitForTimeout(2500);
  await shoot(page, 'machine-stats');
  await shoot(page.locator('#machine-dock'), 'machine-stats-dock');

  await page.getByRole('button', { name: 'Commands', exact: true }).click();
  await page.waitForTimeout(500);
  await shoot(page.locator('#machine-dock'), 'dock-commands');
});
