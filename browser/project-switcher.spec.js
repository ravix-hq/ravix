import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// Phoenix LiveView 1.2's JS.focus runs immediately and again in two animation
// frames. Wait for that mount command to finish before exercising focus across
// a search-result patch; otherwise its deferred focus can steal the selected row.
async function searchReady(search) {
  await expect(search).toBeFocused();
  await search.evaluate(() => new Promise(resolve =>
    requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await expect(search).toBeFocused();
}

test('Home, the project page and quick-jump navigate with keyboard and fit desktop and phone', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  const projects = [];
  for (const name of ['Tree Alpha', 'Tree Beta with a long project name to fit a phone']) {
    await page.goto('/home');
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await openAddRepository(page);
    await page.getByLabel('Project name', { exact: true }).fill(name);
    await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
    await expect(page.locator('#crumb-plans')).toBeVisible();
    const path = new URL(page.url()).pathname;
    await page.locator('#top-new-track').click();
    const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
    await dialog.getByRole('button', { name: 'Options', exact: true }).click();
    await dialog.getByLabel('Branch name').fill(name.startsWith('Tree Alpha') ? 'alpha-work' : 'beta-work');
    await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect(dialog).not.toBeVisible();
    await expect(page).toHaveURL(/\/t\//);
    projects.push({ name, path, track: new URL(page.url()).pathname });
  }
  for (const width of [1280, 500]) {
    await page.setViewportSize({ width, height: 900 });
    // Home lists the projects; a project's page lists its tracks.
    // From a track the top bar is its breadcrumb, whose workspace leads Home
    // at every width.
    await page.locator('#topbar .topbar-crumbs a[href="/home"]').click();
    await expect(page).toHaveURL(/\/home$/);
    const alpha = page.locator(`#project-link-${projects[0].path.split('/')[2]}`);
    await expect(alpha).toHaveAttribute('href', projects[0].path);
    await alpha.click();
    await expect(page).toHaveURL(new RegExp(`${projects[0].path}$`));
    const track = page.locator(`#project-tracks a[href='${projects[0].track}']`);
    await expect(track).toBeVisible();
    await track.focus();
    await page.keyboard.press('Enter');
    await expect(page).toHaveURL(new RegExp(`${projects[0].track}$`));
    await expect(page.locator('#topbar .topbar-crumbs a[href^="/p/"]')).toHaveAttribute('href', projects[0].path);
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze()).violations).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: `test-results/project-switcher-${width === 500 ? 'mobile' : 'desktop'}.png` });
    const trigger = page.locator('#quick-jump-trigger');
    // Search is global (RAV-99): the composer does not keep Ctrl+K.
    await page.locator('textarea').first().focus();
    await page.keyboard.press('Control+k');
    await expect(page.locator('#search-dialog')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.locator('#search-dialog')).toHaveCount(0);
    await trigger.focus();
    await page.keyboard.press('Control+k');
    const picker = page.getByRole('dialog', { name: 'Search', exact: true });
    const search = picker.getByLabel('Search projects, tracks and plans');
    await searchReady(search);
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
    await searchReady(search);
    await search.fill('Tree Alpha');
    await expect(picker.locator(`a[href='${projects[0].path}'] .badge`)).toHaveCount(0);
    // Settle the dialog's fade first: axe measures composited colour (see
    // workspace.spec.js's `accessible`). Infinite animations never finish.
    await page.evaluate(() => Promise.all(document.getAnimations()
      .filter(a => a.effect?.getTiming?.().iterations !== Infinity)
      .map(a => a.finished.catch(() => {}))));
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
    await page.keyboard.press('Escape');
    await expect(picker).toHaveCount(0);
    await expect(trigger).toBeFocused();
    await trigger.press('Enter');
    await searchReady(search);
    await search.fill('Tree Beta');
    const betaProject = picker.locator(`a[href='${projects[1].path}']`);
    // Blur sends a pending search change; the selected row moves past Alpha.
    await betaProject.focus();
    await expect(picker.locator(`a[href='${projects[0].path}']`)).toHaveCount(0);
    await expect(betaProject).toBeFocused();
    await betaProject.press('Enter');
    await expect(page).toHaveURL(new RegExp(`${projects[1].path}$`));
    await expect(picker).toHaveCount(0);
    // Inside a project the top bar keeps only the Inbox; off it, the places.
    await expect(page.locator('#topbar .topbar-nav')).toHaveCount(0);
    await page.locator('#topbar-inbox').click();
    await expect(page).toHaveURL(/\/inbox$/);
    await page.locator('#topbar .topbar-nav').getByRole('link', { name: 'Schedules', exact: true }).click();
    await expect(page).toHaveURL(/\/schedules$/);
  }
});
