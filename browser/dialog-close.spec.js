import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-68: a dialog closed with Escape used to stay on screen until the
// server's re-render removed it, so the scrim caught the next click and the
// click only closed the dialog again. The latency simulator holds every
// round trip open long enough that a click right after Escape always lands
// while the close is still in flight, as it does over a slow connection. The
// clicks go to a point on the screen, as a person's do, so whatever is on top
// there receives them.
const LATENCY_MS = 400;

async function clickAt(page, locator) {
  const box = await locator.boundingBox();
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
}

async function newTrack(page, branch) {
  await page.locator('#top-new-track').click();
  const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
  await dialog.getByRole('button', { name: 'Options', exact: true }).click();
  await dialog.getByLabel('Branch name').fill(branch);
  await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(dialog).not.toBeVisible();
}

test('the first click after Escape closes a dialog reaches what is under it', async ({ page }) => {
  test.setTimeout(150_000);
  await page.setViewportSize({ width: 1280, height: 900 });
  await signIn(page, 'escaper');
  await connectClaude(page);
  await openAddRepository(page);
  const project = page.getByRole('dialog', { name: 'Add a repository' });
  await project.getByLabel('Project name', { exact: true }).fill('Escape hatch');
  await expect(project.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await project.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await project.getByRole('button', { name: 'Add repository' }).click();
  await expect(project).not.toBeVisible();
  await newTrack(page, 'escape-first');
  const firstPath = new URL(page.url()).pathname;
  await newTrack(page, 'escape-second');
  await expect(page).toHaveURL(url => url.pathname !== firstPath && url.pathname.includes('/t/'));
  // The project's page (the top bar's crumb) lists both.
  await page.locator('#topbar .topbar-crumbs a[href^="/p/"]').click();
  const first = page.locator(`#tracks-graph-row-${firstPath.split('/t/')[1]} a.tracks-title`);
  await expect(first).toBeVisible();

  await page.evaluate(ms => window.liveSocket.enableLatencySim(ms), LATENCY_MS);
  try {
    // New track, Escape, and straight on to another track in the list.
    await page.locator('#top-new-track').click();
    const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
    await expect(dialog).toBeVisible();
    await page.keyboard.press('Escape');
    await clickAt(page, first);
    await expect(dialog).toHaveCount(0);
    await expect(page).toHaveURL(new RegExp(`${firstPath}$`));
    await expect(page.locator('#track-header')).toBeVisible();

    // Sharing, Escape, and straight on to the track's Preview tab.
    await page.getByRole('button', { name: /^Track sharing/ }).click();
    const sharing = page.getByRole('dialog');
    await expect(sharing).toBeVisible();
    const preview = page.getByRole('navigation', { name: 'Track views' })
      .getByRole('button', { name: 'Preview', exact: true });
    await expect(preview).toHaveAttribute('aria-pressed', 'false');
    await page.keyboard.press('Escape');
    await clickAt(page, preview);
    await expect(sharing).toHaveCount(0);
    await expect(preview).toHaveAttribute('aria-pressed', 'true');

    // On a phone the top bar keeps search: Escape closes it, and the next
    // open (a later round trip than anything Escape pushed) still opens it.
    await page.setViewportSize({ width: 500, height: 900 });
    const trackPath = new URL(page.url()).pathname;
    await page.locator('#quick-jump-trigger').click();
    const search = page.getByRole('dialog', { name: 'Search', exact: true });
    await expect(search).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(search).toHaveCount(0);
    await page.locator('#quick-jump-trigger').click();
    await expect(search).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(search).toHaveCount(0);
    await expect(page).toHaveURL(url => url.pathname === trackPath);
  } finally {
    await page.evaluate(() => window.liveSocket.disableLatencySim());
  }
});
