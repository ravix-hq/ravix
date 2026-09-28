import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

// ADR 0009 phase 3b, with RAVIX_WORKSPACE_ACCESS on: `bun run
// test:browser:workspace-access` starts the harness (browser/server.py) so.
// Workspace admission has no UI until phase 4 and sharing with selected
// members none until phase 5, so the two rows those will write -- the
// project's workspace and a membership, then a permission row -- are written
// here, into the harness's disposable database only.
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

async function openTrack(page, visibility, branch) {
  await page.locator('#yard .workspace-project.current .project-add').click();
  const track = page.getByRole('dialog', { name: 'New track', exact: true });
  await track.getByLabel('Sharing', { exact: true }).selectOption(visibility);
  await track.getByRole('button', { name: 'Advanced', exact: true }).click();
  await track.getByLabel('Branch name', { exact: true }).fill(branch);
  await track.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('.track-crumbs')).toContainText(branch);
  return new URL(page.url()).pathname;
}

test('a private track stays out of another workspace member\'s rail, search and badges', async ({ page, browser }) => {
  // The harness runs the app with the switch as the run sets it: off for
  // `test:browser`, on for `test:browser:workspace-access`.
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  test.setTimeout(150_000);
  const sql = browserSql();

  await signIn(page, 'workspacecreator');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Workspace visibility project');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectPath = new URL(page.url()).pathname;
  const projectId = idOf(projectPath);

  const secretPath = await openTrack(page, 'private', 'workspace-secret');
  const secretId = idOf(secretPath);
  await page.goto(projectPath);
  const openPath = await openTrack(page, 'project', 'workspace-open');
  const openId = idOf(openPath);

  const colleagueContext = await browser.newContext();
  try {
    const colleague = await colleagueContext.newPage();
    // Signing in writes the colleague's user row and personal workspace.
    await signIn(colleague, 'workspacecolleague');
    await expect(colleague.locator('body')).not.toContainText('Workspace visibility project');

    // Admit the project to the creator's personal workspace and the colleague
    // to that workspace. The private track needs attention (a failed setup),
    // so a leaked badge would count it; the open one does not.
    sql(`UPDATE ravix.projects SET workspace_id = (SELECT id FROM ravix.workspaces
           WHERE personal_user_id = '00000000-0000-4000-8000-000000009009') WHERE id = '${projectId}'`);
    sql(`INSERT INTO ravix.workspace_memberships (workspace_id, user_id, role, created_at)
           SELECT p.workspace_id, u.id, 'member', NOW() FROM ravix.projects p, ravix.users u
           WHERE p.id = '${projectId}' AND u.login = 'workspacecolleague'`);
    sql(`UPDATE ravix.tracks SET setup_state = 'failed' WHERE id = '${secretId}'`);
    sql(`UPDATE ravix.tracks SET setup_state = 'ready' WHERE id = '${openId}'`);

    await colleague.goto(projectPath);
    await expect(colleague.locator('#project-sections[aria-busy="false"]')).toBeAttached();
    await expect(colleague.locator(`#project-track-tab-${openId}`)).toBeVisible();
    await expect(colleague.locator(`#project-track-tab-${secretId}`)).toHaveCount(0);
    await expect(colleague.locator('body')).not.toContainText('workspace-secret');
    await expect(colleague.locator(`#project-link-${projectId} .badge`)).toHaveCount(0);

    await colleague.locator('#quick-jump-trigger').click();
    const search = colleague.getByLabel('Search projects, tracks and plans');
    await search.fill('workspace-secret');
    await expect(colleague.locator('#search-dialog [data-jump-result]')).toHaveCount(0);
    await search.fill('workspace-open');
    await expect(colleague.locator(`#search-track-link-${openId}`)).toBeVisible();
    await colleague.keyboard.press('Escape');

    await colleague.goto('/inbox');
    await expect(colleague.locator('#project-sections[aria-busy="false"]')).toBeAttached();
    await expect(colleague.locator('body')).not.toContainText('workspace-secret');

    // Its URL opens nothing for them.
    await colleague.goto(secretPath);
    await expect(colleague).toHaveURL(new RegExp(`${projectPath}$`));
    await expect(colleague.locator('body')).not.toContainText('workspace-secret');

    // The creator, meanwhile, sees it and its badge.
    await page.goto(projectPath);
    await expect(page.locator(`#project-track-tab-${secretId}`)).toBeVisible();
    await expect(page.locator(`#project-link-${projectId} .badge`)).toHaveAttribute('aria-label', '1 unread');

    // Shared with the colleague by a permission row, it reaches them.
    sql(`INSERT INTO ravix.track_permissions (track_id, user_id, workspace_id, granted_by_user_id, created_at)
           SELECT '${secretId}', u.id, p.workspace_id, '00000000-0000-4000-8000-000000009009', NOW()
           FROM ravix.projects p, ravix.users u
           WHERE p.id = '${projectId}' AND u.login = 'workspacecolleague'`);
    await colleague.goto(secretPath);
    await expect(colleague.locator('.track-crumbs')).toContainText('workspace-secret');
    await expect(colleague.locator('.track-crumbs')).toContainText('Private');
  } finally {
    await colleagueContext.close();
  }
});
