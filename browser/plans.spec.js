import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn } from './sign-in.js';

test('a project plan assigns coordinated tracks and works at phone width', async ({ page }) => {
  // Not @mockuser: this file runs before workspace.spec.js, whose first-visit
  // walkthrough and empty inbox need that person untouched. @dana is
  // tooling.spec.js's, so plans get @eli.
  await signIn(page, 'eli', '/home');
  await page.getByRole('button', { name: /^Quick start/ }).click();
  await page.getByLabel('Project name', { exact: true }).fill('Planned release');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  const panel = page.locator('#plans-panel');
  await expect(panel).toBeVisible();
  await panel.getByRole('button', { name: 'New plan', exact: true }).click();
  await expect(page).toHaveURL(/\?new=plan$/);
  await expect(panel.getByRole('heading', { name: 'New plan', exact: true })).toBeVisible();
  await expect(panel.getByRole('button', { name: /Move up|Move down|Remove item/ })).toHaveCount(0);
  await expect(panel.getByLabel('Depends on', { exact: true })).toHaveCount(0);
  await expect(panel).not.toContainText('Assigned items must remain unchanged');
  await panel.getByLabel('Title', { exact: true }).fill('Ship the release');
  await panel.getByLabel('Summary and rationale (Markdown)').fill('**Together** with clear boundaries.');
  await panel.getByLabel('Item title', { exact: true }).fill('Build API');
  await panel.getByLabel('Brief', { exact: true }).fill('Own the API routes.');
  await panel.getByLabel('Acceptance notes', { exact: true }).fill('Tests pass.');
  await panel.getByRole('button', { name: 'Add item', exact: true }).click();
  await panel.getByLabel('Item title', { exact: true }).nth(1).fill('Build UI');
  await panel.getByLabel('Brief', { exact: true }).nth(1).fill('Own the views.');
  await panel.getByRole('button', { name: 'Add item', exact: true }).click();
  await panel.getByLabel('Item title', { exact: true }).nth(2).fill('Ship after API');
  await panel.getByLabel('Brief', { exact: true }).nth(2).fill('Wait for the API.\n\n' + 'Release notes.\n\n'.repeat(30));
  await panel.getByLabel('Depends on', { exact: true }).nth(2).selectOption({ label: 'Build API' });
  await panel.getByRole('button', { name: 'Save plan', exact: true }).click();
  await expect(panel.getByRole('heading', { name: 'Ship the release' })).toBeVisible();
  await expect(panel.locator('strong', { hasText: 'Together' })).toBeVisible();
  const planURL = page.url();
  await panel.getByRole('button', { name: 'New plan', exact: true }).click();
  await expect(page).toHaveURL(/\?new=plan$/);
  await page.reload();
  await expect(panel.getByRole('heading', { name: 'New plan', exact: true })).toBeVisible();
  await expect(panel.getByLabel('Title', { exact: true })).toHaveValue('');
  await panel.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(page).not.toHaveURL(/\?/);
  await panel.getByRole('link', { name: 'Ship the release', exact: true }).click();
  await expect(page).toHaveURL(planURL);
  await expect(panel.getByRole('heading', { name: 'Ship the release' })).toBeVisible();
  const card = panel.locator('.plan-item').filter({ has: page.getByRole('heading', { name: 'Build API', exact: true }) });
  await card.getByText('Add a note to Build API', { exact: true }).click();
  await card.getByLabel('Note', { exact: true }).fill('Check the API contract.');
  await card.getByRole('button', { name: 'Add note', exact: true }).click();
  await expect(card).toContainText('Check the API contract.');
  expect(await card.locator('form').evaluate(el => el.parentElement.closest('form') === null)).toBe(true);
  for (const width of [1480, 535]) {
    await page.setViewportSize({ width, height: 900 });
    const sizes = await panel.evaluate(el => ({
      title: parseFloat(getComputedStyle(el.querySelector('h3')).fontSize),
      item: parseFloat(getComputedStyle(el.querySelector('h4')).fontSize),
      body: parseFloat(getComputedStyle(el.querySelector('.md')).fontSize),
    }));
    expect(sizes.title).toBeGreaterThan(sizes.body);
    expect(sizes.item).toBeGreaterThanOrEqual(sizes.body);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  }
  const api = panel.getByRole('group', { name: 'Build API', exact: true });
  const ui = panel.getByRole('group', { name: 'Build UI', exact: true });
  const blocked = panel.getByRole('group', { name: 'Ship after API', exact: true });
  await expect(blocked.getByLabel('Assign', { exact: true })).toBeDisabled();
  await expect(blocked.getByLabel('Track', { exact: true })).toBeDisabled();
  await expect(panel.getByText('Blocked by: Build API', { exact: true })).toBeVisible();
  for (const width of [1480, 535, 390]) {
    await page.setViewportSize({ width, height: 844 });
    await api.scrollIntoViewIfNeeded();
    const boxes = await api.evaluate(el => {
      const rect = node => { const { x, y, width, height } = node.getBoundingClientRect(); return { x, y, width, height }; };
      return {
        choice: rect(el.querySelector('.plan-assign-choice')),
        checkbox: rect(el.querySelector('input')),
        target: rect(el.querySelector('.plan-assign-target')),
        label: rect(el.querySelector('.plan-assign-target label')),
        select: rect(el.querySelector('select')),
      };
    });
    expect(Math.abs(boxes.checkbox.y + boxes.checkbox.height / 2 - boxes.choice.y - boxes.choice.height / 2)).toBeLessThan(2);
    expect(boxes.select.x).toBeGreaterThan(boxes.label.x);
    expect(Math.abs(boxes.select.y + boxes.select.height / 2 - boxes.label.y - boxes.label.height / 2)).toBeLessThan(2);
    if (width === 1480) expect(Math.abs(boxes.choice.y + boxes.choice.height / 2 - boxes.target.y - boxes.target.height / 2)).toBeLessThan(2);
    expect(await panel.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
  }
  await api.getByLabel('Assign', { exact: true }).check();
  await expect(panel.locator('.plan-assign-actions')).toContainText('1 selected');
  await api.getByLabel('Assign', { exact: true }).uncheck();
  await expect(panel.locator('.plan-assign-actions')).toContainText('0 selected');
  await api.getByLabel('Assign', { exact: true }).check();
  await ui.getByLabel('Assign', { exact: true }).check();
  await expect(panel.locator('.plan-assign-actions')).toContainText('2 selected');
  await blocked.scrollIntoViewIfNeeded();
  await expect(panel.getByRole('button', { name: 'Assign selected items' })).toBeInViewport();
  await page.screenshot({ path: 'test-results/plans-assign-phone.png' });
  await panel.getByRole('button', { name: 'Assign selected items' }).click();
  // A track is named after its reserved branch (#154); the item keeps its title.
  await expect(panel.getByRole('link', { name: 'Open track: ravix/build-api' })).toBeVisible();
  await expect(panel.getByRole('link', { name: 'Open track: ravix/build-ui' })).toBeVisible();
  await expect(panel.locator('.chip', { hasText: 'in progress' })).toHaveCount(2);
  const result = await new AxeBuilder({ page }).include('#plans-panel').withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(result.violations).toEqual([]);
  // Project tracks remain side by side; narrow screens scroll the strip
  // instead of stacking tabs or widening the page.
  const tabs = page.getByRole('navigation', { name: 'Project tracks', exact: true }).locator('.track-tabs');
  const assertHorizontalTabs = async () => {
    const boxes = await tabs.locator(':scope > a').evaluateAll(links =>
      links.map(link => {
        const { x, y, width, height } = link.getBoundingClientRect();
        return { x, y, width, height };
      })
    );
    expect(boxes.length).toBeGreaterThanOrEqual(3);
    for (let i = 1; i < boxes.length; i++) {
      expect(Math.abs(boxes[i].y - boxes[0].y)).toBeLessThan(1);
      expect(boxes[i].x).toBeGreaterThanOrEqual(boxes[i - 1].x + boxes[i - 1].width);
    }
  };
  await assertHorizontalTabs();
  await page.setViewportSize({ width: 390, height: 844 });
  await assertHorizontalTabs();
  expect(await tabs.evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true);
  await tabs.getByRole('link', { name: /ravix\/build-ui/ }).scrollIntoViewIfNeeded();
  expect(await tabs.evaluate(el => el.scrollLeft)).toBeGreaterThan(0);

  await expect(panel).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: 'test-results/plans-phone.png', fullPage: true });
  await panel.getByRole('link', { name: 'Open track: ravix/build-api' }).click();
  await expect(page.getByRole('link', { name: 'Plan: Build API' })).toBeVisible();
});
