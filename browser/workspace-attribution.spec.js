import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-86, with RAVIX_WORKSPACE_ACCESS on (`bun run
// test:browser:workspace-access`): on a shared track the agent is delivered
// the thread's commit attribution block ahead of the sender's `[from @login]`
// marker. The bubble shows the sender and what they typed, never the block
// or its noreply address. The project member is written into the harness's
// disposable database only, as workspace-sharing.spec.js does.
function browserSql() {
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database)) throw new Error('Not a browser database');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  return query => execFileSync('psql', [`${server}/${database}`, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c', query], { encoding: 'utf8' }).trim();
}

const idOf = path => {
  const id = path.split('/').pop();
  if (!/^[a-f0-9-]{36}$/.test(id)) throw new Error(`Not an id: ${path}`);
  return id;
};

test('a shared track shows who sent a prompt and what they typed, not the attribution block', async ({ page, browser }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  test.setTimeout(180_000);
  const sql = browserSql();

  const colleagueContext = await browser.newContext();
  try {
    await signIn(await colleagueContext.newPage(), 'attributecolleague');
  } finally {
    await colleagueContext.close();
  }

  await signIn(page, 'attributor', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Attributed prompts');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectId = idOf(new URL(page.url()).pathname);
  // A second person on the project makes the track shared, so the agent is
  // told who is speaking.
  sql(`INSERT INTO ravix.project_members (project_id, user_id, role, invited_by, created_at)
         SELECT '${projectId}', id, 'write', 'attributor', NOW() FROM ravix.users
         WHERE login = 'attributecolleague'`);

  await page.locator('#top-new-track').click();
  const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
  await dialog.getByLabel('What do you want to work on?', { exact: true })
    .fill('Add a **health check** endpoint');
  await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(dialog).toHaveCount(0);

  // Setup's later checks and the delivery ride the queue's sweep, whose
  // backstop is thirty seconds (first-prompt.spec.js).
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 60_000 });
  await expect(page.locator('.workspace-queue')).toHaveCount(0, { timeout: 45_000 });
  const said = page.locator('#transcript-turns .said')
    .filter({ hasText: 'Add a health check endpoint' });
  await expect(said).toHaveCount(1, { timeout: 20_000 });
  await expect(said.locator('.speaker')).toHaveText('@attributor');
  await expect(said.locator('.workspace-prompt strong')).toHaveText('health check');
  await expect(said.locator('.workspace-prompt')).toHaveText('Add a health check endpoint');
  const transcript = await page.locator('#transcript-turns').innerText();
  expect(transcript).not.toContain('[ravix commit attribution]');
  expect(transcript).not.toContain('noreply');
  expect(transcript).not.toContain('Co-authored-by');
});
