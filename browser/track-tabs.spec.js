import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { expectInlineChoice } from './controls.js';
import { openAddRepository } from './new-track.js';

test('a project page lists many tracks vertically at desktop and phone widths', async ({ page }) => {
  test.setTimeout(120_000);
  // Keep mockuser's first-visit state for the onboarding walkthrough.
  await signIn(page, 'eli');
  await connectClaude(page);
  await openAddRepository(page);
  const project = page.getByRole('dialog', { name: 'Add a repository' });
  await project.getByLabel('Project name', { exact: true }).fill('Scrolling tracks');
  await expect(project.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await project.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await project.getByRole('button', { name: 'Add repository' }).click();
  await expect(project).not.toBeVisible();
  const seen = new Set();
  for (let index = 0; index < 12; index++) {
    await page.locator('#top-new-track').click();
    const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
    await dialog.getByRole('button', { name: 'Options', exact: true }).click();
    await dialog.getByLabel('Branch name').fill(`scrolling-track-${index}`);
    await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect(dialog).not.toBeVisible();
    await expect.poll(() => {
      const id = new URL(page.url()).pathname.split('/t/')[1];
      return !!id && !seen.has(id);
    }).toBe(true);
    seen.add(new URL(page.url()).pathname.split('/t/')[1]);
  }
  const projectPath = new URL(page.url()).pathname.split('/t/')[0];
  for (const width of [1280, 500, 390]) {
    await page.setViewportSize({ width, height: 600 });
    await page.goto(projectPath);
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await expect(page.locator('#crumb-tracks .count')).toHaveText('12');
    for (const view of ['graph', 'list']) {
      await page.locator(`#project-tracks-${view}`).click();
      const strip = page.locator(`#tracks-${view}`);
      await expect(strip.locator('a.tracks-title')).toHaveCount(12);
      // One under another, and the page scrolls to the rest. The graph
      // draws the newest first.
      const boxes = await strip.locator('a.tracks-title').evaluateAll(links => links.map(link => link.getBoundingClientRect().y));
      expect(boxes).toEqual([...boxes].sort((a, b) => a - b));
      if (view === 'graph') await expect(strip.locator('a.tracks-title').first()).toHaveText(/^\s*Scrolling track 11, /);
      const last = strip.locator('a.tracks-title').last();
      await last.scrollIntoViewIfNeeded();
      await expect(last).toBeInViewport();
      expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    }
    const first = page.locator('#tracks-list a.tracks-title', { hasText: /^\s*Scrolling track 0, / });
    await expect(first).toHaveCount(1);
    await first.focus();
    await first.press('Enter');
    await expect(page).toHaveURL(/\/t\//);
    await expect(page.locator('#track-header .track-title-text')).toHaveText('Scrolling track 0');
  }
  // Close is in the header's ⋯ (RAV-82). It still confirms, and dismissing
  // returns focus to ⋯.
  const header = page.locator('#track-header');
  const more = header.getByRole('button', { name: 'More for this track', exact: true });
  const close = header.getByRole('button', { name: 'Close track', exact: true });
  await expect(header.getByRole('button', { name: 'Project settings', exact: true })).toHaveCount(0);
  await expect(header.getByRole('button', { name: /^Track sharing/ })).toHaveAttribute('data-tip', /viewing now/);
  await expect(close).toBeHidden();
  await more.click();
  await expect(close).toBeVisible();
  await close.click();
  const dialog = page.getByRole('dialog', { name: 'Close track', exact: true });
  await expect(dialog).toBeVisible();
  // RAV-59: the shared checkbox input keeps its size beside its label.
  await expectInlineChoice(dialog.locator('label[for="close-force"]'));
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(more).toBeFocused();
});
