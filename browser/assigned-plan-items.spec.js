import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn } from './sign-in.js';

test('assigned plan items stay compact across widths and themes', async ({ page }) => {
  await signIn(page, 'eli', '/home');
  await page.getByRole('button', { name: /^Quick start/ }).click();
  await page.getByLabel('Project name', { exact: true }).fill('Assigned items');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  await page.getByRole('navigation', { name: 'Project tracks', exact: true }).getByRole('button', { name: 'New track', exact: true }).click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();
  const track = new URL(page.url()).pathname.split('/t/')[1];
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || !/^[a-f0-9-]{36}$/.test(track)) throw new Error('Invalid browser fixture');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  execFileSync('psql', [`${server}/${database}`, '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', `
    INSERT INTO ravix.plans (id, project_id, title, summary, version, created_by_login, archived, inserted_at, updated_at)
    SELECT 'compact-plan', project_id, 'Small fixes: task state, machine stats, 404 and navigation', '', 1, 'eli', false, now(), now() FROM ravix.tracks WHERE id = '${track}';
    INSERT INTO ravix.plan_items (id, plan_id, position, title, brief, acceptance, dependencies, track_id, inserted_at, updated_at)
    SELECT 'compact-' || n, 'compact-plan', n, title, 'Implement and validate ' || title || '.', 'Tests pass at desktop and phone widths.', '{}', '${track}', now(), now()
    FROM (VALUES (0, 'Report task completion'), (1, 'Show readable machine stats'), (2, 'Render a helpful 404'), (3, 'Keep navigation responsive')) AS items(n,title);
    UPDATE ravix.tracks SET origin_kind = 'plan', origin_plan_id = 'compact-plan', origin_item_id = 'compact-0', origin_title = 'Report task completion', origin_url = '/p/' || project_id || '?plan=compact-plan' WHERE id = '${track}';
  `]);
  await page.reload();
  const summary = page.locator('.track-plan-summary');
  await expect(summary).toHaveCount(1);
  await expect(summary.getByRole('button')).toHaveAttribute('aria-expanded', 'false');
  await expect(summary).toContainText('0 of 4 done');
  await expect(page.locator('.track-plan-item-row')).toHaveCount(0);
  await expect(page.locator('.track-plan-chip')).toHaveAttribute('title', 'Small fixes: task state, machine stats, 404 and navigation');
  for (const theme of ['midnight', 'daylight']) {
    await page.locator('html').evaluate((el, theme) => el.dataset.theme = theme, theme);
    for (const width of [1480, 500]) {
      await page.setViewportSize({ width, height: 900 });
      await expect(summary).toBeVisible();
      expect(await summary.evaluate(el => el.getBoundingClientRect().height)).toBeLessThan(60);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await page.screenshot({ path: `tmp/assigned-after-${theme}-${width}.png` });
      await summary.getByRole('button').click();
      await expect(page.locator('.track-plan-item-row')).toHaveCount(4);
      await expect(page.locator('.track-plan-detail')).toHaveCount(0);
      await page.screenshot({ path: `tmp/assigned-list-${theme}-${width}.png` });
      await page.locator('.track-plan-item-title').first().click();
      await expect(page.locator('.track-plan-detail')).toContainText('Implement and validate Report task completion.');
      await page.getByLabel('Add an item note').fill(`Verified ${theme} at ${width}px`);
      await page.getByRole('button', { name: 'Add note', exact: true }).click();
      await expect(page.locator('.track-plan-detail')).toContainText(`Verified ${theme} at ${width}px`);
      await page.screenshot({ path: `tmp/assigned-expanded-${theme}-${width}.png` });
      const result = await new AxeBuilder({ page }).include('.track-conversation').withTags(['wcag2a', 'wcag2aa']).analyze();
      expect(result.violations).toEqual([]);
      await page.locator('.track-plan-item-title').first().click();
      await summary.getByRole('button').click();
    }
  }
});
