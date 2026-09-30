import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { spoken } from './track-label.js';

async function newTrack(page, name) {
  await page.locator('#yard .workspace-project.current .project-add').click();
  const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
  await dialog.getByRole('button', { name: 'Options', exact: true }).click();
  await dialog.getByLabel('Branch name', { exact: true }).fill(name);
  await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('.track-crumbs')).toContainText(spoken(name));
}

test('Mine/Everyone filters the rail by creator, and Show closed lists closed tracks', async ({ page, browser }) => {
  test.setTimeout(120_000);
  await signIn(page, 'filterowner');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add repository', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'Add repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Filter project');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectPath = new URL(page.url()).pathname;
  // The owner's People is the project's Access settings page (RAV-74).
  await page.locator('#workspace-stage').getByRole('link', { name: 'People', exact: true }).click();
  await expect(page).toHaveURL(/\/settings\/access$/);
  await page.getByLabel('GitHub username', { exact: true }).fill('filtermember');
  await page.getByRole('button', { name: 'Invite', exact: true }).click();
  await expect(page.locator('#project-access')).toContainText('@filtermember');
  await newTrack(page, 'owner-work');
  await newTrack(page, 'owner-finished');

  const memberContext = await browser.newContext();
  try {
    const member = await memberContext.newPage();
    await signIn(member, 'filtermember', projectPath);
    await connectClaude(member);
    await member.goto(projectPath);
    await newTrack(member, 'member-work');
  } finally {
    await memberContext.close();
  }

  await page.goto(projectPath);
  const rail = page.locator('#yard');
  const memberTab = rail.getByRole('link', { name: /Member work, created by @filtermember/ });
  const ownerTab = rail.getByRole('link', { name: /Owner work, created by @filterowner/ });
  await expect(memberTab).toBeVisible();
  await expect(memberTab.getByRole('img', { name: 'Created by @filtermember', exact: true })).toBeVisible();
  await expect(memberTab.locator('.track-creator')).toHaveAttribute('title', 'Created by @filtermember');

  const scope = rail.getByRole('group', { name: 'Show tracks from', exact: true });
  await scope.getByRole('button', { name: 'Mine', exact: true }).click();
  await expect(scope.getByRole('button', { name: 'Mine', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(memberTab).toHaveCount(0);
  await expect(ownerTab).toBeVisible();
  // A server-side preference: it survives a reload.
  await page.reload();
  await expect(page.locator('#project-sections[aria-busy="false"]')).toBeAttached();
  await expect(ownerTab).toBeVisible();
  await expect(memberTab).toHaveCount(0);

  // Quick-jump still searches everything unless asked for `mine:`.
  await page.locator('#quick-jump-trigger').click();
  const search = page.getByLabel('Search projects, tracks and plans');
  await search.fill('member-work');
  await expect(page.locator('#search-dialog [data-jump-result]', { hasText: 'Member work' })).toHaveCount(1);
  await search.fill('mine: member-work');
  await expect(page.locator('#search-dialog')).toContainText('No tracks match');
  await page.keyboard.press('Escape');

  await scope.getByRole('button', { name: 'Everyone', exact: true }).click();
  await expect(memberTab).toBeVisible();

  // Close one of the owner's tracks, then find it again through the project menu.
  await rail.getByRole('link', { name: /Owner finished/ }).click();
  await expect(page.locator('.track-crumbs')).toContainText('Owner finished');
  await page.getByRole('button', { name: 'Close track', exact: true }).click();
  const close = page.getByRole('dialog', { name: 'Close track', exact: true });
  await close.getByRole('button', { name: 'Close track', exact: true }).click();
  await expect(rail.getByRole('link', { name: /Owner finished/ })).toHaveCount(0);

  await rail.getByRole('button', { name: 'More for Filter project', exact: true }).click();
  const showClosed = page.getByRole('menuitemcheckbox', { name: 'Show closed tracks', exact: true });
  await expect(showClosed).toHaveAttribute('aria-checked', 'false');
  await showClosed.click();
  const closedList = rail.getByRole('list', { name: 'Closed tracks in Filter project', exact: true });
  await expect(closedList.getByRole('listitem')).toHaveCount(1);
  await expect(closedList).toContainText('Owner finished');
  await expect(closedList.getByRole('img', { name: 'Created by @filterowner', exact: true })).toBeVisible();
  // Closed tracks are listed, not counted or opened.
  await expect(closedList.getByRole('link')).toHaveCount(0);

  const result = await new AxeBuilder({ page }).include('#yard').withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(result.violations).toEqual([]);

  await page.reload();
  await expect(page.locator('#project-sections[aria-busy="false"]')).toBeAttached();
  await expect(closedList).toContainText('Owner finished');
});
