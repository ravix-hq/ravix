import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-98: every icon-only control on a track's page is named and has the
// app's one tooltip, which a pointer and the keyboard both show, with the
// shortcut beside it; the keyboard draws a focus ring and a click does not.

// Visible controls with no word a sighted person can read, and what each lacks.
async function iconOnlyGaps(page) {
  return page.evaluate(() => {
    const visible = el => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
    const words = el => {
      const copy = el.cloneNode(true);
      copy.querySelectorAll('[aria-hidden=true], .sr-only, svg').forEach(n => n.remove());
      return /[\p{L}\p{N}]/u.test(copy.textContent);
    };
    const gaps = [];
    for (const el of document.querySelectorAll('button, a[href], summary')) {
      if (!visible(el) || el.closest('.sr-only, [aria-hidden=true], #tooltip') || words(el)) continue;
      // A thumbnail is named by its image's alt text.
      if (el.querySelector('img[alt]')) continue;
      const named = el.getAttribute('aria-label') || el.getAttribute('aria-labelledby') || el.querySelector('.sr-only')?.textContent.trim();
      const id = el.id ? `#${el.id}` : `${el.tagName.toLowerCase()}.${[...el.classList].join('.')}`;
      if (!named) gaps.push(`${id}: no name`);
      if (!el.dataset.tip) gaps.push(`${id}: no tooltip`);
    }
    return gaps;
  });
}

const ring = locator => locator.evaluate(el => {
  const style = getComputedStyle(el);
  return { style: style.outlineStyle, width: style.outlineWidth };
});

test('icon-only controls are named and tipped, and only the keyboard draws a ring', async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1280, height: 800 });
  await signIn(page, 'tooltipfocus', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill(`Tooltips ${Date.now().toString(36)}`);
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  const projectRow = page.locator('#yard .workspace-project.current');
  await projectRow.locator('.project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 30_000 });

  expect(await iconOnlyGaps(page)).toEqual([]);
  const axe = await new AxeBuilder({ page }).withRules(['button-name', 'link-name', 'summary-name']).analyze();
  expect(axe.violations.map(v => `${v.id}: ${v.nodes.map(n => n.target).join(', ')}`)).toEqual([]);

  // A pointer: the tip comes after a pause, under the control, with its shortcut.
  const tooltip = page.locator('#tooltip');
  const search = page.locator('#quick-jump-trigger');
  await search.hover();
  await expect(tooltip).toBeVisible();
  await expect(tooltip).toContainText('Search projects, tracks and plans');
  await expect(tooltip.locator('kbd')).toHaveText(/^(⌘K|Ctrl\+K)$/);
  const [anchor, tip] = await Promise.all([search.boundingBox(), tooltip.boundingBox()]);
  expect(tip.y).toBeGreaterThanOrEqual(anchor.y + anchor.height);
  await page.screenshot({ path: test.info().outputPath('tooltip-hover.png') });

  // Moving to the next control shows its tip at once; leaving hides it.
  await projectRow.hover();
  await projectRow.locator('.project-add').hover();
  await expect(tooltip).toHaveText('New track');
  await page.mouse.move(640, 700);
  await expect(tooltip).toBeHidden();

  // A click focuses without a ring and hides the tip.
  const toggle = page.locator('#inspector-toggle');
  await toggle.click();
  await expect(toggle).toBeFocused();
  expect((await ring(toggle)).style).toBe('none');
  await expect(tooltip).toBeHidden();
  await toggle.click();

  // The keyboard: a two-pixel ring, and the tip without waiting.
  await page.locator('#track-more-trigger').focus();
  await page.keyboard.press('Shift+Tab');
  await page.keyboard.press('Tab');
  const more = page.locator('#track-more-trigger');
  await expect(more).toBeFocused();
  expect(await ring(more)).toEqual({ style: 'solid', width: '2px' });
  await expect(tooltip).toHaveText('More for this track');
  await page.screenshot({ path: test.info().outputPath('focus-ring.png') });
  await page.keyboard.press('Escape');
  await expect(tooltip).toBeHidden();

  // Sharing opened and closed with the mouse, by Escape or its ×: focus goes
  // back to the button with no ring. Opened from the keyboard, the ring stays.
  const share = page.getByRole('button', { name: /^Track sharing/ });
  const people = page.getByRole('dialog');
  for (const close of [() => page.keyboard.press('Escape'), () => people.getByRole('button', { name: 'Close', exact: true }).click()]) {
    await share.click();
    await expect(people).toBeVisible();
    await page.mouse.move(640, 700);
    await close();
    await expect(people).toBeHidden();
    await expect(share).toBeFocused();
    expect((await ring(share)).style).toBe('none');
    await expect(tooltip).toBeHidden();
  }
  await page.keyboard.press('Shift+Tab');
  await page.keyboard.press('Tab');
  await expect(share).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(people).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(share).toBeFocused();
  expect(await ring(share)).toEqual({ style: 'solid', width: '2px' });

  // A click in the transcript's empty space outlines nothing.
  const scroller = page.locator('#transcript-scroll');
  const box = await scroller.boundingBox();
  await page.mouse.click(box.x + box.width / 2, box.y + 40);
  expect((await ring(scroller)).style).toBe('none');

  // Every theme draws the ring in its accent, never transparent.
  for (const theme of ['daylight', 'github-light']) {
    await page.evaluate(t => { document.documentElement.dataset.theme = t; }, theme);
    const color = await more.evaluate(el => getComputedStyle(el).outlineColor);
    expect(color).not.toMatch(/rgba\(0, 0, 0, 0\)|transparent/);
  }

  // New track is the first tab stop, though the rail's top row is drawn above it.
  await page.goto('/home');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await page.keyboard.press('Tab');
  await expect(page.locator('#top-new-track')).toBeFocused();
  const [first, top] = await Promise.all([
    page.locator('#top-new-track').boundingBox(),
    page.locator('#quick-jump-trigger').boundingBox(),
  ]);
  expect(top.y).toBeLessThan(first.y);

  // The other pages' icon-only controls, and the open account menu's.
  for (const path of ['/home', '/inbox', '/schedules']) {
    await page.goto(path);
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    expect(await iconOnlyGaps(page), path).toEqual([]);
  }
  await page.locator('#account-trigger').click();
  await expect(page.locator('#account-menu')).toBeVisible();
  expect(await iconOnlyGaps(page)).toEqual([]);
});
