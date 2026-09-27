import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

test('vertical track tabs preserve keyboard navigation and the mobile drawer', async ({ page }) => {
  test.setTimeout(120_000);
  // Keep mockuser's first-visit state for the onboarding walkthrough.
  await signIn(page, 'eli');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project' });
  await project.getByLabel('Project name', { exact: true }).fill('Scrolling tracks');
  await expect(project.locator('#project-repositories option')).not.toHaveCount(0);
  await project.getByLabel('Repository', { exact: true }).fill('mockuser/atlas-api');
  await project.getByRole('button', { name: 'Create project' }).click();
  await expect(project).not.toBeVisible();
  const nav = page.getByRole('navigation', { name: 'Project tracks', exact: true });
  for (let index = 0; index < 7; index++) {
    await nav.getByRole('button', { name: 'New track', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
    await dialog.getByRole('button', { name: 'Advanced', exact: true }).click();
    await dialog.getByLabel('Branch name').fill(`scrolling-track-${index}`);
    await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect(dialog).not.toBeVisible();
    await expect(nav.locator('.workspace-track')).toHaveCount(index + 1);
  }
  const strip = page.getByRole('tablist', { name: 'Project tracks' });
  await expect(strip).toHaveAttribute('aria-orientation', 'vertical');
  await expect(strip.locator('.track-num')).toHaveCount(0);
  await expect(strip.getByRole('tab').first()).toHaveText('Overview');
  await expect(strip.getByRole('tab')).toHaveCount(8);
  for (const width of [1280, 500, 390]) {
    await page.setViewportSize({ width, height: 600 });
    if (width < 760) {
      await expect(strip).not.toBeVisible();
      await page.getByRole('button', { name: 'Menu', exact: true }).click();
    }
    await expect(page.locator('#yard')).toContainText('scrolling-track-0');
    const boxes = await strip.getByRole('tab').evaluateAll(tabs => tabs.map(tab => {
      const { x, y, height } = tab.getBoundingClientRect();
      return { x, y, height };
    }));
    for (let index = 1; index < boxes.length; index++) {
      expect(boxes[index].x).toBe(boxes[0].x);
      expect(boxes[index].y).toBeGreaterThanOrEqual(boxes[index - 1].y + boxes[index - 1].height);
    }
    const selected = strip.locator('[aria-selected="true"]');
    await selected.focus();
    await selected.press('Home');
    const overview = strip.getByRole('tab', { name: 'Overview', exact: true });
    await expect(overview).toBeFocused();
    await overview.press('ArrowUp');
    const last = strip.getByRole('tab').last();
    await expect(last).toBeFocused();
    await expect(last).toBeInViewport({ ratio: 0.99 });
    await expect(strip.locator('[tabindex="0"]')).toHaveCount(1);
    await last.press('ArrowDown');
    await expect(overview).toBeFocused();
    await overview.press('ArrowDown');
    const first = strip.locator('.workspace-track').first();
    await expect(first).toBeFocused();
    await expect(first).toHaveAttribute('aria-selected', 'false');
    await first.press(' ');
    if (width < 760) {
      await expect(strip).not.toBeVisible();
      await page.getByRole('button', { name: 'Menu', exact: true }).click();
    }
    await expect(first).toHaveAttribute('aria-selected', 'true');
    await expect(first).toHaveAttribute('aria-current', 'page');
    await first.focus();
    await first.press('End');
    await expect(last).toBeFocused();
    await last.press('Enter');
    if (width < 760) {
      await expect(strip).not.toBeVisible();
      await page.getByRole('button', { name: 'Menu', exact: true }).click();
    }
    await expect(last).toHaveAttribute('aria-selected', 'true');
    await page.reload();
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    if (width < 760) await page.getByRole('button', { name: 'Menu', exact: true }).click();
    await expect(strip.locator('[aria-selected="true"]')).toBeInViewport({ ratio: 0.99 });
    const scroll = page.locator('.yard-scroll');
    await scroll.evaluate(el => { el.scrollTop = 0; });
    await scroll.hover();
    await page.mouse.wheel(0, 150);
    await expect.poll(() => scroll.evaluate(el => el.scrollTop)).toBeGreaterThan(0);
    await nav.getByRole('button', { name: 'New track', exact: true }).click();
    const newTrack = page.getByRole('dialog', { name: 'New track', exact: true });
    await expect(newTrack).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(newTrack).not.toBeVisible();
    if (width < 760) {
      await expect(strip).not.toBeVisible();
      await page.getByRole('button', { name: 'Menu', exact: true }).click();
    }
    const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
    expect(result.violations).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: test.info().outputPath(`vertical-tabs-${width}.png`) });
    if (width < 760) {
      await page.getByRole('button', { name: 'Close menu', exact: true }).click();
      await expect(strip).not.toBeVisible();
      const collapsed = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
      expect(collapsed.violations).toEqual([]);
    }
  }
  // Every tab shares the ravix/ namespace, so it is named but not drawn.
  await page.getByRole('button', { name: 'Menu', exact: true }).click();
  const firstTab = strip.getByRole('tab', { name: /^ravix\/scrolling-track-0\b/ });
  await expect(firstTab).toHaveCount(1);
  await expect(firstTab.locator('.track-title')).toHaveText('scrolling-track-0');
  await page.getByRole('button', { name: 'Close menu', exact: true }).click();
  // The direct action still confirms and restores focus when dismissed.
  const header = page.locator('.track-crumbs');
  const close = header.getByRole('button', { name: 'Close track', exact: true });
  await expect(header.getByRole('button', { name: 'Project settings', exact: true })).toHaveAttribute('title', 'Project settings');
  await expect(header.getByRole('button', { name: /^Track sharing/ })).toHaveAttribute('title', /viewing now/);
  await expect(close).toBeVisible();
  await close.click();
  const dialog = page.getByRole('dialog', { name: 'Close track', exact: true });
  await expect(dialog).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(close).toBeFocused();
});
