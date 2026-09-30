import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { openProjectSettings, saveMachine } from './settings.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

test('readable project variables add, edit, reject auth names and remove through Fountain', async ({ page, request }) => {
  await signIn(page, 'dana');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add repository', exact: true }).first().click();
  const create = page.getByRole('dialog', { name: 'Add repository' });
  await create.getByLabel('Project name', { exact: true }).fill('Readable variables browser');
  await create.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(create).not.toBeVisible();
  // RAV-74: variables are a part of the Machine page, saved with the rest.
  const dialog = await openProjectSettings(page, 'machine');
  const bar = page.locator('#project-machine-bar');
  await expect(dialog.locator('#machine-variables')).toContainText('Up to 100 variables');
  await dialog.getByRole('button', { name: 'Add variable', exact: true }).click();
  await dialog.getByLabel('Variable name', { exact: true }).fill('PORT');
  await dialog.getByLabel('Variable value', { exact: true }).fill('4321');
  await saveMachine(page, ['1 variable added']);
  const environments = (await (await request.get(`${mock}/api/environments`)).json()).data;
  const env = environments.find(e => e.env_vars.PORT === '4321');
  expect(env).toBeDefined();
  await dialog.getByLabel('Variable value', { exact: true }).fill('4322');
  await saveMachine(page, ['1 variable changed']);
  expect((await (await request.get(`${mock}/api/environments/${env.id}`)).json()).data.env_vars).toEqual({ PORT: '4322' });
  await dialog.getByLabel('Variable name', { exact: true }).fill('OPENAI_API_KEY');
  await bar.getByRole('button', { name: /^Save/ }).click();
  await expect(page.getByText('Use a secret if you intend to override billing with a provider auth variable.', { exact: true })).toBeVisible();
  await expect(page.locator('#machine-review')).toHaveCount(0);
  await expect(dialog.getByLabel('Variable name', { exact: true })).toHaveValue('OPENAI_API_KEY');
  await bar.getByRole('button', { name: 'Discard', exact: true }).click();
  await expect(dialog.getByLabel('Variable name', { exact: true })).toHaveValue('PORT');
  await dialog.getByRole('button', { name: 'Remove variable 1', exact: true }).click();
  await saveMachine(page, ['1 variable removed']);
  expect((await (await request.get(`${mock}/api/environments/${env.id}`)).json()).data.env_vars).toEqual({});
});
