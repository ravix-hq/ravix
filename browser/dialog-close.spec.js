import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

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
  await page.locator('#yard .workspace-project.current .project-add').click();
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
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project' });
  await project.getByLabel('Project name', { exact: true }).fill('Escape hatch');
  await expect(project.locator('#project-repositories option')).not.toHaveCount(0);
  await project.getByLabel('Repository', { exact: true }).fill('mockuser/atlas-api');
  await project.getByRole('button', { name: 'Create project' }).click();
  await expect(project).not.toBeVisible();
  await newTrack(page, 'escape-first');
  await newTrack(page, 'escape-second');
  const links = page.locator('#yard .workspace-project.current .project-tree-tracks').getByRole('link');
  await expect(links).toHaveCount(2);
  const [first, second] = [links.nth(0), links.nth(1)];
  await first.click();
  await expect(first).toHaveAttribute('aria-current', 'page');
  const secondPath = await second.getAttribute('href');

  await page.evaluate(ms => window.liveSocket.enableLatencySim(ms), LATENCY_MS);
  try {
    // New track, Escape, and straight on to another track in the sidebar.
    await page.locator('#yard .workspace-project.current .project-add').click();
    const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
    await expect(dialog).toBeVisible();
    await page.keyboard.press('Escape');
    await clickAt(page, second);
    await expect(dialog).toHaveCount(0);
    await expect(page).toHaveURL(new RegExp(`${secondPath}$`));
    await expect(second).toHaveAttribute('aria-current', 'page');

    // Sharing, Escape, and straight on to the inspector's Preview tab.
    await page.getByRole('button', { name: /^Track sharing/ }).click();
    const sharing = page.getByRole('dialog');
    await expect(sharing).toBeVisible();
    const preview = page.getByRole('navigation', { name: 'Inspector panels' })
      .getByRole('button', { name: 'Preview', exact: true });
    await expect(preview).not.toHaveClass(/selected/);
    await page.keyboard.press('Escape');
    await clickAt(page, preview);
    await expect(sharing).toHaveCount(0);
    await expect(preview).toHaveClass(/selected/);

    // One Escape closes the topmost thing: on a phone, a dialog opened from
    // the menu closes and the menu stays.
    await page.setViewportSize({ width: 500, height: 900 });
    await page.getByRole('button', { name: 'Menu', exact: true }).click();
    await expect(page.locator('aside#yard.forced')).toBeVisible();
    await page.locator('#quick-jump-trigger').click();
    const search = page.getByRole('dialog', { name: 'Search', exact: true });
    await expect(search).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(search).toHaveCount(0);
    // Opening it again is a later round trip than anything that Escape
    // pushed, so the menu is still open only if nothing closed it.
    await page.locator('#quick-jump-trigger').click();
    await expect(search).toBeVisible();
    await expect(page.locator('aside#yard.forced')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(search).toHaveCount(0);
    await page.keyboard.press('Escape');
    await expect(page.locator('aside#yard.forced')).toHaveCount(0);
  } finally {
    await page.evaluate(() => window.liveSocket.disableLatencySim());
  }
});
