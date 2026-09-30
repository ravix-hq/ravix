import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { chooseSharing } from './new-track.js';

test('private tracks are hidden from project members until invited', async ({ page, browser }) => {
  test.setTimeout(120_000);
  await signIn(page, 'privacycreator');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Private track project');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectPath = new URL(page.url()).pathname;
  await page.locator('#workspace-stage').getByRole('button', { name: 'People', exact: true }).click();
  await page.getByLabel('GitHub username', { exact: true }).fill('privacyguest');
  await page.getByRole('button', { name: 'Invite', exact: true }).click();
  await expect(page.locator('#people-dialog')).toContainText('@privacyguest');
  await page.keyboard.press('Escape');
  await page.locator('#yard .workspace-project.current .project-add').click();
  const track = page.getByRole('dialog', { name: 'New track', exact: true });
  await expect(track.locator('#new-track-sharing-trigger')).toContainText('Everyone');
  await chooseSharing(track, 'private');
  await track.getByRole('button', { name: 'Options', exact: true }).click();
  await track.getByLabel('Branch name', { exact: true }).fill('secret-investigation');
  await track.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('.track-crumbs')).toContainText('secret-investigation');
  await expect(page.locator('.track-crumbs')).toContainText('Private');
  const trackPath = new URL(page.url()).pathname;

  const guestContext = await browser.newContext();
  try {
    const guest = await guestContext.newPage();
    await signIn(guest, 'privacyguest', projectPath);
    await expect(guest.locator('#project-sections[aria-busy="false"]')).toBeAttached();
    await expect(guest.locator('body')).not.toContainText('secret-investigation');
    await guest.locator('#quick-jump-trigger').click();
    await guest.getByLabel('Search projects, tracks and plans').fill('secret-investigation');
    await expect(guest.locator('#search-dialog [data-jump-result]')).toHaveCount(0);
    await guest.keyboard.press('Escape');
    await guest.goto(trackPath);
    await expect(guest).toHaveURL(new RegExp(`${projectPath}$`));
    await expect(guest.locator('body')).not.toContainText('secret-investigation');

    await page.getByRole('button', { name: /^Track sharing/ }).click();
    const people = page.locator('#track-people-dialog');
    await people.getByLabel('GitHub username', { exact: true }).fill('privacyguest');
    await people.getByRole('button', { name: 'Invite', exact: true }).click();
    await expect(people).toContainText('@privacyguest');
    await guest.goto(trackPath);
    await expect(guest.locator('.track-crumbs')).toContainText('secret-investigation');
    await expect(guest.locator('.track-crumbs')).toContainText('Private');
  } finally {
    await guestContext.close();
  }
});
