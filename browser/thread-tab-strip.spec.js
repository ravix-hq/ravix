import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { newThread } from './draft-runtime.js';
import { openAddRepository } from './new-track.js';

const bottom = (page, selector) => page.locator(selector).first().evaluate(el => el.getBoundingClientRect().bottom);

// RAV-97: the thread tabs. The active mark is the tab colour wherever tabs
// are; beside the conversation they stand on end, one per row with its state
// and agent under its name; across the top (a narrow window) they stop at
// about 180px and, once they overrun the row, fade at the edges and gain ‹ ›;
// "+" is a menu; the active tab is renamed with ✎, a double-click or F2; a
// hovered tab's × closes (archives) its thread; and the track's head sits
// straight under the top bar with the thread list straight under its tabs'
// hairline.
test('thread tab strip: underline, overflow, + menu, rename, close and aligned pane heads', async ({ page }) => {
  test.setTimeout(150_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'eli');
  await connectClaude(page);
  await openAddRepository(page);
  const dialog = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await dialog.getByLabel('Project name', { exact: true }).fill('Tab strip');
  await dialog.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(dialog).not.toBeVisible();
  await page.locator('#top-new-track').click();
  const newTrack = page.getByRole('dialog', { name: 'New track', exact: true });
  await newTrack.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(newTrack).not.toBeVisible();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });

  // The track's head under the top bar: its tabs end it on one hairline,
  // and the thread list starts on that line. One thread is listed too.
  const head = await bottom(page, '#track-header');
  const top = await page.locator('#track-header').first().evaluate(el => el.getBoundingClientRect().top);
  expect(top).toBe(await bottom(page, '#topbar'));
  expect(await bottom(page, '#track-header .track-tabs')).toBe(head);
  expect(await page.locator('#track-header .track-tabs').evaluate(el => getComputedStyle(el).borderBottomWidth)).toBe('1px');
  await expect(page.locator('#thread-switcher')).toBeVisible();
  expect(await page.locator('#thread-switcher').evaluate(el => el.getBoundingClientRect().top)).toBe(head);
  await expect(page.locator('.thread-tab')).toHaveCount(1);

  // "+" opens a menu of 32px rows; New thread is the draft tab it always was.
  const add = page.getByRole('button', { name: 'Add thread', exact: true });
  await add.click();
  await expect(add).toHaveAttribute('aria-expanded', 'true');
  const addMenu = page.locator('#thread-add-menu');
  const row = addMenu.getByRole('button', { name: /^New thread/ });
  await expect(row).toBeVisible();
  await expect(row.locator('kbd')).toHaveText(/^(⌘T|Ctrl\+T)$/);
  expect((await row.boundingBox()).height).toBeGreaterThanOrEqual(32);
  await page.keyboard.press('Escape');
  await expect(addMenu).toBeHidden();
  await expect(add).toBeFocused();
  for (const title of ['Fix the login redirect loop', 'Write migration for audit table',
    'Refactor the billing webhook handler', 'Add dark mode to the settings page',
    'Investigate the flaky upload test on CI']) {
    await newThread(page);
    await expect(page.locator('#thread-tab-draft')).toBeVisible();
    await composer.fill(title);
    await page.getByRole('button', { name: 'Send', exact: true }).click();
    await expect(page.locator('#thread-tab-draft')).toHaveCount(0);
  }
  const tabs = page.locator('.thread-tab');
  await expect(tabs).toHaveCount(6);

  // The tab colour, not the ink, marks the selected tab, here and in the
  // track's own tabs.
  const accent = await page.evaluate(() => {
    const probe = document.createElement('i');
    probe.style.color = 'var(--tab)';
    document.body.append(probe);
    const color = getComputedStyle(probe).color;
    probe.remove();
    return color;
  });
  const selected = page.locator('.thread-tab[aria-selected="true"]');
  expect(await selected.evaluate(el => getComputedStyle(el, '::after').backgroundColor)).toBe(accent);
  expect(await tabs.first().evaluate(el => getComputedStyle(el, '::after').backgroundColor)).not.toBe(accent);
  const trackTab = page.locator('#track-header .track-tabs > button.on');
  await expect(trackTab).toHaveCount(1);
  expect(await trackTab.evaluate(el => getComputedStyle(el).borderBottomColor)).toBe(accent);

  // Beside the conversation: one 220px column, a row per thread, each with
  // its state and agent under its name, and nothing to scroll sideways.
  const strip = page.locator('#thread-switcher');
  await expect(page.locator('#thread-tablist')).toHaveAttribute('aria-orientation', 'vertical');
  expect(Math.round((await strip.boundingBox()).width)).toBe(220);
  const rows = await tabs.evaluateAll(els => els.map(el => {
    const { left, top, width } = el.getBoundingClientRect();
    return { left: Math.round(left), top, width: Math.round(width) };
  }));
  expect(new Set(rows.map(row => row.left)).size, `tab lefts ${rows.map(row => row.left)}`).toBe(1);
  expect(new Set(rows.map(row => row.width)).size, `tab widths ${rows.map(row => row.width)}`).toBe(1);
  expect(rows.every((row, i) => i === 0 || row.top > rows[i - 1].top)).toBe(true);
  await expect(tabs.nth(1).locator('.thread-tab-meta')).toBeVisible();
  await expect(tabs.nth(1).locator('.thread-tab-meta')).toHaveText(/^\S.* · \S/);
  expect(await tabs.nth(2).locator('.thread-tab-title').evaluate(el => getComputedStyle(el).textOverflow)).toBe('ellipsis');
  await expect(page.getByRole('button', { name: 'Scroll threads left', exact: true })).toBeHidden();
  await expect(page.getByRole('button', { name: 'Scroll threads right', exact: true })).toBeHidden();

  // Across the top of a narrow window, six tabs overrun the row: each stops
  // at about 180px and ends in "…", the tablist scrolls, and ‹ › move it.
  await page.setViewportSize({ width: 700, height: 800 });
  await expect(tabs.nth(1).locator('.thread-tab-meta')).toBeHidden();
  await expect(strip).toHaveAttribute('data-overflow', /start|end/);
  for (const width of await tabs.evaluateAll(els => els.map(el => el.getBoundingClientRect().width))) {
    expect(width).toBeLessThanOrEqual(181);
  }
  expect(await tabs.nth(2).locator('.thread-tab-title').evaluate(el => getComputedStyle(el).textOverflow)).toBe('ellipsis');
  const back = page.getByRole('button', { name: 'Scroll threads left', exact: true });
  const forward = page.getByRole('button', { name: 'Scroll threads right', exact: true });
  await expect(back).toBeVisible();
  await expect(forward).toBeVisible();
  const list = page.locator('#thread-tablist');
  const scrollLeft = () => list.evaluate(el => el.scrollLeft);
  await list.evaluate(el => { el.scrollLeft = el.scrollWidth; });
  const before = await scrollLeft();
  await back.click();
  await expect.poll(scrollLeft).toBeLessThan(before);
  await forward.click();
  await expect.poll(scrollLeft).toBeGreaterThan(before - 1);
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
  await page.setViewportSize({ width: 1440, height: 900 });

  // ✎ on the active tab: a field over it, focused with its text selected.
  // Enter saves, and focus returns to the tab.
  const second = tabs.nth(1);
  const id = await second.getAttribute('data-thread-id');
  await second.click();
  await expect(second).toHaveAttribute('aria-selected', 'true');
  // Hovering shows × without moving ✎: nothing shifts under the pointer.
  const pencil = second.locator('.thread-tab-rename');
  await page.mouse.move(0, 0);
  const still = await pencil.boundingBox();
  await second.hover();
  await expect(second.locator('.thread-tab-close')).toBeVisible();
  expect(await pencil.boundingBox()).toEqual(still);
  await pencil.click();
  const field = page.getByRole('textbox', { name: 'Thread name', exact: true });
  await expect(field).toBeFocused();
  expect(await field.evaluate(el => el.selectionEnd - el.selectionStart)).toBe((await field.inputValue()).length);
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
  await field.fill('Audit table migration');
  await field.press('Enter');
  await expect(field).toHaveCount(0);
  const renamed = page.locator(`#thread-tab-${id}`);
  await expect(renamed.locator('.thread-tab-title')).toHaveText('Audit table migration');
  await expect(renamed).toBeFocused();

  // A double-click, then Escape: nothing changes and focus returns.
  await renamed.dblclick();
  await expect(field).toBeFocused();
  await field.fill('Thrown away');
  await field.press('Escape');
  await expect(field).toHaveCount(0);
  await expect(renamed.locator('.thread-tab-title')).toHaveText('Audit table migration');
  await expect(renamed).toBeFocused();

  // F2, then leaving the field, saves too; the name survives a reload.
  await renamed.press('F2');
  await expect(field).toBeFocused();
  await field.fill('Audit migration');
  await composer.click();
  await expect(renamed.locator('.thread-tab-title')).toHaveText('Audit migration');
  await page.reload();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(page.locator(`#thread-tab-${id} .thread-tab-title`)).toHaveText('Audit migration');

  // A hovered tab shows × ("Close thread"); an idle thread closes at once,
  // and stays closed after a reload.
  const last = tabs.last();
  const closing = await last.getAttribute('data-thread-id');
  const close = last.locator('.thread-tab-close');
  await expect(close).toBeHidden();
  await last.hover();
  await expect(close).toBeVisible();
  await expect(close).toHaveAttribute('data-tip', 'Close thread');
  expect((await close.boundingBox()).width).toBe(20);
  await close.click();
  await expect(page.locator(`#thread-tab-${closing}`)).toHaveCount(0);
  await expect(tabs).toHaveCount(5);
  await page.reload();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(tabs).toHaveCount(5);
  await expect(page.locator(`#thread-tab-${closing}`)).toHaveCount(0);
  // Delete on a focused tab closes it as well.
  const fourth = tabs.nth(3);
  const deleted = await fourth.getAttribute('data-thread-id');
  await fourth.click();
  await fourth.press('Delete');
  await expect(page.locator(`#thread-tab-${deleted}`)).toHaveCount(0);
  await expect(tabs).toHaveCount(4);
  await expect(page.locator('.thread-tab[aria-selected="true"]')).toHaveCount(1);
});
