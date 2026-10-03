import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-65, on the project page's list that replaced the sidebar's: a failed
// machine's row says so with its dot, and every row's dot and name stay in
// one column whichever state each row is in.
test('project track rows line up whatever state each row shows', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  await page.getByLabel('Project name', { exact: true }).fill(`Aligned rail ${Date.now().toString(36)}`);
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(page).toHaveURL(/\/p\/[0-9a-f-]{36}$/);
  const projectPath = new URL(page.url()).pathname;
  const ids = [];
  for (let i = 0; i < 3; i++) {
    const previousPath = new URL(page.url()).pathname;
    await page.locator('#top-new-track').click();
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
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await page.locator('#project-tracks-list').click();
  const rows = ids.map(id => page.locator(`#tracks-row-${id}`));
  const dot = rows[1].locator('.dot');
  await expect(dot).toHaveClass(/\berror\b/);
  await expect(dot).toHaveAttribute('role', 'img');
  await expect(dot).toHaveAttribute('aria-label', /(^| · )Error$/);
  await expect(rows[1].locator('.tracks-row-state')).toHaveText('Error');
  for (const index of [0, 2]) {
    await expect(rows[index].locator('.dot.error')).toHaveCount(0);
    await expect(rows[index].locator('.tracks-row-state')).toHaveText('Idle');
  }

  // The columns: the status dot, whose it is (and the sharing icon) with
  // the name, the owner, the state and the age.
  const x = async (row, selector) => (await row.locator(selector).first().boundingBox()).x;
  for (const selector of ['.dot', '.track-sharing', '.tracks-title', '.tracks-row-owner', '.tracks-row-state', '.tracks-row-age']) {
    const xs = await Promise.all(rows.map(row => x(row, selector)));
    expect(new Set(xs.map(Math.round)).size, `${selector} x-positions ${xs}`).toBe(1);
  }
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);

  // The graph: each track's label is a 56px row in the 300px label column,
  // and its lane is drawn level with it.
  await page.locator('#project-tracks-graph').click();
  await expect(page.locator('#tracks-graph')).toBeVisible();
  const graph = await page.locator('#tracks-graph').evaluate(el => {
    const labels = [...el.querySelectorAll('[id^="tracks-graph-row-"]')];
    const lanes = [...el.querySelectorAll('.tracks-graph-plot .lane .lane-bar')];
    const column = el.querySelector('.tracks-graph-labels').getBoundingClientRect().width;
    return {
      column,
      heights: labels.map(row => Math.round(row.getBoundingClientRect().height)),
      titles: labels.map(row => Math.round(row.querySelector('.tracks-title').getBoundingClientRect().x)),
      offsets: labels.map((row, i) => {
        const r = row.getBoundingClientRect(), bar = lanes[i].getBoundingClientRect();
        return Math.abs((bar.top + bar.height / 2) - (r.top + r.height / 2));
      }),
    };
  });
  expect(Math.round(graph.column)).toBe(300);
  expect(graph.heights).toEqual([56, 56, 56]);
  expect(new Set(graph.titles).size, `graph title x-positions ${graph.titles}`).toBe(1);
  for (const offset of graph.offsets) expect(offset).toBeLessThanOrEqual(2);
});
