import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn } from './sign-in.js';
import { breadcrumb, createWorkspace } from './settings.js';

// RAV-72, end to end on one page: a workspace's General, the first page on
// the frame's one-Save model. Typing shows the "Unsaved changes · Discard /
// Save" bar; leaving by a link, by the switcher or by closing the tab asks
// first; Discard and Save each end it. Needs RAVIX_WORKSPACE_ACCESS.
test('workspace General: the unsaved-changes bar, the leave confirmation, Discard and Save', async ({ page }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  test.setTimeout(120_000);
  await signIn(page, 'mentioner', '/home');
  await createWorkspace(page, 'Frame Team');
  const members = new URL(page.url()).pathname;
  const general = members.replace(/members$/, 'general');
  await expect(page).toHaveTitle('Members · Frame Team · Ravix');
  await expect(breadcrumb(page)).toHaveText(/Frame Team\s*›?\s*Settings\s*›?\s*Members/);
  await expect(page.locator('#settings-nav-members .settings-count')).toHaveText('1');
  await expect(page.locator('#yard')).toBeVisible();

  await page.locator('#settings-nav-general').click();
  await expect(page).toHaveURL(new RegExp(`${general}$`));
  const bar = page.getByRole('region', { name: 'Unsaved changes' });
  const leave = page.getByRole('alertdialog', { name: 'Leave without saving?' });
  const name = page.getByLabel('Name', { exact: true });
  await expect(bar).toBeHidden();
  await expect(page.locator('#workspace-kind')).toHaveText('Team workspace');

  // Typing shows the bar; Discard puts the saved name back.
  await name.fill('Frame Team draft');
  await expect(bar).toBeVisible();
  await expect(bar).toContainText('Unsaved changes');
  const accessibility = await new AxeBuilder({ page }).include('#settings-page')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(accessibility.violations).toEqual([]);
  await bar.getByRole('button', { name: 'Discard', exact: true }).click();
  await expect(bar).toBeHidden();
  await expect(name).toHaveValue('Frame Team');

  // Leaving by a patch link asks, in the page; Keep editing stays.
  const nativeDialogs = [];
  page.on('dialog', async dialog => { nativeDialogs.push(dialog.type()); await dialog.dismiss(); });
  await name.fill('Frame Labs');
  await page.locator('#settings-nav-members').click();
  await expect(leave).toBeVisible();
  await expect(leave.getByRole('button', { name: 'Keep editing', exact: true })).toBeFocused();
  await leave.getByRole('button', { name: 'Keep editing', exact: true }).click();
  await expect(leave).toBeHidden();
  await expect(page).toHaveURL(new RegExp(`${general}$`));
  await expect(name).toHaveValue('Frame Labs');

  // So does the switcher, and Escape keeps editing too.
  await page.locator('#workspace-switcher-trigger').click();
  await page.locator('#workspace-menu').getByRole('button', { name: /mentioner/ }).click();
  await expect(leave).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(leave).toBeHidden();
  await expect(page).toHaveURL(new RegExp(`${general}$`));
  expect(nativeDialogs).toEqual([]);

  // Closing or reloading the tab is the browser's own question.
  const unload = page.waitForEvent('dialog');
  page.reload().catch(() => {});
  expect((await unload).type()).toBe('beforeunload');
  await expect(name).toHaveValue('Frame Labs');

  // Save ends it: the bar goes, and the switcher and the title follow.
  await bar.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(bar).toBeHidden();
  await expect(page.getByText('Workspace renamed.', { exact: true })).toBeVisible();
  await expect(page.locator('#workspace-switcher-trigger')).toContainText('Frame Labs');
  await expect(page).toHaveTitle('General · Frame Labs · Ravix');

  // Nothing unsaved: leaving does not ask. Discard and leave follows the link.
  await page.locator('#settings-nav-members').click();
  await expect(page).toHaveURL(new RegExp(`${members}$`));
  await page.goBack();
  await expect(page).toHaveURL(new RegExp(`${general}$`));
  await name.fill('Never saved');
  await page.locator('#settings-nav-members').click();
  await leave.getByRole('button', { name: 'Discard and leave', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`${members}$`));
  await page.locator('#settings-nav-general').click();
  await expect(name).toHaveValue('Frame Labs');
});
