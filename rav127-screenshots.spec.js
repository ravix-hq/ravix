import { readFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { createWorkspace } from './settings.js';

// RAV-127 evidence, not a regression test: the sidebar in two workspaces,
// with a section made in each, before and after sections belong to a
// workspace. Opt in with RAV127_PHASE=before|after under
// RAVIX_WORKSPACE_ACCESS=true; PNGs land in tmp/rav127/<phase>/.
const phase = process.env.RAV127_PHASE;
const dir = `tmp/rav127/${phase}`;

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

async function switchTo(page, name) {
  await page.locator('#workspace-switcher-trigger').click();
  const menu = page.locator('#workspace-menu');
  await expect(menu).toBeVisible();
  await menu.getByRole('button', { name }).click();
  await expect(page.locator('#workspace-switcher-trigger')).toContainText(name);
  await settled(page);
}

async function createSection(page, name, projectId) {
  await page.locator('#manage-sections').click();
  const dialog = page.getByRole('dialog', { name: 'Project sections', exact: true });
  await dialog.getByLabel('New section', { exact: true }).fill(name);
  await dialog.getByRole('button', { name: 'Create section', exact: true }).click();
  await expect(dialog.locator('input[value="' + name + '"]')).toBeVisible();
  if (projectId) {
    await dialog.locator(`#project-section-${projectId}`).selectOption({ label: name });
  }
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
}

async function shot(page, name) {
  await settled(page);
  await page.locator('#yard').screenshot({ path: `${dir}/${name}.png` });
}

test('RAV-127: the sidebar sections of two workspaces', async ({ page }) => {
  test.skip(!phase || process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'Opt-in screenshot capture');
  test.setTimeout(180_000);
  mkdirSync(dir, { recursive: true });
  const sql = browserSql();
  await page.setViewportSize({ width: 1280, height: 900 });

  await signIn(page, 'scopeowner');
  await connectClaude(page);
  await page.goto('/home');
  await settled(page);
  const billing = await addProject(page, 'Billing app');
  const docs = await addProject(page, 'Docs site');
  const api = await addProject(page, 'Team API');
  // Repository projects, so they sit in sections rather than the Scratch group.
  sql(`UPDATE ravix.projects SET repo_full_name = 'scopeowner/billing' WHERE id = '${billing}'`);
  sql(`UPDATE ravix.projects SET repo_full_name = 'scopeowner/docs' WHERE id = '${docs}'`);
  sql(`UPDATE ravix.projects SET repo_full_name = 'acme/api' WHERE id = '${api}'`);

  await page.locator('#workspace-switcher-trigger').click();
  await createWorkspace(page, 'Acme');
  const acme = idOf(new URL(page.url()).pathname.replace('/settings/members', ''));
  sql(`UPDATE ravix.projects SET workspace_id = '${acme}' WHERE id = '${api}'`);

  // Personal workspace: a section with a project in it.
  await page.goto('/home');
  await settled(page);
  await switchTo(page, /scopeowner/);
  await createSection(page, 'Client work', billing);
  await expect(page.locator('#yard').getByText('Client work')).toBeVisible();
  await shot(page, '1-personal-with-section');

  // Acme: before, the empty "Client work" shows up here too; after, it does not.
  await switchTo(page, /Acme/);
  await shot(page, '2-acme-before-own-section');

  // A section made in Acme is shown there while empty.
  await createSection(page, 'Acme backlog');
  await expect(page.locator('#yard').getByText('Acme backlog')).toBeVisible();
  await shot(page, '3-acme-with-own-section');

  // Back in the personal workspace: before, "Acme backlog" leaks here; after, it does not.
  await switchTo(page, /scopeowner/);
  await shot(page, '4-personal-again');
});
