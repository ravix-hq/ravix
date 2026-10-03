import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-100: Inbox, Schedules and Not found share one content edge and width,
// and Home's dashboard runs the window's width; the top bar's places keep
// their height when counts arrive; a dialog does not
// move once it is open; a form's selects stand as tall as its inputs. A
// failed setup is written into the harness's disposable database only, as
// workspace-visibility.spec.js does, to put cards in the Inbox.
function browserSql() {
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database)) throw new Error('Not a browser database');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  return query => execFileSync('psql', [`${server}/${database}`, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c', query], { encoding: 'utf8' }).trim();
}

const connected = page => expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);

test('stage pages share one edge; the nav, dialogs and selects hold still', async ({ page }) => {
  test.setTimeout(150_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'stagepages', '/home');
  await connectClaude(page);

  // The Add repository dialog's top stays where it opened while the
  // repositories arrive, and the field under them does not move.
  await page.goto('/home');
  await connected(page);
  await openAddRepository(page);
  const dialog = page.locator('#new-project-dialog-dialog');
  await expect(dialog).toBeVisible();
  const frames = await page.evaluate(() => new Promise(resolve => {
    const seen = [];
    const start = performance.now();
    const tick = () => {
      const box = document.querySelector('#new-project-dialog-dialog')?.getBoundingClientRect();
      if (box) seen.push(Math.round(box.top));
      if (performance.now() - start < 1500) requestAnimationFrame(tick); else resolve(seen);
    };
    tick();
  }));
  expect(new Set(frames).size).toBe(1);
  await expect(dialog.getByLabel('GitHub account', { exact: true })).toBeVisible();
  expect(Math.round((await dialog.boundingBox()).y)).toBe(frames[0]);
  await dialog.getByLabel('Project name', { exact: true }).fill('Stage pages');
  await dialog.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(dialog).toHaveCount(0);

  // A track whose setup failed, so the Inbox has a card and a count.
  await page.locator('#top-new-track').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page).toHaveURL(url => url.pathname.includes('/t/'));
  const trackId = new URL(page.url()).pathname.split('/t/')[1];
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 60_000 });
  browserSql()(`UPDATE ravix.tracks SET setup_state = 'failed' WHERE id = '${trackId}'`);

  const edges = {};
  for (const path of ['/home', '/inbox', '/schedules', '/no-such-page']) {
    await page.goto(path);
    await connected(page);
    // Home is the three-column dashboard, not a stage page; the others are.
    const inner = page.locator(path === '/home' ? '#project-tabpanel #home.home-dashboard' : '#project-tabpanel .stage-page-inner');
    await expect(inner).toHaveCount(1);
    if (path === '/home') await expect(page.locator('#project-tabpanel .stage-page-inner')).toHaveCount(0);
    const box = await inner.boundingBox();
    edges[path] = { left: Math.round(box.x), width: Math.round(box.width) };
  }
  // Inbox, Schedules and the 404 share one column; Home is the dashboard,
  // full-bleed: its side column flush with the window's left edge.
  for (const path of ['/schedules', '/no-such-page']) expect(edges[path]).toEqual(edges['/inbox']);
  expect(edges['/home'].left).toBe(0);
  expect(edges['/home'].width).toBe(1440);
  expect(edges['/home'].width).toBeGreaterThan(edges['/inbox'].width);
  await page.goto('/home');
  await connected(page);
  const side = await page.locator('#home-side').boundingBox();
  expect(Math.round(side.x)).toBe(0);
  expect(Math.round(side.width)).toBe(320);

  // The Inbox's count sits inside its place in the top bar: every place
  // there is one height.
  await page.goto('/inbox');
  await connected(page);
  const nav = page.locator('#topbar .topbar-nav');
  await expect(nav.getByRole('link', { name: /^Inbox/ }).locator('.badge')).toHaveText('1');
  const heights = await nav.locator('.topbar-item').evaluateAll(rows =>
    rows.map(row => Math.round(row.getBoundingClientRect().height)));
  expect(heights).toHaveLength(3);
  expect(new Set(heights).size).toBe(1);
  const inbox = await new AxeBuilder({ page }).include('#inbox')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(inbox.violations).toEqual([]);

  // Schedules: one line and Learn more, the empty card's action, and selects
  // the inputs' height.
  await page.goto('/schedules');
  await connected(page);
  const panel = page.locator('#schedules-panel');
  await expect(panel.getByText('Refresh to see the latest run status')).toBeHidden();
  await panel.getByText('Learn more', { exact: true }).click();
  await expect(panel.getByText('Refresh to see the latest run status')).toBeVisible();
  const name = page.locator('#schedule-form').getByLabel('Name', { exact: true });
  const repeat = page.locator('#schedule-form').getByLabel('Repeat', { exact: true });
  expect(Math.round((await repeat.boundingBox()).height)).toBe(Math.round((await name.boundingBox()).height));
  await page.locator('#schedules-empty').getByRole('button', { name: 'Create schedule', exact: true }).click();
  await expect(name).toBeFocused();
  const schedules = await new AxeBuilder({ page }).include('#schedules-panel')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(schedules.violations).toEqual([]);
});
