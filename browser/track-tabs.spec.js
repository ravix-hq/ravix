import { test, expect } from '@playwright/test';
import { signIn } from './sign-in.js';

test('overflowing track tabs scroll with a mouse and keep navigation reachable', async ({ page }) => {
  test.setTimeout(120_000);
  // Keep mockuser's first-visit state for the onboarding walkthrough.
  await signIn(page, 'eli');
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project' });
  await project.getByLabel('Project name', { exact: true }).fill('Scrolling tracks');
  await expect(project.getByLabel('Repository', { exact: true }).locator('option')).not.toHaveCount(1);
  await project.getByLabel('Repository', { exact: true }).selectOption('mockuser/atlas-api');
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
  const strip = page.locator('.track-tabs');
  for (const width of [1280, 390]) {
    await page.setViewportSize({ width, height: 844 });
    await strip.evaluate(el => { el.scrollLeft = 0; });
    await expect.poll(() => strip.evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true);
    await strip.hover();
    await page.mouse.wheel(150, 0);
    await expect.poll(() => strip.evaluate(el => el.scrollLeft)).toBeGreaterThan(0);
    await strip.evaluate(el => { el.scrollLeft = 0; });
    await page.mouse.wheel(0, 150);
    await expect.poll(() => strip.evaluate(el => el.scrollLeft)).toBeGreaterThan(0);
    await expect(nav.getByRole('button', { name: 'Scroll tracks right' })).toBeInViewport();
    const beforeRight = await strip.evaluate(el => el.scrollLeft);
    await nav.getByRole('button', { name: 'Scroll tracks right' }).click();
    await expect.poll(() => strip.evaluate(el => el.scrollLeft)).toBeGreaterThan(beforeRight);
    const last = strip.locator('.workspace-track').last();
    // Keyboard focus must reveal off-screen links as well. Allow subpixel
    // clipping from Chromium rounding scroll offsets (observed ratio 0.99944).
    await last.focus();
    await expect(last).toBeInViewport({ ratio: 0.99 });
    await last.press('Enter');
    await expect(last).toHaveAttribute('aria-current', 'page');
    await page.reload();
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await expect(strip.locator('[aria-current="page"]')).toBeInViewport({ ratio: 0.99 });
    const beforeLeft = await strip.evaluate(el => el.scrollLeft);
    await nav.getByRole('button', { name: 'Scroll tracks left' }).click();
    await expect.poll(() => strip.evaluate(el => el.scrollLeft)).toBeLessThan(beforeLeft);
    await strip.getByRole('link', { name: 'Overview', exact: true }).focus();
    await expect(strip.getByRole('link', { name: 'Overview', exact: true })).toBeInViewport();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  }
});
