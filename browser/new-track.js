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
