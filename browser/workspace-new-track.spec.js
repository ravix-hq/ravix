import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { createWorkspace } from './settings.js';

// ADR 0009 phase 4c, RAV-10: New track's one repository list for the current
// workspace -- preselection, type-ahead with quick-jump's keys, "Add a
// repository…" returning with the repository selected, and scratch apart --
// at desktop and phone widths, axe clean.
// Runs under `bun run test:browser:workspace-access`, with the switch on.
async function axeClean(page) {
  const result = await new AxeBuilder({ page })
    .include('#new-track-dialog')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
    .analyze();
  expect(result.violations).toEqual([]);
}

test('New track lists the workspace repositories, adds one, and keeps scratch apart', async ({ page }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  test.setTimeout(150_000);
  await page.setViewportSize({ width: 1280, height: 900 });
  await signIn(page, 'picker', '/home');
  await connectClaude(page);
  await page.goto('/home');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);

  // A team workspace, connected to GitHub, with one repository admitted.
  await page.locator('#workspace-switcher-trigger').click();
  await createWorkspace(page, 'Picker Team');
  await page.getByRole('link', { name: 'Connect GitHub', exact: true }).click();
  await expect(page.locator('#workspace-catalog')).toContainText('mockuser/atlas-api');
  await page.locator('#workspace-catalog li', { hasText: 'mockuser/atlas-api' })
    .getByRole('button', { name: 'Add', exact: true }).click();
  await expect(page).toHaveURL(/\/p\/[^/]+$/);
  const projectPath = new URL(page.url()).pathname;
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);

  // The top button: this project's workspace, this project preselected.
  await page.locator('#top-new-track').click();
  const dialog = page.locator('#new-track-dialog');
  await expect(dialog.locator('#repo-picker')).toBeVisible();
  await expect(dialog.locator('#repo-picker label')).toContainText('Picker Team');
  await expect(dialog.locator('#repo-picker-selected')).toContainText('mockuser/atlas-api');
  const list = dialog.locator('#repo-picker-list');
  await expect(list.locator('button[aria-pressed="true"]')).toHaveText('mockuser/atlas-api');
  await expect(list.locator('li').last()).toContainText('Add a repository…');
  await expect(dialog.locator('#repo-option-scratch')).toBeVisible();
  await expect(list.locator('#repo-option-scratch')).toHaveCount(0);
  await axeClean(page);

  // Type-ahead, and quick-jump's keys: nothing matches, then the add step.
  const query = dialog.getByLabel(/Repository/);
  await query.fill('ledger');
  await expect(list).toContainText('No repository here matches.');
  await query.press('ArrowDown');
  await expect(dialog.locator('#repo-option-add')).toBeFocused();
  await page.keyboard.press('Enter');
  const add = dialog.locator('#repo-picker-add');
  await expect(add).toContainText('mockuser/ledger');
  await expect(add).not.toContainText('mockuser/atlas-api');
  await axeClean(page);
  await add.locator('[data-repo="mockuser/ledger"]').click();

  // Back with the new repository selected.
  await expect(dialog.locator('#repo-picker-selected')).toContainText('mockuser/ledger');
  await expect(list.locator('button[aria-pressed="true"]')).toHaveText('mockuser/ledger');
  await expect(list).toContainText('mockuser/atlas-api');

  // Enter in the query takes the first match.
  await query.fill('atlas');
  await expect(list.locator('button[phx-click="picker-pick"]')).toHaveCount(1);
  await query.press('Enter');
  await expect(dialog.locator('#repo-picker-selected')).toContainText('mockuser/atlas-api');

  // A phone: the project row's New track, the same list, still clean.
  await page.keyboard.press('Escape');
  await page.setViewportSize({ width: 500, height: 900 });
  await page.goto(`${projectPath}?new=track`);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(page.locator('#new-track-dialog #repo-picker')).toBeVisible();
  await expect(page.locator('#repo-picker-selected')).toContainText('mockuser/atlas-api');
  await axeClean(page);
});
