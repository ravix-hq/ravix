import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn, connectClaude } from './sign-in.js';
import { expectHeaderUnobstructed } from './header-layout.js';
import { openAddRepository } from './new-track.js';

// RAV-63: at a laptop width the plan chip, which lands after the track does,
// used to take all of its room from the project name ("r…") and clip the
// badges. The project is the top bar's crumb now, the title the head's h1
// and the chip on the status line under it: none may move when it lands.
test('the track header keeps the project and title readable and still as late parts land', async ({ page }) => {
  await page.setViewportSize({ width: 1024, height: 800 });
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  await page.getByLabel('Project name', { exact: true }).fill('ravix-hdr');
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  // The project's own page names it in full, in the top bar's breadcrumb.
  const projectName = page.locator('#topbar .topbar-crumbs .project-label');
  await expect(projectName).toHaveText('ravix-hdr');
  expect(await projectName.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
  await page.locator('#top-new-track').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();

  const track = new URL(page.url()).pathname.split('/t/')[1];
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || !/^[a-f0-9-]{36}$/.test(track)) throw new Error('Invalid browser fixture');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  const sql = statement => execFileSync('psql', [`${server}/${database}`, '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', statement]);
  const title = 'Reflow the track header after load';
  sql(`UPDATE ravix.tracks SET title = '${title}', sandbox_layout = 'dedicated',
         branch = 'ravix/rav-63-track-header-reflow-with-a-very-long-branch-name' WHERE id = '${track}';`);
  await page.reload();
  const header = page.locator('header#track-header');
  await expect(header).toContainText(title);
  await expect(page.locator('#track-machine-scope')).toHaveText('Own machine');

  const measure = () => page.evaluate(() => {
    const box = sel => {
      const r = document.querySelector(sel).getBoundingClientRect();
      return { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) };
    };
    const header = document.querySelector('header#track-header');
    // The project is the top bar's crumb now; the title is the head's h1,
    // which wraps rather than cutting its words.
    const crumb = 'header#topbar .topbar-crumbs a[href^="/p/"]';
    const label = document.querySelector(`${crumb} .project-label`);
    const title = document.querySelector('#track-header .track-title-text');
    const close = document.querySelector('#track-more-trigger').getBoundingClientRect();
    return {
      header: box('header#track-header'),
      project: box(crumb),
      title: box('#track-header .track-title-text'),
      projectWhole: label.scrollWidth <= label.clientWidth,
      titleShown: title.scrollWidth <= title.clientWidth + 1 && title.textContent.trim().length > 0,
      overflow: header.scrollWidth > header.clientWidth || close.right > header.getBoundingClientRect().right,
      page: document.documentElement.scrollWidth > innerWidth,
      // A status chip's words are drawn whole or not at all, never "Own m".
      fragments: [...header.querySelectorAll('[data-fit-label]')]
        .filter(el => el.clientWidth > 0 && el.scrollWidth > el.clientWidth + 1).map(el => el.textContent),
    };
  });
  const before = await measure();
  expect(before.projectWhole).toBe(true);
  expect(before.titleShown).toBe(true);
  expect(before.overflow).toBe(false);
  expect(before.page).toBe(false);
  expect(before.fragments).toEqual([]);
  await expectHeaderUnobstructed(page);

  sql(`
    INSERT INTO ravix.plans (id, project_id, title, summary, version, created_by_login, archived, inserted_at, updated_at)
    SELECT 'header-plan', project_id, 'Small fixes: task state, machine stats, 404 and navigation', '', 1, 'eli', false, now(), now() FROM ravix.tracks WHERE id = '${track}';
    INSERT INTO ravix.plan_items (id, plan_id, position, title, brief, acceptance, dependencies, track_id, inserted_at, updated_at)
    SELECT 'header-' || n, 'header-plan', n, 'Item ' || n, 'Do item ' || n || '.', '', '{}', '${track}', now(), now()
    FROM generate_series(0, 2) AS n;
  `);
  await page.reload();
  const chip = header.locator('.track-plan-toggle');
  await expect(chip).toContainText('3 items');
  const after = await measure();
  await page.screenshot({ path: 'tmp/track-header-1024.png' });
  // The chip landing moves neither the project nor the title, nor the height.
  expect(after.project).toEqual(before.project);
  expect(after.title).toEqual(before.title);
  expect(after.header.height).toBe(before.header.height);
  expect(after.projectWhole).toBe(true);
  expect(after.titleShown).toBe(true);
  expect(after.overflow).toBe(false);
  expect(after.page).toBe(false);
  expect(after.fragments).toEqual([]);
  await expectHeaderUnobstructed(page);
  // The chip is named in full, and its count is drawn (HeaderFit's compact
  // state is gone: the status line has the room).
  await expect(header.getByRole('button', { name: 'Plan: Small fixes: task state, machine stats, 404 and navigation · 3 items', exact: true })).toBeVisible();
  // The count is drawn whole.
  expect(await chip.locator('.track-plan-count').evaluate(el => el.getBoundingClientRect().width)).toBeGreaterThan(0);
  expect(await chip.locator('.track-plan-count').evaluate(el => el.scrollWidth <= el.clientWidth + 1)).toBe(true);
});
