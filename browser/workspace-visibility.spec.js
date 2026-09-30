import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { chooseSharing } from './new-track.js';

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
  await chooseSharing(track, visibility);
  await track.getByRole('button', { name: 'Options', exact: true }).click();
  await track.getByLabel('Branch name', { exact: true }).fill(branch);
  await track.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('.track-crumbs')).toContainText(branch);
  return new URL(page.url()).pathname;
}

// A track's own setup turn runs on the server after it is created, and its
// completion bumps the conversation's activity. Until it has finished, whether
// the track reads as an unread reply depends on who was looking when it did.
// So wait for that turn to finish (`#track-setup-status` goes once setup is
// ready), after which nothing runs on the track again.
async function settled(page) {
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });
}

test('a private track stays out of another workspace member\'s rail, search and badges', async ({ page, browser }) => {
  // The harness runs the app with the switch as the run sets it: off for
  // `test:browser`, on for `test:browser:workspace-access`.
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  test.setTimeout(150_000);
  const sql = browserSql();
  // Every repeat shares the harness's database and these two people, so each
  // names its own project and branches.
  const run = `${Date.now().toString(36)}${test.info().repeatEachIndex}`;
  const projectName = `Workspace visibility ${run}`;
  const secretBranch = `workspace-secret-${run}`;
  const openBranch = `workspace-open-${run}`;

  await signIn(page, 'workspacecreator');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill(projectName);
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectPath = new URL(page.url()).pathname;
  const projectId = idOf(projectPath);

  const secretPath = await openTrack(page, 'private', secretBranch);
  const secretId = idOf(secretPath);
  await settled(page);
  await page.goto(projectPath);
  const openPath = await openTrack(page, 'project', openBranch);
  const openId = idOf(openPath);
  await settled(page);

  // The creator reads the open track after its last activity: loading the
  // page marks it read before the track is drawn, so once the crumbs are
  // there the read is recorded. It is then no reply of theirs to count.
  await page.goto(openPath);
  await expect(page.locator('.track-crumbs')).toContainText(openBranch);
  await expect(page.locator(`#project-track-tab-${openId} .dot.unread`)).toHaveCount(0);

  const colleagueContext = await browser.newContext();
  try {
    const colleague = await colleagueContext.newPage();
    // Signing in writes the colleague's user row and personal workspace.
    await signIn(colleague, 'workspacecolleague');
    await expect(colleague.locator('body')).not.toContainText(projectName);

    // Admit the project to the creator's personal workspace and the colleague
    // to that workspace (an earlier repeat may have already). The private
    // track needs attention (a failed setup), so a leaked badge counts it.
    sql(`UPDATE ravix.projects SET workspace_id = (SELECT id FROM ravix.workspaces
           WHERE personal_user_id = '00000000-0000-4000-8000-000000009009') WHERE id = '${projectId}'`);
    sql(`INSERT INTO ravix.workspace_memberships (workspace_id, user_id, role, created_at)
           SELECT p.workspace_id, u.id, 'member', NOW() FROM ravix.projects p, ravix.users u
           WHERE p.id = '${projectId}' AND u.login = 'workspacecolleague'
           ON CONFLICT DO NOTHING`);
    sql(`UPDATE ravix.tracks SET setup_state = 'failed' WHERE id = '${secretId}'`);

    // The colleague has never read the open track, so its settled reply is
    // exactly one unread for them; the private track would make it two.
    await colleague.goto(projectPath);
    await expect(colleague.locator('#project-sections[aria-busy="false"]')).toBeAttached();
    await expect(colleague.locator(`#project-track-tab-${openId}`)).toBeVisible();
    await expect(colleague.locator(`#project-track-tab-${openId} .dot.unread`)).toHaveCount(1);
    await expect(colleague.locator(`#project-track-tab-${secretId}`)).toHaveCount(0);
    await expect(colleague.locator('body')).not.toContainText(secretBranch);
    await expect(colleague.locator(`#project-link-${projectId} .badge`)).toHaveAttribute('aria-label', '1 unread');

    await colleague.locator('#quick-jump-trigger').click();
    const search = colleague.getByLabel('Search projects, tracks and plans');
    await search.fill(secretBranch);
    await expect(colleague.locator('#search-dialog [data-jump-result]')).toHaveCount(0);
    await search.fill(openBranch);
    await expect(colleague.locator(`#search-track-link-${openId}`)).toBeVisible();
    await colleague.keyboard.press('Escape');

    await colleague.goto('/inbox');
    await expect(colleague.locator('#project-sections[aria-busy="false"]')).toBeAttached();
    await expect(colleague.locator('body')).toContainText(openBranch);
    await expect(colleague.locator('body')).not.toContainText(secretBranch);

    // Its URL opens nothing for them.
    await colleague.goto(secretPath);
    await expect(colleague).toHaveURL(new RegExp(`${projectPath}$`));
    await expect(colleague.locator('body')).not.toContainText(secretBranch);

    // The creator, meanwhile, sees it, and it is their one unread: the open
    // track was read after it settled.
    await page.goto(projectPath);
    await expect(page.locator(`#project-track-tab-${secretId}`)).toBeVisible();
    await expect(page.locator(`#project-track-tab-${openId} .dot.unread`)).toHaveCount(0);
    await expect(page.locator(`#project-link-${projectId} .badge`)).toHaveAttribute('aria-label', '1 unread');

    // Shared with the colleague by a permission row, it reaches them.
    sql(`INSERT INTO ravix.track_permissions (track_id, user_id, workspace_id, granted_by_user_id, created_at)
           SELECT '${secretId}', u.id, p.workspace_id, '00000000-0000-4000-8000-000000009009', NOW()
           FROM ravix.projects p, ravix.users u
           WHERE p.id = '${projectId}' AND u.login = 'workspacecolleague'`);
    await colleague.goto(secretPath);
    await expect(colleague.locator('.track-crumbs')).toContainText(secretBranch);
    await expect(colleague.locator('.track-crumbs')).toContainText('Private');
  } finally {
    await colleagueContext.close();
  }
});
