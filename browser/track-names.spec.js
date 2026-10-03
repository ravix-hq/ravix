import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-83: a track that has a title (RAV-48's, or a person's) is called by it
// on Home, its project's page, its header and the Inbox, and its branch slug is not
// printed beside it but kept for the tooltip. One still titled with its
// branch goes by the branch read as words, less the `ravix/` every Ravix
// branch shares.
test('tracks are named by their titles, not their branch slugs', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await signIn(page, 'titler', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  await page.getByLabel('Project name', { exact: true }).fill('ravix-names');
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(page.locator('#topbar .topbar-crumbs')).toContainText('ravix-names');
  const projectPath = new URL(page.url()).pathname;

  const tracks = [];
  const shown = () => new URL(page.url()).pathname.split('/t/')[1];
  for (let i = 0; i < 3; i++) {
    await page.locator('#top-new-track').click();
    await page.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect.poll(shown).toMatch(/^[a-f0-9-]{36}$/);
    await expect.poll(() => tracks.includes(shown())).toBe(false);
    await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();
    tracks.push(shown());
  }
  const [titled, failed, untitled] = tracks;

  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || !tracks.every(id => /^[a-f0-9-]{36}$/.test(id))) {
    throw new Error('Invalid browser fixture');
  }
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  const sql = statement => execFileSync('psql', [`${server}/${database}`, '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', statement]);
  const branch = 'ravix/rav-83-name-tracks-by-title-not-branch-s';
  // Opened before automatic titles, and never renamed.
  const slug = 'ravix/draft-adr-0009-proposed-workspaces';
  sql(`
    UPDATE ravix.tracks SET title = 'Name Tracks by Title', title_source = 'auto', branch = '${branch}' WHERE id = '${titled}';
    UPDATE ravix.tracks SET title = 'Fix Login Redirect', title_source = 'auto', branch = 'ravix/crewe-zq7',
      setup_state = 'failed', setup_error = 'The opening turn failed.' WHERE id = '${failed}';
    UPDATE ravix.tracks SET title = '${slug}', branch = '${slug}' WHERE id = '${untitled}';
  `);

  await page.goto(`${projectPath}/t/${titled}`);
  const header = page.locator('header#track-header');
  await expect(header).toContainText('Name Tracks by Title');
  await page.screenshot({ path: 'tmp/track-names-track.png' });
  await page.goto('/inbox');
  const card = page.locator('.inbox-item', { hasText: 'Setup failed' });
  await expect(card).toBeVisible();
  await page.screenshot({ path: 'tmp/track-names-inbox.png' });

  // The Inbox card: the title, and nothing of the branch.
  await expect(card.locator('strong')).toHaveText('Fix Login Redirect');
  await expect(card).not.toContainText('crewe');

  // Home's Needs you (its recent tracks are gone): the failed track by its
  // title and why, and nothing of any branch.
  await page.goto('/home');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  const needs = page.locator(`#home-needs-${failed}`);
  await expect(needs.locator('strong')).toHaveText('Fix Login Redirect');
  await expect(needs).toContainText('could not be set up');
  await expect(page.locator('#home-activity')).not.toContainText('ravix/');
  await expect(page.locator('#home-activity')).not.toContainText('crewe');

  // The project's page: the same names, every raw branch on hover.
  await page.goto(projectPath);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await page.locator('#project-tracks-list').click();
  const tab = id => page.locator(`#tracks-row-${id} .tracks-title`);
  await expect(tab(titled)).toHaveText(/^\s*Name Tracks by Title, /);
  await expect(tab(failed)).toHaveText(/^\s*Fix Login Redirect, /);
  await expect(tab(untitled)).toHaveText(/^\s*Draft ADR 0009 proposed workspaces, /);
  await expect(tab(titled)).toHaveAttribute('title', `Name Tracks by Title\n${branch}`);
  await expect(tab(untitled)).toHaveAttribute('title', `Draft ADR 0009 proposed workspaces\n${slug}`);

  // The header's title is the title alone. The branch is the status line's
  // chip, and in the ribbon beneath.
  await tab(titled).click();
  await expect(header.locator('.track-title-text')).toHaveText('Name Tracks by Title');
  await expect(header.locator('h1.track-title')).not.toContainText(branch);
  await expect(header.locator('.track-head-status .track-branch')).toHaveText(branch);
  await expect(page.locator('.track-ribbon')).toContainText(branch);
  await expect(page).toHaveTitle('Name Tracks by Title · ravix-names · Ravix');

  // An untitled track's header reads as words too, and so does the tab title.
  await page.locator('#topbar .topbar-crumbs a[href^="/p/"]').click();
  await page.locator('#project-tracks-list').click();
  await tab(untitled).click();
  await expect(page.locator('.track-ribbon')).toContainText(slug);
  await page.screenshot({ path: 'tmp/track-names-untitled.png' });
  await expect(header.locator('.track-title-text')).toHaveText('Draft ADR 0009 proposed workspaces');
  await expect(header.locator('h1.track-title')).not.toContainText('ravix/');
  await expect(page).toHaveTitle('Draft ADR 0009 proposed workspaces · ravix-names · Ravix');
});
