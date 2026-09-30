import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// Whether `inner` lies wholly inside `outer`, with a pixel of rounding.
function within(inner, outer) {
  return inner.y >= outer.y - 1 && inner.y + inner.height <= outer.y + outer.height + 1 &&
    inner.x >= outer.x - 1 && inner.x + inner.width <= outer.x + outer.width + 1;
}

// RAV-90: the Commands pane's empty state is all there without scrolling ---
// mark, title, what the tab is for and Open Preview --- and neither pane
// repeats whose machine it is under the header's badge, which says so first.
test("the dock's Commands empty state is whole, under no second machine heading", async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  // A seeded dedicated-open identity, so the header badge says "Own machine".
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add repository', exact: true }).first().click();
  const dialog = page.getByRole('dialog', { name: 'Add repository', exact: true });
  await dialog.getByLabel('Project name', { exact: true }).fill('Dock commands');
  await dialog.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page).toHaveURL(url => url.pathname.includes('/t/') && !url.search);
  await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 45_000 });
  await expect(page.locator('#track-machine-scope')).toHaveText('Own machine');

  await page.getByRole('button', { name: 'Commands', exact: true }).click();
  const scroll = page.locator('#track-terminal .term-scroll');
  const empty = page.locator('#track-terminal .dock-empty .empty');
  await expect(empty.locator('h3')).toHaveText('No commands yet');
  await expect(page.locator('#machine-dock').getByText("This track's machine")).toHaveCount(0);
  await expect(page.locator('#machine-dock .dock-context')).toHaveCount(0);

  for (const size of [{ width: 1440, height: 900 }, { width: 1024, height: 700 }]) {
    await page.setViewportSize(size);
    // Nothing to scroll to: the pane holds the whole of it.
    expect(await scroll.evaluate(el => el.scrollHeight - el.clientHeight)).toBeLessThanOrEqual(1);
    const pane = await scroll.boundingBox();
    for (const part of [empty.locator('.mark'), empty.locator('h3'), empty.locator('p'),
      empty.getByRole('button', { name: 'Open Preview', exact: true })]) {
      await expect(part).toBeVisible();
      expect(within(await part.boundingBox(), pane)).toBe(true);
    }
  }
  await page.setViewportSize({ width: 1440, height: 900 });
  expect((await new AxeBuilder({ page }).include('#machine-dock').withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);

  await page.getByRole('button', { name: 'Machine stats', exact: true }).click();
  await expect(page.locator('#machine-dock .dock-empty h3').or(page.locator('.machine-stats')).first()).toBeVisible();
  await expect(page.locator('#machine-dock').getByText("This track's machine")).toHaveCount(0);
  await expect(page.locator('#machine-dock .dock-context')).toHaveCount(0);
});
