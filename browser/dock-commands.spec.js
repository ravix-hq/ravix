import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// Whether `inner` lies wholly inside `outer`, with a pixel of rounding.
function within(inner, outer) {
  return inner.y >= outer.y - 1 && inner.y + inner.height <= outer.y + outer.height + 1 &&
    inner.x >= outer.x - 1 && inner.x + inner.width <= outer.x + outer.width + 1;
}

// RAV-90: at every height the dock's Commands pane takes, its empty state is
// all there without scrolling --- mark, title, what the tab is for and Open
// Preview, or in a short pane the title and Open Preview --- and neither pane
// repeats whose machine it is under the header's badge, which says so first.
test("the dock's Commands empty state is whole, under no second machine heading", async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  // A seeded dedicated-open identity, so the header badge says "Own machine".
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  const dialog = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await dialog.getByLabel('Project name', { exact: true }).fill('Dock commands');
  await dialog.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await page.locator('#top-new-track').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page).toHaveURL(url => url.pathname.includes('/t/') && !url.search);
  await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 45_000 });
  await expect(page.locator('#track-machine-scope')).toHaveText('Own machine');

  // The dock is the Terminal tab's page now, not a strip under the inspector.
  const views = page.getByRole('navigation', { name: 'Track views', exact: true });
  await views.getByRole('button', { name: 'Terminal', exact: true }).click();
  await page.getByRole('button', { name: 'Commands', exact: true }).click();
  const scroll = page.locator('#track-terminal .term-scroll');
  const empty = page.locator('#track-terminal .dock-empty .empty');
  await expect(empty.locator('h3')).toHaveText('No commands yet');
  await expect(page.locator('#machine-dock').getByText("This track's machine")).toHaveCount(0);
  await expect(page.locator('#machine-dock .dock-context')).toHaveCount(0);

  // Every part the pane shows lies wholly inside it, with nothing to scroll
  // to; a pane too short for the whole of it keeps one line and the button.
  const whole = async (label) => {
    const height = (await scroll.boundingBox()).height;
    expect(await scroll.evaluate(el => el.scrollHeight - el.clientHeight), label).toBeLessThanOrEqual(1);
    const pane = await scroll.boundingBox();
    const parts = [empty.locator('h3'), empty.getByRole('button', { name: 'Open Preview', exact: true })];
    if (await empty.locator('p').isVisible()) parts.push(empty.locator('.mark'), empty.locator('p'));
    else expect(height, `${label}: trimmed only when short`).toBeLessThan(190);
    for (const part of parts) {
      await expect(part).toBeVisible();
      expect(within(await part.boundingBox(), pane), label).toBe(true);
    }
    return height;
  };

  // The desktop dock, at two widths.
  for (const size of [{ width: 1440, height: 900 }, { width: 1024, height: 700 }]) {
    await page.setViewportSize(size);
    await whole(`${size.width}x${size.height}`);
    await expect(empty.locator('p')).toBeVisible();
  }

  // The narrow Terminal view is all dock, as tall as the window leaves it:
  // from a phone held sideways to a tall one.
  await page.setViewportSize({ width: 500, height: 900 });
  await views.getByRole('button', { name: 'Threads' }).click();
  await expect(empty.locator('h3')).toBeHidden();
  await views.getByRole('button', { name: 'Terminal', exact: true }).click();
  await expect(empty.locator('h3')).toBeVisible();
  const heights = [];
  for (let height = 900; height >= 320; height -= 20) {
    await page.setViewportSize({ width: 500, height });
    heights.push(await whole(`500x${height}`));
  }
  // The sweep reached a pane short enough to trim, and one tall enough not to.
  expect(Math.max(...heights)).toBeGreaterThan(400);
  expect(Math.min(...heights)).toBeLessThan(188);
  await page.setViewportSize({ width: 500, height: 900 });
  await expect(empty.locator('p')).toBeVisible();
  await page.setViewportSize({ width: 500, height: 320 });
  await expect(empty.locator('p')).toBeHidden();
  await expect(empty.locator('h3')).toHaveText('No commands yet');
  await views.getByRole('button', { name: 'Threads' }).click();
  await expect(empty.locator('h3')).toBeHidden();

  await page.setViewportSize({ width: 1440, height: 900 });
  await views.getByRole('button', { name: 'Terminal', exact: true }).click();
  await expect(empty.locator('h3')).toBeVisible();
  expect((await new AxeBuilder({ page }).include('#machine-dock').withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);

  await page.getByRole('button', { name: 'Machine stats', exact: true }).click();
  await expect(page.locator('#machine-dock .dock-empty h3').or(page.locator('.machine-stats')).first()).toBeVisible();
  await expect(page.locator('#machine-dock').getByText("This track's machine")).toHaveCount(0);
  await expect(page.locator('#machine-dock .dock-context')).toHaveCount(0);
});
