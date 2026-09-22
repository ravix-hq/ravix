import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

test('a project plan assigns coordinated tracks and works at phone width', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign in with GitHub', exact: true }).click();
  // Not @mockuser: this file runs before workspace.spec.js, whose first-visit
  // walkthrough and empty inbox need that person untouched. @dana is
  // tooling.spec.js's, so plans get @eli.
  await page.getByRole('link', { name: 'Sign in as @eli', exact: true }).click();
  if (new URL(page.url()).pathname.startsWith('/welcome')) {
    await page.getByRole('button', { name: 'Skip setup', exact: true }).click();
  }
  await page.goto('/home');
  await page.getByRole('button', { name: /^Quick start/ }).click();
  await page.getByLabel('Project name', { exact: true }).fill('Planned release');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  const panel = page.locator('#plans-panel');
  await expect(panel).toBeVisible();
  await panel.getByRole('button', { name: 'New plan', exact: true }).click();
  await panel.getByLabel('Title', { exact: true }).fill('Ship the release');
  await panel.getByLabel('Summary and rationale (Markdown)').fill('**Together** with clear boundaries.');
  await panel.getByLabel('Item title', { exact: true }).fill('Build API');
  await panel.getByLabel('Brief', { exact: true }).fill('Own the API routes.');
  await panel.getByLabel('Acceptance notes', { exact: true }).fill('Tests pass.');
  await panel.getByRole('button', { name: 'Add item', exact: true }).click();
  await panel.getByLabel('Item title', { exact: true }).nth(1).fill('Build UI');
  await panel.getByLabel('Brief', { exact: true }).nth(1).fill('Own the views.');
  await panel.getByRole('button', { name: 'Save plan', exact: true }).click();
  await expect(panel.getByRole('heading', { name: 'Ship the release' })).toBeVisible();
  await expect(panel.locator('strong', { hasText: 'Together' })).toBeVisible();
  await panel.getByLabel('Assign Build API', { exact: true }).check();
  await panel.getByLabel('Assign Build UI', { exact: true }).check();
  await panel.getByRole('button', { name: 'Assign selected items' }).click();
  // A track is named after its reserved branch (#154); the item keeps its title.
  await expect(panel.getByRole('link', { name: 'Open track: ravix/build-api' })).toBeVisible();
  await expect(panel.getByRole('link', { name: 'Open track: ravix/build-ui' })).toBeVisible();
  await expect(panel.locator('.chip', { hasText: 'in progress' })).toHaveCount(2);
  const result = await new AxeBuilder({ page }).include('#plans-panel').withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(result.violations).toEqual([]);
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(panel).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: 'test-results/plans-phone.png', fullPage: true });
  await panel.getByRole('link', { name: 'Open track: ravix/build-api' }).click();
  await expect(page.getByRole('link', { name: 'Plan: Build API' })).toBeVisible();
});
