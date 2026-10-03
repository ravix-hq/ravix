import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// The people dialog sits inside the track page, which re-renders whenever
// the track changes: setup progress, a rename, a turn. A login typed into
// the invite box and then left -- focus moves to Invite as it is pressed --
// used to be redrawn empty by the next such render, so the invitation went
// nowhere ("Please fill out this field"). This is what made
// private-tracks.spec.js fail when setup was still running.
test('a typed login survives the track re-rendering after the box loses focus', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'peopleowner');
  await connectClaude(page);
  await openAddRepository(page);
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('People dialog project');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.locator('#top-new-track').click();
  const track = page.getByRole('dialog', { name: 'New track', exact: true });
  await track.getByRole('button', { name: 'Options', exact: true }).click();
  await track.getByLabel('Branch name', { exact: true }).fill('people-typing');
  await track.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('#track-header')).toContainText('People typing');
  // A rename is what re-renders the track below, and it waits for setup.
  await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 60_000 });
  const trackPath = new URL(page.url()).pathname;

  await page.getByRole('button', { name: /^Track sharing/ }).click();
  const people = page.locator('#track-people-dialog');
  const login = people.getByLabel('GitHub username', { exact: true });
  await login.fill('somebody');
  await people.getByRole('heading', { name: 'Track people' }).click();
  await expect(login).not.toBeFocused();

  // Re-render the track under the dialog: rename it from a second tab.
  const other = await page.context().newPage();
  await other.goto(trackPath);
  await expect(other.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  // Connected is not loaded: the track page's first reads are still landing
  // for a moment after the socket joins, and a rename typed into that moment
  // went nowhere in CI (both tabs kept the old title). Wait for the page to
  // have read its machine, as the first tab did above.
  await expect(other.locator('#track-machine-state')).toHaveText('Idle', { timeout: 30_000 });
  await other.getByRole('button', { name: /^Rename track/ }).click();
  const title = other.getByRole('dialog').getByRole('textbox').first();
  await expect(title).toBeVisible();
  await title.fill('people-renamed');
  await expect(title).toHaveValue('people-renamed');
  await title.press('Enter');
  // The tab that renamed first, so a miss says which side lost it.
  await expect(other.locator('#track-header')).toContainText('people-renamed');
  await expect(page.locator('#track-header')).toContainText('people-renamed');

  await expect(login).toHaveValue('somebody');
});
