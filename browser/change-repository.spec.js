import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openProjectSettings } from './settings.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

// RAV-76: Danger zone › Change repository… is a dialog in three steps: pick
// one of the repositories the Ravix GitHub App reads (the New track picker's
// list), read what happens (how many open tracks close), type the project's
// name. The machine then clones the new repository and the tracks close,
// keeping the project's settings and secrets.
test('Danger zone changes the repository through a dialog with a typed confirmation', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const create = page.getByRole('dialog', { name: 'New project' });
  await create.getByLabel('Project name', { exact: true }).fill('Repository move');
  await expect(page.locator('#project-repositories option')).not.toHaveCount(0);
  await create.getByLabel('Repository', { exact: true }).fill('mockuser/atlas-api');
  await create.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(create).not.toBeVisible();

  // A track for the change to close.
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
  await expect(page.locator('#yard .workspace-project.current')).not.toContainText('No open tracks');

  // A setting and a secret that must survive the change, on the mock's records.
  const before = (await (await request.get(`${mock}/api/environments`)).json()).data
    .filter(e => e.repositories?.some(r => r.url === 'https://github.com/mockuser/atlas-api.git'))
    .at(-1);
  await request.put(`${mock}/api/environments/${before.id}`, { data: { setup_script: 'make deps' } });
  await request.post(`${mock}/api/environments/${before.id}/secrets`, { data: { key: 'KEPT_SECRET', value: 'kept-value' } });

  const settings = await openProjectSettings(page, 'danger');
  await expect(settings.locator('#change-repository-current')).toContainText('mockuser/atlas-api');
  await settings.getByRole('button', { name: 'Change repository…', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Change the repository of Repository move' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByLabel('Filter repositories', { exact: true })).toBeFocused();

  // 1. The App's other repositories are offered; the current one is not.
  const list = dialog.getByRole('list', { name: 'Repositories' });
  await expect(list.locator('[data-repo="mockuser/cabinet"]')).toHaveCount(1);
  await expect(list.locator('[data-repo="mockuser/atlas-api"]')).toHaveCount(0);
  await dialog.getByLabel('Filter repositories', { exact: true }).fill('cab');
  await expect(list.getByRole('button')).toHaveCount(1);

  // 2. What happens, with the count.
  await expect(dialog.locator('#change-repository-closing')).toHaveText('1 open track will close');

  // 3. The typed name, and only with a repository picked.
  const confirm = dialog.getByLabel('Type Repository move to confirm changing the repository', { exact: true });
  const submit = dialog.getByRole('button', { name: 'Change repository', exact: true });
  await confirm.fill('Repository move');
  await expect(submit).toBeDisabled();
  await list.locator('[data-repo="mockuser/cabinet"]').click();
  await expect(dialog.locator('#change-repository-review')).toContainText('rebuilt from mockuser/cabinet');
  await expect(submit).toBeEnabled();
  await confirm.fill('Repository mov');
  await expect(submit).toBeDisabled();
  await confirm.fill('Repository move');
  const axe = await new AxeBuilder({ page }).include('#change-repository-dialog')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(axe.violations).toEqual([]);

  // Escape closes it and keeps nothing.
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(settings.getByRole('button', { name: 'Change repository…', exact: true })).toBeFocused();
  await settings.getByRole('button', { name: 'Change repository…', exact: true }).click();
  await expect(dialog.locator('#change-repository-list .repo-option.on')).toHaveCount(0);

  await dialog.getByLabel('Filter repositories', { exact: true }).fill('cab');
  await list.locator('[data-repo="mockuser/cabinet"]').click();
  await confirm.fill('Repository move');
  await submit.click();
  await expect(page.getByText('Repository move now uses mockuser/cabinet. Its tracks were closed and the machine is being rebuilt.', { exact: true })).toBeVisible({ timeout: 30_000 });
  await expect(dialog).toHaveCount(0);
  await expect(settings.locator('#change-repository-current')).toContainText('mockuser/cabinet');
  await expect(page.locator('#yard .workspace-project.current')).toContainText('No open tracks');

  await settings.locator('#settings-nav-general').click();
  await expect(settings.locator('#general-repository')).toContainText('mockuser/cabinet');

  // The machine clones the new repository and keeps its setup script and secret.
  const env = (await (await request.get(`${mock}/api/environments/${before.id}`)).json()).data;
  expect(env.setup_script).toBe('make deps');
  expect(env.repositories.map(r => r.url)).toEqual(['https://github.com/mockuser/cabinet.git']);
  const secrets = (await (await request.get(`${mock}/api/environments/${before.id}/secrets`)).json()).data;
  expect(secrets.map(s => s.key)).toContain('KEPT_SECRET');
});
