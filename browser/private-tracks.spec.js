import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { chooseSharing, openAddRepository } from './new-track.js';

test('private tracks are hidden from project members until invited', async ({ page, browser }) => {
  test.setTimeout(120_000);
  await signIn(page, 'privacycreator');
  await connectClaude(page);
  await openAddRepository(page);
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Private track project');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectPath = new URL(page.url()).pathname;
  // The owner's People is the project's Access settings page (RAV-74).
  await page.locator('#workspace-stage').getByRole('link', { name: 'People', exact: true }).click();
  await expect(page).toHaveURL(/\/settings\/access$/);
  await page.getByLabel('GitHub username', { exact: true }).fill('privacyguest');
  await page.getByRole('button', { name: 'Invite', exact: true }).click();
  await expect(page.locator('#project-access')).toContainText('@privacyguest');
  await page.locator('#top-new-track').click();
  const track = page.getByRole('dialog', { name: 'New track', exact: true });
  await expect(track.locator('#new-track-sharing-trigger')).toContainText('Everyone');
  await chooseSharing(track, 'private');
  await track.getByRole('button', { name: 'Options', exact: true }).click();
  await track.getByLabel('Branch name', { exact: true }).fill('secret-investigation');
  await track.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('#track-header')).toContainText('Secret investigation');
  await expect(page.locator('#track-header')).toContainText('Private');
  const trackPath = new URL(page.url()).pathname;

  const guestContext = await browser.newContext();
  try {
    const guest = await guestContext.newPage();
    await signIn(guest, 'privacyguest', projectPath);
    // Search finds the project once the guest's projects are read, so what
    // is left out below is left out, not yet to load.
    await guest.locator('#quick-jump-trigger').click();
    await guest.getByLabel('Search projects, tracks and plans').fill('Private track project');
    await expect(guest.locator('#search-dialog [data-jump-result]').first()).toBeVisible();
    await expect(guest.locator('body')).not.toContainText(/secret.investigation/i);
    await guest.getByLabel('Search projects, tracks and plans').fill('secret-investigation');
    await expect(guest.locator('#search-dialog [data-jump-result]')).toHaveCount(0);
    await guest.keyboard.press('Escape');
    await guest.goto(trackPath);
    await expect(guest).toHaveURL(new RegExp(`${projectPath}$`));
    await expect(guest.locator('body')).not.toContainText(/secret.investigation/i);

    await page.getByRole('button', { name: /^Track sharing/ }).click();
    const people = page.locator('#track-people-dialog');
    await people.getByLabel('GitHub username', { exact: true }).fill('privacyguest');
    await people.getByRole('button', { name: 'Invite', exact: true }).click();
    await expect(people).toContainText('@privacyguest');
    await guest.goto(trackPath);
    await expect(guest.locator('#track-header')).toContainText('Secret investigation');
    await expect(guest.locator('#track-header')).toContainText('Private');
  } finally {
    await guestContext.close();
  }
});
