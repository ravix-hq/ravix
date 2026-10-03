import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-37: adding a repository is its own flow, apart from daily work. New
// track starts work, from the top bar, Home and the phone alike; Add a
// repository connects a repository as a project, with scratch as the list's
// last choice. It is Home's to offer (the first run's "Add another
// repository", then its New project), not the top bar's.
test('Add a repository searches, picks with Enter, keeps scratch, and hands work to New track', async ({ page }) => {
  await signIn(page, 'addrepository', '/home');
  await connectClaude(page);
  const nav = page.locator('#topbar');
  await expect(nav.getByRole('button', { name: 'New track' })).toBeVisible();
  await expect(nav.getByRole('button', { name: 'New project' })).toHaveCount(0);
  await expect(nav.getByRole('button', { name: /Add a repository|Add another repository/ })).toHaveCount(0);

  await page.locator('#home-quick-start').getByRole('button', { name: 'Add another repository', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await expect(dialog).toContainText('Start work in it from New track');
  const search = dialog.getByRole('searchbox', { name: 'Repository', exact: true });
  await expect(search).toBeFocused();
  const repositories = dialog.getByRole('group', { name: 'Repository', exact: true });
  await expect(repositories.getByRole('radio', { name: 'mockuser/atlas-api', exact: true })).toBeVisible();
  const scratch = repositories.getByRole('radio', { name: 'No repository (scratch machine)', exact: true });
  await expect(scratch).toBeChecked();
  await expect(dialog.getByRole('button', { name: 'Create scratch project', exact: true })).toBeVisible();
  await expect(dialog.getByRole('link', { name: /Configure on GitHub/ })).toHaveAttribute('href', '/api/auth/install');
  expect((await new AxeBuilder({ page }).include('#new-project-dialog-dialog').analyze()).violations).toEqual([]);

  // Enter in the search chooses the first match rather than submitting.
  await search.fill('atlas');
  await expect(repositories.getByRole('radio')).toHaveCount(2);
  await search.press('Enter');
  const atlas = repositories.getByRole('radio', { name: 'mockuser/atlas-api', exact: true });
  await expect(atlas).toBeChecked();
  await expect(dialog).toBeVisible();
  const add = dialog.getByRole('button', { name: 'Add repository', exact: true });
  await expect(add).toBeVisible();

  // Scratch stays one choice away, and the button follows it.
  await scratch.check();
  await expect(dialog.getByRole('button', { name: 'Create scratch project', exact: true })).toBeVisible();
  await atlas.check();
  await add.click();
  await expect(dialog).toHaveCount(0);
  await expect(page.locator('#topbar .topbar-crumbs')).toContainText('atlas-api');

  // Work in it starts from New track, with the new repository preselected.
  await nav.getByRole('button', { name: 'New track' }).click();
  const newTrack = page.getByRole('dialog', { name: 'New track', exact: true });
  await expect(newTrack.locator('#new-track-repo-trigger')).toContainText('atlas-api');
  await expect(newTrack.getByRole('textbox', { name: 'What do you want to work on?' })).toBeFocused();
  await expect(newTrack).toContainText('A track is a branch with its own machine; threads are conversations in it.');

  // The composer's repository chip adds one too, and comes back with it chosen.
  await newTrack.locator('#new-track-repo-trigger').click();
  await newTrack.getByRole('button', { name: 'Add a repository…', exact: true }).click();
  await expect(dialog).toBeVisible();
  await dialog.getByRole('radio', { name: 'mockuser/cabinet', exact: true }).check();
  await dialog.getByRole('button', { name: 'Add repository', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await expect(newTrack).toBeVisible();
  await expect(newTrack.locator('#new-track-repo-trigger')).toContainText('cabinet');
  await page.keyboard.press('Escape');
  await expect(newTrack).toHaveCount(0);

  // On Home, New track is the top bar's alone: Home draws no second one,
  // and the top bar's opens the same dialog there.
  await page.goto('/home');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(page.locator('#home').getByRole('button', { name: 'New track', exact: true })).toHaveCount(0);
  await nav.getByRole('button', { name: 'New track', exact: true }).click();
  await expect(newTrack).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(newTrack).toHaveCount(0);

  // On a phone, the top bar keeps New track, and still has no New project.
  await page.setViewportSize({ width: 390, height: 780 });
  await expect(nav.getByRole('button', { name: 'New project' })).toHaveCount(0);
  const phoneNew = nav.getByRole('button', { name: 'New track', exact: true });
  await expect(phoneNew).toBeInViewport();
  await phoneNew.click();
  await expect(newTrack).toBeVisible();
});
