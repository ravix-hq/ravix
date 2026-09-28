import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn, connectClaude } from './sign-in.js';

test('machine status follows the selected dedicated track, never its shared project', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: /^New project/ }).click();
  await page.getByLabel('Project name', { exact: true }).fill('Track machine isolation');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  const paths = [];
  for (let i = 0; i < 2; i++) {
    const previousPath = new URL(page.url()).pathname;
    await page.locator('#yard .workspace-project.current .project-add').click();
    await page.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect.poll(() => new URL(page.url()).pathname).not.toBe(previousPath);
    await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();
    // Setup finishes on the shared layout the fixture then rewrites.
    await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 30_000 });
    paths.push(new URL(page.url()).pathname);
  }
  const ids = paths.map(path => path.split('/t/')[1]);
  expect(new Set(ids).size).toBe(2);
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || ids.some(id => !/^[a-f0-9-]{36}$/.test(id))) throw new Error('Invalid browser fixture');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  const sql = query => execFileSync('psql', [`${server}/${database}`, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c', query], { encoding: 'utf8' }).trim();
  const conversation = sql(`SELECT conversation_id FROM ravix.tracks WHERE id = '${ids[0]}'`);
  const response = await request.get(`http://localhost:${process.env.MOCK_PORT || 8893}/api/conversations/${conversation}`);
  expect(response.ok()).toBe(true);
  const { data } = await response.json();
  const sandbox = data.sandbox_id;
  if (!/^[a-zA-Z0-9_-]+$/.test(sandbox)) throw new Error('Invalid sandbox fixture');
  // Fixture rows only: production dedicated writers remain disabled. One
  // real mock disk and one missing disk prove selection cannot fall back.
  sql(`UPDATE ravix.tracks SET sandbox_layout = 'dedicated', sandbox_generation = 1, sandbox_id = CASE id WHEN '${ids[0]}' THEN '${sandbox}' ELSE 'missing-${ids[1]}' END WHERE id IN ('${ids[0]}', '${ids[1]}')`);
  for (const index of [0, 1, 0]) {
    await page.goto(paths[index]);
    await expect(page.locator('#track-machine-status')).toHaveText(index === 0
      ? 'Idle.'
      : 'Idle. The machine did not answer just now; your next message wakes it.');
  }
});
