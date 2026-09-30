import { expect } from '@playwright/test';

// RAV-72: a project's settings are pages in the shell, one URL a section.
// The row's gear opens the first; the frame's nav moves between them.
export async function openProjectSettings(page, section = 'general') {
  await page.locator('#yard .workspace-project.current button[title="Project settings"]').click();
  await expect(page).toHaveURL(/\/p\/[^/]+\/settings\/general$/);
  const settings = page.locator('#settings-page');
  if (section !== 'general') {
    await settings.locator(`#settings-nav-${section}`).click();
    await expect(page).toHaveURL(new RegExp(`/settings/${section}$`));
  }
  await expect(settings.locator(`#settings-section-${section}`)).toBeVisible();
  return settings;
}

// "New workspace…" in the switcher's menu opens a small dialog; creating
// goes to the new workspace's Members (RAV-72).
export async function createWorkspace(page, name) {
  const menu = page.locator('#workspace-menu');
  if (!(await menu.evaluate(el => el.matches(':popover-open')))) {
    await page.locator('#workspace-switcher-trigger').click();
  }
  await menu.getByRole('button', { name: 'New workspace…', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'New workspace', exact: true });
  await dialog.getByLabel('Name', { exact: true }).fill(name);
  await dialog.getByRole('button', { name: 'Create workspace', exact: true }).click();
  await expect(page).toHaveURL(/\/w\/[^/?]+\/settings\/members$/);
  await expect(dialog).toHaveCount(0);
}

// The workspace a settings page is for, as its breadcrumb names it.
export const breadcrumb = page => page.getByRole('navigation', { name: 'Breadcrumb' });
