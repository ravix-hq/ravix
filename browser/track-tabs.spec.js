import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { expectInlineChoice } from './controls.js';

test('project track links scroll vertically and preserve the mobile drawer', async ({ page }) => {
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
  for (let index = 0; index < 12; index++) {
    await page.locator('#yard .workspace-project.current .project-add').click();
    const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
    await dialog.getByRole('button', { name: 'Options', exact: true }).click();
    await dialog.getByLabel('Branch name').fill(`scrolling-track-${index}`);
    await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect(dialog).not.toBeVisible();
    await expect(page.locator('#yard .workspace-project.current .workspace-track')).toHaveCount(index + 1);
  }
  const strip = page.locator('#yard .workspace-project.current .project-tree-tracks');
  for (const width of [1280, 500, 390]) {
    await page.setViewportSize({ width, height: 600 });
    if (width < 760) await page.getByRole('button', { name: 'Menu', exact: true }).click();
    await expect(strip.getByRole('link')).toHaveCount(12);
    const first = strip.getByRole('link').first();
    await first.focus();
    await first.press('Enter');
    if (width < 760) {
      await expect(strip).not.toBeVisible();
      await page.getByRole('button', { name: 'Menu', exact: true }).click();
    }
    await expect(first).toHaveAttribute('aria-current', 'page');
    await expect(first.locator('.track-title')).toHaveText('scrolling-track-0');
    await expect(first).toHaveAttribute('aria-label', /^ravix\/scrolling-track-0/);
    const boxes = await strip.getByRole('link').evaluateAll(links => links.map(link => link.getBoundingClientRect().y));
    expect(boxes).toEqual([...boxes].sort((a,b) => a-b));
    const scroll = page.locator('.yard-scroll');
    await scroll.evaluate(el => { el.scrollTop = 0; });
    await scroll.hover();
    await page.mouse.wheel(0, 150);
    await expect.poll(() => scroll.evaluate(el => el.scrollTop)).toBeGreaterThan(0);
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    if (width < 760) {
      await page.getByRole('button', { name: 'Close menu', exact: true }).click();
      await expect(strip).not.toBeVisible();
      expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
    }
  }
  // The direct action still confirms and restores focus when dismissed.
  const header = page.locator('.track-crumbs');
  const close = header.getByRole('button', { name: 'Close track', exact: true });
  await expect(header.getByRole('button', { name: 'Project settings', exact: true })).toHaveCount(0);
  await expect(header.getByRole('button', { name: /^Track sharing/ })).toHaveAttribute('title', /viewing now/);
  await expect(close).toBeVisible();
  await close.click();
  const dialog = page.getByRole('dialog', { name: 'Close track', exact: true });
  await expect(dialog).toBeVisible();
  // RAV-59: the shared checkbox input keeps its size beside its label.
  await expectInlineChoice(dialog.locator('label[for="close-force"]'));
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(close).toBeFocused();
});
