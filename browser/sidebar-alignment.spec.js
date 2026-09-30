import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn, connectClaude } from './sign-in.js';

// RAV-65: a row's status dot keeps its slot when there is none, so the
// avatars down the rail are one column whichever rows have a dot.
test('sidebar avatars line up whether or not a row shows a status dot', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: /^New project/ }).click();
  await page.getByLabel('Project name', { exact: true }).fill(`Aligned rail ${Date.now().toString(36)}`);
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  const projectPath = new URL(page.url()).pathname;
  const ids = [];
  for (let i = 0; i < 3; i++) {
    const previousPath = new URL(page.url()).pathname;
    await page.locator('#yard .workspace-project.current .project-add').click();
    await page.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect.poll(() => new URL(page.url()).pathname).not.toBe(previousPath);
    // Idle is drawn once setup is ready and the opening turn has settled, so
    // nothing the server does later redraws a row's dot under the test.
    await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 30_000 });
    ids.push(new URL(page.url()).pathname.split('/t/')[1]);
  }
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || ids.some(id => !/^[a-f0-9-]{36}$/.test(id))) throw new Error('Invalid browser fixture');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  const sql = query => execFileSync('psql', [`${server}/${database}`, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c', query], { encoding: 'utf8' }).trim();
  // Fixture row only: the middle track's machine failed, which draws a dot.
  sql(`UPDATE ravix.tracks SET sandbox_state = 'failed' WHERE id = '${ids[1]}'`);

  await page.goto(projectPath);
  const rows = ids.map(id => page.locator(`#project-track-tab-${id}`));
  const dot = rows[1].locator('.track-status .dot.error');
  await expect(dot).toBeVisible();
  await expect(dot).toHaveAttribute('role', 'img');
  await expect(dot).toHaveAttribute('aria-label', 'Error');
  await expect(dot).toHaveAttribute('title', "Error: This track's machine failed.");
  for (const index of [0, 2]) await expect(rows[index].locator('.dot')).toHaveCount(0);

  const x = async (row, selector) => (await row.locator(selector).boundingBox()).x;
  for (const selector of ['.track-status', '.track-creator', '.track-title']) {
    const xs = await Promise.all(rows.map(row => x(row, selector)));
    expect(new Set(xs).size, `${selector} x-positions ${xs}`).toBe(1);
  }
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
});
