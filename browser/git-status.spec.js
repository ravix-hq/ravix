import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-56: the Checks tab's Git status. The Sprites mock answers the status,
// commit and push scripts from a per-worktree fixture (mock/previews.ts):
// three uncommitted entries and one unpushed commit, and a push refused when
// the commit message says "reject". `SCREENSHOT_DIR` saves the review shots.
test.use({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });

const shoot = async (target, name, options = {}) => {
  if (process.env.SCREENSHOT_DIR) await target.screenshot({ path: `${process.env.SCREENSHOT_DIR}/${name}.png`, ...options });
};

async function openChecks(page, branch) {
  await page.locator('#top-new-track').click();
  const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
  await dialog.getByRole('button', { name: 'Options', exact: true }).click();
  await dialog.getByLabel('Branch name').fill(branch);
  await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(dialog).not.toBeVisible();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
  await page.getByRole('navigation', { name: 'Track views' }).getByRole('button', { name: 'Checks', exact: true }).click();
  await expect(page.locator('#git-uncommitted')).toContainText('3 uncommitted changes');
}

test('Checks shows uncommitted and unpushed work, commits and pushes it, and surfaces a rejected push', async ({ page }) => {
  test.setTimeout(150_000);
  await signIn(page, 'gitstatus');
  await connectClaude(page);
  await openAddRepository(page);
  const project = page.getByRole('dialog', { name: 'Add a repository' });
  await project.getByLabel('Project name', { exact: true }).fill('Atlas API');
  await expect(project.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await project.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await project.getByRole('button', { name: 'Add repository' }).click();
  await expect(project).not.toBeVisible();

  await openChecks(page, 'search-endpoint');
  const status = page.locator('#git-status');
  await expect(status.locator('#git-unpushed')).toContainText('1 unpushed commit');
  await expect(status.locator('#git-unpushed')).toContainText('branch not on GitHub yet');
  await expect(status.locator('#git-pull')).toContainText('No pull request');
  await expect(status.getByRole('button', { name: 'Create pull request', exact: true })).toBeVisible();
  const axe = await new AxeBuilder({ page }).include('#git-status')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(axe.violations).toEqual([]);
  await shoot(page, 'after-1-checks-git-status');
  await shoot(page.locator('#inspector'), 'after-2-checks-panel');

  await status.getByRole('button', { name: 'Commit and push', exact: true }).click();
  const commit = page.getByRole('dialog', { name: 'Commit and push', exact: true });
  const message = commit.getByLabel('Commit message', { exact: true });
  await expect(message).not.toHaveValue('');
  await message.fill('Add the search endpoint');
  await shoot(page, 'after-3-commit-dialog');
  await commit.getByRole('button', { name: 'Commit and push', exact: true }).click();
  await expect(commit).not.toBeVisible();
  await expect(status.locator('#git-uncommitted')).toContainText('No uncommitted changes');
  await expect(status.locator('#git-unpushed')).toContainText('No unpushed commits');
  await expect(page.getByText('Committed and pushed.')).toBeVisible();
  await shoot(page.locator('#inspector'), 'after-4-committed-and-pushed');

  // A second track's worktree, whose push the remote refuses.
  await openChecks(page, 'search-rejected');
  await status.getByRole('button', { name: 'Commit and push', exact: true }).click();
  await message.fill('Reject: add the search index');
  await commit.getByRole('button', { name: 'Commit and push', exact: true }).click();
  const failure = commit.locator('#commit-failure');
  await expect(failure).toContainText('Committed, but the push failed.');
  await expect(failure).toContainText('The push was rejected');
  await expect(failure).toContainText('[rejected]');
  await expect(message).toHaveValue('Reject: add the search index');
  await shoot(page, 'after-5-push-rejected-dialog');
  await page.keyboard.press('Escape');
  await expect(commit).not.toBeVisible();
  await expect(status.locator('#git-failure')).toContainText('The push was rejected');
  await expect(status.locator('#git-unpushed')).toContainText('2 unpushed commits');
  await shoot(page.locator('#inspector'), 'after-6-push-rejected-status');
});
