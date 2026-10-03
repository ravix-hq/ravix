import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

test('layout evidence', async ({ page }, testInfo) => {
  test.skip(!process.env.LAYOUT_PHASE, 'Opt-in screenshot capture');
  test.setTimeout(120_000);
  await signIn(page, 'dana');
  await connectClaude(page);
  await openAddRepository(page);
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Ravix layout');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).not.toBeVisible();
  await page.locator('#top-new-track').click();
  const track = page.getByRole('dialog', { name: 'New track', exact: true });
  await track.getByRole('button', { name: 'Options', exact: true }).click();
  await track.getByLabel('Branch name').fill('layout-example');
  await track.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
  const trackPath = new URL(page.url()).pathname;
  const projectPath = trackPath.split('/t/')[0];
  // The frame is the top bar over the stage: the track, its project's page
  // and Home, at a desktop and a phone width.
  for (const width of [1280, 500]) {
    await page.setViewportSize({ width, height: 900 });
    const path = name => process.env.LAYOUT_PHASE
      ? `docs/screenshots/rav-9/${process.env.LAYOUT_PHASE}-${name}.png`
      : testInfo.outputPath(`${name}.png`);
    await page.goto(trackPath);
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await expect(page.locator('#topbar .topbar-crumbs')).toBeVisible();
    await expect(page.locator('#track-header .track-tabs')).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();
    await page.screenshot({ path: path(width) });
    await page.goto(projectPath);
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await expect(page.locator('#project-tabpanel nav.repo-tabs')).toBeVisible();
    await expect(page.locator('#project-tracks')).toBeVisible();
    await page.screenshot({ path: path(`${width}-project`) });
    await page.goto('/home');
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await expect(page.locator('#topbar .topbar-nav')).toBeVisible();
    await expect(page.locator('#home-projects')).toBeVisible();
    await page.screenshot({ path: path(`${width}-home`) });
  }
});
