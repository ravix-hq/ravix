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
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill(`Sidebar polish ${Date.now().toString(36)}`);
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
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
  // RAV-74: the open project's Settings comes first, then its People.
  await expect(projectRow.getByRole('menuitem', { name: /^Settings for / })).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(projectRow.getByRole('menuitem', { name: /^People in / })).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(projectRow.getByRole('menuitemcheckbox', { name: 'Show closed tracks' })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(projectRow.locator('.project-menu')).toBeHidden();
  await expect(more).toHaveAttribute('aria-expanded', 'false');
  await expect(more).toBeFocused();
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
});

// RAV-96: the nav's rows are one height with their counts inside them, the
// sidebar toggle says what it hides and its shortcut, the project list keeps
// its width when it scrolls, a count says what it counts, and the You menu
// is single-line rows under a chevron pointing the way it opens.
test('the sidebar nav and You menu keep one pitch and say what they do', async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'sidebarpolish', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill(`Sidebar nav ${Date.now().toString(36)}`);
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  const projectRow = page.locator('#yard .workspace-project.current');
  await projectRow.locator('.project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 30_000 });
  const trackId = new URL(page.url()).pathname.split('/t/')[1];
  const projectId = await projectRow.getAttribute('data-project-id');

  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || !/^[a-f0-9-]{36}$/.test(trackId)) throw new Error('Invalid browser fixture');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  // Fixture row only: a failed setup is something the Inbox and the
  // project's badge count.
  execFileSync('psql', [`${server}/${database}`, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c',
    `UPDATE ravix.tracks SET setup_state = 'failed', setup_error = 'The opening turn failed.' WHERE id = '${trackId}'`]);
  await page.goto('/inbox');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  const badge = page.locator(`#project-link-${projectId} .badge`);
  await expect(badge).toBeVisible();
  const trigger = page.locator('#account-trigger');

  // Evidence first, so the same steps photograph origin/main.
  await page.screenshot({ path: 'tmp/sidebar-nav.png', clip: { x: 0, y: 0, width: 320, height: 900 } });
  await trigger.click();
  const menu = page.locator('#account-menu');
  await expect(menu).toBeVisible();
  await page.screenshot({ path: 'tmp/sidebar-you-menu.png', clip: { x: 0, y: 0, width: 320, height: 900 } });
  await page.keyboard.press('Escape');
  await expect(menu).toBeHidden();

  // Nav rows: one height, the Inbox's count inside it.
  const heights = await page.locator('#yard .yard-nav .yard-item').evaluateAll(els => els.map(el => el.getBoundingClientRect().height));
  expect(new Set(heights), `nav heights ${heights}`).toEqual(new Set([30]));
  await expect(page.locator('#yard .yard-nav .yard-item .badge')).toHaveText('1');

  // The project's count says what it counts.
  await expect(badge).toHaveAttribute('title', '1 track needs you');
  await expect(badge).toHaveAttribute('aria-label', '1 track needs you');

  // The toggle hides the sidebar, says so, and Ctrl+B does the same.
  const toggle = page.locator('#yard-toggle');
  await expect(toggle).toHaveAttribute('title', 'Hide sidebar (Ctrl+B)');
  await expect(toggle).toHaveAccessibleName('Hide sidebar');
  await page.keyboard.press('Control+b');
  await expect(page.locator('html')).toHaveAttribute('data-yard', 'closed');
  await expect(toggle).toHaveAttribute('title', 'Show sidebar (Ctrl+B)');
  await page.keyboard.press('Control+b');
  await expect(page.locator('html')).not.toHaveAttribute('data-yard', 'closed');

  // The project list keeps its scrollbar's room whether or not it scrolls.
  expect(await page.locator('#yard .yard-scroll').evaluate(el => getComputedStyle(el).scrollbarGutter)).toBe('stable');

  // A row is lit by a tint, never underlined.
  const row = page.locator(`#project-track-tab-${trackId}`);
  await row.hover();
  expect(await row.evaluate(el => getComputedStyle(el).textDecorationLine)).toBe('none');

  // The You menu: 32px single-line rows, opened by a chevron pointing up.
  const up = await page.locator('.account-chevron').evaluate(el => new DOMMatrix(getComputedStyle(el).transform).b);
  expect(up).toBeCloseTo(-1);
  await trigger.click();
  await expect(menu).toBeVisible();
  const rows = await menu.locator(':scope > .theme-picker > .theme-trigger, :scope > .notify > .theme-trigger, :scope > .account-item').evaluateAll(els => els.map(el => el.getBoundingClientRect().height));
  expect(rows.length).toBeGreaterThan(5);
  expect(new Set(rows), `menu rows ${rows}`).toEqual(new Set([32]));
  await page.keyboard.press('Escape');
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
});
