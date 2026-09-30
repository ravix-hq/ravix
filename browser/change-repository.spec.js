import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openProjectSettings } from './settings.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

// RAV-76: a project's repository is changed from its Danger zone. It asks
// for the project's name, refuses a repository the Ravix GitHub App cannot
// read, and on success repoints the machine's clone, rebuilds it and closes
// the tracks, keeping the project's settings.
test('Danger zone changes the repository behind a typed confirmation', async ({ page, request }) => {
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

  // A machine setting that must survive the change, set on the mock's record.
  const before = (await (await request.get(`${mock}/api/environments`)).json()).data
    .filter(e => e.repositories?.some(r => r.url === 'https://github.com/mockuser/atlas-api.git'))
    .at(-1);
  await request.put(`${mock}/api/environments/${before.id}`, { data: { setup_script: 'make deps' } });

  const settings = await openProjectSettings(page, 'danger');
  const form = settings.locator('#change-repository-form');
  await expect(form.locator('#change-repository-current')).toContainText('mockuser/atlas-api');
  // The App's other repositories are suggested; the current one is not.
  await expect(form.locator('#change-repository-choices option[value="mockuser/cabinet"]')).toHaveCount(1);
  await expect(form.locator('#change-repository-choices option[value="mockuser/atlas-api"]')).toHaveCount(0);

  const repo = form.getByLabel('New repository', { exact: true });
  const confirm = form.getByLabel('Type Repository move to confirm changing the repository', { exact: true });
  const submit = form.getByRole('button', { name: 'Change repository', exact: true });
  await repo.fill('mockuser/cabinet');
  await expect(submit).toBeDisabled();
  await confirm.fill('Repository mov');
  await expect(submit).toBeDisabled();
  await confirm.fill('Repository move');
  await expect(submit).toBeEnabled();
  const axe = await new AxeBuilder({ page }).include('#settings-page')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(axe.violations).toEqual([]);

  // A repository the App cannot read changes nothing.
  await repo.fill('mockuser/not-installed');
  await submit.click();
  await expect(page.getByText(/cannot read that repository/)).toBeVisible();
  await expect(repo).toHaveValue('mockuser/not-installed');
  await expect(form.locator('#change-repository-current')).toContainText('mockuser/atlas-api');

  await repo.fill('mockuser/cabinet');
  await submit.click();
  await expect(page.getByText('Repository move now uses mockuser/cabinet. Its tracks were closed and the machine is being rebuilt.', { exact: true })).toBeVisible({ timeout: 30_000 });
  await expect(form.locator('#change-repository-current')).toContainText('mockuser/cabinet');
  await expect(repo).toHaveValue('');
  await expect(page.locator('#yard .workspace-project.current')).toContainText('No open tracks');

  await settings.locator('#settings-nav-general').click();
  await expect(settings.locator('#general-repository')).toContainText('mockuser/cabinet');

  // The machine clones the new repository and keeps its setup script.
  const env = (await (await request.get(`${mock}/api/environments/${before.id}`)).json()).data;
  expect(env.setup_script).toBe('make deps');
  expect(env.repositories.map(r => r.url)).toEqual(['https://github.com/mockuser/cabinet.git']);
});
