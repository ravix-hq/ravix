import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

test('a project plan assigns coordinated tracks and works at phone width', async ({ page }) => {
  // Not @mockuser: this file runs before workspace.spec.js, whose first-visit
  // walkthrough and empty inbox need that person untouched. @dana is
  // tooling.spec.js's, so plans get @eli.
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: /^New project/ }).click();
  await page.getByLabel('Project name', { exact: true }).fill('Planned release');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  const panel = page.locator('#plans-panel');
  // Plans are not on the project's home; the project row opens them.
  await expect(page.locator('#project-tabpanel .crumbs')).toBeVisible();
  await expect(panel).toHaveCount(0);
  await page.getByRole('link', { name: 'Plans in Planned release', exact: true }).click();
  await expect(page).toHaveURL(/\/plans$/);
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
  await expect(panel.locator('.plans-list')).toContainText('0% complete');
  await expect(panel.locator('.plans-list')).toContainText('3 unstarted');
  await expect(panel.locator('.plans-list')).toContainText('1 blocked');
  for (const theme of ['midnight', 'daylight']) {
    await page.locator('html').evaluate((el, value) => el.dataset.theme = value, theme);
    for (const width of [1480, 500]) {
      await page.setViewportSize({ width, height: 900 });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await page.screenshot({ path: `tmp/plan-progress-${theme}-${width}.png` });
    }
    const result = await new AxeBuilder({ page }).include('#plans-panel').withTags(['wcag2a', 'wcag2aa']).analyze();
    expect(result.violations).toEqual([]);
  }
  await page.locator('html').evaluate(el => el.dataset.theme = 'midnight');
  await page.setViewportSize({ width: 1280, height: 900 });
  // Quick-jump finds the plan by its title.
  await page.keyboard.press('Control+k');
  await page.getByLabel('Search projects, tracks and plans').fill('ship the');
  await page.locator('#search-dialog').getByRole('link', { name: 'Plan: Ship the release' }).click();
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
  // Each item links its own track and keeps its title. The track opens under
  // its reserved branch (#154), but its first prompt may retitle it at any
  // moment (RAV-48, `Ravix.Tracks.Titling`), so the link is found by item.
  const item = name => panel.locator('article', { has: page.getByRole('heading', { name, exact: true, level: 4 }) });
  const apiTrack = item('Build API').getByRole('link', { name: /^Open track: / });
  const uiTrack = item('Build UI').getByRole('link', { name: /^Open track: / });
  await expect(apiTrack).toBeVisible();
  await expect(uiTrack).toBeVisible();
  const uiHref = await uiTrack.getAttribute('href');
  expect(uiHref).toMatch(/\/t\/[a-f0-9-]{36}$/);
  expect(await apiTrack.getAttribute('href')).not.toBe(uiHref);
  await expect(panel.locator('.chip', { hasText: 'in progress' })).toHaveCount(2);
  const result = await new AxeBuilder({ page }).include('#plans-panel').withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(result.violations).toEqual([]);
  // Track navigation lives in the sidebar and follows its mobile collapse.
  await page.setViewportSize({ width: 1280, height: 844 });
  const tabs = page.locator('#yard .workspace-project.current .project-tree-tracks');
  await expect(tabs).toHaveAttribute('aria-label', /^Tracks in /);
  await expect(tabs.locator(`a[href="${uiHref}"]`)).toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(tabs).not.toBeVisible();
  await page.getByRole('button', { name: 'Menu', exact: true }).click();
  await expect(tabs.locator(`a[href="${uiHref}"]`)).toBeInViewport();
  await page.getByRole('button', { name: 'Close menu', exact: true }).click();

  await expect(panel).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: 'test-results/plans-phone.png', fullPage: true });
  await apiTrack.click();
  await page.getByRole('button', { name: /^Plan: Ship the release · 1 item/ }).click();
  await expect(page.getByRole('link', { name: 'Plan · Ship the release' })).toBeVisible();
});
