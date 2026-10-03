import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-101: Changes lists files Git is not tracking yet. The Sprites mock
// answers the untracked read only for a worktree named for it
// (mock/previews.ts), beside the Fountain mock's tracked diff.
// `SCREENSHOT_DIR` saves the review shots.
test.use({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });

const shoot = async (target, name, options = {}) => {
  if (process.env.SCREENSHOT_DIR) await target.screenshot({ path: `${process.env.SCREENSHOT_DIR}/${name}.png`, ...options });
};

test('Changes lists an untracked file as new beside the tracked diff', async ({ page }) => {
  test.setTimeout(150_000);
  await signIn(page, 'untracked');
  await connectClaude(page);
  await openAddRepository(page);
  const project = page.getByRole('dialog', { name: 'Add a repository' });
  await project.getByLabel('Project name', { exact: true }).fill('Atlas API');
  await expect(project.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await project.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await project.getByRole('button', { name: 'Add repository' }).click();
  await expect(project).not.toBeVisible();

  await page.locator('#top-new-track').click();
  const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
  await dialog.getByRole('button', { name: 'Options', exact: true }).click();
  await dialog.getByLabel('Branch name').fill('notes-untracked');
  await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(dialog).not.toBeVisible();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
  await page.getByRole('navigation', { name: 'Track views' }).getByRole('button', { name: 'Changes', exact: true }).click();

  const panel = page.locator('.changes-panel');
  await expect(panel.locator('.change-file', { hasText: 'window.ts' })).toBeVisible({ timeout: 15_000 });
  await shoot(page.locator('#inspector'), 'changes-list');
  const untracked = panel.locator('.change-file', { hasText: 'NOTES.md' });
  await expect(untracked).toBeVisible();
  await expect(untracked.locator('.change-untracked')).toHaveAttribute('title', 'New, untracked');
  await expect(untracked).toContainText('+3');
  const axe = await new AxeBuilder({ page }).include('.changes-panel')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(axe.violations).toEqual([]);

  await untracked.click();
  await expect(page.locator('.diff-line.diff-add code', { hasText: 'Untracked, and now listed.' })).toBeVisible();
  await shoot(page.locator('#inspector'), 'untracked-diff');
});
