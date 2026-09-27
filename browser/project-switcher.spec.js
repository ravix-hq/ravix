import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

test('project switcher searches, patches and restores focus at desktop and phone widths', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  const projects = [];
  for (const name of ['Switcher Alpha', 'Switcher Beta with a long project name to fit a phone']) {
    await page.goto('/home');
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await page.getByRole('button', { name: /^New project/ }).click();
    await page.getByLabel('Project name', { exact: true }).fill(name);
    await page.getByRole('button', { name: 'Create project', exact: true }).click();
    await expect(page.getByRole('heading', { name: 'Plans', exact: true })).toBeVisible();
    projects.push({ name, path: new URL(page.url()).pathname });
  }

  for (const width of [1280, 500]) {
    await page.setViewportSize({ width, height: 900 });
    const trigger = page.locator(width === 500 ? '#mobile-project-switcher-trigger' : '#project-switcher-trigger');
    await expect(trigger).toContainText(projects[1].name);
    await trigger.click();
    const picker = page.getByRole('dialog', { name: 'Projects', exact: true });
    const search = picker.getByLabel('Find a project', { exact: true });
    await expect(search).toBeFocused();
    await search.fill('switcher alpha');
    const alpha = picker.locator(`a[href='${projects[0].path}']`);
    await expect(alpha).toBeVisible();
    await expect(alpha.locator('.badge')).toHaveText('0');
    await expect(picker.locator(`a[href='${projects[1].path}']`)).toHaveCount(0);
    await expect(picker.getByRole('button', { name: 'Manage sections' })).toBeVisible();
    await page.evaluate(() => Promise.all(document.getAnimations().filter(a => a.effect?.getTiming().iterations !== Infinity).map(a => a.finished.catch(() => {}))));
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze()).violations).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: `tmp/switcher-${width}.png` });
    await page.keyboard.press('Escape');
    await expect(picker).toHaveCount(0);
    await expect(trigger).toBeFocused();
    await trigger.press('Enter');
    await search.fill('switcher alpha');
    await alpha.focus();
    await alpha.press('Enter');
    await expect(page).toHaveURL(new RegExp(`${projects[0].path}$`));
    await expect(picker).toHaveCount(0);
    await expect(trigger).toContainText(projects[0].name);
    await expect(page.locator('aside#yard.forced')).toHaveCount(0);
    await trigger.click();
    await search.fill('switcher beta');
    await picker.locator(`a[href='${projects[1].path}']`).click();
    await expect(page).toHaveURL(new RegExp(`${projects[1].path}$`));
    const nav = page.locator(width === 500 ? '.workspace-mobile-nav' : '.yard-nav');
    await nav.getByRole('link', { name: /^Inbox(?: \d+)?$/ }).click();
    await expect(page).toHaveURL(/\/inbox$/);
    await expect(trigger).toHaveText('Projects');
    await nav.getByRole('link', { name: 'Schedules', exact: true }).click();
    await expect(page).toHaveURL(/\/schedules$/);
    await trigger.click();
    await picker.locator(`a[href='${projects[1].path}']`).click();
  }
  // Selecting through the rail on a phone closes its menu too.
  await page.getByRole('button', { name: 'Menu', exact: true }).click();
  await page.locator('#project-switcher-trigger').click();
  await page.locator(`#project-switcher a[href='${projects[0].path}']`).click();
  await expect(page.locator('aside#yard.forced')).toHaveCount(0);
});
