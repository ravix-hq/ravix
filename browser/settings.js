import { expect } from '@playwright/test';

// RAV-72: a project's settings are pages in the shell, one URL a section.
// The row's gear opens the first; the frame's nav moves between them.
// RAV-74: the pages are general, access, agent, machine and danger.
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

// RAV-74: the Machine page's one save. The bar's Save asks first, listing
// what changes (`expectLines`) and how many tracks a rebuild closes; its
// confirmation is the save. Answers the question's text.
export async function saveMachine(page, expectLines = []) {
  const bar = page.locator('#project-machine-bar');
  await bar.getByRole('button', { name: /^Save/ }).click();
  const review = page.locator('#machine-review [role=alertdialog]');
  await expect(review).toBeVisible();
  for (const line of expectLines) await expect(review.getByRole('listitem').filter({ hasText: line })).toHaveCount(1);
  const text = await review.innerText();
  await review.locator('#confirm-machine').click();
  await expect(review).toHaveCount(0);
  await expect(bar).toBeHidden();
  return text;
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
