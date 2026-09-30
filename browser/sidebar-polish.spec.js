import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn, connectClaude } from './sign-in.js';

// RAV-96: every sidebar row keeps one height and one gap, a working track
// spins where its age would be, a private one is a lock rather than a word,
// and the open track is scrolled into view however long the rail is.
test('sidebar rows keep one rhythm, spin while working and keep the open track in view', async ({ page }) => {
  test.setTimeout(150_000);
  await page.setViewportSize({ width: 1280, height: 640 });
  await signIn(page, 'sidebarpolish', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill(`Sidebar polish ${Date.now().toString(36)}`);
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  const projectRow = page.locator('#yard .workspace-project.current');
  const projectId = await projectRow.getAttribute('data-project-id');

  const ids = [];
  for (let i = 0; i < 3; i++) {
    const previousPath = new URL(page.url()).pathname;
    await projectRow.locator('.project-add').click();
    await page.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect.poll(() => new URL(page.url()).pathname).not.toBe(previousPath);
    // Idle once the opening turn has settled, so nothing redraws a row later.
    await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 30_000 });
    ids.push(new URL(page.url()).pathname.split('/t/')[1]);
  }
  const [privateId, runningId, openId] = ids;

  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || ids.some(id => !/^[a-f0-9-]{36}$/.test(id))) throw new Error('Invalid browser fixture');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  const sql = query => execFileSync('psql', [`${server}/${database}`, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c', query], { encoding: 'utf8' }).trim();
  // Fixture rows only. The rail lists oldest first, so a dozen siblings a
  // day older than the open track put it below
  // the fold of a 640px window, and one track is private.
  sql(`
    UPDATE ravix.tracks SET title = 'Private notes', visibility = 'private' WHERE id = '${privateId}';
    UPDATE ravix.tracks SET title = 'Refactor the rail' WHERE id = '${runningId}';
    UPDATE ravix.tracks SET title = 'The open track' WHERE id = '${openId}';
    INSERT INTO ravix.tracks
    SELECT (jsonb_populate_record(t, jsonb_build_object(
      'id', gen_random_uuid(), 'slug', t.slug || '-' || n, 'branch', t.branch || '-' || n,
      'sandbox_id', NULL, 'conversation_id', t.conversation_id || '-sibling-' || n,
      'title', 'Sibling ' || n, 'created_at', t.created_at - interval '1 day' + make_interval(mins => n)))).*
    FROM ravix.tracks t, generate_series(1, 12) n WHERE t.id = '${openId}';
  `);

  // One track takes a turn the mock keeps running for twelve seconds.
  await page.goto(`/p/${projectId}/t/${runningId}`);
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled();
  await composer.fill('Demonstrate a long-running turn');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(page.locator('#track-machine-state')).toHaveText('Working', { timeout: 20_000 });

  await page.goto(`/p/${projectId}/t/${openId}`);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  const rail = page.locator('#yard .yard-scroll');
  const rows = projectRow.locator('.project-tree-tracks .track-tab');
  await expect(rows).toHaveCount(15);
  const open = page.locator(`#project-track-tab-${openId}`);
  await expect(open).toHaveAttribute('aria-current', 'page');

  // Working: a spinner in the age slot, not a dot as well, and the same
  // slot's right edge as every age. The row's name still says Working.
  const running = page.locator(`#project-track-tab-${runningId}`);
  await expect(running).toHaveAttribute('aria-label', /, Working/);
  await page.screenshot({ path: 'tmp/sidebar-polish-open.png' });
  // Evidence before any assertion, so the same steps photograph origin/main:
  // the rail's last rows up close, and the project's ⋯ menu.
  const scrolled = await rail.evaluate(el => el.scrollTop);
  await rail.evaluate(el => { el.scrollTop = el.scrollHeight; });
  await page.locator('#yard').screenshot({ path: 'tmp/sidebar-polish-rows.png' });
  await projectRow.locator('.workspace-project-row').hover();
  await projectRow.getByRole('button', { name: /^More for / }).click();
  await expect(projectRow.locator('.project-menu')).toBeVisible();
  await page.screenshot({ path: 'tmp/sidebar-polish-menu.png' });
  await page.keyboard.press('Escape');
  await expect(projectRow.locator('.project-menu')).toBeHidden();
  await rail.evaluate((el, top) => { el.scrollTop = top; }, scrolled);
  await expect(running.locator('.track-meta .track-spinner')).toBeVisible();
  await expect(running.locator('.track-spinner')).toHaveAttribute('aria-label', 'Working');
  await expect(running.locator('.dot')).toHaveCount(0);
  await expect(running.locator('.track-age')).toHaveCount(0);
  const right = async locator => { const box = await locator.boundingBox(); return Math.round(box.x + box.width); };
  expect(await right(running.locator('.track-meta'))).toBe(await right(open.locator('.track-meta')));

  // The open track is on screen, and it had to be scrolled to.
  const inView = async () => {
    const [view, box] = await Promise.all([rail.boundingBox(), open.boundingBox()]);
    return box.y >= view.y && box.y + box.height <= view.y + view.height;
  };
  await expect.poll(inView).toBe(true);
  expect(await rail.evaluate(el => el.scrollTop)).toBeGreaterThan(0);

  // One height for every row, project and track, and one gap between tracks.
  const boxes = await rows.evaluateAll(els => els.map(el => el.getBoundingClientRect()).map(({ y, height }) => ({ y, height })));
  const projectHeight = (await projectRow.locator('.workspace-project-row').boundingBox()).height;
  expect(new Set([projectHeight, ...boxes.map(box => box.height)]), `row heights ${projectHeight} ${boxes.map(box => box.height)}`).toEqual(new Set([28]));
  const gaps = boxes.slice(1).map((box, i) => Math.round(box.y - boxes[i].y));
  expect(new Set(gaps), `row steps ${gaps}`).toEqual(new Set([29]));

  // Private: a lock with a tooltip, in the row's name, not a word in its room.
  const lock = page.locator(`#project-track-tab-${privateId} .track-private`);
  await expect(lock.locator('svg')).toBeVisible();
  await expect(lock).toHaveAttribute('title', /^Private/);
  await expect(page.locator(`#project-track-tab-${privateId}`)).toHaveAttribute('aria-label', /, private,/);
  expect((await lock.boundingBox()).width).toBeLessThan(16);

  // A patch that keeps the same track open leaves the rail where the person
  // put it: switching Mine and back redraws every row.
  await rail.evaluate(el => { el.scrollTop = 0; });
  await page.locator('#rail-scope-mine').click();
  await expect(page.locator('#rail-scope-mine')).toHaveAttribute('aria-pressed', 'true');
  await page.locator('#rail-scope-everyone').click();
  await expect(page.locator('#rail-scope-everyone')).toHaveAttribute('aria-pressed', 'true');
  expect(await rail.evaluate(el => el.scrollTop)).toBe(0);

  // Opening a track in a project folded in this browser (from a link, or
  // quick jump) unfolds it and brings the row into view.
  await projectRow.locator('.project-collapse').click();
  await expect(open).toBeHidden();
  await page.goto(`/p/${projectId}/t/${privateId}`);
  await expect(page.locator(`#project-track-tab-${privateId}`)).toBeVisible();
  await projectRow.locator('.project-collapse').click();
  await expect(open).toBeHidden();
  await page.locator('#quick-jump-trigger').click();
  await page.locator('#search-query').fill('The open track');
  await page.locator('#search-dialog [data-jump-result]').filter({ hasText: 'The open track' }).first().click();
  await expect(open).toHaveAttribute('aria-current', 'page');
  await expect(open).toBeVisible();
  await expect.poll(inView).toBe(true);

  // The ⋯ menu is a menu button: the keyboard opens it onto its first item,
  // the arrows move, and Escape closes it back onto its trigger.
  const more = projectRow.getByRole('button', { name: /^More for / });
  await expect(more).toHaveAttribute('aria-haspopup', 'menu');
  await more.focus();
  await page.keyboard.press('ArrowDown');
  await expect(more).toHaveAttribute('aria-expanded', 'true');
  await expect(projectRow.getByRole('menuitem', { name: /^People in / })).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(projectRow.getByRole('menuitemcheckbox', { name: 'Show closed tracks' })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(projectRow.locator('.project-menu')).toBeHidden();
  await expect(more).toHaveAttribute('aria-expanded', 'false');
  await expect(more).toBeFocused();
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
});
