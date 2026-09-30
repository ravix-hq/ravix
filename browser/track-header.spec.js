import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn, connectClaude } from './sign-in.js';
import { expectHeaderUnobstructed } from './header-layout.js';

// RAV-63: at a laptop width the plan chip, which lands after the track does,
// used to take all of its room from the project name ("r…") and clip the
// badges, and opening a track made the rail's project row an icon wider.
test('the track header keeps the project and title readable and still as late parts land', async ({ page }) => {
  await page.setViewportSize({ width: 1024, height: 800 });
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill('ravix-hdr');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  const projectRow = page.locator('#yard .workspace-project.current');
  await expect(projectRow).toContainText('ravix-hdr');
  const project = await projectRow.getAttribute('data-project-id');
  const railName = page.locator(`#project-link-${project} .project-label`);
  const railBefore = await railName.evaluate(el => el.getBoundingClientRect().width);
  await projectRow.locator('.project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();

  // Selecting a track leaves the rail's project row as wide as it was.
  expect(await railName.evaluate(el => el.getBoundingClientRect().width)).toBe(railBefore);
  expect(await railName.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);

  const track = new URL(page.url()).pathname.split('/t/')[1];
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || !/^[a-f0-9-]{36}$/.test(track)) throw new Error('Invalid browser fixture');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  const sql = statement => execFileSync('psql', [`${server}/${database}`, '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', statement]);
  const title = 'Reflow the track header after load';
  sql(`UPDATE ravix.tracks SET title = '${title}', sandbox_layout = 'dedicated',
         branch = 'ravix/rav-63-track-header-reflow-with-a-very-long-branch-name' WHERE id = '${track}';`);
  await page.reload();
  const header = page.locator('header.track-crumbs');
  await expect(header).toContainText(title);
  await expect(page.locator('#track-machine-scope')).toHaveText('Own machine');

  const measure = () => page.evaluate(() => {
    const box = sel => {
      const r = document.querySelector(sel).getBoundingClientRect();
      return { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) };
    };
    const header = document.querySelector('header.track-crumbs');
    const title = document.querySelector('.track-title-crumb');
    // What the first sixteen characters of the title take in its own font.
    const probe = title.cloneNode(false);
    probe.textContent = title.textContent.trim().slice(0, 16);
    probe.style.cssText = 'position:absolute;visibility:hidden;min-width:0;width:auto;padding:0;border:0';
    header.append(probe);
    const sixteen = probe.getBoundingClientRect().width;
    probe.remove();
    const titleStyle = getComputedStyle(title);
    const titleText = title.clientWidth - parseFloat(titleStyle.paddingLeft) - parseFloat(titleStyle.paddingRight);
    const label = document.querySelector('.project-crumb .project-label');
    const close = document.querySelector('.track-crumbs [aria-label="Close track"]').getBoundingClientRect();
    return {
      header: box('header.track-crumbs'),
      project: box('.project-crumb'),
      title: box('.track-title-crumb'),
      projectWhole: label.scrollWidth <= label.clientWidth,
      titleShown: titleText + 1 >= sixteen,
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
  // At this width the chips are down to their icons, and the plan chip
  // to its icon and count.
  await expect(header).toHaveAttribute('data-compact', '');
  await expect(header.getByRole('button', { name: 'Plan: Small fixes: task state, machine stats, 404 and navigation · 3 items', exact: true })).toBeVisible();
  // The chip gave way down to its icon and count; the count is still drawn.
  expect(await chip.locator('.track-plan-count').evaluate(el => el.getBoundingClientRect().width)).toBeGreaterThan(0);
  expect(await chip.locator('.track-plan-count').evaluate(el => el.scrollWidth <= el.clientWidth + 1)).toBe(true);
});
