import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { createWorkspace } from './settings.js';

// ADR 0009 follow-up: the switcher makes a workspace current and the app
// shows only it -- the sidebar, quick-jump and the Inbox -- the choice
// survives a reload, a `/p/:id` link into another workspace switches to it,
// and the gear beside the name opens the workspace's settings. At desktop
// and phone widths, axe clean. Runs under `bun run
// test:browser:workspace-access`, with the switch on. Moving a project into
// the team is written here, into the harness's disposable database only,
// as workspace-visibility.spec.js does: that is another item's UI.
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

async function axeClean(page, selector) {
  const result = await new AxeBuilder({ page })
    .include(selector)
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
    .analyze();
  expect(result.violations).toEqual([]);
}

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

test('the switcher scopes the app to the current workspace, and remembers it', async ({ page }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Runs under test:browser:workspace-access');
  test.setTimeout(150_000);
  const sql = browserSql();
  await page.setViewportSize({ width: 1280, height: 900 });

  await signIn(page, 'scopeowner');
  await connectClaude(page);
  await page.goto('/home');
  await settled(page);
  const personalId = await addProject(page, 'Personal scope project');
  const teamProjectId = await addProject(page, 'Team scope project');

  // A team workspace: creating it makes it current and opens its settings.
  await page.locator('#workspace-switcher-trigger').click();
  await createWorkspace(page, 'Scope Team');
  const teamId = idOf(new URL(page.url()).pathname.replace('/settings/members', ''));
  sql(`UPDATE ravix.projects SET workspace_id = '${teamId}' WHERE id = '${teamProjectId}'`);

  const yard = page.locator('#yard');
  await page.goto('/inbox');
  await settled(page);
  await expect(page.locator('#workspace-switcher-trigger')).toContainText('Scope Team');
  await expect(yard.locator(`#project-row-${teamProjectId}`)).toBeVisible();
  await expect(yard.locator(`#project-row-${personalId}`)).toHaveCount(0);
  await expect(page.locator('.inbox header')).toContainText('in Scope Team');
  await axeClean(page, '#yard');

  // Quick-jump searches this workspace only.
  await page.locator('#quick-jump-trigger').click();
  await page.getByLabel('Search projects, tracks and plans').fill('scope project');
  await expect(page.locator(`#search-project-link-${teamProjectId}`)).toBeVisible();
  await expect(page.locator(`#search-project-link-${personalId}`)).toHaveCount(0);
  await page.keyboard.press('Escape');

  // The workspace menu opens its settings, at Members, in the shell.
  await page.locator('#workspace-switcher-trigger').click();
  await page.getByRole('button', { name: 'Workspace settings', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/w/${teamId}/settings/members$`));
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Members');
  await expect(page.getByRole('navigation', { name: 'Breadcrumb' })).toContainText('Scope Team');
  await page.goto('/home');
  await settled(page);

  // Switch to the personal workspace: an event, not a navigation.
  await page.locator('#workspace-switcher-trigger').click();
  const menu = page.locator('#workspace-menu');
  await expect(menu).toBeVisible();
  await axeClean(page, '#workspace-menu');
  await menu.getByRole('button', { name: /scopeowner/ }).click();
  await expect(page).toHaveURL(/\/home$/);
  await expect(page.locator('#workspace-switcher-trigger')).toContainText('scopeowner');
  await expect(yard.locator(`#project-row-${personalId}`)).toBeVisible();
  await expect(yard.locator(`#project-row-${teamProjectId}`)).toHaveCount(0);

  // Remembered across a reload.
  await page.reload();
  await settled(page);
  await expect(page.locator('#workspace-switcher-trigger')).toContainText('scopeowner');
  await expect(yard.locator(`#project-row-${personalId}`)).toBeVisible();

  // A link to a project in another workspace switches to it.
  await page.goto(`/p/${teamProjectId}`);
  await settled(page);
  await expect(page.locator('#workspace-switcher-trigger')).toContainText('Scope Team');
  await expect(yard.locator(`#project-row-${teamProjectId}`)).toHaveClass(/current/);
  await expect(yard.locator(`#project-row-${personalId}`)).toHaveCount(0);

  // A phone: the Menu brings the sidebar back, and switching works there too.
  await page.setViewportSize({ width: 500, height: 900 });
  await page.goto('/home');
  await settled(page);
  await page.locator('.workspace-mobile-nav').getByRole('button', { name: 'Menu' }).click();
  await expect(yard).toBeVisible();
  await axeClean(page, '#yard');
  await page.locator('#workspace-switcher-trigger').click();
  await expect(menu).toBeVisible();
  await axeClean(page, '#workspace-menu');
  await menu.getByRole('button', { name: /scopeowner/ }).click();
  await expect(page.locator('#workspace-switcher-trigger')).toContainText('scopeowner');
  await expect(yard.locator(`#project-row-${personalId}`)).toBeAttached();
  await expect(yard.locator(`#project-row-${teamProjectId}`)).toHaveCount(0);
});
