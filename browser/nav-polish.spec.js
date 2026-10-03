import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-96, in the redesigned frame: the top bar's places to go are one
// height with their counts inside them, a project's count (on Home) says
// what it counts, a place is lit by a tint rather than underlined, and the
// You menu is single-line rows dropping down from the avatar at the top
// right.
test('the top bar nav and You menu keep one pitch and say what they do', async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'sidebarpolish', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  await page.getByLabel('Project name', { exact: true }).fill(`Top bar ${Date.now().toString(36)}`);
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(page).toHaveURL(/\/p\/[0-9a-f-]{36}$/);
  const projectId = new URL(page.url()).pathname.split('/')[2];
  await page.locator('#top-new-track').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 30_000 });
  const trackId = new URL(page.url()).pathname.split('/t/')[1];

  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || !/^[a-f0-9-]{36}$/.test(trackId)) throw new Error('Invalid browser fixture');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  // Fixture row only: a failed setup is something the Inbox and the
  // project's badge count.
  execFileSync('psql', [`${server}/${database}`, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c',
    `UPDATE ravix.tracks SET setup_state = 'failed', setup_error = 'The opening turn failed.' WHERE id = '${trackId}'`]);
  await page.goto('/home');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  const badge = page.locator(`#home-project-${projectId} .badge`);
  await expect(badge).toBeVisible();
  const trigger = page.locator('#account-trigger');

  // Evidence first, so the same steps photograph origin/main.
  await page.screenshot({ path: 'tmp/topbar-nav.png', clip: { x: 0, y: 0, width: 1440, height: 120 } });
  await trigger.click();
  const menu = page.locator('#account-menu');
  await expect(menu).toBeVisible();
  await page.screenshot({ path: 'tmp/topbar-you-menu.png', clip: { x: 1040, y: 0, width: 400, height: 600 } });
  await page.keyboard.press('Escape');
  await expect(menu).toBeHidden();

  // The places to go: one height, the Inbox's count inside it. There is no
  // sidebar beside them any more.
  await expect(page.locator('#sidebar')).toHaveCount(0);
  const nav = page.locator('#topbar .topbar-nav');
  await expect(nav).toBeVisible();
  await expect(nav.locator('.topbar-item')).toHaveText(['Projects', /Inbox\s*1/, 'Schedules']);
  const heights = await nav.locator('.topbar-item').evaluateAll(els => els.map(el => Math.round(el.getBoundingClientRect().height)));
  expect(new Set(heights).size, `nav heights ${heights}`).toBe(1);
  const inbox = nav.getByRole('link', { name: /^Inbox/ });
  await expect(inbox.locator('.badge')).toHaveText('1');
  const [item, count] = await Promise.all([inbox.boundingBox(), inbox.locator('.badge').boundingBox()]);
  expect(count.y).toBeGreaterThanOrEqual(item.y);
  expect(count.y + count.height).toBeLessThanOrEqual(item.y + item.height);
  expect(count.x + count.width).toBeLessThanOrEqual(item.x + item.width);
  // Home (Projects) is the page shown, and says so.
  await expect(nav.getByRole('link', { name: 'Projects', exact: true })).toHaveAttribute('aria-current', 'page');
  await expect(nav.locator('[aria-current="page"]')).toHaveCount(1);

  // The project's count says what it counts.
  await expect(badge).toHaveAttribute('title', '1 track needs you');
  await expect(badge).toHaveAttribute('aria-label', '1 track needs you');

  // A row is lit by a tint, never underlined.
  await inbox.hover();
  expect(await inbox.evaluate(el => getComputedStyle(el).textDecorationLine)).toBe('none');
  expect(await inbox.evaluate(el => getComputedStyle(el).backgroundColor)).not.toMatch(/rgba\(0, 0, 0, 0\)|transparent/);

  // The You menu: 32px single-line rows, dropping down from the avatar and
  // kept inside the window at its right.
  await trigger.click();
  await expect(menu).toBeVisible();
  const rows = await menu.locator(':scope > .theme-picker > .theme-trigger, :scope > .notify > .theme-trigger, :scope > .account-item').evaluateAll(els => els.map(el => el.getBoundingClientRect().height));
  expect(rows.length).toBeGreaterThan(5);
  expect(new Set(rows), `menu rows ${rows}`).toEqual(new Set([32]));
  const [avatar, dropdown] = await Promise.all([trigger.boundingBox(), menu.boundingBox()]);
  expect(dropdown.y).toBeGreaterThanOrEqual(avatar.y + avatar.height);
  expect(dropdown.x + dropdown.width).toBeLessThanOrEqual(1440);
  expect(Math.abs(dropdown.x + dropdown.width - (avatar.x + avatar.width))).toBeLessThanOrEqual(8);
  await page.keyboard.press('Escape');
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
});
