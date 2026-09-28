import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

test('project run script is inherited: run, ready, restart, stop and plain override', async ({ page }) => {
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: /^New project/ }).click();
  await page.getByLabel('Project name', { exact: true }).fill('Run script browser');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();

  await page.locator('.track-crumbs').getByRole('button', { name: 'Project settings', exact: true }).click();
  const settings = page.getByRole('dialog', { name: 'Project settings', exact: true });
  await settings.getByRole('button', { name: 'Run script', exact: true }).click();
  await settings.locator('#default-directory').fill('.');
  await settings.locator('#default-command').fill('npm run dev -- --port "$PORT" --strictPort');
  await settings.locator('#default-readiness').fill('/');
  await settings.getByRole('button', { name: 'Save defaults', exact: true }).click();
  await expect(page.getByText('Run script saved.', { exact: true })).toBeVisible();
  await settings.getByRole('button', { name: 'Close', exact: true }).click();

  await page.locator('button[phx-click="panel"][phx-value-name="preview"]').click();
  const status = page.locator('#run-status');
  const run = page.locator('button[phx-value-action="run"]');
  const restart = page.locator('button[phx-value-action="restart-run"]');
  const stop = page.locator('button[phx-value-action="stop"]');
  await expect(status).toHaveText('Status: stopped');
  await run.click();
  await expect(status).toHaveText('Status: ready');
  await expect(page.locator('button[phx-value-action="open"]')).toBeVisible();
  await restart.click();
  await expect(restart).toBeEnabled();
  await expect(status).toHaveText('Status: ready');
  await page.locator('button[phx-value-action="logs"]').click();
  await expect(page.locator('#preview-logs pre')).toContainText('VITE');
  await stop.click();
  await expect(status).toHaveText('Status: stopped');

  await page.getByText('Run script override', { exact: true }).click();
  await page.locator('#preview-path').fill('');
  await page.locator('#preview-config-form').getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.locator('#run-keeps-awake')).toHaveText("Keeps this track's machine awake while running");
  await run.click();
  await expect(status).toHaveText('Status: running');
  await expect(page.locator('button[phx-value-action="open"]')).toHaveCount(0);
  await expect(page.locator('iframe.workspace-preview')).toHaveCount(0);
  await stop.click();
  await expect(status).toHaveText('Status: stopped');
});
