import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

test('project creation requires the selected agent and retains the submitted form', async ({ page }) => {
  await signIn(page, 'dana', '/home');
  await page.getByRole('button', { name: /^Quick start/ }).click();
  const dialog = page.getByRole('dialog', { name: 'New project' });
  await dialog.getByLabel('Project name', { exact: true }).fill('Credential gate');
  await dialog.getByLabel('Agent', { exact: true }).selectOption('codex');
  await dialog.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(dialog.locator('.field').filter({ has: page.locator('#project-runtime') }))
    .toContainText('Connect Codex before creating a project with it.');
  await expect(dialog.getByLabel('Project name', { exact: true })).toHaveValue('Credential gate');
  await expect(dialog.getByLabel('Agent', { exact: true })).toHaveValue('codex');
  await expect(dialog.getByRole('button', { name: 'Create project', exact: true })).toBeEnabled();
  await page.keyboard.press('Escape');
  await expect(dialog).not.toBeVisible();
  await connectClaude(page);
  await page.getByRole('button', { name: /^Quick start/ }).click();
  await dialog.getByLabel('Project name', { exact: true }).fill('Credential gate');
  await dialog.getByLabel('Agent', { exact: true }).selectOption('claude');
  await dialog.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(dialog).not.toBeVisible();
  await expect(page.locator('.crumbs')).toContainText('Credential gate');
});
