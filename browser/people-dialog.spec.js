import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

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
  await page.getByRole('button', { name: 'Add repository', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'Add repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('People dialog project');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  const track = page.getByRole('dialog', { name: 'New track', exact: true });
  await track.getByRole('button', { name: 'Options', exact: true }).click();
  await track.getByLabel('Branch name', { exact: true }).fill('people-typing');
  await track.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('.track-crumbs')).toContainText('People typing');
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
  await other.getByRole('button', { name: /^Rename track/ }).click();
  const title = other.getByRole('dialog').getByRole('textbox').first();
  await title.fill('people-renamed');
  await title.press('Enter');
  await expect(page.locator('.track-crumbs')).toContainText('people-renamed');

  await expect(login).toHaveValue('somebody');
});
