import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { expectInlineChoice } from './controls.js';

// ADR 0009 phase 5, with RAVIX_WORKSPACE_ACCESS on (`bun run
// test:browser:workspace-access`): the track header's Share dialog shares a
// private track with one workspace member, and it still leaks to no other
// member through the rail, search, badges or the Inbox. Admission to the
// workspace is written here, into the harness's disposable database only,
// as workspace-visibility.spec.js does; everything about sharing goes
// through the dialog.
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

test('the Share dialog shares a private track with one member, and nobody else learns of it', async ({ page, browser, context }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  test.setTimeout(180_000);
  const sql = browserSql();
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);

  await signIn(page, 'sharecreator');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Workspace sharing project');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectPath = new URL(page.url()).pathname;
  const projectId = idOf(projectPath);
  const secretPath = await openTrack(page, 'private', 'share-secret');
  const secretId = idOf(secretPath);

  const colleagueContext = await browser.newContext();
  const bystanderContext = await browser.newContext();
  try {
    const colleague = await colleagueContext.newPage();
    const bystander = await bystanderContext.newPage();
    await signIn(colleague, 'sharecolleague');
    await signIn(bystander, 'sharebystander');

    // The creator's personal workspace takes the project and both of them.
    // The private track needs attention, so a leaked badge would count it.
    sql(`UPDATE ravix.projects SET workspace_id = (SELECT id FROM ravix.workspaces
           WHERE personal_user_id = '00000000-0000-4000-8000-000000009013') WHERE id = '${projectId}'`);
    sql(`INSERT INTO ravix.workspace_memberships (workspace_id, user_id, role, created_at)
           SELECT p.workspace_id, u.id, 'member', NOW() FROM ravix.projects p, ravix.users u
           WHERE p.id = '${projectId}' AND u.login IN ('sharecolleague', 'sharebystander')`);
    sql(`UPDATE ravix.tracks SET setup_state = 'failed' WHERE id = '${secretId}'`);

    // The Share dialog: private already, an accessible dialog, no invite link.
    await page.goto(secretPath);
    await page.getByRole('button', { name: /^Share/ }).click();
    const share = page.getByRole('dialog', { name: 'Share track', exact: true });
    await expect(share).toBeVisible();
    await expect(share.getByLabel('Only people I add')).toBeChecked();
    await expect(share).not.toContainText('invite link');
    // RAV-59: each radio sits beside its one-line label.
    for (const name of ['Everyone in ', 'Only people I add']) {
      await expectInlineChoice(share.locator('.share-visibility label').filter({ hasText: name }));
    }
    const axe = await new AxeBuilder({ page }).include('#track-share-dialog-dialog')
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
    expect(axe.violations).toEqual([]);

    // The @-mention box offers workspace members only; the keyboard picks one.
    const box = share.getByRole('combobox', { name: 'Add workspace members' });
    await box.fill('@mockuser');
    await expect(share.getByRole('listbox')).toBeHidden();
    await box.fill('@share');
    const options = share.getByRole('listbox');
    await expect(options.getByRole('option', { name: /@sharecolleague/ })).toBeVisible();
    await expect(options.getByRole('option', { name: /@sharebystander/ })).toBeVisible();
    await expect(options.getByRole('option', { name: /@sharecreator/ })).toHaveCount(0);
    await box.fill('@sharecol');
    await expect(options.getByRole('option')).toHaveCount(1);
    await expect(box).toHaveAttribute('aria-activedescendant', 'share-option-sharecolleague');
    await box.press('Enter');
    await expect(share.getByRole('list', { name: 'Shared with' })).toContainText('@sharecolleague');

    // Copy link is the track's own address.
    await share.getByRole('button', { name: 'Copy link', exact: true }).click();
    await expect(share.getByRole('status')).toHaveText('Copied');
    expect(await page.evaluate(() => navigator.clipboard.readText())).toMatch(new RegExp(`${secretPath}$`));
    await page.keyboard.press('Escape');
    await expect(share).toHaveCount(0);

    // The colleague it was shared with opens it.
    await colleague.goto(secretPath);
    await expect(colleague.locator('.track-crumbs')).toContainText('share-secret');

    // The bystander, in the same workspace, learns nothing of it.
    await bystander.goto(projectPath);
    await expect(bystander.locator('#project-sections[aria-busy="false"]')).toBeAttached();
    await expect(bystander.locator(`#project-track-tab-${secretId}`)).toHaveCount(0);
    await expect(bystander.locator('body')).not.toContainText('share-secret');
    await expect(bystander.locator(`#project-link-${projectId} .badge`)).toHaveCount(0);
    await bystander.locator('#quick-jump-trigger').click();
    await bystander.getByLabel('Search projects, tracks and plans').fill('share-secret');
    await expect(bystander.locator('#search-dialog [data-jump-result]')).toHaveCount(0);
    await bystander.keyboard.press('Escape');
    await bystander.goto('/inbox');
    await expect(bystander.locator('#project-sections[aria-busy="false"]')).toBeAttached();
    await expect(bystander.locator('body')).not.toContainText('share-secret');
    await bystander.goto(secretPath);
    await expect(bystander).toHaveURL(new RegExp(`${projectPath}$`));

    // Removing the colleague takes the open page away from them at once.
    await page.getByRole('button', { name: /^Share/ }).click();
    await share.getByRole('button', { name: 'Remove @sharecolleague', exact: true }).click();
    await expect(share).toContainText('Not shared with anyone yet.');
    await expect(colleague.locator('.track-crumbs')).toHaveCount(0);
    await expect(colleague.locator('body')).not.toContainText('share-secret');
  } finally {
    await colleagueContext.close();
    await bystanderContext.close();
  }
});

// RAV-32: a workspace project's People dialog offers no invitation and no
// invite link. RAV-75: it lists everyone who reaches the project with where
// their role comes from, and gives a workspace member a different role.
test("a workspace project's People dialog lists every source and gives a different role", async ({ page }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  const sql = browserSql();

  await signIn(page, 'sharecreator');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const dialog = page.getByRole('dialog', { name: 'New project', exact: true });
  await dialog.getByLabel('Project name', { exact: true }).fill('Retired links project');
  await dialog.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  const projectPath = new URL(page.url()).pathname;
  const projectId = idOf(projectPath);
  sql(`UPDATE ravix.projects SET workspace_id = (SELECT id FROM ravix.workspaces
         WHERE personal_user_id = '00000000-0000-4000-8000-000000009013') WHERE id = '${projectId}'`);
  const workspaceId = sql(`SELECT workspace_id FROM ravix.projects WHERE id = '${projectId}'`);
  expect(workspaceId).toMatch(/^[a-f0-9-]{36}$/);

  // Two more members: one with a direct grant, one the workspace alone admits.
  sql(`INSERT INTO ravix.users (id, github_id, login, created_at, last_seen_at) VALUES
         ('00000000-0000-4000-8000-000000097501', '97501', 'accessalice', NOW(), NOW()),
         ('00000000-0000-4000-8000-000000097502', '97502', 'accesscarol', NOW(), NOW())
         ON CONFLICT DO NOTHING`);
  sql(`INSERT INTO ravix.workspace_memberships (workspace_id, user_id, role, created_at)
         SELECT '${workspaceId}', id, 'member', NOW() FROM ravix.users
         WHERE login IN ('accessalice', 'accesscarol') ON CONFLICT DO NOTHING`);
  sql(`INSERT INTO ravix.project_members (project_id, user_id, invited_by, role, created_at)
         VALUES ('${projectId}', '00000000-0000-4000-8000-000000097501',
                 '00000000-0000-4000-8000-000000009013', 'write', NOW())`);

  await page.goto(projectPath);
  await page.getByRole('button', { name: 'People', exact: true }).click();
  const people = page.getByRole('dialog', { name: 'Project people', exact: true });
  await expect(people).toBeVisible();
  await expect(people.getByLabel('GitHub username')).toHaveCount(0);
  await expect(people).not.toContainText('invite link');
  await expect(people).not.toContainText('members page');
  const summary = people.getByRole('list', { name: 'Access summary' });
  await expect(summary).toContainText('Base role: Write');
  await expect(summary).toContainText('Direct access: 1 person');
  await expect(summary).toContainText('3 sharecreator members get Write by default');
  await expect(people.locator('#people-person-sharecreator')).toContainText('Admin');
  await expect(people.locator('#people-person-sharecreator')).toContainText('owner');
  await expect(people.locator('#people-person-accessalice')).toContainText('direct');
  const carol = people.locator('#people-person-accesscarol');
  await expect(carol).toContainText('from workspace');
  const axe = await new AxeBuilder({ page }).include('#people-dialog')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(axe.violations).toEqual([]);

  // Give the workspace member a lower role: it becomes a direct grant.
  await carol.getByRole('button', { name: 'Give @accesscarol a different role', exact: true }).click();
  const menu = page.getByRole('menu', { name: 'Role for @accesscarol', exact: true });
  await expect(menu).toBeVisible();
  await menu.getByRole('menuitemradio', { name: /^Read/ }).click();
  await expect(carol).toContainText('direct');
  await expect(carol.getByRole('button', { name: 'Role for @accesscarol: Read', exact: true })).toBeVisible();
  await expect(summary).toContainText('Direct access: 2 people');
  expect(sql(`SELECT role FROM ravix.project_members WHERE project_id = '${projectId}'
                AND user_id = '00000000-0000-4000-8000-000000097502'`)).toBe('read');

  // And back to the workspace's.
  await carol.getByRole('button', { name: 'Role for @accesscarol: Read', exact: true }).click();
  await menu.getByRole('menuitem', { name: 'Use workspace role (Write)', exact: true }).click();
  await expect(carol).toContainText('from workspace');
  await expect(summary).toContainText('Direct access: 1 person');
});
