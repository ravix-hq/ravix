import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-99: Ctrl+K (⌘K on a Mac) opens quick jump from anywhere, the composer
// included; nothing typed straight after it is lost; and the dialog's top
// stays where it opened while the results under it change.
async function newTrack(page, name) {
  await page.locator('#yard .workspace-project.current .project-add').click();
  const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
  await dialog.getByRole('button', { name: 'Options', exact: true }).click();
  await dialog.getByLabel('Branch name', { exact: true }).fill(name);
  await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await expect(page).toHaveURL(/\/t\//);
}

const top = locator => locator.evaluate(el => el.getBoundingClientRect().top);

test('Ctrl+K opens quick jump from the composer, keeps every key and stays put', async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'quickjumper', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill('Jump project');
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(page.locator('#crumb-plans')).toBeVisible();
  const long = 'rav-83-workspaces-as-the-unit-of-sharing-across-projects-teams-and-organisations-in-one-place-for-everyone';
  // Read as words once created: the issue key in capitals, the rest as typed.
  const named = `RAV-83 ${long.slice(7).replaceAll('-', ' ')}`;
  await newTrack(page, long);
  await newTrack(page, 'rav-99-quick-jump');

  // Linux Chrome: the hint says Ctrl K, and the key works from the composer.
  const trigger = page.locator('#quick-jump-trigger');
  await expect(trigger).toHaveAttribute('title', /\(Ctrl K\)$/);
  const composer = page.locator('textarea').first();
  await composer.focus();
  const dialog = page.getByRole('dialog', { name: 'Search', exact: true });
  const query = dialog.getByLabel('Search projects, tracks and plans');

  // Typed at once, with no wait for the dialog: every key lands in the query.
  await page.keyboard.press('Control+k');
  await page.keyboard.type('rav-9', { delay: 0 });
  await expect(query).toBeFocused();
  await expect(query).toHaveValue('rav-9');
  await expect(composer).toHaveValue('');
  const rows = dialog.locator('[data-jump-result]');
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toHaveText('RAV-99 quick jump');

  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);

  // The top is where it opened, through every result change and the empty
  // state, and it is near the top of the page rather than its middle.
  await page.keyboard.press('Control+k');
  await expect(query).toBeFocused();
  const panel = page.locator('#search-dialog-dialog');
  await expect(rows).toHaveCount(3);
  const opened = await top(panel);
  expect(Math.abs(opened - 900 * 0.12)).toBeLessThanOrEqual(2);
  const tops = new Set([opened]);
  for (const [text, count] of [['r', 3], ['rav-8', 1], ['rav-83-zz', 0], ['', 3]]) {
    await query.fill(text);
    if (count) await expect(rows).toHaveCount(count);
    else await expect(dialog.getByRole('status')).toHaveText("No tracks match 'rav-83-zz'");
    tops.add(await top(panel));
  }
  expect([...tops]).toEqual([opened]);

  // A long name ends in an ellipsis inside the row, not wrapped mid-word.
  const label = dialog.locator('[data-jump-result] .search-label', { hasText: 'RAV-83 ' });
  expect(await label.evaluate(el => [getComputedStyle(el).textOverflow, el.scrollWidth > el.clientWidth]))
    .toEqual(['ellipsis', true]);
  // The full name is the row's tooltip, as the sidebar says it
  // (`Track.label/1`, RAV-83), and the raw branch under it.
  await expect(label.locator('xpath=..')).toHaveAttribute('title', `${named}\nravix/${long}`);
  // The group header is muted text with a count, not a link-blue heading.
  const header = dialog.locator('h3').first();
  await expect(header.locator('.search-count')).toHaveText('2');
  expect(await header.evaluate(el => getComputedStyle(el).color))
    .toBe(await page.evaluate(() => getComputedStyle(document.body).getPropertyValue('--dim').trim())
      .then(hex => `rgb(${[1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16)).join(', ')})`));

  // Arrows move the highlight, Enter opens it.
  await query.fill('rav-8');
  await expect(rows).toHaveCount(1);
  await query.press('ArrowDown');
  await expect(rows.first()).toBeFocused();
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
  await page.keyboard.press('Enter');
  await expect(dialog).toHaveCount(0);
  await expect(page.locator('.track-crumbs')).toContainText(named);
});
