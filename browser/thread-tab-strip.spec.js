import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { newThread } from './draft-runtime.js';

// RAV-97: the thread tab strip. The selected tab is underlined in the accent;
// the tabs scroll on their own and All threads lists them once they overrun
// the row; "+" is a menu (New thread, New terminal); a tab is renamed in
// place by a double-click, F2, or its ⋯. A tab has no close: Ravix has no
// way to close one thread.
test('thread tab strip: accent underline, overflow, + menu and rename', async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'eli');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
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

  // "+" opens a menu; New thread is the draft tab it always was.
  const add = page.getByRole('button', { name: 'New thread or terminal', exact: true });
  await add.click();
  await expect(add).toHaveAttribute('aria-expanded', 'true');
  const addMenu = page.locator('#thread-add-menu');
  await expect(addMenu.getByRole('button', { name: 'New terminal', exact: true })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(addMenu).toBeHidden();
  await expect(add).toBeFocused();
  for (const title of ['Fix the login redirect loop', 'Write migration for audit table',
    'Refactor the billing webhook handler', 'Add dark mode to settings page']) {
    await newThread(page);
    await expect(page.locator('#thread-tab-draft')).toBeVisible();
    await composer.fill(title);
    await page.getByRole('button', { name: 'Send', exact: true }).click();
    await expect(page.locator('#thread-tab-draft')).toHaveCount(0);
  }
  const tabs = page.locator('.thread-tab');
  await expect(tabs).toHaveCount(5);

  // The accent, not the ink, underlines the selected tab.
  const selected = page.locator('.thread-tab[aria-selected="true"]');
  const accent = await page.evaluate(() => {
    const probe = document.createElement('i');
    probe.style.color = 'var(--accent)';
    document.body.append(probe);
    const color = getComputedStyle(probe).color;
    probe.remove();
    return color;
  });
  expect(await selected.evaluate(el => getComputedStyle(el, '::after').backgroundColor)).toBe(accent);
  expect(await tabs.first().evaluate(el => getComputedStyle(el, '::after').backgroundColor)).not.toBe(accent);

  // Too many tabs for the row: the tablist scrolls, the selected tab stays
  // whole, nothing sits on top of it, and All threads lists every thread.
  await page.setViewportSize({ width: 1024, height: 800 });
  const strip = page.locator('#thread-switcher');
  await expect(strip).toHaveAttribute('data-overflow', /start|end/);
  const all = page.getByRole('button', { name: 'All threads', exact: true });
  await expect(all).toBeVisible();
  const list = await page.locator('#thread-tablist').boundingBox();
  const shown = await selected.boundingBox();
  expect(shown.x).toBeGreaterThanOrEqual(list.x - 1);
  expect(shown.x + shown.width).toBeLessThanOrEqual(list.x + list.width + 1);
  const addBox = await add.boundingBox();
  expect(addBox.x).toBeGreaterThanOrEqual(list.x + list.width - 1);
  const current = await selected.locator('.thread-tab-title').innerText();
  await all.click();
  const allMenu = page.locator('#thread-overflow-menu');
  await expect(allMenu.getByRole('button')).toHaveCount(5);
  await expect(allMenu.locator('[aria-current="true"]')).toHaveText(current);
  const first = await tabs.first().getAttribute('data-thread-id');
  await allMenu.getByRole('button').first().click();
  await expect(allMenu).toBeHidden();
  await expect(tabs.first()).toHaveAttribute('aria-selected', 'true');
  // Chosen from the menu, it is scrolled into sight.
  await expect.poll(() => page.locator('#thread-tablist').evaluate(list => {
    const tab = list.querySelector('.thread-tab[aria-selected="true"]').getBoundingClientRect();
    const box = list.getBoundingClientRect();
    return tab.left >= box.left - 1 && tab.right <= box.right + 1;
  })).toBe(true);
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
  await page.setViewportSize({ width: 1440, height: 900 });

  // Double-click: a field over the tab, focused with its text selected.
  // Enter saves, and focus returns to the tab.
  const second = tabs.nth(1);
  const id = await second.getAttribute('data-thread-id');
  await second.dblclick();
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

  // ⋯ › Rename, then Escape: nothing changes and focus returns to the tab.
  await expect(renamed).toHaveAttribute('aria-selected', 'true');
  await page.getByRole('button', { name: 'More for this thread', exact: true }).click();
  await page.locator('#thread-more-menu').getByRole('button', { name: /Rename thread/ }).click();
  await expect(field).toBeFocused();
  await field.fill('Thrown away');
  await field.press('Escape');
  await expect(field).toHaveCount(0);
  await expect(renamed.locator('.thread-tab-title')).toHaveText('Audit table migration');
  await expect(renamed).toBeFocused();

  // F2 on a tab, then leaving the field, saves too; the name survives a reload.
  await renamed.press('F2');
  await expect(field).toBeFocused();
  await field.fill('Audit migration');
  await composer.click();
  await expect(renamed.locator('.thread-tab-title')).toHaveText('Audit migration');
  await page.reload();
  await expect(page.locator(`#thread-tab-${id} .thread-tab-title`)).toHaveText('Audit migration');
  await expect(page.locator(`#thread-tab-${first}`)).toBeVisible();
  // No close on a tab.
  await expect(page.locator('#thread-tablist button[aria-label^="Close"]')).toHaveCount(0);
});
