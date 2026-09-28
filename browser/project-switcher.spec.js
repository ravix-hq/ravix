import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

test('project tree and quick-jump navigate with keyboard and fit desktop and phone', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  const projects = [];
  for (const name of ['Tree Alpha', 'Tree Beta with a long project name to fit a phone']) {
    await page.goto('/home');
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await page.getByRole('button', { name: /^New project/ }).click();
    await page.getByLabel('Project name', { exact: true }).fill(name);
    await page.getByRole('button', { name: 'Create project', exact: true }).click();
    await expect(page.getByRole('heading', { name: 'Plans', exact: true })).toBeVisible();
    const path = new URL(page.url()).pathname;
    await page.locator('#yard .workspace-project.current .project-add').click();
    const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
    await dialog.getByRole('button', { name: 'Advanced', exact: true }).click();
    await dialog.getByLabel('Branch name').fill(name.startsWith('Tree Alpha') ? 'alpha-work' : 'beta-work');
    await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect(dialog).not.toBeVisible();
    await expect(page).toHaveURL(/\/t\//);
    projects.push({ name, path, track: new URL(page.url()).pathname });
  }
  for (const width of [1280, 500]) {
    await page.setViewportSize({ width, height: 900 });
    if (width === 500) await page.getByRole('button', { name: 'Menu', exact: true }).click();
    const alpha = page.locator(`#project-tree .workspace-project:has(a[href='${projects[0].path}'])`);
    const toggle = alpha.locator('.project-collapse');
    await expect(alpha.locator('.workspace-track')).toBeVisible();
    await toggle.click();
    await expect(alpha.locator('.workspace-track')).not.toBeVisible();
    await page.reload();
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    if (width === 500) await page.getByRole('button', { name: 'Menu', exact: true }).click();
    await expect(toggle).toHaveAttribute('aria-expanded', 'false');
    await toggle.click();
    await alpha.locator('.workspace-project-name').click();
    await expect(page).toHaveURL(new RegExp(`${projects[0].path}$`));
    if (width === 500) {
      await expect(page.locator('#yard.forced')).toHaveCount(0);
      await page.getByRole('button', { name: 'Menu', exact: true }).click();
    }
    await alpha.locator('.workspace-track').click();
    await expect(page).toHaveURL(new RegExp(`${projects[0].track}$`));
    if (width === 500) {
      await expect(page.locator('#yard.forced')).toHaveCount(0);
      await page.getByRole('button', { name: 'Menu', exact: true }).click();
    }
    await expect(alpha.locator('.workspace-track')).toHaveAttribute('aria-current', 'page');
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze()).violations).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: `docs/screenshots/sidebar-tree/after-${width === 500 ? 'mobile' : 'desktop'}.png` });
    if (width === 500) await page.getByRole('button', { name: 'Close menu', exact: true }).click();
    const trigger = page.locator(width === 500 ? '#mobile-quick-jump-trigger' : '#quick-jump-trigger');
    if (width === 1280) await page.locator('#yard-toggle').click();
    // Editing shortcuts belong to the composer, even while global search is available.
    await page.locator('textarea').first().focus();
    await page.keyboard.press('Control+k');
    await expect(page.locator('#search-dialog')).toHaveCount(0);
    await trigger.focus();
    await page.keyboard.press('Control+k');
    const picker = page.getByRole('dialog', { name: 'Search', exact: true });
    const search = picker.getByLabel('Search projects and tracks');
    await expect(search).toBeFocused();
    await search.fill('beta-work');
    await expect(picker.locator(`a[href='${projects[1].track}']`)).toBeVisible();
    await expect(picker.locator(`a[href='${projects[0].path}']`)).toHaveCount(0);
    await search.press('ArrowDown');
    await expect(picker.locator(`a[href='${projects[1].track}']`)).toBeFocused();
    await page.keyboard.press('Enter');
    await expect(page).toHaveURL(new RegExp(`${projects[1].track}$`));
    await expect(picker).toHaveCount(0);
    await trigger.focus();
    await page.keyboard.press('Control+k');
    await expect(search).toBeFocused();
    await search.fill('Tree Alpha');
    await expect(picker.locator(`a[href='${projects[0].path}'] .badge`)).toHaveCount(0);
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
    await page.keyboard.press('Escape');
    await expect(picker).toHaveCount(0);
    await expect(trigger).toBeFocused();
    await trigger.press('Enter');
    await search.fill('Tree Beta');
    const betaProject = picker.locator(`a[href='${projects[1].path}']`);
    // Blur sends a pending search change; the selected row moves past Alpha.
    await betaProject.focus();
    await expect(picker.locator(`a[href='${projects[0].path}']`)).toHaveCount(0);
    await expect(betaProject).toBeFocused();
    await betaProject.press('Enter');
    await expect(page).toHaveURL(new RegExp(`${projects[1].path}$`));
    await expect(picker).toHaveCount(0);
    if (width === 1280) await page.locator('#yard-toggle').click();
    const nav = page.locator(width === 500 ? '.workspace-mobile-nav' : '.yard-nav');
    await nav.getByRole('link', { name: /^Inbox(?: \d+)?$/ }).click();
    await expect(page).toHaveURL(/\/inbox$/);
    await nav.getByRole('link', { name: 'Schedules', exact: true }).click();
    await expect(page).toHaveURL(/\/schedules$/);
  }
});
