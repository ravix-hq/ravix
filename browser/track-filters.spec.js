import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { spoken } from './track-label.js';
import { openAddRepository } from './new-track.js';

async function newTrack(page, name) {
  await page.locator('#top-new-track').click();
  const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
  await dialog.getByRole('button', { name: 'Options', exact: true }).click();
  await dialog.getByLabel('Branch name', { exact: true }).fill(name);
  await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('#track-header')).toContainText(spoken(name));
}

test('a project\'s tracks say whose each is, quick-jump\'s mine: filters by creator, and Show closed lists closed tracks', async ({ page, browser }) => {
  test.setTimeout(120_000);
  await signIn(page, 'filterowner');
  await connectClaude(page);
  await openAddRepository(page);
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
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

  // The project's page lists every track, with who opened it.
  await page.goto(projectPath);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  const panel = page.locator('#project-tracks');
  const asList = async () => {
    await panel.locator('#project-tracks-list').click();
    await expect(panel.locator('#tracks-list')).toBeVisible();
  };
  await asList();
  const row = branch => panel.locator('#tracks-list .tracks-row', { hasText: branch });
  const memberTab = row('member-work');
  const ownerTab = row('owner-work');
  await expect(memberTab).toBeVisible();
  await expect(memberTab.locator('.tracks-row-meta')).toContainText('by @filtermember');
  await expect(ownerTab.locator('.tracks-row-meta')).toContainText('by @filterowner');

  // Everyone/Mine is gone: the list always shows every track the viewer
  // may see, and each row says whose it is.
  await expect(page.getByRole('group', { name: 'Show tracks from', exact: true })).toHaveCount(0);
  await expect(page.locator('[id^="rail-scope-"]')).toHaveCount(0);
  await expect(memberTab.locator('.tracks-row-owner .track-owner')).toContainText('@filtermember');
  await expect(ownerTab.locator('.tracks-row-owner .track-owner')).toContainText('You');
  await page.reload();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await asList();
  await expect(ownerTab).toBeVisible();
  await expect(memberTab).toBeVisible();

  // Quick-jump still searches everything unless asked for `mine:`.
  await page.locator('#quick-jump-trigger').click();
  const search = page.getByLabel('Search projects, tracks and plans');
  await search.fill('member-work');
  await expect(page.locator('#search-dialog [data-jump-result]', { hasText: 'Member work' })).toHaveCount(1);
  await search.fill('mine: member-work');
  await expect(page.locator('#search-dialog')).toContainText('No tracks match');
  await page.keyboard.press('Escape');

  await expect(memberTab).toBeVisible();

  // Close one of the owner's tracks, then find it again with Show closed.
  await row('owner-finished').locator('.tracks-title').click();
  await expect(page.locator('#track-header')).toContainText('Owner finished');
  await page.getByRole('button', { name: 'More for this track', exact: true }).click();
  await page.getByRole('button', { name: 'Close track', exact: true }).click();
  const close = page.getByRole('dialog', { name: 'Close track', exact: true });
  await close.getByRole('button', { name: 'Close track', exact: true }).click();
  await expect(page).toHaveURL(url => url.pathname === projectPath);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await asList();
  await expect(row('owner-finished')).toHaveCount(0);

  const showClosed = panel.locator('#project-tracks-closed');
  await expect(showClosed).toHaveAttribute('aria-pressed', 'false');
  await showClosed.click();
  await expect(showClosed).toHaveAttribute('aria-pressed', 'true');
  const closedRows = panel.locator('#tracks-list .tracks-row.closed');
  await expect(closedRows).toHaveCount(1);
  await expect(closedRows).toContainText('owner-finished');
  await expect(closedRows.locator('.tracks-row-meta')).toContainText('by @filterowner');
  await expect(panel.locator('.project-tracks-count')).toContainText('1 closed');
  // Closed tracks are listed, not opened (nor, in a scratch project with no
  // repository to branch from, reopened).
  await expect(closedRows.getByRole('link')).toHaveCount(0);
  await expect(closedRows.getByRole('button', { name: /^Reopen / })).toHaveCount(0);

  const result = await new AxeBuilder({ page }).include('#project-tracks').withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(result.violations).toEqual([]);

  await page.reload();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(panel.locator('#tracks-graph .tracks-graph-label.closed')).toContainText('owner-finished');
});
