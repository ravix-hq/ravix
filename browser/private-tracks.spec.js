import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

test('private tracks are hidden from project members until invited', async ({ page, browser }) => {
  test.setTimeout(120_000);
  await signIn(page, 'mockuser');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Private track project');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectPath = new URL(page.url()).pathname;
  await page.locator('#workspace-stage').getByRole('button', { name: 'People', exact: true }).click();
  await page.getByLabel('GitHub username', { exact: true }).fill('eli');
  await page.getByRole('button', { name: 'Invite', exact: true }).click();
  await expect(page.locator('#people-dialog')).toContainText('@eli');
  await page.keyboard.press('Escape');
  await page.getByRole('navigation', { name: 'Project tracks', exact: true }).getByRole('button', { name: 'New track', exact: true }).click();
  const track = page.getByRole('dialog', { name: 'New track', exact: true });
  await expect(track.getByLabel('Sharing', { exact: true })).toHaveValue('project');
  await track.getByLabel('Sharing', { exact: true }).selectOption('private');
  await track.getByRole('button', { name: 'Advanced', exact: true }).click();
  await track.getByLabel('Branch name', { exact: true }).fill('secret-investigation');
  await track.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('.track-crumbs')).toContainText('secret-investigation');
  await expect(page.locator('.track-crumbs')).toContainText('Private');
  const trackPath = new URL(page.url()).pathname;

  const guestContext = await browser.newContext();
  try {
    const guest = await guestContext.newPage();
    await signIn(guest, 'eli', projectPath);
    await expect(guest.locator('#project-sections[aria-busy="false"]')).toBeAttached();
    await expect(guest.locator('body')).not.toContainText('secret-investigation');
    await guest.goto(trackPath);
    await expect(guest).toHaveURL(new RegExp(`${projectPath}$`));
    await expect(guest.locator('body')).not.toContainText('secret-investigation');

    await page.getByRole('button', { name: /^Track sharing/ }).click();
    const people = page.locator('#track-people-dialog');
    await people.getByLabel('GitHub username', { exact: true }).fill('eli');
    await people.getByRole('button', { name: 'Invite', exact: true }).click();
    await expect(people).toContainText('@eli');
    await guest.goto(trackPath);
    await expect(guest.locator('.track-crumbs')).toContainText('secret-investigation');
    await expect(guest.locator('.track-crumbs')).toContainText('Private');
  } finally {
    await guestContext.close();
  }
});
