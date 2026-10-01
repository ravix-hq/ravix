import { readFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { createWorkspace } from './settings.js';

// RAV-128 evidence, not a regression test: the sidebar and the track header
// as a non-creator member of a team workspace, and as somebody a legacy
// project was shared with. Run with RAVIX_WORKSPACE_ACCESS=true on main and
// on the branch; PNGs land in RAV128_OUT.
const OUT = process.env.RAV128_OUT || 'tmp/rav-128';

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

async function addProject(page, name) {
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const dialog = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await dialog.getByLabel('Project name', { exact: true }).fill(name);
  await dialog.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  return idOf(new URL(page.url()).pathname);
}

async function settled(page) {
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(page.locator('#project-sections[aria-busy="false"]')).toBeAttached();
}

async function shot(page, name) {
  mkdirSync(OUT, { recursive: true });
  await page.screenshot({ path: `${OUT}/${name}.png` });
}

async function switchTo(page, pattern) {
  await page.locator('#workspace-switcher-trigger').click();
  await page.locator('#workspace-menu').getByRole('button', { name: pattern }).click();
  await expect(page.locator('#workspace-switcher-trigger')).toContainText(pattern);
}

test('RAV-128 sidebar and track header, before/after', async ({ page, browser }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Needs the workspace switch on');
  test.setTimeout(300_000);
  const sql = browserSql();
  await page.setViewportSize({ width: 1280, height: 900 });

  await signIn(page, 'teamowner', '/home');
  await connectClaude(page);
  await page.goto('/home');
  await settled(page);
  const teamProjectId = await addProject(page, 'ravix');
  const legacyId = await addProject(page, 'ravix-legacy');

  await page.locator('#workspace-switcher-trigger').click();
  await createWorkspace(page, 'Acme Robotics');
  const teamId = idOf(new URL(page.url()).pathname.replace('/settings/members', ''));
  await page.getByLabel('GitHub username', { exact: true }).fill('teammate');
  await page.getByRole('button', { name: 'Invite', exact: true }).click();
  await expect(page.locator('#workspace-invites')).toContainText('@teammate');

  sql(`UPDATE ravix.projects SET workspace_id = '${teamId}' WHERE id = '${teamProjectId}'`);
  sql(`UPDATE ravix.projects SET workspace_id = NULL WHERE id = '${legacyId}'`);

  // A track on the team project, cut by its creator.
  await page.goto(`/p/${teamProjectId}`);
  await settled(page);
  await page.locator('#yard .workspace-project.current .project-add').click();
  const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
  await dialog.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();
  const trackPath = new URL(page.url()).pathname;
  const trackId = trackPath.split('/t/')[1];
  sql(`UPDATE ravix.tracks SET title = 'Label projects by workspace' WHERE id = '${trackId}'`);

  await page.goto(`/p/${teamProjectId}`);
  await settled(page);
  await shot(page, 'team-project-creator');
  await page.goto(trackPath);
  await expect(page.locator('header.track-crumbs')).toContainText('Label projects by workspace');
  await shot(page, 'team-track-creator');

  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  try {
    const mate = await context.newPage();
    // The first sign-in accepts the workspace invitation and mints the row
    // the legacy share below needs.
    await signIn(mate, 'teammate', '/home');
    sql(`INSERT INTO ravix.project_members (project_id, user_id, invited_by, role, created_at)
         SELECT '${legacyId}', id, 'teamowner', 'write', NOW() FROM ravix.users WHERE login = 'teammate'`);

    await switchTo(mate, /Acme Robotics/);
    await mate.goto(`/p/${teamProjectId}`);
    await settled(mate);
    await expect(mate.locator(`#project-link-${teamProjectId} .project-label`)).toContainText('ravix');
    await shot(mate, 'team-project-member');
    await mate.goto(trackPath);
    await expect(mate.locator('header.track-crumbs')).toContainText('Label projects by workspace');
    await shot(mate, 'team-track-member');

    await switchTo(mate, /teammate/);
    await mate.goto(`/p/${legacyId}`);
    await settled(mate);
    await expect(mate.locator(`#project-link-${legacyId} .project-label`)).toContainText('ravix-legacy');
    await shot(mate, 'legacy-project-member');
  } finally {
    await context.close();
  }
});
