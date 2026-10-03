import { expect } from '@playwright/test';

// RAV-60: the New track dialog's choices are chips whose menus are popovers.
// These pick through them the way a person does: open the chip, click the
// choice, and the popover closes.
export async function chooseSharing(dialog, visibility) {
  const chip = dialog.locator('#new-track-sharing-trigger');
  await chip.click();
  await dialog.locator('#new-track-sharing-menu label', { hasText: visibility === 'private' ? 'Only me' : 'Everyone' }).click();
  await expect(dialog.locator('#new-track-sharing-menu')).toBeHidden();
  await expect(chip).toContainText(visibility === 'private' ? 'Only me' : 'Everyone');
}

export async function openRepositories(dialog) {
  await dialog.locator('#new-track-repo-trigger').click();
  await expect(dialog.locator('#new-track-repo-menu')).toBeVisible();
}

// The Add a repository dialog is opened from Home: its New project button
// once there are projects, or the first-run form's "Add another repository"
// before there are any. Off Home, the top bar's mark goes there first, the
// way a person would.
export async function openAddRepository(page) {
  const trigger = page.locator('#home-add-repository, #home-quick-start-add-repository');
  if (new URL(page.url()).pathname !== '/home') {
    await page.locator('#topbar .topbar-home').click();
    await expect(page).toHaveURL(/\/home$/);
  }
  await trigger.click();
  await expect(page.getByRole('dialog', { name: 'Add a repository', exact: true })).toBeVisible();
}
